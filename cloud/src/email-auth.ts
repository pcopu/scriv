import type { Env, User } from './types';
import { APIError, assert, body, challenge, json, randomToken, rateLimit, sha256, str, uuid } from './http';
import { sendLoginEmail } from './email';

const EXPIRY_MS = 10 * 60_000;
const RESEND_MS = 60_000;
const MAX_ATTEMPTS = 5;
const INVALID_CODE = 'This sign-in code is expired, used, or does not match this device. Request a new code if needed.';

/** Case-insensitive account policy; deliberately no provider-specific dot/plus rewriting. */
export function normalizeEmail(value: unknown): string {
  const email = str(value, 'email', 320).trim().toLowerCase();
  const parts = email.split('@'), [local, domain] = parts;
  assert(email.length <= 254 && parts.length === 2 && local && local.length <= 64 && domain &&
    /^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+$/.test(local) && !local.startsWith('.') && !local.endsWith('.') && !local.includes('..') &&
    domain.includes('.') && domain.split('.').every(label => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label)),
    400, 'invalid_email', 'Enter a valid email address.');
  return email;
}

/** Rejection sampling avoids modulo bias; Math.random is never an authentication source. */
export function randomEmailCode(): string {
  const sample = new Uint32Array(1);
  do { crypto.getRandomValues(sample); } while (sample[0]! >= 4_294_000_000);
  return String(sample[0]! % 1_000_000).padStart(6, '0');
}

async function ipLimit(request: Request, env: Env, action: string, limit: number): Promise<void> {
  // Store neither client IPs nor email addresses in rate-limit keys.
  await rateLimit(env, `email-${action}-ip:${await sha256(request.headers.get('cf-connecting-ip') ?? 'local')}`, limit, EXPIRY_MS);
}

async function requestCode(request: Request, env: Env): Promise<Response> {
  await ipLimit(request, env, 'request', 20);
  assert(env.EMAIL && env.EMAIL_FROM, 503, 'auth_not_configured', 'Email sign-in is not configured on this server.');
  const input = await body(request, 4096);
  const email = normalizeEmail(input.email);
  const pkce = str(input.codeChallenge, 'codeChallenge', 43, 43);
  assert(/^[A-Za-z0-9_-]{43}$/.test(pkce), 400, 'invalid_challenge', 'A SHA-256 PKCE challenge is required.');
  await rateLimit(env, `email-request-address:${await sha256(email)}`, 5, 3_600_000);
  // Leave headroom under the initial provider quota. No request path looks up an account.
  await rateLimit(env, 'email-request-global', 900, 86_400_000);
  const now = Date.now(), challengeId = randomToken(), code = randomEmailCode();
  const idHash = await sha256(challengeId);
  // The random challenge ID is only returned to the initiating client, not persisted.
  // Including it in the digest also prevents offline guessing of six-digit codes
  // from a database-only disclosure. The database stores no plaintext codes.
  const codeHash = await sha256(`${challengeId}:${code}`);
  const reserved = await env.DB.prepare(`INSERT INTO email_auth_challenges
    (id_hash,email,pkce_challenge,code_hash,created_at,expires_at) VALUES(?,?,?,?,?,?)
    ON CONFLICT(email,pkce_challenge) DO UPDATE SET
      id_hash=excluded.id_hash,code_hash=excluded.code_hash,created_at=excluded.created_at,
      expires_at=excluded.expires_at,sent_at=NULL,attempts=0,consumed_by=NULL
    WHERE email_auth_challenges.created_at<=? RETURNING id_hash`)
    .bind(idHash,email,pkce,codeHash,now,now+EXPIRY_MS,now-RESEND_MS).first<{id_hash:string}>();
  assert(reserved, 429, 'rate_limited', 'Please wait one minute before requesting another code.');
  try {
    await sendLoginEmail(env,email,code);
    await env.DB.prepare('UPDATE email_auth_challenges SET sent_at=? WHERE id_hash=? AND consumed_by IS NULL')
      .bind(Date.now(),idHash).run();
  } catch {
    // A send might have been accepted before its response failed. Fail closed,
    // retain the resend cooldown, and never reflect/log provider errors or PII.
    await env.DB.prepare("UPDATE email_auth_challenges SET code_hash=NULL,consumed_by='send_failed' WHERE id_hash=?")
      .bind(idHash).run();
    throw new APIError(503, 'email_unavailable', 'Email sign-in is temporarily unavailable. Please wait a minute and retry.');
  }
  return json({challengeId,expiresAt:now+EXPIRY_MS,resendAt:now+RESEND_MS},202);
}

async function verifyCode(request: Request, env: Env): Promise<Response> {
  await ipLimit(request, env, 'verify', 30);
  const input = await body(request, 4096);
  const challengeId = str(input.challengeId, 'challengeId', 43, 43);
  assert(/^[A-Za-z0-9_-]{43}$/.test(challengeId),400,'invalid_field','Invalid sign-in challenge.');
  const code = str(input.code, 'code', 6, 6);
  assert(/^[0-9]{6}$/.test(code),400,'invalid_field','Enter the six-digit sign-in code.');
  const verifier = str(input.codeVerifier, 'codeVerifier', 128, 43);
  assert(/^[A-Za-z0-9._~-]+$/.test(verifier),400,'invalid_verifier','PKCE verifier contains unsupported characters.');
  const idHash = await sha256(challengeId);
  const candidate = await env.DB.prepare('SELECT email FROM email_auth_challenges WHERE id_hash=?').bind(idHash).first<{email:string}>();
  if (candidate) await rateLimit(env, `email-verify-address:${await sha256(candidate.email)}`, 20, EXPIRY_MS);
  const codeHash = await sha256(`${challengeId}:${code}`), pkce = await challenge(verifier);
  const now = Date.now(), userId = uuid(), sessionId = uuid(), token = randomToken(48), consumeId = randomToken();
  const tokenHash = await sha256(token), expiresAt = now + Math.max(1,Math.min(90,Number(env.SESSION_DAYS)||30))*86_400_000;
  const deviceName = typeof input.deviceName === 'string' ? input.deviceName.slice(0,100) : 'Mac';
  // D1 batch is transactional. Increment/check attempts and consume atomically,
  // then condition every identity/session write on this request's unique marker.
  // A rollback preserves the challenge; a replay/race cannot mint two sessions.
  const result = await env.DB.batch([
    env.DB.prepare(`UPDATE email_auth_challenges SET attempts=attempts+1,
      consumed_by=CASE WHEN code_hash=? AND pkce_challenge=? THEN ? ELSE NULL END
      WHERE id_hash=? AND consumed_by IS NULL AND sent_at IS NOT NULL AND expires_at>? AND attempts<?
      RETURNING consumed_by`)
      .bind(codeHash,pkce,consumeId,idHash,now,MAX_ATTEMPTS),
    env.DB.prepare(`INSERT INTO users(id,github_id,name,email,created_at)
      SELECT ?,?,'Scriv user',c.email,? FROM email_auth_challenges c
      WHERE c.id_hash=? AND c.consumed_by=? AND NOT EXISTS(SELECT 1 FROM email_identities e WHERE e.email=c.email)`)
      .bind(userId,`email:${userId}`,now,idHash,consumeId),
    env.DB.prepare(`INSERT INTO email_identities(email,user_id,verified_at)
      SELECT c.email,?,? FROM email_auth_challenges c
      WHERE c.id_hash=? AND c.consumed_by=? AND NOT EXISTS(SELECT 1 FROM email_identities e WHERE e.email=c.email)`)
      .bind(userId,now,idHash,consumeId),
    env.DB.prepare(`INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at)
      SELECT ?,?,e.user_id,?,?,? FROM email_auth_challenges c JOIN email_identities e ON e.email=c.email
      WHERE c.id_hash=? AND c.consumed_by=?`)
      .bind(tokenHash,sessionId,deviceName,now,expiresAt,idHash,consumeId),
    env.DB.prepare(`SELECT u.id,u.name,u.email,u.avatar_url avatarUrl FROM users u JOIN sessions s ON s.user_id=u.id WHERE s.token_hash=?`)
      .bind(tokenHash)
  ]);
  const user = result[4]?.results[0] as unknown as User | undefined;
  assert(user,401,'invalid_code',INVALID_CODE);
  return json({token,expiresAt,user});
}

export async function emailAuthRoutes(request: Request, env: Env): Promise<Response | null> {
  const path = new URL(request.url).pathname;
  if (request.method !== 'POST' || !['/auth/email/request','/auth/email/verify'].includes(path)) return null;
  // Native requests omit Origin. Browsers must be same-origin and use JSON so a
  // cross-site form/no-cors request cannot turn this endpoint into a mail sender.
  assert(request.headers.get('content-type')?.split(';')[0]?.trim().toLowerCase() === 'application/json',
    415,'unsupported_media_type','Email sign-in requires a JSON request.');
  const origin = request.headers.get('origin');
  assert(origin === null || origin === new URL(env.PUBLIC_URL).origin,403,'invalid_origin','Email sign-in must start from this service or the Scriv app.');
  return path === '/auth/email/request' ? requestCode(request,env) : verifyCode(request,env);
}
