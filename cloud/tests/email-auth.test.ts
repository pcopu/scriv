import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { env as bindings } from 'cloudflare:workers';
import { applyD1Migrations, reset } from 'cloudflare:test';
import worker from '../src/index';
import type { Env } from '../src/types';
import { challenge, randomToken, sha256 } from '../src/http';
import { normalizeEmail, randomEmailCode } from '../src/email-auth';

const env = bindings as unknown as Env & { TEST_MIGRATIONS: any[] };
const NOW = 1_800_000_100_000;
let now: number;
let sent: EmailMessageBuilder[];
let testEnv: Env;
let send: ReturnType<typeof vi.fn>;
const verifier = 'v'.repeat(50);
const ctx = {waitUntil() {},passThroughOnException() {}} as unknown as ExecutionContext;
beforeEach(async () => {
  await applyD1Migrations(env.DB,env.TEST_MIGRATIONS);
  now = NOW; sent = [];
  vi.spyOn(Date,'now').mockImplementation(() => now);
  send = vi.fn(async (message: EmailMessageBuilder) => { sent.push(message); return {messageId:'mock-message'}; });
  testEnv = {...env, EMAIL: {send} as SendEmail, EMAIL_FROM:'login@scriv.example'};
});
afterEach(async () => { vi.restoreAllMocks(); await reset(); });
async function call(path: string, payload: unknown, ip = '192.0.2.1', selectedEnv = testEnv) {
  const response = await worker.fetch(new Request(`https://scriv.test${path}`,{method:'POST',headers:{'content-type':'application/json','cf-connecting-ip':ip},body:JSON.stringify(payload)}),selectedEnv,ctx);
  return {response,status:response.status,data:await response.json<any>()};
}
async function request(email = 'alex@example.com', selectedVerifier = verifier, ip = '192.0.2.1') {
  return call('/auth/email/request',{email,codeChallenge:await challenge(selectedVerifier)},ip);
}
function mailCode(index = sent.length-1): string { return /\b[0-9]{6}\b/.exec(sent[index]!.text!)![0]; }
async function start(email = 'alex@example.com', selectedVerifier = verifier, ip = '192.0.2.1') {
  const r = await request(email,selectedVerifier,ip); expect(r.status).toBe(202);
  return {...r.data,code:mailCode(),codeVerifier:selectedVerifier};
}
async function verify(started: any, overrides: Record<string,unknown> = {}, ip = '192.0.2.1') {
  return call('/auth/email/verify',{...started,deviceName:'Test Mac',...overrides},ip);
}
async function count(table: string) { return (await env.DB.prepare(`SELECT COUNT(*) n FROM ${table}`).first<{n:number}>())!.n; }
async function row(id: string) { return env.DB.prepare('SELECT * FROM email_auth_challenges WHERE id_hash=?').bind(await sha256(id)).first<any>(); }

describe('email sign-in', () => {
  it('sends only the fixed transactional template, persists no plaintext secrets, and authenticates once', async () => {
    const started = await start('  ALEX@Example.COM  ');
    expect(started.challengeId).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(started.expiresAt).toBe(NOW+600_000); expect(started.resendAt).toBe(NOW+60_000);
    expect(sent[0]).toMatchObject({to:'alex@example.com',from:{email:'login@scriv.example',name:'Scriv'},subject:'Your Scriv sign-in code'});
    expect(sent[0]!.html).toContain(started.code); expect(sent[0]).not.toHaveProperty('cc');
    const stored = await row(started.challengeId);
    expect(stored.id_hash).toBe(await sha256(started.challengeId));
    expect(stored.code_hash).toBe(await sha256(`${started.challengeId}:${started.code}`));
    expect(JSON.stringify(stored)).not.toContain(started.challengeId); expect(stored).not.toHaveProperty('code');
    expect(await count('users')).toBe(0); expect(await count('email_identities')).toBe(0);
    const accepted = await verify(started);
    expect(accepted.status).toBe(200); expect(accepted.response.headers.get('cache-control')).toBe('no-store');
    expect(accepted.data.user).toMatchObject({name:'Scriv user',email:'alex@example.com',avatarUrl:null});
    expect(accepted.data.token).toHaveLength(64); expect(accepted.data.expiresAt).toBe(NOW+30*86_400_000);
    const session = await env.DB.prepare('SELECT * FROM sessions').first<any>();
    expect(session.token_hash).toBe(await sha256(accepted.data.token)); expect(session.device_name).toBe('Test Mac');
    const me = await worker.fetch(new Request('https://scriv.test/v1/me',{headers:{authorization:`Bearer ${accepted.data.token}`}}),testEnv,ctx);
    expect(me.status).toBe(200); expect((await me.json<any>()).user.id).toBe(accepted.data.user.id);
    expect((await verify(started)).data.error.code).toBe('invalid_code'); expect(await count('sessions')).toBe(1);
    const limits = await env.DB.prepare('SELECT key FROM security_limits').all<{key:string}>();
    expect(limits.results.every(r => !r.key.includes('alex@') && !r.key.includes('192.0.2.1'))).toBe(true);
  });

  it('keeps Github contact emails separate, preserves their sessions, and reuses only verified email identity', async () => {
    await env.DB.prepare("INSERT INTO users(id,github_id,name,email,created_at) VALUES('legacy','1234','Legacy','alex@example.com',?)").bind(now).run();
    await env.DB.prepare("INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at) VALUES(?,'legacy-session','legacy','Mac',?,?)").bind(await sha256('legacy-token'),now,now+86_400_000).run();
    const first = await verify(await start()), second = await verify(await start('ALEX@example.com','w'.repeat(50)));
    expect(first.status).toBe(200); expect(first.data.user.id).not.toBe('legacy');
    expect(second.data.user.id).toBe(first.data.user.id); expect(await count('users')).toBe(2);
    expect(await count('email_identities')).toBe(1); expect(await count('sessions')).toBe(3);
    const legacy = await worker.fetch(new Request('https://scriv.test/v1/me',{headers:{authorization:'Bearer legacy-token'}}),testEnv,ctx);
    expect(legacy.status).toBe(200); expect((await legacy.json<any>()).user.id).toBe('legacy');
  });

  it('atomically permits only one winner for parallel replay', async () => {
    const started = await start();
    const results = await Promise.all(Array.from({length:10},() => verify(started)));
    expect(results.filter(r=>r.status===200)).toHaveLength(1); expect(results.filter(r=>r.status===401)).toHaveLength(9);
    expect(await count('users')).toBe(1); expect(await count('sessions')).toBe(1);
  });

  it('converges concurrent device sign-ins on one identity without orphan users', async () => {
    const a = await start(), b = await start('alex@example.com','w'.repeat(50));
    const results = await Promise.all([verify(a),verify(b)]);
    expect(results.map(r=>r.status)).toEqual([200,200]); expect(results[0]!.data.user.id).toBe(results[1]!.data.user.id);
    expect(await count('users')).toBe(1); expect(await count('email_identities')).toBe(1); expect(await count('sessions')).toBe(2);
  });

  it('rejects PKCE mismatch and locks after exactly five failed attempts, including concurrent guesses', async () => {
    const started = await start();
    expect((await verify(started,{codeVerifier:'w'.repeat(50)})).status).toBe(401);
    const wrongCode = started.code === '000000' ? '000001' : '000000';
    const failed = await Promise.all(Array.from({length:7},() => verify(started,{code:wrongCode})));
    expect(failed.every(r=>r.status===401)).toBe(true); expect((await row(started.challengeId)).attempts).toBe(5);
    expect((await verify(started)).status).toBe(401); expect(await count('users')).toBe(0); expect(await count('sessions')).toBe(0);
  });

  it('allows the fifth attempt to succeed but rejects at the exact expiry boundary', async () => {
    const started = await start();
    for (let i=0;i<4;i++) expect((await verify(started,{code:started.code==='000000'?'000001':'000000'})).status).toBe(401);
    expect((await verify(started)).status).toBe(200);
    const expiring = await start('expires@example.com'); now = expiring.expiresAt;
    expect((await verify(expiring)).status).toBe(401); expect((await row(expiring.challengeId)).attempts).toBe(0);
  });

  it('enforces exact resend cooldown, invalidates only this device, and serializes concurrent resends', async () => {
    const a = await start(), b = await start('alex@example.com','w'.repeat(50));
    now = NOW+59_999; expect((await request()).status).toBe(429); expect(sent).toHaveLength(2);
    now = NOW+60_000; const attempts = await Promise.all([request(),request()]);
    expect(attempts.map(r=>r.status).sort()).toEqual([202,429]); expect(sent).toHaveLength(3);
    expect((await verify(a)).status).toBe(401); expect((await verify(b)).status).toBe(200);
    const fresh = attempts.find(r=>r.status===202)!.data;
    expect((await verify({...fresh,code:mailCode(),codeVerifier:verifier})).status).toBe(200);
  });

  it('returns the same acceptance envelope for a new and existing email account', async () => {
    await verify(await start()); now += 60_000;
    const existing = await request(), fresh = await request('fresh@example.com');
    expect(existing.status).toBe(fresh.status); expect(Object.keys(existing.data)).toEqual(Object.keys(fresh.data));
    expect(existing.data.expiresAt).toBe(fresh.data.expiresAt); expect(existing.data).not.toHaveProperty('user');
  });
});

describe('email authentication abuse and failure boundaries', () => {
  it('normalizes a conservative ASCII mailbox and rejects injection, malformed values, and invalid PKCE', async () => {
    expect(normalizeEmail(' A+tag@EXAMPLE.com ')).toBe('a+tag@example.com');
    for (const email of ['a@example.com\r\nBcc:victim@example.com','a@@example.com','a@example.com@','a@example.com@@other','a..b@example.com','.a@example.com','a@-example.com','a@localhost','a@ex..com','a'.repeat(65)+'@example.com']) {
      expect((await request(email)).status).toBe(400);
    }
    expect((await call('/auth/email/request',{email:'alex@example.com',codeChallenge:'!'.repeat(43)})).status).toBe(400);
    expect(send).not.toHaveBeenCalled(); expect(await count('email_auth_challenges')).toBe(0);
  });

  it('bounds requests by normalized email across devices and IPs without querying account existence', async () => {
    for(let i=0;i<5;i++) expect((await request('ALEX@example.com',String(i).repeat(50),`192.0.2.${i+1}`)).status).toBe(202);
    expect((await request('alex@example.com','z'.repeat(50),'192.0.2.99')).status).toBe(429); expect(sent).toHaveLength(5);
  });

  it('bounds per-IP requests and verification of unknown challenges', async () => {
    for(let i=0;i<20;i++) expect((await request(`person${i}@example.com`)).status).toBe(202);
    expect((await request('overflow@example.com')).status).toBe(429); expect(sent).toHaveLength(20);
    const unknown = {challengeId:randomToken(),code:'123456',codeVerifier:verifier};
    for(let i=0;i<30;i++) expect((await verify(unknown)).status).toBe(401);
    expect((await verify(unknown)).status).toBe(429);
  });

  it('bounds verification by email across challenges and source IPs', async () => {
    const all = [];
    for(let i=0;i<5;i++) all.push(await start('alex@example.com',String(i).repeat(50),`192.0.2.${i+1}`));
    for(let i=0;i<20;i++) {
      const c = all[Math.floor(i/5)]!;
      expect((await verify(c,{code:c.code==='000000'?'000001':'000000'},`198.51.100.${i+1}`)).status).toBe(401);
    }
    expect((await verify(all[4],{},'198.51.100.99')).status).toBe(429); expect(await count('sessions')).toBe(0);
  });

  it('enforces a bounded global send quota and resets fixed-window limits at their boundary', async () => {
    const bucket = Math.floor(now/86_400_000);
    await env.DB.prepare('INSERT INTO security_limits(key,count,expires_at) VALUES(?,?,?)').bind(`email-request-global:${bucket}`,899,(bucket+2)*86_400_000).run();
    expect((await request()).status).toBe(202); expect((await request('other@example.com')).status).toBe(429);
    now=(bucket+1)*86_400_000; expect((await request('other@example.com')).status).toBe(202);
  });

  it('fails closed when mail fails, keeps the resend cooldown, and never logs provider details', async () => {
    const log = vi.spyOn(console,'error').mockImplementation(()=>{});
    let intercepted: EmailMessageBuilder | undefined;
    send.mockImplementationOnce(async (message: EmailMessageBuilder) => { intercepted=message; throw new Error(`Sensitive provider error ${message.to}: ${message.text}`); });
    const response = await request(); expect(response.status).toBe(503); expect(response.data.error.code).toBe('email_unavailable');
    expect(JSON.stringify(response.data)).not.toContain('alex@example.com'); expect(JSON.stringify(response.data)).not.toContain(intercepted!.text!);
    expect(log).not.toHaveBeenCalled(); const stored = await env.DB.prepare('SELECT * FROM email_auth_challenges').first<any>();
    expect(stored.code_hash).toBeNull(); expect(stored.sent_at).toBeNull(); expect(stored.consumed_by).toBe('send_failed');
    expect((await request()).status).toBe(429); expect(await count('users')).toBe(0);
    now+=60_000; expect((await request()).status).toBe(202);
  });

  it('does not activate a code while the send is still pending', async () => {
    let release!: () => void; let entered!: () => void;
    const ready = new Promise<void>(r=>entered=r), pending = new Promise<void>(r=>release=r);
    send.mockImplementationOnce(async (message: EmailMessageBuilder)=>{sent.push(message);entered();await pending;return{messageId:'mock'};});
    const requesting = request(); await ready;
    const stored = await env.DB.prepare('SELECT * FROM email_auth_challenges').first<any>(); expect(stored.sent_at).toBeNull();
    expect(await count('users')).toBe(0); release(); expect((await requesting).status).toBe(202);
  });

  it('rolls back consume and identity creation together on session persistence failure, allowing a safe retry', async () => {
    const started = await start();
    await env.DB.exec("CREATE TRIGGER reject_test_session BEFORE INSERT ON sessions BEGIN SELECT RAISE(ABORT,'test_session_failure'); END;");
    vi.spyOn(console,'error').mockImplementation(()=>{});
    expect((await verify(started)).status).toBe(500); expect((await row(started.challengeId)).consumed_by).toBeNull();
    expect((await row(started.challengeId)).attempts).toBe(0); expect(await count('users')).toBe(0); expect(await count('email_identities')).toBe(0);
    await env.DB.exec('DROP TRIGGER reject_test_session;'); expect((await verify(started)).status).toBe(200);
  });

  it('rejects browser cross-origin and simple-form mail requests without sending', async () => {
    for (const headers of [{'content-type':'text/plain'},{'content-type':'application/json',origin:'https://other.example'},{'content-type':'application/json',origin:'null'}]) {
      const response = await worker.fetch(new Request('https://scriv.test/auth/email/request',{method:'POST',headers,body:JSON.stringify({email:'alex@example.com',codeChallenge:await challenge(verifier)})}),testEnv,ctx);
      expect([403,415]).toContain(response.status);
    }
    expect(send).not.toHaveBeenCalled(); expect(await count('email_auth_challenges')).toBe(0);
    const allowed = await worker.fetch(new Request('https://scriv.test/auth/email/request',{method:'POST',headers:{'content-type':'application/json; charset=utf-8',origin:'https://scriv.test'},body:JSON.stringify({email:'alex@example.com',codeChallenge:await challenge(verifier)})}),testEnv,ctx);
    expect(allowed.status).toBe(202);
  });

  it('rejects missing configuration and oversized bodies before sending', async () => {
    const unavailable = await call('/auth/email/request',{email:'alex@example.com',codeChallenge:await challenge(verifier)},'192.0.2.1',{...testEnv,EMAIL:undefined});
    expect(unavailable.status).toBe(503); expect(unavailable.data.error.code).toBe('auth_not_configured');
    expect((await call('/auth/email/request',{email:'x'.repeat(5000)})).status).toBe(413); expect(send).not.toHaveBeenCalled();
  });

  it('keeps pre-migration users, sessions, projects and memberships unchanged', async () => {
    await reset();
    await applyD1Migrations(env.DB,env.TEST_MIGRATIONS.slice(0,2));
    await env.DB.prepare("INSERT INTO users(id,github_id,name,email,created_at) VALUES('existing','9876','Original','alex@example.com',?)").bind(now).run();
    await env.DB.prepare("INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at) VALUES(?,'old-session','existing','Mac',?,?)").bind(await sha256('old-token'),now,now+86_400_000).run();
    await env.DB.prepare("INSERT INTO teams(id,name,owner_id,created_at) VALUES('old-team','Original team','existing',?)").bind(now).run();
    await env.DB.prepare("INSERT INTO team_members(team_id,user_id,role,joined_at) VALUES('old-team','existing','owner',?)").bind(now).run();
    await env.DB.prepare("INSERT INTO projects(id,title,owner_id,team_id,created_at,updated_at) VALUES('old-project','Film','existing','old-team',?,?)").bind(now,now).run();
    const before = await env.DB.batch(['users','sessions','teams','team_members','projects'].map(table=>env.DB.prepare(`SELECT * FROM ${table}`)));
    await applyD1Migrations(env.DB,env.TEST_MIGRATIONS);
    const after = await env.DB.batch(['users','sessions','teams','team_members','projects'].map(table=>env.DB.prepare(`SELECT * FROM ${table}`)));
    expect(after.map(r=>r.results)).toEqual(before.map(r=>r.results));
    expect(await count('email_identities')).toBe(0); expect(await count('email_auth_challenges')).toBe(0);
    expect((await env.DB.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
    const original = await worker.fetch(new Request('https://scriv.test/v1/me',{headers:{authorization:'Bearer old-token'}}),testEnv,ctx);
    expect(original.status).toBe(200); expect((await original.json<any>()).user.id).toBe('existing');
  });

  it('removes expired and consumed challenge PII during existing scheduled maintenance', async () => {
    const expired = await start('expired@example.com'), consumed = await start('used@example.com');
    await verify(consumed);
    now+=60_000; const live = await start('live@example.com'); now=expired.expiresAt;
    let work: Promise<unknown> | undefined;
    await worker.scheduled({} as ScheduledController,testEnv,{waitUntil(p:Promise<unknown>){work=p;}} as ExecutionContext);
    await work;
    expect(await row(expired.challengeId)).toBeNull(); expect(await row(consumed.challengeId)).toBeNull();
    expect(await row(live.challengeId)).not.toBeNull(); expect(await count('email_identities')).toBe(1);
  });

  it('uses secure rejection sampling including the upper excluded range and zero-padding', () => {
    const randomness = vi.spyOn(crypto,'getRandomValues');
    randomness.mockImplementationOnce((a:any)=>{a[0]=4_294_967_295;return a;});
    randomness.mockImplementationOnce((a:any)=>{a[0]=7;return a;});
    expect(randomEmailCode()).toBe('000007'); expect(randomness).toHaveBeenCalledTimes(2);
  });
});
