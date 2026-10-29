import { emailAuthRoutes } from './email-auth';
import { refreshUserAccess } from './notifications';
import type { Env } from './types';
import { authenticate } from './access';
import { APIError, assert, body, challenge, json, publicBase, randomToken, rateLimit, sha256, str, uuid } from './http';

export async function authRoutes(request: Request, env: Env): Promise<Response | null> {
  const url = new URL(request.url); const path = url.pathname;
  if (path.startsWith('/auth/email/')) return emailAuthRoutes(request,env);
  if (path === '/auth/github/start' && request.method === 'GET') {
    assert(env.GITHUB_CLIENT_ID && env.GITHUB_CLIENT_SECRET,503,'auth_not_configured','Scriv sign-in is not configured on this server.');
    await rateLimit(env,`oauth:${request.headers.get('cf-connecting-ip') ?? 'local'}`,30,600000);
    const codeChallenge = str(url.searchParams.get('codeChallenge'),'codeChallenge',43,43);
    assert(/^[A-Za-z0-9_-]{43}$/.test(codeChallenge),400,'invalid_challenge','A SHA-256 PKCE challenge is required.');
    const clientState = str(url.searchParams.get('state'),'state',128,16);
    const state = randomToken();
    await env.DB.prepare('INSERT INTO oauth_states(state_hash,client_state,challenge,expires_at) VALUES(?,?,?,?)')
      .bind(await sha256(state),clientState,codeChallenge,Date.now()+600000).run();
    const redirect = new URL('https://github.com/login/oauth/authorize');
    redirect.searchParams.set('client_id',env.GITHUB_CLIENT_ID);
    redirect.searchParams.set('redirect_uri',`${publicBase(env)}/auth/github/callback`);
    redirect.searchParams.set('scope','read:user user:email'); redirect.searchParams.set('state',state);
    return Response.redirect(redirect.toString(),302);
  }
  if (path === '/auth/github/callback' && request.method === 'GET') {
    const state = str(url.searchParams.get('state'),'state',128);
    const stored = await env.DB.prepare('DELETE FROM oauth_states WHERE state_hash=? AND expires_at>? RETURNING client_state,challenge')
      .bind(await sha256(state),Date.now()).first<{client_state:string;challenge:string}>();
    assert(stored,400,'oauth_expired','This sign-in has expired. Start sign-in again from Scriv.');
    const callback = new URL('scriv://auth/callback'); callback.searchParams.set('state',stored.client_state);
    if (url.searchParams.has('error')) { callback.searchParams.set('error','access_denied'); return Response.redirect(callback.toString(),302); }
    const code = str(url.searchParams.get('code'),'code',512);
    assert(env.GITHUB_CLIENT_ID && env.GITHUB_CLIENT_SECRET,503,'auth_not_configured','Scriv sign-in is not configured.');
    const tokenResponse = await fetch('https://github.com/login/oauth/access_token',{
      method:'POST',headers:{'accept':'application/json','content-type':'application/json'},
      body:JSON.stringify({client_id:env.GITHUB_CLIENT_ID,client_secret:env.GITHUB_CLIENT_SECRET,code,redirect_uri:`${publicBase(env)}/auth/github/callback`})
    });
    const githubToken = await tokenResponse.json<{access_token?:string}>();
    assert(tokenResponse.ok && githubToken.access_token,502,'provider_error','GitHub could not complete sign-in. Please retry.');
    const headers = {'authorization':`Bearer ${githubToken.access_token}`,'user-agent':'Scriv','accept':'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28'};
    const response = await fetch('https://api.github.com/user',{headers});
    assert(response.ok,502,'provider_error','GitHub profile could not be loaded.');
    const profile = await response.json<{id:number;login:string;name?:string;email?:string;avatar_url?:string}>();
    assert(Number.isSafeInteger(profile.id) && profile.login,502,'provider_error','GitHub returned an invalid profile.');
    let email = profile.email ?? null;
    if (!email) {
      const emailResponse = await fetch('https://api.github.com/user/emails',{headers});
      if (emailResponse.ok) { const emails = await emailResponse.json<{email:string;primary:boolean;verified:boolean}[]>(); email = emails.find(e=>e.primary&&e.verified)?.email ?? null; }
    }
    const userId = uuid();
    const user = await env.DB.prepare(`INSERT INTO users(id,github_id,name,email,avatar_url,created_at) VALUES(?,?,?,?,?,?) ON CONFLICT(github_id) DO UPDATE SET name=excluded.name,email=excluded.email,avatar_url=excluded.avatar_url RETURNING id`)
      .bind(userId,String(profile.id),(profile.name||profile.login).slice(0,200),email,profile.avatar_url??null,Date.now()).first<{id:string}>();
    assert(user,500,'storage_error','Sign-in could not be saved.');
    const exchangeCode = randomToken();
    await env.DB.prepare('INSERT INTO auth_codes(code_hash,user_id,challenge,expires_at) VALUES(?,?,?,?)')
      .bind(await sha256(exchangeCode),user.id,stored.challenge,Date.now()+120000).run();
    callback.searchParams.set('code',exchangeCode);
    return Response.redirect(callback.toString(),302);
  }
  if (path === '/auth/exchange' && request.method === 'POST') {
    await rateLimit(env,`exchange:${request.headers.get('cf-connecting-ip')??'local'}`,30,600000);
    const input = await body(request,4096);
    const code = str(input.code,'code',128,32); const verifier = str(input.codeVerifier,'codeVerifier',128,43);
    assert(/^[A-Za-z0-9._~-]+$/.test(verifier),400,'invalid_verifier','PKCE verifier contains unsupported characters.');
    const stored = await env.DB.prepare('DELETE FROM auth_codes WHERE code_hash=? AND challenge=? AND expires_at>? RETURNING user_id')
      .bind(await sha256(code),await challenge(verifier),Date.now()).first<{user_id:string}>();
    assert(stored,401,'invalid_code','This sign-in code is expired, used, or does not match this device.');
    const token = randomToken(48); const now = Date.now(); const days = Math.max(1,Math.min(90,Number(env.SESSION_DAYS)||30));
    const expiresAt = now+days*86400000;
    await env.DB.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at) VALUES(?,?,?,?,?,?)')
      .bind(await sha256(token),uuid(),stored.user_id,typeof input.deviceName==='string'?input.deviceName.slice(0,100):'Mac',now,expiresAt).run();
    const user = await env.DB.prepare('SELECT id,name,email,avatar_url avatarUrl FROM users WHERE id=?').bind(stored.user_id).first();
    return json({token,expiresAt,user});
  }
  if (path === '/auth/logout' && request.method === 'POST') {
    const identity = await authenticate(request,env);
    await env.DB.prepare('UPDATE sessions SET revoked_at=? WHERE token_hash=?').bind(Date.now(),identity.tokenHash).run();
    await refreshUserAccess(env,identity.user.id,identity.sessionId);return json({ok:true});
  }
  if (path === '/auth/sessions' && request.method === 'GET') {
    const identity = await authenticate(request,env);
    const sessions = await env.DB.prepare('SELECT id,device_name deviceName,created_at createdAt,expires_at expiresAt FROM sessions WHERE user_id=? AND revoked_at IS NULL AND expires_at>?').bind(identity.user.id,Date.now()).all();
    return json({sessions:sessions.results,currentSessionId:identity.sessionId});
  }
  const sessionMatch = /^\/auth\/sessions\/([^/]+)$/.exec(path);
  if (sessionMatch && request.method === 'DELETE') {
    const identity = await authenticate(request,env);
    await env.DB.prepare('UPDATE sessions SET revoked_at=? WHERE id=? AND user_id=?').bind(Date.now(),sessionMatch[1],identity.user.id).run();
    await refreshUserAccess(env,identity.user.id,sessionMatch[1]);return json({ok:true});
  }
  return null;
}
