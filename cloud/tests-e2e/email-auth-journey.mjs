// Real HTTP service-process integration; not Catalyst/native application E2E.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, rm, readFile, readdir, copyFile, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, isAbsolute } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';

process.on('uncaughtException', error => { console.error('Email authentication journey failed at: ' + (error.stack?.split('\n').find(line => line.trimStart().startsWith('at ')) ?? 'unknown')); process.exitCode = 1; });
if (process.argv[2] !== '--owned-child' && (!process.env.SCRIV_TRACER_RUNTIME || !isAbsolute(process.env.SCRIV_TRACER_RUNTIME))) { console.error('Set SCRIV_TRACER_RUNTIME to the absolute path of the reviewed local Tracer runtime.'); process.exit(2); }
const here = await realpath(dirname(fileURLToPath(import.meta.url)));
// --cloud supports an outside-repository candidate without changing its sources.
const cloud = await realpath(process.argv[2] === '--owned-child' ? process.argv[4] :
  process.argv[2] === '--cloud' ? process.argv[3] : join(here, '..'));
const self = await realpath(fileURLToPath(import.meta.url));
if (process.argv[2] !== '--owned-child') {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'scriv-email-auth-')));
  let child;
  let timer;
  const killOwned = signal => {
    if (child?.pid) {
      try { process.kill(-child.pid, signal); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    }
  };
  const interrupt = () => killOwned('SIGTERM');
  try {
    for (const name of ['home', 'tmp', 'state']) await mkdir(join(root, name), { mode: 0o700 });
    // Resolve installed dependencies from an owned runner, never edit the repository.
    await copyFile(self, join(root, 'runner.mjs'));
    await symlink(await realpath(join(cloud, 'node_modules')), join(root, 'node_modules'), 'dir');
    child = spawn(process.execPath, [join(root, 'runner.mjs'), '--owned-child', root, cloud], {
      cwd: root, detached: true, stdio: 'inherit',
      // Deliberately no inherited credentials, proxy settings, config, or NODE_OPTIONS.
      env: { PATH: dirname(process.execPath), HOME: join(root, 'home'), TMPDIR: join(root, 'tmp'),
        XDG_CONFIG_HOME: join(root, 'home'), XDG_CACHE_HOME: join(root, 'home'),
        WRANGLER_SEND_METRICS: 'false', CI: '1', SCRIV_TRACER_RUNTIME: process.env.SCRIV_TRACER_RUNTIME },
    });
    process.on('SIGINT', interrupt); process.on('SIGTERM', interrupt);
    timer = setTimeout(() => killOwned('SIGKILL'), 90_000);
    const result = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', (code, signal) => resolve({ code, signal }));
    });
    assert.equal(result.code, 0, `Owned service journey failed: exit=${result.code}, signal=${result.signal}`);
  } finally {
    clearTimeout(timer);
    process.off('SIGINT', interrupt); process.off('SIGTERM', interrupt);
    killOwned('SIGKILL');
    await rm(root, { recursive: true, force: true });
    console.log('Owned service process group and temporary state cleaned.');
  }
} else {
  const root = await realpath(process.argv[3]);
  assert.equal(await realpath(process.cwd()), root);
  assert.equal(process.env.HOME, join(root, 'home'));
  const { build } = await import('esbuild');
  const { Miniflare, Log, LogLevel, convertV4MiniflareOptions } = await import('miniflare');
  const { unstable_splitSqlQuery } = await import('wrangler');
  const bundle = join(root, 'worker.mjs');
  await build({ entryPoints: [join(cloud, 'src/index.ts')], outfile: bundle,
    bundle: true, format: 'esm', platform: 'neutral', target: 'es2022',
    external: ['cloudflare:*'], logLevel: 'silent' });
  let outboundAttempts = 0;
  const denyOutbound = () => { outboundAttempts++; throw new Error('Unexpected outbound request denied'); };
  // The installed Miniflare 5 adapter translates this explicit, local-only config.
  const common = { unsafeInspectorProxy: false, compatibilityDate: '2026-10-29', modules: true, outboundService: denyOutbound };
  const config = convertV4MiniflareOptions({
    host: '127.0.0.1', port: 0, cf: false, telemetry: { enabled: false },
    unsafeLocalExplorer: false, unsafeObservability: false,
    unsafeEnableSharedStorage: false, logRequests: false, log: new Log(LogLevel.ERROR),
    resourcePersistencePath: join(root, 'state'), resourceTmpPath: join(root, 'tmp'),
    workers: [{ ...common, name: 'scriv', scriptPath: bundle,
      bindings: { PUBLIC_URL: 'http://127.0.0.1', ENVIRONMENT: 'test', EMAIL_FROM: 'sender@example.invalid' },
      serviceBindings: { EMAIL: 'local-mailbox' },
      d1Databases: { DB: 'journey-db' }, r2Buckets: ['ASSETS'],
      durableObjects: { PROJECTS: { className: 'ProjectRoom', useSQLite: true }, BILLING: { className: 'BillingCoordinator', useSQLite: true } },
    }, { ...common, name: 'local-mailbox', script: `import { WorkerEntrypoint } from 'cloudflare:workers';
      let mailbox = [];
      export default class extends WorkerEntrypoint {
        async send(message) {
          if (!/^synthetic-[a-z0-9]+@example\\.invalid$/.test(message.to) || message.from.email !== 'sender@example.invalid' || message.subject !== 'Your Scriv sign-in code') throw new Error('Denied non-synthetic delivery');
          const match = /^Your Scriv sign-in code is ([0-9]{6})\\./.exec(message.text);
          if (!match || mailbox.length >= 8) throw new Error('Invalid local mailbox message');
          mailbox.push({to:message.to, code:match[1]});
        }
        async take() { return mailbox.shift() || null; }
        async size() { return mailbox.length; }
      }` }],
  });
  const mf = new Miniflare(config);
  let requests = 0;
  try {
    const db = await mf.getD1Database('DB', 'scriv');
    const migrations = (await readdir(join(cloud, 'migrations'))).filter(name => /^\d+_.+\.sql$/.test(name)).sort();
    assert.deepEqual(migrations, ['0001_identity_teams.sql', '0002_generation_jobs.sql', '0003_email_auth.sql']);
    for (const name of migrations) await db.batch(unstable_splitSqlQuery(await readFile(join(cloud, 'migrations', name), 'utf8')).map(sql => db.prepare(sql)));
    async function request(path, { method = 'GET', body, token } = {}) {
      const base = await mf.ready;
      assert.equal(base.hostname, '127.0.0.1'); assert.equal(base.protocol, 'http:'); assert(Number(base.port) > 0);
      const url = new URL(path, base); assert.equal(url.origin, base.origin);
      const encoded = body === undefined ? undefined : JSON.stringify(body);
      assert(requests++ < 40); assert(Buffer.byteLength(encoded ?? '') <= 4096);
      const response = await fetch(url, { method, headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(encoded ? { 'content-type': 'application/json' } : {}) }, body: encoded, redirect: 'error', signal: AbortSignal.timeout(5000) });
      assert.equal(response.headers.get('cache-control'), 'no-store');
      assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
      const reader = response.body.getReader(); const parts = []; let size = 0;
      while (true) { const { done, value } = await reader.read(); if (done) break; size += value.length; assert(size <= 16384); parts.push(value); }
      return { status: response.status, data: JSON.parse(Buffer.concat(parts).toString('utf8')) };
    }
    // Trusted runtime graph is pinned and resolved locally, with no registry fallback.
    const runtimePath = process.env.SCRIV_TRACER_RUNTIME;
    if (!runtimePath || !isAbsolute(runtimePath) || await realpath(runtimePath) !== runtimePath) throw new Error('Trusted local SCRIV_TRACER_RUNTIME is required');
    const modulePins = {
      'scenario-runtime.mjs':'b5f634d2d9318f216b044104f40636187ea6808f62ba78b64082ef5f6a2f829d',
      'scenarios.mjs':'1c2fce69d317e4397b39789f351b8700613c2289f5c50d900b61ae2e1822acee',
      'tracer.mjs':'97ab1e28255ee4b6a702ea9732b05c0532abd8179189ee3b02a7c09aa71b8eb6',
      'catalog.mjs':'a084193be6c6bdaf95c94b0df36545182eb3cf47e976abe268f811b7f5a1a1c1',
      'proposals.mjs':'8775d1938f43c707191636462f9897bd625935912f5ba6770282604eb7fedb1f',
    };
    if (runtimePath !== join(dirname(runtimePath), 'scenario-runtime.mjs')) throw new Error('Invalid local runtime path');
    for (const [name, digest] of Object.entries(modulePins)) {
      const path = join(dirname(runtimePath), name);
      if (await realpath(path) !== path || createHash('sha256').update(await readFile(path)).digest('hex') !== digest) throw new Error('Untrusted local runtime module');
    }
    const { createScenarioRun } = await import(pathToFileURL(runtimePath).href);
    const catalog = JSON.parse(await readFile(join(cloud, '../docs/testing/email-auth-steps.json'), 'utf8'));
    const run = createScenarioRun({ catalog, scenarioId:'local-email-session-lifecycle', runId:randomUUID(), context:{build:'local-worker-bundle',platform:process.platform,inputRoute:'Scriv CLI service HTTP'} });
    const mailbox = await mf.getWorker('local-mailbox');
    const email = 'synthetic-journey@example.invalid', verifier = randomBytes(48).toString('base64url');
    const challenge = createHash('sha256').update(verifier).digest('base64url');
    const post = body => ({method:'POST',body});
    let result, challengeId, code, token, userId, sessionId;
    await run.step('request-code', async step => {
      result = await step.action('POST /auth/email/request synthetic address and proof challenge', () => request('/auth/email/request',post({email:' Synthetic-Journey@Example.Invalid ',codeChallenge:challenge})));
      await step.expect('observed', async () => { assert.equal(result.status,202); assert.equal(typeof result.data.challengeId,'string'); assert(result.data.expiresAt > Date.now()); assert(result.data.resendAt > Date.now()); challengeId=result.data.challengeId; const message=await mailbox.take(); assert.equal(message.to,email); assert.match(message.code,/^[0-9]{6}$/); code=message.code; assert.equal(await mailbox.size(),0); });
    });
    await run.step('reject-resend', async step => {
      result = await step.action('POST /auth/email/request same address and proof during cooldown', () => request('/auth/email/request',post({email,codeChallenge:challenge})));
      await step.expect('observed', async () => { assert.equal(result.status,429); assert.equal(result.data.error.code,'rate_limited'); assert.equal(await mailbox.size(),0); });
    });
    await run.step('reject-wrong-code', async step => {
      result = await step.action('POST /auth/email/verify incorrect code', () => request('/auth/email/verify',post({challengeId,code:code === '000000' ? '000001' : '000000',codeVerifier:verifier})));
      await step.expect('observed', () => { assert.equal(result.status,401); assert.equal(result.data.error.code,'invalid_code'); });
    });
    await run.step('reject-wrong-proof', async step => {
      result = await step.action('POST /auth/email/verify correct code incorrect proof', () => request('/auth/email/verify',post({challengeId,code,codeVerifier:'v'.repeat(43)})));
      await step.expect('observed', () => { assert.equal(result.status,401); assert.equal(result.data.error.code,'invalid_code'); });
    });
    await run.step('verify-code', async step => {
      result = await step.action('POST /auth/email/verify correct code and proof', () => request('/auth/email/verify',post({challengeId,code,codeVerifier:verifier,deviceName:'Synthetic CLI device'})));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(typeof result.data.token,'string'); assert.equal(result.data.user.email,email); assert(result.data.expiresAt > Date.now()); token=result.data.token; userId=result.data.user.id; });
    });
    await run.step('reject-replay', async step => {
      result = await step.action('POST /auth/email/verify replay consumed code', () => request('/auth/email/verify',post({challengeId,code,codeVerifier:verifier})));
      await step.expect('observed', () => { assert.equal(result.status,401); assert.equal(result.data.error.code,'invalid_code'); });
    });
    await run.step('read-identity', async step => {
      result = await step.action('GET /v1/me using issued session', () => request('/v1/me',{token}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.user.id,userId); assert.equal(result.data.user.email,email); assert.deepEqual(result.data.teams,[]); assert.deepEqual(result.data.projects,[]); sessionId=result.data.sessionId; assert.equal(typeof sessionId,'string'); });
    });
    await run.step('list-session', async step => {
      result = await step.action('GET /auth/sessions using issued session', () => request('/auth/sessions',{token}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.currentSessionId,sessionId); assert.equal(result.data.sessions.length,1); assert.equal(result.data.sessions[0].id,sessionId); assert.equal(result.data.sessions[0].deviceName,'Synthetic CLI device'); });
    });
    const verifier2 = randomBytes(48).toString('base64url'), challenge2 = createHash('sha256').update(verifier2).digest('base64url');
    let challengeId2, code2, token2, sessionId2;
    await run.step('request-second-code', async step => {
      result = await step.action('POST /auth/email/request same synthetic account second device proof', () => request('/auth/email/request',post({email,codeChallenge:challenge2})));
      await step.expect('observed', async () => { assert.equal(result.status,202); challengeId2=result.data.challengeId; const message=await mailbox.take(); assert.equal(message.to,email); assert.match(message.code,/^[0-9]{6}$/); code2=message.code; assert.equal(await mailbox.size(),0); });
    });
    await run.step('verify-second-device', async step => {
      result = await step.action('POST /auth/email/verify second device proof and code', () => request('/auth/email/verify',post({challengeId:challengeId2,code:code2,codeVerifier:verifier2,deviceName:'Synthetic second device'})));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.user.id,userId); assert.equal(result.data.user.email,email); assert.equal(typeof result.data.token,'string'); token2=result.data.token; });
    });
    await run.step('read-two-sessions', async step => {
      result = await step.action('GET /auth/sessions with two authenticated devices', () => request('/auth/sessions',{token}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.currentSessionId,sessionId); assert.equal(result.data.sessions.length,2); const second=result.data.sessions.find(item => item.deviceName === 'Synthetic second device'); assert(second); sessionId2=second.id; assert.notEqual(sessionId2,sessionId); });
    });
    await run.step('revoke-second-session', async step => {
      result = await step.action('DELETE /auth/sessions second device from first device', () => request('/auth/sessions/'+sessionId2,{method:'DELETE',token}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.deepEqual(result.data,{ok:true}); });
    });
    await run.step('reject-second-revoked', async step => {
      result = await step.action('GET /v1/me using revoked second session', () => request('/v1/me',{token:token2}));
      await step.expect('observed', () => { assert.equal(result.status,401); assert.equal(result.data.error.code,'session_expired'); });
    });
    await run.step('read-after-revocation', async step => {
      result = await step.action('GET /auth/sessions after second device revocation', () => request('/auth/sessions',{token}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.currentSessionId,sessionId); assert.equal(result.data.sessions.length,1); assert.equal(result.data.sessions[0].id,sessionId); });
    });
    await run.step('logout', async step => {
      result = await step.action('POST /auth/logout using issued session', () => request('/auth/logout',{method:'POST',token}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.deepEqual(result.data,{ok:true}); });
    });
    await run.step('reject-revoked-session', async step => {
      result = await step.action('GET /v1/me using logged-out session', () => request('/v1/me',{token}));
      await step.expect('observed', () => { assert.equal(result.status,401); assert.equal(result.data.error.code,'session_expired'); });
    });
    const report=run.finish(); assert.equal(report.status,'passed'); assert.equal(outboundAttempts,0); assert.equal(await mailbox.size(),0);
    // Original 16 callbacks have finished. This chapter uses only the local
    // mailbox and public HTTP; no challenge, attempt or session fixtures are seeded.
    const boundaryStart=requests;assert.equal(boundaryStart,16);
    const rows=async(table,order)=>(await db.prepare(`SELECT * FROM ${table} ORDER BY ${order}`).all()).results;
    const identities=async()=>({users:await rows('users','id'),identities:await rows('email_identities','email'),sessions:await rows('sessions','id')});
    const originalIdentity=await identities(),originalChallenges=await rows('email_auth_challenges','id_hash');
    const boundaryEmail='synthetic-boundary@example.invalid',unverifiedId=randomUUID(),fixtureTime=Date.now();
    // A public contact email on a GitHub-style row is not a verified identity.
    await db.prepare('INSERT INTO users(id,github_id,name,email,created_at) VALUES(?,?,?,?,?)').bind(unverifiedId,'987654321','Synthetic unverified contact',boundaryEmail,fixtureTime).run();
    const unverified=await db.prepare('SELECT * FROM users WHERE id=?').bind(unverifiedId).first();
    const baselineIdentity=await identities();assert.equal(baselineIdentity.users.length,originalIdentity.users.length+1);
    assert.deepEqual(baselineIdentity.identities,originalIdentity.identities);assert.deepEqual(baselineIdentity.sessions,originalIdentity.sessions);
    const hashValue=value=>createHash('sha256').update(value).digest('hex');
    const invalidCode={error:{code:'invalid_code',message:'This sign-in code is expired, used, or does not match this device. Request a new code if needed.'}};
    async function issueBoundaryCode(proof) {
      const pkce=createHash('sha256').update(proof).digest('base64url'),start=Date.now();
      const response=await request('/auth/email/request',post({email:boundaryEmail,codeChallenge:pkce}));const end=Date.now();
      assert.equal(response.status,202);assert.deepEqual(Object.keys(response.data).sort(),['challengeId','expiresAt','resendAt']);assert.match(response.data.challengeId,/^[A-Za-z0-9_-]{43}$/);
      const delivered=await mailbox.take();assert.equal(delivered.to,boundaryEmail);assert.match(delivered.code,/^[0-9]{6}$/);assert.equal(await mailbox.size(),0);
      const row=await db.prepare('SELECT * FROM email_auth_challenges WHERE id_hash=?').bind(hashValue(response.data.challengeId)).first();assert.ok(row);
      assert.ok(row.created_at>=start&&row.created_at<=end);assert.ok(row.sent_at>=row.created_at&&row.sent_at<=end);
      assert.deepEqual(row,{id_hash:hashValue(response.data.challengeId),email:boundaryEmail,pkce_challenge:pkce,code_hash:hashValue(response.data.challengeId+':'+delivered.code),created_at:row.created_at,expires_at:row.created_at+600000,sent_at:row.sent_at,attempts:0,consumed_by:null});
      assert.equal(response.data.expiresAt,row.expires_at);assert.equal(response.data.resendAt,row.created_at+60000);
      assert.deepEqual(await identities(),baselineIdentity);
      return {challengeId:response.data.challengeId,code:delivered.code,codeVerifier:proof,row};
    }
    const exhausted=await issueBoundaryCode(randomBytes(48).toString('base64url'));
    const wrong=exhausted.code==='000000'?'000001':'000000';
    const attemptBody=value=>({challengeId:value.challengeId,code:value.code,codeVerifier:value.codeVerifier});
    for(let attempt=1;attempt<=5;attempt++) {
      const rejected=await request('/auth/email/verify',post({...attemptBody(exhausted),code:wrong}));assert.equal(rejected.status,401);assert.deepEqual(rejected.data,invalidCode);
      const current=await db.prepare('SELECT * FROM email_auth_challenges WHERE id_hash=?').bind(exhausted.row.id_hash).first();
      assert.deepEqual(current,{...exhausted.row,attempts:attempt});assert.deepEqual(await identities(),baselineIdentity);assert.equal(await mailbox.size(),0);
    }
    const locked={...exhausted.row,attempts:5};assert.ok(locked.expires_at>Date.now());
    let checked=await request('/auth/email/verify',post(attemptBody(exhausted)));assert.equal(checked.status,401);assert.deepEqual(checked.data,invalidCode);
    assert.deepEqual(await db.prepare('SELECT * FROM email_auth_challenges WHERE id_hash=?').bind(locked.id_hash).first(),locked);
    assert.deepEqual(await identities(),baselineIdentity);
    const fresh=await issueBoundaryCode(randomBytes(48).toString('base64url'));assert.notEqual(fresh.row.pkce_challenge,locked.pkce_challenge);assert.notEqual(fresh.row.id_hash,locked.id_hash);
    const deviceName='Synthetic boundary device '+'x'.repeat(110),verifiedBody={...attemptBody(fresh),deviceName};
    // Dispatch both fetches before awaiting either. This does not force a
    // particular internal D1 interleaving or inject a transaction failure.
    const competitionStarted=Date.now();
    const outcomes=await Promise.all([request('/auth/email/verify',post(verifiedBody)),request('/auth/email/verify',post(verifiedBody))]);
    const competitionFinished=Date.now();assert.deepEqual(outcomes.map(o=>o.status).sort(),[200,401]);
    const winner=outcomes.find(o=>o.status===200).data,loser=outcomes.find(o=>o.status===401).data;assert.deepEqual(loser,invalidCode);
    assert.deepEqual(Object.keys(winner).sort(),['expiresAt','token','user']);assert.match(winner.token,/^[A-Za-z0-9_-]{64}$/);
    assert.notEqual(winner.user.id,unverifiedId);assert.deepEqual(winner.user,{id:winner.user.id,name:'Scriv user',email:boundaryEmail,avatarUrl:null});
    const consumed=await db.prepare('SELECT * FROM email_auth_challenges WHERE id_hash=?').bind(fresh.row.id_hash).first();
    assert.match(consumed.consumed_by,/^[A-Za-z0-9_-]{43}$/);assert.deepEqual(consumed,{...fresh.row,attempts:1,consumed_by:consumed.consumed_by});
    const after=await identities(),newUsers=after.users.filter(u=>!baselineIdentity.users.some(old=>old.id===u.id)),newIdentities=after.identities.filter(i=>!baselineIdentity.identities.some(old=>old.email===i.email)),newSessions=after.sessions.filter(s=>!baselineIdentity.sessions.some(old=>old.id===s.id));
    assert.equal(newUsers.length,1);assert.equal(newIdentities.length,1);assert.equal(newSessions.length,1);
    const user=newUsers[0],identity=newIdentities[0],session=newSessions[0];
    assert.equal(user.id,winner.user.id);assert.equal(user.github_id,'email:'+user.id);assert.equal(user.email,boundaryEmail);assert.equal(user.name,'Scriv user');assert.equal(user.avatar_url,null);
    assert.ok(user.created_at>=competitionStarted&&user.created_at<=competitionFinished);
    assert.deepEqual(identity,{email:boundaryEmail,user_id:user.id,verified_at:user.created_at});
    assert.equal(session.user_id,user.id);assert.equal(session.token_hash,hashValue(winner.token));assert.equal(session.device_name,deviceName.slice(0,100));assert.equal(session.created_at,user.created_at);
    assert.equal(session.expires_at,user.created_at+30*86400000);assert.equal(winner.expiresAt,session.expires_at);assert.equal(session.revoked_at,null);
    assert.deepEqual(after.users.filter(u=>u.id!==user.id),baselineIdentity.users);assert.deepEqual(after.identities.filter(i=>i.email!==boundaryEmail),baselineIdentity.identities);assert.deepEqual(after.sessions.filter(s=>s.id!==session.id),baselineIdentity.sessions);
    assert.deepEqual(await db.prepare('SELECT * FROM users WHERE id=?').bind(unverifiedId).first(),unverified);
    checked=await request('/v1/me',{token:winner.token});assert.equal(checked.status,200);assert.deepEqual(checked.data.user,winner.user);assert.equal(checked.data.sessionId,session.id);assert.deepEqual(checked.data.teams,[]);assert.deepEqual(checked.data.projects,[]);
    checked=await request('/auth/sessions',{token:winner.token});assert.equal(checked.status,200);assert.equal(checked.data.currentSessionId,session.id);assert.equal(checked.data.sessions.length,1);assert.equal(checked.data.sessions[0].id,session.id);assert.equal(checked.data.sessions[0].deviceName,deviceName.slice(0,100));
    checked=await request('/auth/email/verify',post(verifiedBody));assert.equal(checked.status,401);assert.deepEqual(checked.data,invalidCode);assert.deepEqual(await identities(),after);
    assert.deepEqual(await db.prepare('SELECT * FROM email_auth_challenges WHERE id_hash=?').bind(fresh.row.id_hash).first(),consumed);
    const logoutStart=Date.now();checked=await request('/auth/logout',{method:'POST',token:winner.token});assert.equal(checked.status,200);assert.deepEqual(checked.data,{ok:true});
    const revoked=await db.prepare('SELECT * FROM sessions WHERE id=?').bind(session.id).first();assert.ok(Number.isInteger(revoked.revoked_at));assert.ok(revoked.revoked_at>=logoutStart&&revoked.revoked_at<=Date.now());assert.deepEqual(revoked,{...session,revoked_at:revoked.revoked_at});
    checked=await request('/v1/me',{token:winner.token});assert.equal(checked.status,401);assert.deepEqual(checked.data,{error:{code:'session_expired',message:'Your Scriv session has expired. Sign in again.'}});
    const final=await identities();assert.deepEqual(final.users,after.users);assert.deepEqual(final.identities,after.identities);assert.deepEqual(final.sessions.map(s=>s.id===session.id?session:s),after.sessions);
    const finalChallenges=await rows('email_auth_challenges','id_hash');assert.equal(finalChallenges.length,originalChallenges.length+2);
    assert.deepEqual(finalChallenges.filter(c=>c.id_hash!==locked.id_hash&&c.id_hash!==consumed.id_hash),originalChallenges);
    assert.deepEqual(finalChallenges.find(c=>c.id_hash===locked.id_hash),locked);assert.deepEqual(finalChallenges.find(c=>c.id_hash===consumed.id_hash),consumed);
    assert.equal(await mailbox.size(),0);assert.equal(outboundAttempts,0);assert.equal(requests-boundaryStart,15);
    console.log(JSON.stringify({kind:'email-consumption-evidence',httpChecks:15,wrongAttempts:5,correctAfterExhaustionStatus:401,competingStatuses:outcomes.map(o=>o.status).sort(),newVerifiedUsers:1,newIdentities:1,newSessions:1,unverifiedContactPreserved:true,internalInterleavingControlled:false,nativeScenarios:0,outboundAttempts}));
    // Accepted synthetic delivery can still fail its response; recovery uses real cooldown time.
    assert.equal(requests,31);const recoveryStart=requests,recoveryBaseline=await identities(),recoveryChallenges=await rows('email_auth_challenges','id_hash');
    await mf.setOptions(convertV4MiniflareOptions({
      host:'127.0.0.1',port:0,cf:false,telemetry:{enabled:false},unsafeLocalExplorer:false,unsafeObservability:false,unsafeEnableSharedStorage:false,logRequests:false,log:new Log(LogLevel.ERROR),
      resourcePersistencePath:join(root,'state'),resourceTmpPath:join(root,'tmp'),
      workers:[{...common,name:'scriv',scriptPath:bundle,bindings:{PUBLIC_URL:'http://127.0.0.1',ENVIRONMENT:'test',EMAIL_FROM:'sender@example.invalid'},serviceBindings:{EMAIL:'local-mailbox'},
        d1Databases:{DB:'journey-db'},r2Buckets:['ASSETS'],durableObjects:{PROJECTS:{className:'ProjectRoom',useSQLite:true},BILLING:{className:'BillingCoordinator',useSQLite:true}}},
        {...common,name:'local-mailbox',script:`import { WorkerEntrypoint } from 'cloudflare:workers';
          let mailbox=[],calls=0;
          export default class extends WorkerEntrypoint {
            async send(message) {
              if(message.to!=='synthetic-recovery@example.invalid'||message.from.email!=='sender@example.invalid'||message.subject!=='Your Scriv sign-in code')throw new Error('Denied non-synthetic delivery');
              const match=/^Your Scriv sign-in code is ([0-9]{6})\\./.exec(message.text);if(!match||mailbox.length>=2)throw new Error('Invalid local mailbox message');
              mailbox.push({to:message.to,code:match[1]});calls++;if(calls===1)throw new Error('Synthetic delivery accepted but response failed');
            }
            async take(){return mailbox.shift()||null;}async size(){return mailbox.length;}async attempts(){return calls;}
          }` }],
    }));
    const recoveryDB=await mf.getD1Database('DB','scriv'),recoveryMailbox=await mf.getWorker('local-mailbox');
    const recoveryRows=async(table,order)=>(await recoveryDB.prepare(`SELECT * FROM ${table} ORDER BY ${order}`).all()).results;
    const recoveryIdentities=async()=>({users:await recoveryRows('users','id'),identities:await recoveryRows('email_identities','email'),sessions:await recoveryRows('sessions','id')});
    assert.deepEqual(await recoveryIdentities(),recoveryBaseline);assert.deepEqual(await recoveryRows('email_auth_challenges','id_hash'),recoveryChallenges);
    const recoveryEmail='synthetic-recovery@example.invalid',recoveryProof=randomBytes(48).toString('base64url'),recoveryPKCE=createHash('sha256').update(recoveryProof).digest('base64url'),recoveryBody={email:recoveryEmail,codeChallenge:recoveryPKCE};
    async function guardedEmailRequest(contentType,origin){
      const base=await mf.ready;assert.equal(base.hostname,'127.0.0.1');assert.equal(base.protocol,'http:');assert(Number(base.port)>0);assert(requests++<40);
      const raw=JSON.stringify(recoveryBody);assert(Buffer.byteLength(raw)<=4096);
      const response=await fetch(new URL('/auth/email/request',base),{method:'POST',headers:{'content-type':contentType,...(origin?{origin}:{})},body:raw,redirect:'error',signal:AbortSignal.timeout(5000)});
      assert.equal(response.headers.get('cache-control'),'no-store');assert.equal(response.headers.get('x-content-type-options'),'nosniff');
      const reader=response.body.getReader(),parts=[];let size=0;while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;assert(size<=16384);parts.push(value);}
      return {status:response.status,data:JSON.parse(Buffer.concat(parts).toString('utf8'))};
    }
    const limitsBefore=await recoveryRows('security_limits','key');
    let recoveryResponse=await guardedEmailRequest('text/plain');assert.equal(recoveryResponse.status,415);assert.deepEqual(recoveryResponse.data,{error:{code:'unsupported_media_type',message:'Email sign-in requires a JSON request.'}});
    recoveryResponse=await guardedEmailRequest('application/json','https://other.example.invalid');assert.equal(recoveryResponse.status,403);assert.deepEqual(recoveryResponse.data,{error:{code:'invalid_origin',message:'Email sign-in must start from this service or the Scriv app.'}});
    assert.deepEqual(await recoveryRows('security_limits','key'),limitsBefore);assert.equal(await recoveryMailbox.attempts(),0);assert.equal(await recoveryMailbox.size(),0);
    assert.deepEqual(await recoveryIdentities(),recoveryBaseline);assert.deepEqual(await recoveryRows('email_auth_challenges','id_hash'),recoveryChallenges);
    const failedStart=Date.now();recoveryResponse=await request('/auth/email/request',post(recoveryBody));const failedEnd=Date.now();
    assert.equal(recoveryResponse.status,503);assert.deepEqual(recoveryResponse.data,{error:{code:'email_unavailable',message:'Email sign-in is temporarily unavailable. Please wait a minute and retry.'}});
    const deliveredBeforeFailure=await recoveryMailbox.take();assert.equal(deliveredBeforeFailure.to,recoveryEmail);assert.match(deliveredBeforeFailure.code,/^[0-9]{6}$/);assert.equal(await recoveryMailbox.attempts(),1);assert.equal(await recoveryMailbox.size(),0);
    const failedRows=await recoveryRows('email_auth_challenges','id_hash'),failedChallenge=failedRows.find(c=>c.email===recoveryEmail);assert.ok(failedChallenge);assert.match(failedChallenge.id_hash,/^[a-f0-9]{64}$/);
    assert(failedChallenge.created_at>=failedStart&&failedChallenge.created_at<=failedEnd);
    assert.deepEqual(failedChallenge,{id_hash:failedChallenge.id_hash,email:recoveryEmail,pkce_challenge:recoveryPKCE,code_hash:null,created_at:failedChallenge.created_at,expires_at:failedChallenge.created_at+600000,sent_at:null,attempts:0,consumed_by:'send_failed'});
    assert.deepEqual(failedRows.filter(c=>c.email!==recoveryEmail),recoveryChallenges);assert.deepEqual(await recoveryIdentities(),recoveryBaseline);
    assert(Date.now()<failedChallenge.created_at+60000);recoveryResponse=await request('/auth/email/request',post(recoveryBody));assert.equal(recoveryResponse.status,429);assert.deepEqual(recoveryResponse.data,{error:{code:'rate_limited',message:'Please wait one minute before requesting another code.'}});
    assert.deepEqual(await recoveryRows('email_auth_challenges','id_hash'),failedRows);assert.deepEqual(await recoveryIdentities(),recoveryBaseline);assert.equal(await recoveryMailbox.attempts(),1);assert.equal(await recoveryMailbox.size(),0);
    const cooldownWait=failedChallenge.created_at+60000-Date.now()+25;assert(cooldownWait>0&&cooldownWait<=60025);await new Promise(resolve=>setTimeout(resolve,cooldownWait));assert(Date.now()>failedChallenge.created_at+60000);
    const resendStart=Date.now();recoveryResponse=await request('/auth/email/request',post(recoveryBody));const resendEnd=Date.now();assert.equal(recoveryResponse.status,202);assert.deepEqual(Object.keys(recoveryResponse.data).sort(),['challengeId','expiresAt','resendAt']);
    const replacementResponse=recoveryResponse.data;assert.match(replacementResponse.challengeId,/^[A-Za-z0-9_-]{43}$/);const recoveredDelivery=await recoveryMailbox.take();assert.equal(recoveredDelivery.to,recoveryEmail);assert.match(recoveredDelivery.code,/^[0-9]{6}$/);assert.equal(await recoveryMailbox.attempts(),2);assert.equal(await recoveryMailbox.size(),0);
    const replacementRows=await recoveryRows('email_auth_challenges','id_hash'),replacement=replacementRows.find(c=>c.email===recoveryEmail);assert.notEqual(replacement.id_hash,failedChallenge.id_hash);assert(replacement.created_at>=resendStart&&replacement.created_at<=resendEnd);assert(replacement.sent_at>=replacement.created_at&&replacement.sent_at<=resendEnd);
    assert.deepEqual(replacement,{id_hash:hashValue(replacementResponse.challengeId),email:recoveryEmail,pkce_challenge:recoveryPKCE,code_hash:hashValue(replacementResponse.challengeId+':'+recoveredDelivery.code),created_at:replacement.created_at,expires_at:replacement.created_at+600000,sent_at:replacement.sent_at,attempts:0,consumed_by:null});
    assert.equal(replacementResponse.expiresAt,replacement.expires_at);assert.equal(replacementResponse.resendAt,replacement.created_at+60000);assert.equal(replacementRows.length,failedRows.length);assert.deepEqual(replacementRows.filter(c=>c.email!==recoveryEmail),recoveryChallenges);assert.deepEqual(await recoveryIdentities(),recoveryBaseline);
    const verifyStart=Date.now();recoveryResponse=await request('/auth/email/verify',post({challengeId:replacementResponse.challengeId,code:recoveredDelivery.code,codeVerifier:recoveryProof,deviceName:'Synthetic recovered device'}));const verifyEnd=Date.now();assert.equal(recoveryResponse.status,200);
    const recovered=recoveryResponse.data;assert.deepEqual(Object.keys(recovered).sort(),['expiresAt','token','user']);assert.match(recovered.token,/^[A-Za-z0-9_-]{64}$/);assert.deepEqual(recovered.user,{id:recovered.user.id,name:'Scriv user',email:recoveryEmail,avatarUrl:null});
    const verified=await recoveryIdentities(),recoveredUsers=verified.users.filter(u=>!recoveryBaseline.users.some(old=>old.id===u.id)),recoveredSessions=verified.sessions.filter(s=>!recoveryBaseline.sessions.some(old=>old.id===s.id));assert.equal(recoveredUsers.length,1);assert.equal(recoveredSessions.length,1);
    const recoveredUser=recoveredUsers[0],recoveredSession=recoveredSessions[0];assert(recoveredUser.created_at>=verifyStart&&recoveredUser.created_at<=verifyEnd);assert.deepEqual(recoveredUser,{id:recovered.user.id,github_id:'email:'+recovered.user.id,name:'Scriv user',email:recoveryEmail,avatar_url:null,created_at:recoveredUser.created_at});
    assert.deepEqual(verified.identities.filter(i=>i.email===recoveryEmail),[{email:recoveryEmail,user_id:recoveredUser.id,verified_at:recoveredUser.created_at}]);assert.match(recoveredSession.id,/^[0-9a-f-]{36}$/);
    assert.deepEqual(recoveredSession,{token_hash:hashValue(recovered.token),id:recoveredSession.id,user_id:recoveredUser.id,device_name:'Synthetic recovered device',created_at:recoveredUser.created_at,expires_at:recoveredUser.created_at+30*86400000,revoked_at:null});assert.equal(recovered.expiresAt,recoveredSession.expires_at);
    assert.deepEqual(verified.users.filter(u=>u.id!==recoveredUser.id),recoveryBaseline.users);assert.deepEqual(verified.identities.filter(i=>i.email!==recoveryEmail),recoveryBaseline.identities);assert.deepEqual(verified.sessions.filter(s=>s.id!==recoveredSession.id),recoveryBaseline.sessions);
    const recoveredChallenge=await recoveryDB.prepare('SELECT * FROM email_auth_challenges WHERE id_hash=?').bind(replacement.id_hash).first();assert.match(recoveredChallenge.consumed_by,/^[A-Za-z0-9_-]{43}$/);assert.deepEqual(recoveredChallenge,{...replacement,attempts:1,consumed_by:recoveredChallenge.consumed_by});
    recoveryResponse=await request('/v1/me',{token:recovered.token});assert.equal(recoveryResponse.status,200);assert.deepEqual(recoveryResponse.data,{user:recovered.user,sessionId:recoveredSession.id,teams:[],projects:[]});
    const recoveryLogoutStart=Date.now();recoveryResponse=await request('/auth/logout',{method:'POST',token:recovered.token});const recoveryLogoutEnd=Date.now();assert.equal(recoveryResponse.status,200);assert.deepEqual(recoveryResponse.data,{ok:true});
    const recoveredRevoked=await recoveryDB.prepare('SELECT * FROM sessions WHERE id=?').bind(recoveredSession.id).first();assert(recoveredRevoked.revoked_at>=recoveryLogoutStart&&recoveredRevoked.revoked_at<=recoveryLogoutEnd);assert.deepEqual(recoveredRevoked,{...recoveredSession,revoked_at:recoveredRevoked.revoked_at});
    recoveryResponse=await request('/v1/me',{token:recovered.token});assert.equal(recoveryResponse.status,401);assert.deepEqual(recoveryResponse.data,{error:{code:'session_expired',message:'Your Scriv session has expired. Sign in again.'}});
    const recoveryFinal=await recoveryIdentities();assert.deepEqual(recoveryFinal,{...verified,sessions:verified.sessions.map(s=>s.id===recoveredSession.id?recoveredRevoked:s)});assert.deepEqual(await recoveryRows('email_auth_challenges','id_hash'),[...recoveryChallenges,recoveredChallenge].sort((a,b)=>a.id_hash.localeCompare(b.id_hash)));
    assert.equal(await recoveryMailbox.attempts(),2);assert.equal(await recoveryMailbox.size(),0);assert.equal(outboundAttempts,0);assert.equal(requests-recoveryStart,9);assert.equal(requests,40);
    console.log(JSON.stringify({kind:'email-delivery-recovery-evidence',httpChecks:9,guardRefusals:2,syntheticAcceptedDeliveryFailures:1,cooldownRefusals:1,naturalCooldownWaitMs:cooldownWait,syntheticSendAttempts:2,newVerifiedUsers:1,newIdentities:1,newSessions:1,failedChallengeReplaced:true,clockOrExpiryChanged:false,nativeScenarios:0,outboundAttempts}));
    console.log(JSON.stringify({result:'PASS',journey:'email-auth',requests,outboundAttempts,nativeScenarios:0,bundleSha256:createHash('sha256').update(await readFile(bundle)).digest('hex'),runtime:report}));
  } finally { await mf.dispose(); }
}
