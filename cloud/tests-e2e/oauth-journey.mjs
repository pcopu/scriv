// Real HTTP service-process integration; not Catalyst/native application E2E.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, rm, readFile, readdir, copyFile, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, isAbsolute } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';

process.on('uncaughtException', error => { console.error('GitHub OAuth journey failed at: ' + (error.stack?.split('\n').find(line => line.trimStart().startsWith('at ')) ?? 'unknown')); process.exitCode = 1; });
if (process.argv[2] !== '--owned-child' && (!process.env.SCRIV_TRACER_RUNTIME || !isAbsolute(process.env.SCRIV_TRACER_RUNTIME))) { console.error('Set SCRIV_TRACER_RUNTIME to the absolute path of the reviewed local Tracer runtime.'); process.exit(2); }
const here = await realpath(dirname(fileURLToPath(import.meta.url)));
// --cloud supports an outside-repository candidate without changing its sources.
const cloud = await realpath(process.argv[2] === '--owned-child' ? process.argv[4] :
  process.argv[2] === '--cloud' ? process.argv[3] : join(here, '..'));
const self = await realpath(fileURLToPath(import.meta.url));
if (process.argv[2] !== '--owned-child') {
  let root, capture, child, timer, interrupted = false;
  const killOwned = signal => {
    if (child?.pid) {
      try { process.kill(-child.pid, signal); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    }
  };
  const interrupt = () => { interrupted = true; killOwned('SIGTERM'); };
  process.on('SIGINT', interrupt); process.on('SIGTERM', interrupt);
  try {
    try {
      root = await realpath(await mkdtemp(join(tmpdir(), 'scriv-oauth-')));
      for (const name of ['home', 'tmp', 'state']) await mkdir(join(root, name), { mode: 0o700 });
      capture = process.env.SCRIV_SERVICE_COVERAGE_DIR
        ? await (await import(pathToFileURL(join(cloud, 'tests-e2e/capture-generation-coverage.mjs')).href))
          .prepareServiceCapture(process.env.SCRIV_SERVICE_COVERAGE_DIR, process.env.SCRIV_TRACER_CLI, { journeyPath: 'cloud/tests-e2e/oauth-journey.mjs' }) : null;
      // Resolve installed dependencies from an owned runner, never edit the repository.
      await copyFile(self, join(root, 'runner.mjs'));
      await symlink(await realpath(join(cloud, 'node_modules')), join(root, 'node_modules'), 'dir');
      assert.equal(interrupted, false, 'Cancelled during preparation; no Worker launched');
      child = spawn(process.execPath, [join(root, 'runner.mjs'), '--owned-child', root, cloud, ...(capture ? [capture.path] : [])], {
        cwd: root, detached: true, stdio: 'inherit',
        // Deliberately no inherited credentials, proxy settings, config, or NODE_OPTIONS.
        env: { PATH: dirname(process.execPath), HOME: join(root, 'home'), TMPDIR: join(root, 'tmp'),
          XDG_CONFIG_HOME: join(root, 'home'), XDG_CACHE_HOME: join(root, 'home'),
          WRANGLER_SEND_METRICS: 'false', CI: '1', SCRIV_TRACER_RUNTIME: process.env.SCRIV_TRACER_RUNTIME },
      });
      timer = setTimeout(() => killOwned('SIGKILL'), 90_000);
      const result = await new Promise((resolve, reject) => {
        child.once('error', reject);
        child.once('exit', (code, signal) => resolve({ code, signal }));
      });
      assert.equal(result.code, 0, `Owned service journey failed: exit=${result.code}, signal=${result.signal}`);
    } finally {
      clearTimeout(timer); killOwned('SIGKILL');
      if (root) await rm(root, { recursive: true, force: true });
      console.log('Owned service process group and temporary state cleaned.');
    }
    assert.equal(interrupted, false, 'Cancelled before measurement import');
    if (capture) await capture.finish(() => interrupted);
    assert.equal(interrupted, false, 'Cancelled during measurement import; inspect preserved evidence');
  } finally {
    process.off('SIGINT', interrupt); process.off('SIGTERM', interrupt);
  }
} else {
  const root = await realpath(process.argv[3]);
  assert.equal(await realpath(process.cwd()), root);
  assert.equal(process.env.HOME, join(root, 'home'));
  const { build } = await import('esbuild');
  const { Miniflare, Log, LogLevel, convertV4MiniflareOptions } = await import('miniflare');
  const { unstable_splitSqlQuery } = await import('wrangler');
  async function sourceManifest(directory, prefix='') {
    const result={};
    for (const entry of (await readdir(directory,{withFileTypes:true})).sort((a,b)=>a.name.localeCompare(b.name))) {
      const relative=prefix+entry.name, path=join(directory,entry.name);
      assert(!entry.isSymbolicLink());
      if(entry.isDirectory()) Object.assign(result,await sourceManifest(path,relative+'/'));
      else result[relative]=createHash('sha256').update(await readFile(path)).digest('hex');
    }
    return result;
  }
  const workerSourcesBeforeBuild=await sourceManifest(join(cloud,'src'));
  const migrationHashes=await sourceManifest(join(cloud,'migrations'));
  const dependencyVersions={};
  for(const name of ['esbuild','miniflare','wrangler']) dependencyVersions[name]=JSON.parse(await readFile(join(cloud,'node_modules',name,'package.json'),'utf8')).version;
  const bundle = join(root, 'worker.mjs');
  const capture = process.argv[5]
    ? await (await import(pathToFileURL(join(cloud, 'tests-e2e/capture-generation-coverage.mjs')).href))
      .loadServiceCapture(process.argv[5]) : null;
  if (!capture) await build({ entryPoints: [join(cloud, 'src/index.ts')], outfile: bundle,
    bundle: true, format: 'esm', platform: 'neutral', target: 'es2022',
    external: ['cloudflare:*'], logLevel: 'silent' });
  let outboundAttempts = 0, deniedOutbound = 0;
  const fixtureCounts = { token:0, profile:0, emails:0 };
  let providerMode = 'valid';
  const providerFixture = async request => {
    assert(outboundAttempts++ < 16);
    const url = new URL(request.url);
    const reply = (value, status=200) => new Response(JSON.stringify(value), {status,headers:{'content-type':'application/json'}});
    // Exact synthetic-only allowlist. No forwarding or network fallback exists.
    try {
      if (url.href === 'https://github.com/login/oauth/access_token') {
        assert.equal(request.method,'POST'); assert.equal(request.headers.get('accept'),'application/json');
        assert.equal(request.headers.get('content-type'),'application/json');
        const value=await request.json();
        assert.deepEqual(value,{client_id:'synthetic-client',client_secret:'synthetic-secret',code:'synthetic-provider-code',redirect_uri:'http://127.0.0.1/auth/github/callback'});
        fixtureCounts.token++;
        if (providerMode === 'token-error') return reply({error:'simulated_denial'},400);
        if (providerMode === 'malformed-token-json') return new Response('{synthetic-private-provider-marker', {headers:{'content-type':'application/json'}});
        return reply({access_token:'synthetic-provider-token'});
      }
      assert(['https://api.github.com/user','https://api.github.com/user/emails'].includes(url.href));
      assert.equal(request.method,'GET'); assert.equal(await request.text(),'');
      assert.equal(request.headers.get('authorization'),'Bearer synthetic-provider-token');
      assert.equal(request.headers.get('user-agent'),'Scriv'); assert.equal(request.headers.get('accept'),'application/vnd.github+json');
      assert.equal(request.headers.get('x-github-api-version'),'2022-11-28');
      if (url.pathname === '/user') {
        fixtureCounts.profile++;
        if (providerMode === 'profile-error') return reply({message:'simulated failure'},503);
        if (providerMode === 'invalid-profile') return reply({id:1.5,login:'synthetic-login'});
        return reply({id:87654321,login:'synthetic-login',name:'Synthetic GitHub User',email:null,avatar_url:null});
      }
      fixtureCounts.emails++;
      return reply([{email:'unverified@example.invalid',primary:true,verified:false},{email:'secondary@example.invalid',primary:false,verified:true},{email:'synthetic-github@example.invalid',primary:true,verified:true}]);
    } catch { deniedOutbound++; throw new Error('Denied unknown or unsafe simulated provider request'); }
  };
  const config = convertV4MiniflareOptions({
    host:'127.0.0.1',port:0,cf:false,telemetry:{enabled:false},
    unsafeLocalExplorer:false,unsafeObservability:false,unsafeEnableSharedStorage:false,
    logRequests:false,log:new Log(LogLevel.ERROR),
    resourcePersistencePath:join(root,'state'),resourceTmpPath:join(root,'tmp'),
    workers:[{name:'scriv',unsafeInspectorProxy:false,compatibilityDate:'2026-10-29',modules:true,
      outboundService:providerFixture,...(capture ? { script: capture.options.script } : { scriptPath: bundle }),
      bindings:{PUBLIC_URL:'http://127.0.0.1',ENVIRONMENT:'test',GITHUB_CLIENT_ID:'synthetic-client',GITHUB_CLIENT_SECRET:'synthetic-secret',...(capture?.options.bindings ?? {})},
      d1Databases:{DB:'journey-db'},r2Buckets:['ASSETS'],
      durableObjects:{PROJECTS:{className:'ProjectRoom',useSQLite:true},BILLING:{className:'BillingCoordinator',useSQLite:true}}
    }]
  });
  const mf = new Miniflare(config);
  let requests = 0, captureStarted = false;
  const coverageActions = [];
  let boundaryRequests = 0;
  try {
    const db = await mf.getD1Database('DB', 'scriv');
    const migrations = (await readdir(join(cloud, 'migrations'))).filter(name => /^\d+_.+\.sql$/.test(name)).sort();
    assert.deepEqual(migrations, ['0001_identity_teams.sql', '0002_generation_jobs.sql', '0003_email_auth.sql']);
    for (const name of migrations) await db.batch(unstable_splitSqlQuery(await readFile(join(cloud, 'migrations', name), 'utf8')).map(sql => db.prepare(sql)));
    async function request(path, { method = 'GET', body, token, boundary = false } = {}) {
      const base = await mf.ready;
      assert.equal(base.hostname, '127.0.0.1'); assert.equal(base.protocol, 'http:'); assert(Number(base.port) > 0);
      const url = new URL(path, base); assert.equal(url.origin, base.origin);
      const encoded = body === undefined ? undefined : JSON.stringify(body);
      if (boundary) assert(boundaryRequests++ < 5);
      else assert(requests++ < 40);
      assert(Buffer.byteLength(encoded ?? '') <= 4096);
      if (capture) coverageActions.push(`${method} ${url.pathname.replace(/[0-9a-f]{8}-[0-9a-f-]{27}/gi, ':id')}`);
      const response = await fetch(url, { method, headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(encoded ? { 'content-type': 'application/json' } : {}) }, body: encoded, redirect: 'manual', signal: AbortSignal.timeout(5000) });
      if (response.status === 302) return {status:302,location:new URL(response.headers.get('location'))};
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
    const catalog = JSON.parse(await readFile(join(cloud, '../docs/testing/oauth-steps.json'), 'utf8'));
    const run = createScenarioRun({ catalog, scenarioId:'local-github-oauth-pkce', runId:randomUUID(), context:{build:'local-worker-bundle',platform:process.platform,inputRoute:'Scriv CLI service HTTP; GitHub simulated only'} });
    const verifier=randomBytes(48).toString('base64url'), challenge=createHash('sha256').update(verifier).digest('base64url');
    const clientState='synthetic-client-state-123456';
    const start=()=>request('/auth/github/start?'+new URLSearchParams({codeChallenge:challenge,state:clientState}));
    const callback=(state,extra={code:'synthetic-provider-code'})=>request('/auth/github/callback?'+new URLSearchParams({state,...extra}));
    const exchange=codeVerifier=>request('/auth/exchange',{method:'POST',body:{code,codeVerifier,deviceName:'Synthetic OAuth device'}});
    const errorIs=(result,status,code)=>{assert.equal(result.status,status);assert.equal(result.data.error.code,code);};
    const redirectIs=result=>{assert.equal(result.status,302);assert.equal(result.location.protocol,'scriv:');assert.equal(result.location.hostname,'auth');assert.equal(result.location.pathname,'/callback');assert.equal(result.location.searchParams.get('state'),clientState);};
    // Auxiliary owned-D1 observations, separate from the 24 public HTTP actions.
    // Compare all synthetic rows, including sessions belonging to any user. Never log row values.
    let persistedBaseline;
    let persistenceSnapshots=0;
    async function persistedAuthState() {
      persistenceSnapshots++;
      const rows={};
      for (const table of ['users','sessions','auth_codes']) {
        rows[table]=(await db.prepare(`SELECT * FROM ${table} ORDER BY 1`).all()).results;
      }
      return rows;
    }
    async function assertAuthStateUnchanged() {
      assert(persistedBaseline);
      assert.deepEqual(await persistedAuthState(),persistedBaseline);
    }
    let result,state,code,token,userId;
    if (capture) { await capture.begin(await mf.ready); captureStarted = true; }
    await run.step('reject-malformed-challenge', async step => {
      result = await step.action('GET OAuth start malformed challenge', () => request('/auth/github/start?'+new URLSearchParams({codeChallenge:'!'.repeat(43),state:clientState})));
      await step.expect('observed', async () => { errorIs(result,400,'invalid_challenge'); assert.equal(outboundAttempts,0); });
    });
    await run.step('start-sign-in', async step => {
      result = await step.action('GET OAuth start valid challenge and client state', () => start());
      await step.expect('observed', async () => { assert.equal(result.status,302); assert.equal(result.location.origin,'https://github.com'); assert.equal(result.location.pathname,'/login/oauth/authorize'); assert.equal(result.location.searchParams.get('client_id'),'synthetic-client'); assert.equal(result.location.searchParams.get('redirect_uri'),'http://127.0.0.1/auth/github/callback'); assert.equal(result.location.searchParams.get('scope'),'read:user user:email'); state=result.location.searchParams.get('state'); assert.match(state,/^[A-Za-z0-9_-]{32,128}$/); assert.notEqual(state,clientState); assert.equal(outboundAttempts,0); });
    });
    await run.step('complete-provider-callback', async step => {
      result = await step.action('GET callback synthetic GitHub authorization', () => callback(state));
      await step.expect('observed', async () => { redirectIs(result); code=result.location.searchParams.get('code'); assert.match(code,/^[A-Za-z0-9_-]{32,128}$/); assert.deepEqual(fixtureCounts,{token:1,profile:1,emails:1}); });
    });
    await run.step('reject-state-replay', async step => {
      result = await step.action('GET callback consumed state replay', () => callback(state));
      await step.expect('observed', async () => { errorIs(result,400,'oauth_expired'); assert.equal(outboundAttempts,3); });
    });
    await run.step('reject-verifier-characters', async step => {
      result = await step.action('POST exchange malformed verifier', () => exchange('!'.repeat(43)));
      await step.expect('observed', async () => { errorIs(result,400,'invalid_verifier'); });
    });
    await run.step('reject-wrong-verifier', async step => {
      result = await step.action('POST exchange wrong valid verifier', () => exchange('x'.repeat(43)));
      await step.expect('observed', async () => { errorIs(result,401,'invalid_code'); });
    });
    await run.step('exchange-correct-proof', async step => {
      result = await step.action('POST exchange correct verifier after failures', () => exchange(verifier));
      await step.expect('observed', async () => { assert.equal(result.status,200); assert.equal(result.data.user.name,'Synthetic GitHub User'); assert.equal(result.data.user.email,'synthetic-github@example.invalid'); assert.equal(result.data.user.avatarUrl,null); assert(result.data.expiresAt>Date.now()); token=result.data.token; assert.match(token,/^[A-Za-z0-9_-]{64}$/); userId=result.data.user.id; });
    });
    await run.step('reject-code-replay', async step => {
      result = await step.action('POST exchange consumed code replay', () => exchange(verifier));
      await step.expect('observed', async () => { errorIs(result,401,'invalid_code'); });
    });
    await run.step('read-oauth-identity', async step => {
      result = await step.action('GET identity using OAuth session', () => request('/v1/me',{token}));
      await step.expect('observed', async () => { assert.equal(result.status,200); assert.equal(result.data.user.id,userId); assert.equal(result.data.user.email,'synthetic-github@example.invalid'); assert.deepEqual(result.data.teams,[]); assert.deepEqual(result.data.projects,[]); });
    });
    await run.step('read-oauth-session', async step => {
      result = await step.action('GET sessions using OAuth session', () => request('/auth/sessions',{token}));
      await step.expect('observed', async () => { assert.equal(result.status,200); assert.equal(result.data.sessions.length,1); assert.equal(result.data.sessions[0].deviceName,'Synthetic OAuth device'); assert.equal(result.data.currentSessionId,result.data.sessions[0].id); persistedBaseline=await persistedAuthState(); assert.equal(persistedBaseline.sessions.length,1); assert.equal(persistedBaseline.users.length,1); assert.equal(persistedBaseline.auth_codes.length,0); });
    });
    await run.step('start-cancellation', async step => {
      result = await step.action('GET OAuth start cancellation fixture', () => start());
      await step.expect('observed', async () => { assert.equal(result.status,302); state=result.location.searchParams.get('state'); assert(state); await assertAuthStateUnchanged(); });
    });
    await run.step('cancel-callback', async step => {
      result = await step.action('GET callback provider cancellation', () => callback(state,{error:'access_denied'}));
      await step.expect('observed', async () => { redirectIs(result); assert.equal(result.location.searchParams.get('error'),'access_denied'); assert.equal(result.location.searchParams.has('code'),false); assert.equal(outboundAttempts,3); await assertAuthStateUnchanged(); });
    });
    await run.step('reject-cancelled-state', async step => {
      result = await step.action('GET callback cancelled state replay', () => callback(state));
      await step.expect('observed', async () => { errorIs(result,400,'oauth_expired'); assert.equal(outboundAttempts,3); await assertAuthStateUnchanged(); });
    });
    await run.step('start-token-error', async step => {
      result = await step.action('GET OAuth start token-error fixture', () => start());
      await step.expect('observed', async () => { assert.equal(result.status,302); state=result.location.searchParams.get('state'); assert(state); providerMode='token-error'; await assertAuthStateUnchanged(); });
    });
    await run.step('reject-token-error', async step => {
      result = await step.action('GET callback simulated token-error', () => callback(state));
      await step.expect('observed', async () => { errorIs(result,502,'provider_error'); assert.deepEqual(fixtureCounts,{token:2,profile:1,emails:1}); await assertAuthStateUnchanged(); });
    });
    await run.step('replay-token-error', async step => {
      result = await step.action('GET callback token-error consumed state', () => callback(state));
      await step.expect('observed', async () => { errorIs(result,400,'oauth_expired'); assert.deepEqual(fixtureCounts,{token:2,profile:1,emails:1}); await assertAuthStateUnchanged(); });
    });
    await run.step('start-profile-error', async step => {
      result = await step.action('GET OAuth start profile-error fixture', () => start());
      await step.expect('observed', async () => { assert.equal(result.status,302); state=result.location.searchParams.get('state'); assert(state); providerMode='profile-error'; await assertAuthStateUnchanged(); });
    });
    await run.step('reject-profile-error', async step => {
      result = await step.action('GET callback simulated profile-error', () => callback(state));
      await step.expect('observed', async () => { errorIs(result,502,'provider_error'); assert.deepEqual(fixtureCounts,{token:3,profile:2,emails:1}); await assertAuthStateUnchanged(); });
    });
    await run.step('replay-profile-error', async step => {
      result = await step.action('GET callback profile-error consumed state', () => callback(state));
      await step.expect('observed', async () => { errorIs(result,400,'oauth_expired'); assert.deepEqual(fixtureCounts,{token:3,profile:2,emails:1}); await assertAuthStateUnchanged(); });
    });
    await run.step('start-invalid-profile', async step => {
      result = await step.action('GET OAuth start invalid-profile fixture', () => start());
      await step.expect('observed', async () => { assert.equal(result.status,302); state=result.location.searchParams.get('state'); assert(state); providerMode='invalid-profile'; await assertAuthStateUnchanged(); });
    });
    await run.step('reject-invalid-profile', async step => {
      result = await step.action('GET callback simulated invalid-profile', () => callback(state));
      await step.expect('observed', async () => { errorIs(result,502,'provider_error'); assert.deepEqual(fixtureCounts,{token:4,profile:3,emails:1}); await assertAuthStateUnchanged(); });
    });
    await run.step('replay-invalid-profile', async step => {
      result = await step.action('GET callback invalid-profile consumed state', () => callback(state));
      await step.expect('observed', async () => { errorIs(result,400,'oauth_expired'); assert.deepEqual(fixtureCounts,{token:4,profile:3,emails:1}); await assertAuthStateUnchanged(); });
    });
    await run.step('logout-oauth', async step => {
      result = await step.action('POST logout OAuth session', () => request('/auth/logout',{method:'POST',token}));
      await step.expect('observed', async () => { assert.equal(result.status,200); assert.deepEqual(result.data,{ok:true}); });
    });
    await run.step('reject-logged-out-oauth', async step => {
      result = await step.action('GET identity after OAuth logout', () => request('/v1/me',{token}));
      await step.expect('observed', async () => { errorIs(result,401,'session_expired'); });
    });
    assert.deepEqual(await sourceManifest(join(cloud,'src')),workerSourcesBeforeBuild);
    const report=run.finish(); assert.equal(report.status,'passed'); assert.equal(deniedOutbound,0); assert.deepEqual(fixtureCounts,{token:4,profile:3,emails:1}); assert.equal(requests,24); assert.equal(persistenceSnapshots,13);
    // Re-authentication and session ownership: public HTTP, synthetic provider only.
    // Concurrent dispatch observes one-use outcomes; it does not force internal D1 overlap.
    const digest = value => createHash('sha256').update(value).digest('hex');
    const authRows = async () => {
      const value = {};
      for (const table of ['users','sessions','oauth_states','auth_codes','email_identities']) value[table] = (await db.prepare(`SELECT * FROM ${table} ORDER BY 1`).all()).results;
      return value;
    };
    const oldRows = await authRows(); assert.equal(oldRows.users.length,1); assert.equal(oldRows.sessions.length,1); assert(oldRows.sessions[0].revoked_at);
    assert.deepEqual(oldRows.oauth_states,[]); assert.deepEqual(oldRows.auth_codes,[]); assert.deepEqual(oldRows.email_identities,[]);
    const foreignUserId=randomUUID(), foreignSessionId=randomUUID(), fixtureTime=Date.now();
    await db.prepare('INSERT INTO users(id,github_id,name,email,avatar_url,created_at) VALUES(?,?,?,?,?,?)').bind(foreignUserId,'987654322','Synthetic unrelated user',null,null,fixtureTime).run();
    await db.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at) VALUES(?,?,?,?,?,?)').bind(digest(randomBytes(48).toString('base64url')),foreignSessionId,foreignUserId,'Synthetic unrelated device',fixtureTime,fixtureTime+86400000).run();
    const seededRows=await authRows(); assert.equal(seededRows.users.length,2); assert.equal(seededRows.sessions.length,2);
    const issued=[]; providerMode='valid';
    for (let phase=0;phase<2;phase++) {
      const proof=randomBytes(48).toString('base64url'), proofHash=createHash('sha256').update(proof).digest('base64url');
      const client=`synthetic-relogin-state-${phase}`, startBefore=Date.now();
      const launched=await request('/auth/github/start?'+new URLSearchParams({codeChallenge:proofHash,state:client})); const startAfter=Date.now();
      assert.equal(launched.status,302); const opaqueState=launched.location.searchParams.get('state'); assert.match(opaqueState,/^[A-Za-z0-9_-]{32,128}$/); assert.notEqual(opaqueState,client);
      const started=await authRows(); assert.equal(started.oauth_states.length,1); assert.deepEqual(Object.keys(started.oauth_states[0]).sort(),['challenge','client_state','expires_at','state_hash']);
      assert.deepEqual({...started.oauth_states[0],expires_at:0},{state_hash:digest(opaqueState),client_state:client,challenge:proofHash,expires_at:0}); assert(started.oauth_states[0].expires_at>=startBefore+600000 && started.oauth_states[0].expires_at<=startAfter+600000);
      assert.deepEqual(started.users,seededRows.users); assert.deepEqual(started.sessions,[...seededRows.sessions,...issued.map(x=>x.row)].sort((a,b)=>a.token_hash.localeCompare(b.token_hash))); assert.deepEqual(started.auth_codes,[]);
      const callbackPath='/auth/github/callback?'+new URLSearchParams({state:opaqueState,code:'synthetic-provider-code'}), callbackBefore=Date.now();
      const callbacks=phase===0 ? await Promise.all([request(callbackPath),request(callbackPath)]) : [await request(callbackPath)]; const callbackAfter=Date.now();
      if(phase===0) { assert.deepEqual(callbacks.map(x=>x.status).sort(),[302,400]); errorIs(callbacks.find(x=>x.status===400),400,'oauth_expired'); }
      const authorized=callbacks.find(x=>x.status===302); assert(authorized); assert.equal(authorized.location.protocol,'scriv:'); assert.equal(authorized.location.hostname,'auth'); assert.equal(authorized.location.pathname,'/callback'); assert.equal(authorized.location.searchParams.get('state'),client);
      const exchangeCode=authorized.location.searchParams.get('code'); assert.match(exchangeCode,/^[A-Za-z0-9_-]{32,128}$/);
      const afterCallback=await authRows(); assert.deepEqual(afterCallback.oauth_states,[]); assert.deepEqual(afterCallback.users,seededRows.users); assert.deepEqual(afterCallback.sessions,started.sessions); assert.equal(afterCallback.auth_codes.length,1);
      const codeRow=afterCallback.auth_codes[0]; assert.deepEqual(Object.keys(codeRow).sort(),['challenge','code_hash','expires_at','user_id']); assert.deepEqual({...codeRow,expires_at:0},{code_hash:digest(exchangeCode),user_id:userId,challenge:proofHash,expires_at:0}); assert(codeRow.expires_at>=callbackBefore+120000 && codeRow.expires_at<=callbackAfter+120000);
      const deviceName=`Synthetic repeat OAuth device ${phase}`, exchangeBefore=Date.now();
      const consume=()=>request('/auth/exchange',{method:'POST',body:{code:exchangeCode,codeVerifier:proof,deviceName}});
      const exchanges=phase===1 ? await Promise.all([consume(),consume()]) : [await consume()]; const exchangeAfter=Date.now();
      if(phase===1) { assert.deepEqual(exchanges.map(x=>x.status).sort(),[200,401]); errorIs(exchanges.find(x=>x.status===401),401,'invalid_code'); }
      const accepted=exchanges.find(x=>x.status===200); assert(accepted); assert.equal(accepted.data.user.id,userId); assert.match(accepted.data.token,/^[A-Za-z0-9_-]{64}$/);
      assert.deepEqual(accepted.data.user,{id:userId,name:'Synthetic GitHub User',email:'synthetic-github@example.invalid',avatarUrl:null});
      const afterExchange=await authRows(); assert.deepEqual(afterExchange.users,seededRows.users); assert.deepEqual(afterExchange.oauth_states,[]); assert.deepEqual(afterExchange.auth_codes,[]); assert.deepEqual(afterExchange.email_identities,[]);
      const added=afterExchange.sessions.filter(x=>!started.sessions.some(y=>y.id===x.id)); assert.equal(added.length,1); const row=added[0]; assert.deepEqual(Object.keys(row).sort(),['created_at','device_name','expires_at','id','revoked_at','token_hash','user_id']);
      assert.equal(row.user_id,userId); assert.equal(row.token_hash,digest(accepted.data.token)); assert.equal(row.device_name,deviceName); assert.equal(row.revoked_at,null); assert(row.created_at>=exchangeBefore && row.created_at<=exchangeAfter); assert.equal(row.expires_at,row.created_at+30*86400000); assert.equal(accepted.data.expiresAt,row.expires_at);
      assert.deepEqual(afterExchange.sessions.filter(x=>x.id!==row.id),started.sessions); issued.push({row,token:accepted.data.token});
      assert.deepEqual(fixtureCounts,{token:5+phase,profile:4+phase,emails:2+phase}); assert.equal(outboundAttempts,11+3*phase); assert.equal(deniedOutbound,0);
    }
    const [sibling,current]=issued; assert.notEqual(sibling.row.id,current.row.id); assert.notEqual(sibling.token,current.token);
    const publicSession=row=>({id:row.id,deviceName:row.device_name,createdAt:row.created_at,expiresAt:row.expires_at});
    const sortSessions=rows=>[...rows].sort((a,b)=>a.id.localeCompare(b.id));
    const inventory=await request('/auth/sessions',{token:current.token}); assert.equal(inventory.status,200); assert.equal(inventory.data.currentSessionId,current.row.id); assert.deepEqual(sortSessions(inventory.data.sessions),sortSessions(issued.map(x=>publicSession(x.row))));
    const beforeForeign=await authRows(); const foreignRevoke=await request('/auth/sessions/'+foreignSessionId,{method:'DELETE',token:current.token}); assert.equal(foreignRevoke.status,200); assert.deepEqual(foreignRevoke.data,{ok:true}); assert.deepEqual(await authRows(),beforeForeign);
    const currentIdentity=await request('/v1/me',{token:current.token}); assert.equal(currentIdentity.status,200); assert.equal(currentIdentity.data.user.id,userId); assert.deepEqual(currentIdentity.data.teams,[]); assert.deepEqual(currentIdentity.data.projects,[]);
    const revokeBefore=Date.now(); const revoked=await request('/auth/sessions/'+sibling.row.id,{method:'DELETE',token:current.token}); const revokeAfter=Date.now(); assert.equal(revoked.status,200); assert.deepEqual(revoked.data,{ok:true});
    const afterSibling=await authRows(); const revokedRow=afterSibling.sessions.find(x=>x.id===sibling.row.id); assert(revokedRow.revoked_at>=revokeBefore && revokedRow.revoked_at<=revokeAfter); assert.deepEqual({...revokedRow,revoked_at:null},sibling.row);
    assert.deepEqual({...afterSibling,sessions:afterSibling.sessions.map(x=>x.id===sibling.row.id?sibling.row:x)},beforeForeign);
    errorIs(await request('/v1/me',{token:sibling.token}),401,'session_expired');
    const remaining=await request('/auth/sessions',{token:current.token}); assert.equal(remaining.status,200); assert.equal(remaining.data.currentSessionId,current.row.id); assert.deepEqual(remaining.data.sessions,[publicSession(current.row)]);
    const unknownBaseline = await authRows(), unknownProviderCalls = outboundAttempts;
    errorIs(await request('/auth/unknown', {boundary:true}), 404, 'not_found');
    errorIs(await request('/v1/unknown', {token:current.token,boundary:true}), 404, 'not_found');
    assert.deepEqual(await authRows(), unknownBaseline); assert.equal(outboundAttempts, unknownProviderCalls);
    const logoutBefore=Date.now(); const loggedOut=await request('/auth/logout',{method:'POST',token:current.token}); const logoutAfter=Date.now(); assert.equal(loggedOut.status,200); assert.deepEqual(loggedOut.data,{ok:true});
    errorIs(await request('/v1/me',{token:current.token}),401,'session_expired');
    const finalRows=await authRows(), finalCurrent=finalRows.sessions.find(x=>x.id===current.row.id); assert(finalCurrent.revoked_at>=logoutBefore && finalCurrent.revoked_at<=logoutAfter); assert.deepEqual({...finalCurrent,revoked_at:null},current.row);
    assert.deepEqual({...finalRows,sessions:finalRows.sessions.map(x=>x.id===current.row.id?current.row:x)},afterSibling);
    assert.deepEqual(finalRows.sessions.filter(x=>!issued.some(y=>y.row.id===x.id)),seededRows.sessions); assert.deepEqual(finalRows.users,seededRows.users);
    assert.deepEqual(await sourceManifest(join(cloud,'src')),workerSourcesBeforeBuild); assert.equal(requests,40); assert.equal(outboundAttempts,14); assert.equal(deniedOutbound,0);
    console.log(JSON.stringify({kind:'oauth-session-isolation-evidence',httpChecks:16,repeatedSignIns:2,callbackStatuses:[302,400],exchangeStatuses:[200,401],newUsers:0,newSessions:2,foreignSessionPreserved:true,originalRevokedSessionPreserved:true,internalInterleavingControlled:false,nativeScenarios:0}));
    // Invalid provider JSON follows the real callback handler's generic error response.
    const malformedBaseline = await authRows(), malformedCalls = {...fixtureCounts}, malformedAttempts = outboundAttempts;
    providerMode = 'malformed-token-json';
    const malformedStart = await request('/auth/github/start?' + new URLSearchParams({codeChallenge:challenge,state:clientState}), {boundary:true});
    assert.equal(malformedStart.status,302); const malformedState = malformedStart.location.searchParams.get('state'); assert(malformedState);
    const malformedStarted = await authRows(); assert.equal(malformedStarted.oauth_states.length,1);
    assert.deepEqual({...malformedStarted,oauth_states:[]},malformedBaseline);
    const malformedCallbackPath = '/auth/github/callback?' + new URLSearchParams({state:malformedState,code:'synthetic-provider-code'});
    const malformedReply = await request(malformedCallbackPath,{boundary:true});
    assert.equal(malformedReply.status,500);
    assert.deepEqual(malformedReply.data,{error:{code:'internal_error',message:'The server could not complete this request. Please retry.'}});
    assert.equal(JSON.stringify(malformedReply.data).includes('synthetic-private-provider-marker'),false);
    assert.deepEqual(await authRows(),malformedBaseline);
    errorIs(await request(malformedCallbackPath,{boundary:true}),400,'oauth_expired');
    assert.deepEqual(await authRows(),malformedBaseline);
    assert.deepEqual(fixtureCounts,{...malformedCalls,token:malformedCalls.token+1});
    assert.equal(outboundAttempts,malformedAttempts+1); assert.equal(deniedOutbound,0); assert.equal(boundaryRequests,5);
    console.log(JSON.stringify({kind:'oauth-public-boundary-evidence',httpChecks:boundaryRequests,unknownRouteRefusals:2,malformedProviderJSONRefusals:1,consumedStateReplays:1,newUsers:0,newSessions:0,newExchangeCodes:0,liveProvider:false}));
    console.log(JSON.stringify({result:'PASS',journey:'oauth',provider:'LOCAL SIMULATION ONLY; no real GitHub login',requests,boundaryRequests,totalHttpChecks:requests+boundaryRequests,outboundAttempts,deniedOutbound,fixtureCounts,nativeScenarios:0,auxiliaryPersistence:{snapshots:persistenceSnapshots,selectQueries:persistenceSnapshots*3,tables:['users','sessions','auth_codes'],scope:'All owned synthetic rows; baseline immutable; values never logged'},workerSourcesBeforeBuild,migrationHashes,dependencyVersions,runtimeModulePins:modulePins,catalogSha256:createHash('sha256').update(await readFile(join(cloud,'../docs/testing/oauth-steps.json'))).digest('hex'),bundleSha256:createHash('sha256').update(capture ? capture.options.script : await readFile(bundle)).digest('hex'),runtime:report}));
  } finally {
    try {
      if (captureStarted) await capture.end(await mf.ready, requests + boundaryRequests, coverageActions);
    } finally { await mf.dispose(); }
  }
}
