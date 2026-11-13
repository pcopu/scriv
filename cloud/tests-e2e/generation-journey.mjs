// Real HTTP service-process integration; not Catalyst/native application E2E.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, rm, readFile, readdir, copyFile, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, isAbsolute } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';

process.on('uncaughtException', () => { console.error('Generation journey failed; no response or exception details were emitted.'); process.exitCode = 1; });
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
      root = await realpath(await mkdtemp(join(tmpdir(), 'scriv-generation-')));
      for (const name of ['home', 'tmp', 'state']) await mkdir(join(root, name), { mode: 0o700 });
      capture = process.env.SCRIV_GENERATION_COVERAGE_DIR
        ? await (await import(pathToFileURL(join(cloud, 'tests-e2e/capture-generation-coverage.mjs')).href))
          .prepareGenerationCapture(process.env.SCRIV_GENERATION_COVERAGE_DIR, process.env.SCRIV_TRACER_CLI) : null;
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
  const bundle = join(root, 'worker.mjs');
  const capture = process.argv[5]
    ? await (await import(pathToFileURL(join(cloud, 'tests-e2e/capture-generation-coverage.mjs')).href))
      .loadGenerationCapture(process.argv[5]) : null;
  if (!capture) await build({ entryPoints: [join(cloud, 'src/index.ts')], outfile: bundle,
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
    workers: [{ ...common, name: 'scriv', ...(capture ? { script: capture.options.script } : { scriptPath: bundle }),
      bindings: { PUBLIC_URL: 'http://127.0.0.1', ENVIRONMENT: 'test', ...(capture?.options.bindings ?? {}) },
      d1Databases: { DB: 'journey-db' }, r2Buckets: ['ASSETS'],
      durableObjects: { PROJECTS: { className: 'ProjectRoom', useSQLite: true }, BILLING: { className: 'BillingCoordinator', useSQLite: true } },
    }],
  });
  const mf = new Miniflare(config);
  let requests = 0;
  try {
    const db = await mf.getD1Database('DB', 'scriv');
    const migrations = (await readdir(join(cloud, 'migrations'))).filter(name => /^\d+_.+\.sql$/.test(name)).sort();
    assert.deepEqual(migrations, ['0001_identity_teams.sql', '0002_generation_jobs.sql', '0003_email_auth.sql']);
    for (const name of migrations) await db.batch(unstable_splitSqlQuery(await readFile(join(cloud, 'migrations', name), 'utf8')).map(sql => db.prepare(sql)));
    // Fixture provisioning only, before HTTP: ephemeral identities, hashed sessions
    // and a synthetic paid team. This does not test provider login or billing.
    const now = Date.now(), teamId = randomUUID(), projectId = randomUUID(), itemId = randomUUID();
    const actors = {};
    for (const role of ['owner', 'member', 'viewer', 'outsider']) {
      const actor = actors[role] = { id: randomUUID(), sessionId: randomUUID(), token: randomBytes(32).toString('base64url') };
      await db.prepare('INSERT INTO users(id,github_id,name,created_at) VALUES(?,?,?,?)').bind(actor.id, `email:${actor.id}`, `Synthetic ${role}`, now).run();
      await db.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at) VALUES(?,?,?,?,?,?)').bind(createHash('sha256').update(actor.token).digest('hex'), actor.sessionId, actor.id, 'Synthetic CLI device', now, now + 3600000).run();
    }
    actors.member2 = { id: actors.member.id, sessionId: randomUUID(), token: randomBytes(32).toString('base64url') };
    await db.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at) VALUES(?,?,?,?,?,?)').bind(createHash('sha256').update(actors.member2.token).digest('hex'), actors.member2.sessionId, actors.member2.id, 'Synthetic second device', now, now + 3600000).run();
    await db.prepare('INSERT INTO teams(id,name,owner_id,created_at,subscription_status,paid_until) VALUES(?,?,?,?,?,?)').bind(teamId, 'Synthetic collaboration team', actors.owner.id, now, 'active', now + 3600000).run();
    for (const role of ['owner', 'member', 'viewer']) await db.prepare('INSERT INTO team_members(team_id,user_id,role,joined_at) VALUES(?,?,?,?)').bind(teamId, actors[role].id, role, now).run();
    const bucket = await mf.getR2Bucket('ASSETS', 'scriv');
    assert.deepEqual((await bucket.list()).objects, []);
    async function request(path, { role = 'owner', method = 'GET', body, status = 200, code } = {}) {
      const base = await mf.ready;
      assert.equal(base.hostname, '127.0.0.1'); assert.equal(base.protocol, 'http:'); assert(Number(base.port) > 0);
      const url = new URL(path, base); assert.equal(url.origin, base.origin);
      const encoded = body === undefined ? undefined : JSON.stringify(body);
      assert(requests++ < 80); assert(Buffer.byteLength(encoded ?? '') <= 16384);
      const response = await fetch(url, { method, headers: { authorization: `Bearer ${actors[role].token}`, ...(encoded ? { 'content-type': 'application/json' } : {}) }, body: encoded, redirect: 'error', signal: AbortSignal.timeout(5000) });
      // Never include response bodies or headers in errors: leases are secrets.
      const actualStatus = response.status;
      assert.equal(response.headers.get('cache-control'), 'no-store');
      assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
      const reader = response.body.getReader(); const parts = []; let size = 0;
      while (true) { const { done, value } = await reader.read(); if (done) break; size += value.length; assert(size <= 65536, 'Response bound'); parts.push(value); }
      const data = JSON.parse(Buffer.concat(parts).toString('utf8'));
      return { status: actualStatus, data };
    }
    // The trusted runtime and its complete local import graph are pinned; no registry fallback.
    const runtimePath = process.env.SCRIV_TRACER_RUNTIME;
    if (!runtimePath || !isAbsolute(runtimePath) || await realpath(runtimePath) !== runtimePath) throw new Error('Trusted local SCRIV_TRACER_RUNTIME is required');
    const modulePins = {
      'scenario-runtime.mjs':'b5f634d2d9318f216b044104f40636187ea6808f62ba78b64082ef5f6a2f829d',
      'scenarios.mjs':'1c2fce69d317e4397b39789f351b8700613c2289f5c50d900b61ae2e1822acee',
      'tracer.mjs':'97ab1e28255ee4b6a702ea9732b05c0532abd8179189ee3b02a7c09aa71b8eb6','proposals.mjs':'8775d1938f43c707191636462f9897bd625935912f5ba6770282604eb7fedb1f',
      'catalog.mjs':'a084193be6c6bdaf95c94b0df36545182eb3cf47e976abe268f811b7f5a1a1c1',
    };
    if (runtimePath !== join(dirname(runtimePath), 'scenario-runtime.mjs')) throw new Error('Invalid local runtime path');
    for (const [name, digest] of Object.entries(modulePins)) {
      const path = join(dirname(runtimePath), name);
      if (await realpath(path) !== path || createHash('sha256').update(await readFile(path)).digest('hex') !== digest) throw new Error('Untrusted local runtime module');
    }
    const { createScenarioRun } = await import(pathToFileURL(runtimePath).href);
    const catalog = JSON.parse(await readFile(join(cloud, '../docs/testing/generation-steps.json'), 'utf8'));
    const run = createScenarioRun({ catalog, scenarioId:'generation-job-lifecycle', runId:randomUUID(), context:{build:'local-worker-bundle',platform:process.platform,inputRoute:'Scriv CLI service HTTP'} });
    const route = suffix => `/v1/projects/${projectId}/generation-jobs${suffix}`;
    const jobId = randomUUID(), targetItemId = randomUUID(), outputImageId = randomUUID();
    const job2 = randomUUID(), job3 = randomUUID(), claimOp = randomUUID(), completeOp = randomUUID(), failClaim = randomUUID(), failOp = randomUUID(), recoverOp = randomUUID(), cancelOp = randomUUID();
    const original = {id:jobId,targetItemId,sourceRevision:3};
    const post = body => ({method:'POST', body, role:'member'});
    const patch = body => ({method:'PATCH', body, role:'member'});
    let result;
    if (capture) await capture.begin(await mf.ready);
    await run.step('create-project', async step => {
      result = await step.action('POST /v1/projects synthetic team project', () => request('/v1/projects', post({id:projectId,title:'Synthetic generation project',teamId})));
      await step.expect('observed', () => { assert.equal(result.status,201); assert.equal(result.data.project.id,projectId); });
    });
    await run.step('create-job', async step => {
      result = await step.action('POST generation-jobs queued job', () => request(route(''),post({id:jobId,targetItemId,sourceRevision:3})));
      await step.expect('observed', () => { assert.equal(result.status,201); assert.equal(result.data.job.id,jobId); assert.equal(result.data.job.status,'queued'); assert.equal(result.data.job.version,1); });
    });
    await run.step('read-job', async step => {
      result = await step.action('GET generation-jobs job as viewer', () => request(route('/'+jobId),{role:'viewer'}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.job.id,jobId); assert.equal(result.data.job.targetItemId,targetItemId); assert.equal(result.data.job.sourceRevision,3); });
    });
    let cursor, page1, page2;
    await run.step('replay-create', async step => {
      result = await step.action('POST generation-jobs identical queued job', () => request(route(''),post(original)));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.replayed,true); assert.equal(result.data.job.version,1); });
    });
    await run.step('conflict-create', async step => {
      result = await step.action('POST generation-jobs changed revision same ID', () => request(route(''),post({...original,sourceRevision:4})));
      await step.expect('observed', () => { assert.equal(result.status,409); assert.equal(result.data.error.code,'job_conflict'); });
    });
    await run.step('reject-private-field', async step => {
      result = await step.action('POST generation-jobs with synthetic prompt field', () => request(route(''),post({...original,prompt:'synthetic'})));
      await step.expect('observed', () => { assert.equal(result.status,400); assert.equal(result.data.error.code,'invalid_field'); });
    });
    await run.step('reject-viewer-create', async step => {
      result = await step.action('POST generation-jobs as viewer', () => request(route(''),{...post({id:randomUUID(),targetItemId,sourceRevision:1}),role:'viewer'}));
      await step.expect('observed', () => { assert.equal(result.status,403); assert.equal(result.data.error.code,'not_allowed'); });
    });
    await run.step('reject-outsider-read', async step => {
      result = await step.action('GET generation-jobs as outsider', () => request(route(''),{role:'outsider'}));
      await step.expect('observed', () => { assert.equal(result.status,404); assert.equal(result.data.error.code,'not_found'); });
    });
    await run.step('reject-other-owner', async step => {
      result = await step.action('POST generation-jobs claim as team owner', () => request(route('/'+jobId+'/claim'),{...post({operationId:randomUUID(),expectedVersion:1}),role:'owner'}));
      await step.expect('observed', () => { assert.equal(result.status,403); assert.equal(result.data.error.code,'not_job_owner'); });
    });
    await run.step('reject-unclaimed-update', async step => {
      result = await step.action('PATCH generation-jobs completion before claim', () => request(route('/'+jobId),patch({operationId:randomUUID(),expectedVersion:1,status:'completed',outputImageId})));
      await step.expect('observed', () => { assert.equal(result.status,409); assert.equal(result.data.error.code,'job_conflict'); });
    });
    await run.step('claim-job', async step => {
      result = await step.action('POST generation-jobs claim on original device', () => request(route('/'+jobId+'/claim'),post({operationId:claimOp,expectedVersion:1})));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.job.status,'running'); assert.equal(result.data.job.version,2); assert.equal(result.data.job.ownerDeviceId,actors.member.sessionId); });
    });
    await run.step('replay-claim', async step => {
      result = await step.action('POST generation-jobs identical claim retry', () => request(route('/'+jobId+'/claim'),post({operationId:claimOp,expectedVersion:1})));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.replayed,true); assert.equal(result.data.job.version,2); });
    });
    await run.step('conflict-operation', async step => {
      result = await step.action('POST generation-jobs reused claim operation with changed body', () => request(route('/'+jobId+'/claim'),post({operationId:claimOp,expectedVersion:2})));
      await step.expect('observed', () => { assert.equal(result.status,409); assert.equal(result.data.error.code,'operation_conflict'); });
    });
    await run.step('reject-live-takeover', async step => {
      result = await step.action('POST generation-jobs recovery claim from second device while live', () => request(route('/'+jobId+'/claim'),{...post({operationId:randomUUID(),expectedVersion:2,recover:true}),role:'member2'}));
      await step.expect('observed', () => { assert.equal(result.status,409); assert.equal(result.data.error.code,'job_conflict'); });
    });
    await run.step('reject-missing-output', async step => {
      result = await step.action('PATCH generation-jobs completion without output', () => request(route('/'+jobId),patch({operationId:randomUUID(),expectedVersion:2,status:'completed'})));
      await step.expect('observed', () => { assert.equal(result.status,400); assert.equal(result.data.error.code,'invalid_field'); });
    });
    await run.step('complete-job', async step => {
      result = await step.action('PATCH generation-jobs completed with image ID', () => request(route('/'+jobId),patch({operationId:completeOp,expectedVersion:2,status:'completed',outputImageId})));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.job.status,'completed'); assert.equal(result.data.job.outputImageId,outputImageId); assert.equal(result.data.job.version,3); });
    });
    await run.step('replay-complete', async step => {
      result = await step.action('PATCH generation-jobs identical completion retry', () => request(route('/'+jobId),patch({operationId:completeOp,expectedVersion:2,status:'completed',outputImageId})));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.replayed,true); assert.equal(result.data.job.version,3); });
    });
    await run.step('claim-replay-current', async step => {
      result = await step.action('POST generation-jobs retry original claim after completion', () => request(route('/'+jobId+'/claim'),post({operationId:claimOp,expectedVersion:1})));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.replayed,true); assert.equal(result.data.job.status,'completed'); assert.equal(result.data.job.version,3); });
    });
    await run.step('reject-completed-recovery', async step => {
      result = await step.action('POST generation-jobs recovery on completed job', () => request(route('/'+jobId+'/claim'),post({operationId:randomUUID(),expectedVersion:3,recover:true})));
      await step.expect('observed', () => { assert.equal(result.status,409); assert.equal(result.data.error.code,'job_conflict'); });
    });
    await run.step('read-completed', async step => {
      result = await step.action('GET generation-jobs completed job as viewer', () => request(route('/'+jobId),{role:'viewer'}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.job.status,'completed'); assert.equal(result.data.job.outputImageId,outputImageId); assert.equal(result.data.job.version,3); });
    });
    await run.step('create-failure-job', async step => {
      result = await step.action('POST generation-jobs second queued job', () => request(route(''),post({id:job2,targetItemId,sourceRevision:5})));
      await step.expect('observed', () => { assert.equal(result.status,201); assert.equal(result.data.job.status,'queued'); });
    });
    await run.step('claim-failure-job', async step => {
      result = await step.action('POST generation-jobs second job claim', () => request(route('/'+job2+'/claim'),post({operationId:failClaim,expectedVersion:1})));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.job.version,2); });
    });
    await run.step('fail-job', async step => {
      result = await step.action('PATCH generation-jobs second job failed with safe code', () => request(route('/'+job2),patch({operationId:failOp,expectedVersion:2,status:'failed',errorCode:'synthetic_failure'})));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.job.status,'failed'); assert.equal(result.data.job.errorCode,'synthetic_failure'); assert.equal(result.data.job.version,3); });
    });
    await run.step('reject-recovery-omission', async step => {
      result = await step.action('POST generation-jobs failed job without recover flag', () => request(route('/'+job2+'/claim'),post({operationId:randomUUID(),expectedVersion:3})));
      await step.expect('observed', () => { assert.equal(result.status,409); assert.equal(result.data.error.code,'job_conflict'); });
    });
    await run.step('recover-failed', async step => {
      result = await step.action('POST generation-jobs failed job recovery on second device', () => request(route('/'+job2+'/claim'),{...post({operationId:recoverOp,expectedVersion:3,recover:true}),role:'member2'}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.job.status,'running'); assert.equal(result.data.job.version,4); assert.equal(result.data.job.ownerDeviceId,actors.member2.sessionId); assert.equal(result.data.job.errorCode,null); });
    });
    await run.step('fence-former-device', async step => {
      result = await step.action('PATCH generation-jobs running job from former device', () => request(route('/'+job2),patch({operationId:randomUUID(),expectedVersion:4,status:'completed',outputImageId})));
      await step.expect('observed', () => { assert.equal(result.status,409); assert.equal(result.data.error.code,'job_conflict'); });
    });
    await run.step('cancel-recovered', async step => {
      result = await step.action('PATCH generation-jobs cancellation by creator on original device', () => request(route('/'+job2),patch({operationId:cancelOp,expectedVersion:4,status:'cancelled',errorCode:'user_cancelled'})));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.job.status,'cancelled'); assert.equal(result.data.job.version,5); assert.equal(result.data.job.errorCode,'user_cancelled'); });
    });
    await run.step('read-cancelled', async step => {
      result = await step.action('GET generation-jobs cancelled job as viewer', () => request(route('/'+job2),{role:'viewer'}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.job.status,'cancelled'); assert.equal(result.data.job.version,5); });
    });
    await run.step('create-third-job', async step => {
      result = await step.action('POST generation-jobs third queued job', () => request(route(''),post({id:job3,targetItemId,sourceRevision:7})));
      await step.expect('observed', () => { assert.equal(result.status,201); assert.equal(result.data.job.version,1); });
    });
    await run.step('reject-cursor', async step => {
      result = await step.action('GET generation-jobs invalid cursor', () => request(route('?cursor=invalid'),{role:'viewer'}));
      await step.expect('observed', () => { assert.equal(result.status,400); assert.equal(result.data.error.code,'invalid_cursor'); });
    });
    await run.step('list-first-page', async step => {
      result = await step.action('GET generation-jobs limit one as viewer', () => request(route('?limit=1'),{role:'viewer'}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.jobs.length,1); assert.equal(typeof result.data.nextCursor,'string'); page1=result.data.jobs[0].id; cursor=result.data.nextCursor; });
    });
    await run.step('list-second-page', async step => {
      result = await step.action('GET generation-jobs next cursor as viewer', () => request(route('?limit=1&cursor='+encodeURIComponent(cursor)),{role:'viewer'}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.jobs.length,1); assert.notEqual(result.data.jobs[0].id,page1); assert.equal(typeof result.data.nextCursor,'string'); page2=result.data.jobs[0].id; cursor=result.data.nextCursor; });
    });
    await run.step('list-final-page', async step => {
      result = await step.action('GET generation-jobs final cursor as viewer', () => request(route('?limit=1&cursor='+encodeURIComponent(cursor)),{role:'viewer'}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.jobs.length,1); assert.equal(result.data.nextCursor,null); assert.deepEqual(new Set([page1,page2,result.data.jobs[0].id]),new Set([jobId,job2,job3])); });
    });
    await run.step('reject-missing-job', async step => {
      result = await step.action('GET generation-jobs nonexistent job', () => request(route('/'+randomUUID()),{role:'viewer'}));
      await step.expect('observed', () => { assert.equal(result.status,404); assert.equal(result.data.error.code,'job_not_found'); });
    });
    const report=run.finish(); assert.equal(report.status,'passed'); assert.equal(outboundAttempts,0);
    // The original 34 named callbacks finish above. This appended chapter uses
    // public HTTP and read-only storage observations, not production helper calls.
    const recoveryStart = requests;
    assert.equal(recoveryStart, 34);
    const rows = async table => (await db.prepare(`SELECT * FROM ${table} ORDER BY rowid`).all()).results;
    const business = async () => ({ jobs: await rows('generation_jobs'), receipts: await rows('generation_job_operations'),
      projects: await rows('projects'), teams: await rows('teams'), members: await rows('team_members'), assets: await rows('assets'),
      objects: (await bucket.list()).objects });
    const baseline = await business();
    const getJobRow = async id => await db.prepare('SELECT * FROM generation_jobs WHERE project_id=? AND id=?').bind(projectId,id).first();
    const publicKeys = ['schemaVersion','id','projectId','targetItemId','sourceRevision','status','progressText','createdAt','updatedAt','createdBy','ownerDeviceId','ownerDeviceName','version','leaseExpiresAt','outputImageId','errorCode'].sort();
    async function publicJob(value, id, expected, projected = false) {
      assert.deepEqual(Object.keys(value).sort(), publicKeys);
      const row = await getJobRow(id); assert.ok(row);
      const full = {schemaVersion:1,id,projectId,targetItemId,sourceRevision:row.source_revision,status:expected.status,
        progressText:expected.progressText,createdAt:row.created_at,updatedAt:row.updated_at,createdBy:actors.member.id,
        ownerDeviceId:expected.ownerDeviceId,ownerDeviceName:expected.ownerDeviceName,version:expected.version,
        leaseExpiresAt:row.lease_expires_at,outputImageId:expected.outputImageId ?? null,errorCode:expected.errorCode ?? null};
      assert.deepEqual(value,full); assert.equal(row.created_by,actors.member.id); assert.equal(row.target_item_id,targetItemId);
      assert.equal(row.owner_device_id,expected.ownerDeviceId); assert.equal(row.owner_device_name,expected.ownerDeviceName);
      assert.equal(row.version,expected.version); assert.equal(row.output_image_id,full.outputImageId); assert.equal(row.error_code,full.errorCode);
      if (!projected) { assert.equal(row.status,expected.status); assert.equal(row.progress_text,expected.progressText); }
      return row;
    }
    const expectState = (status,version,role,progressText,extra={}) => ({status,version,ownerDeviceId:actors[role].sessionId,
      ownerDeviceName:role==='member'?'Synthetic CLI device':'Synthetic second device',progressText,...extra});
    let refused = 0, mutationReceipts = [];
    async function refusal(path, options, status, code, message) {
      const before = await business(); const response = await request(path,options);
      assert.equal(response.status,status); assert.deepEqual(response.data,{error:{code,message}});
      assert.deepEqual(await business(),before); refused++; return response;
    }
    async function mutation(id, body, role, claim, expected) {
      const before = await rows('generation_job_operations'); const start=Date.now();
      const response=await request(route('/'+id+(claim?'/claim':'')),{method:claim?'POST':'PATCH',body,role});
      assert.equal(response.status,200); assert.deepEqual(Object.keys(response.data),['job']);
      const row=await publicJob(response.data.job,id,expected); const end=Date.now();
      assert.equal(row.last_operation_id,body.operationId); assert.ok(row.updated_at>=start&&row.updated_at<=end);
      if(expected.status==='running') assert.ok(row.lease_expires_at>=start+90000&&row.lease_expires_at<=end+90000);
      else assert.equal(row.lease_expires_at,0);
      const receipt=await db.prepare('SELECT * FROM generation_job_operations WHERE project_id=? AND job_id=? AND operation_id=?').bind(projectId,id,body.operationId).first();
      assert.deepEqual(Object.keys(receipt).sort(),['project_id','job_id','operation_id','request_hash','actor_session_id','resulting_version','created_at'].sort());
      assert.deepEqual({...receipt,request_hash:'hash'},{project_id:projectId,job_id:id,operation_id:body.operationId,request_hash:'hash',actor_session_id:actors[role].sessionId,resulting_version:expected.version,created_at:row.updated_at});
      assert.match(receipt.request_hash,/^[0-9a-f]{64}$/); assert.deepEqual(await rows('generation_job_operations'),[...before,receipt]);
      mutationReceipts.push(receipt); return response;
    }
    const invalidMessage='Only generation job metadata is accepted. Keep prompts, paths and credentials on your Mac.';
    const conflictMessage='Job ownership, version or project access changed. Refresh before retrying.';
    const a=randomUUID(), b=randomUUID(), originalA={id:a,targetItemId,sourceRevision:11};
    await refusal(route(''),post({...originalA,prompt:'Synthetic private prompt marker'}),400,'invalid_field',invalidMessage);
    let response=await request(route(''),post(originalA)); assert.equal(response.status,201);
    await publicJob(response.data.job,a,expectState('queued',1,'member','Queued on this Mac'));
    const firstClaim={operationId:randomUUID(),expectedVersion:1};
    await refusal(route('/'+a+'/claim'),post({...firstClaim,credential:'synthetic-not-a-credential'}),400,'invalid_field',invalidMessage);
    await refusal(route('/'+a+'/claim'),post({...firstClaim,recover:'yes'}),400,'invalid_field','recover must be a boolean.');
    await mutation(a,firstClaim,'member',true,expectState('running',2,'member','Starting on this Mac'));
    const progressOp={operationId:randomUUID(),expectedVersion:2,status:'running'};
    await refusal(route('/'+a),patch({...progressOp,progressText:'Line one\nLine two'}),400,'invalid_field','Progress must be a single short line.');
    await refusal(route('/'+a),patch({...progressOp,progressText:'x'.repeat(161)}),400,'invalid_field','progressText must be 1–160 characters.');
    await refusal(route('/'+a),patch({...progressOp,outputImageId}),400,'invalid_field','Only completed jobs have an output image ID.');
    await refusal(route('/'+a),patch({...progressOp,errorCode:'synthetic_error'}),400,'invalid_field','Only failed, waiting or cancelled jobs have an error code.');
    await refusal(route('/'+a),patch({...progressOp,status:'failed',errorCode:'Provider says: synthetic failure'}),400,'invalid_field','Use a short error code, not a provider response.');
    await refusal(route('/'+a),patch({...progressOp,localPath:'/synthetic/private/input'}),400,'invalid_field',invalidMessage);
    const progressText='x'.repeat(160);
    await mutation(a,{...progressOp,progressText},'member',false,expectState('running',3,'member',progressText));
    await mutation(a,{operationId:randomUUID(),expectedVersion:3,status:'waiting',errorCode:'user_paused'},'member',false,expectState('waiting',4,'member','Waiting for this Mac',{errorCode:'user_paused'}));
    await refusal(route('/'+a+'/claim'),{...post({operationId:randomUUID(),expectedVersion:4}),role:'member2'},409,'job_conflict',conflictMessage);
    const recoveryA={operationId:randomUUID(),expectedVersion:4,recover:true};
    await mutation(a,recoveryA,'member2',true,expectState('running',5,'member2','Starting on this Mac'));
    const beforeReplay=await business();
    response=await request(route('/'+a+'/claim'),post(firstClaim)); assert.equal(response.status,200); assert.equal(response.data.replayed,true);
    await publicJob(response.data.job,a,expectState('running',5,'member2','Starting on this Mac')); assert.deepEqual(await business(),beforeReplay);
    await refusal(route('/'+a+'/claim'),{...post(firstClaim),role:'member2'},409,'operation_conflict','This operation ID was already used for a different request or device.');
    await refusal(route('/'+a),patch({operationId:randomUUID(),expectedVersion:5,status:'completed',outputImageId}),409,'job_conflict',conflictMessage);
    const completedA={operationId:randomUUID(),expectedVersion:5,status:'completed',outputImageId};
    await mutation(a,completedA,'member2',false,expectState('completed',6,'member2','Completed',{outputImageId}));
    const beforeCreateReplay=await business();
    response=await request(route(''),post(originalA)); assert.equal(response.status,200); assert.equal(response.data.replayed,true);
    await publicJob(response.data.job,a,expectState('completed',6,'member2','Completed',{outputImageId})); assert.deepEqual(await business(),beforeCreateReplay);
    const originalB={id:b,targetItemId,sourceRevision:12};
    response=await request(route(''),post(originalB)); assert.equal(response.status,201);
    await publicJob(response.data.job,b,expectState('queued',1,'member','Queued on this Mac'));
    await mutation(b,{operationId:randomUUID(),expectedVersion:1},'member',true,expectState('running',2,'member','Starting on this Mac'));
    const beforeLogout=await business(), rawB=await getJobRow(b); assert.ok(rawB.lease_expires_at>Date.now());
    response=await request('/auth/logout',{method:'POST',role:'member'}); assert.equal(response.status,200); assert.deepEqual(response.data,{ok:true});
    const revoked=await db.prepare('SELECT revoked_at,expires_at FROM sessions WHERE id=?').bind(actors.member.sessionId).first();
    assert.ok(Number.isInteger(revoked.revoked_at)); assert.ok(revoked.expires_at>Date.now());
    const retained=await db.prepare('SELECT revoked_at,expires_at FROM sessions WHERE id=?').bind(actors.member2.sessionId).first();
    assert.equal(retained.revoked_at,null); assert.ok(retained.expires_at>Date.now()); assert.deepEqual(await business(),beforeLogout);
    response=await request(route('/'+b),{role:'viewer'}); assert.equal(response.status,200);
    await publicJob(response.data.job,b,expectState('waiting',2,'member','Waiting for this Mac'),true);
    assert.deepEqual(await getJobRow(b),rawB); assert.ok(rawB.lease_expires_at>Date.now());
    response=await request(route(''),{role:'viewer'}); assert.equal(response.status,200); assert.equal(response.data.nextCursor,null);
    assert.equal(response.data.jobs.length,5); assert.deepEqual(new Set(response.data.jobs.map(j=>j.id)),new Set([jobId,job2,job3,a,b]));
    for(const [id,version] of [[job3,1],[b,2]]) await publicJob(response.data.jobs.find(j=>j.id===id),id,expectState('waiting',version,'member','Waiting for this Mac'),true);
    assert.deepEqual(await business(),beforeLogout);
    await refusal(route('/'+b),patch({operationId:randomUUID(),expectedVersion:2,status:'completed',outputImageId}),401,'session_expired','Your Scriv session has expired. Sign in again.');
    await refusal(route('/'+b+'/claim'),{...post({operationId:randomUUID(),expectedVersion:2}),role:'member2'},409,'job_conflict',conflictMessage);
    assert.ok(rawB.lease_expires_at>Date.now());
    const recoveryB={operationId:randomUUID(),expectedVersion:2,recover:true};
    await mutation(b,recoveryB,'member2',true,expectState('running',3,'member2','Starting on this Mac'));
    const beforeRecoveryReplay=await business();
    response=await request(route('/'+b+'/claim'),{...post(recoveryB),role:'member2'}); assert.equal(response.status,200); assert.equal(response.data.replayed,true);
    await publicJob(response.data.job,b,expectState('running',3,'member2','Starting on this Mac')); assert.deepEqual(await business(),beforeRecoveryReplay);
    await mutation(b,{operationId:randomUUID(),expectedVersion:3,status:'completed',outputImageId},'member2',false,expectState('completed',4,'member2','Completed',{outputImageId}));
    const final=await business(); assert.equal(mutationReceipts.length,8); assert.equal(refused,14);
    assert.deepEqual(final.jobs.filter(j=>j.id!==a&&j.id!==b),baseline.jobs); assert.equal(final.jobs.length,baseline.jobs.length+2);
    assert.deepEqual(final.receipts,[...baseline.receipts,...mutationReceipts]);
    for(const key of ['projects','teams','members','assets','objects']) assert.deepEqual(final[key],baseline[key]);
    assert.equal(outboundAttempts,0); assert.equal(requests-recoveryStart,30);
    console.log(JSON.stringify({kind:'generation-recovery-evidence',httpChecks:requests-recoveryStart,refusals:refused,mutationReceipts:mutationReceipts.length,
      originalCallbacks:34,realLogout:true,leaseExpiryTested:false,nativeScenarios:0,outboundAttempts}));
    // Duplicate and competing callbacks use real concurrent HTTP, not forced SQL overlap.
    assert.equal(requests,64);const callbackBaseline=await business(),callbackUsers=await rows('users'),callbackSessions=await rows('sessions');
    const callbackId=randomUUID(),callbackOriginal={id:callbackId,targetItemId,sourceRevision:21};
    const call=(body,claim=false)=>request(route('/'+callbackId+(claim?'/claim':'')),{method:claim?'POST':'PATCH',body,role:'member2'});
    const receiptHash=(body,claim=false)=>{const raw={action:claim?'claim':'update',...body};return createHash('sha256').update(JSON.stringify(Object.fromEntries(Object.keys(raw).sort().map(k=>[k,raw[k]])))).digest('hex');};
    const callbackReceipts=[];
    const checkMutation=async(body,claim,expected,start,end)=>{
      const row=await getJobRow(callbackId);assert.equal(row.created_at,callbackCreatedRow.created_at);assert.equal(row.source_revision,21);assert.equal(row.last_operation_id,body.operationId);assert(row.updated_at>=start&&row.updated_at<=end);
      assert.equal(row.version,expected.version);assert.equal(row.status,expected.status);assert.equal(row.progress_text,expected.progressText);assert.equal(row.owner_device_id,actors.member2.sessionId);assert.equal(row.owner_device_name,'Synthetic second device');assert.equal(row.output_image_id,expected.outputImageId??null);assert.equal(row.error_code,null);
      if(expected.status==='running')assert(row.lease_expires_at>=start+90000&&row.lease_expires_at<=end+90000);else assert.equal(row.lease_expires_at,0);
      const expectedReceipt={project_id:projectId,job_id:callbackId,operation_id:body.operationId,request_hash:receiptHash(body,claim),actor_session_id:actors.member2.sessionId,resulting_version:expected.version,created_at:row.updated_at};
      callbackReceipts.push(expectedReceipt);assert.deepEqual((await rows('generation_job_operations')).filter(r=>r.job_id===callbackId),callbackReceipts);return row;
    };
    const callbackCreateStart=Date.now();response=await request(route(''),{...post(callbackOriginal),role:'member2'});const callbackCreateEnd=Date.now();assert.equal(response.status,201);const callbackCreatedRow=await publicJob(response.data.job,callbackId,expectState('queued',1,'member2','Queued on this Mac'));assert.equal(callbackCreatedRow.source_revision,21);assert(callbackCreatedRow.created_at>=callbackCreateStart&&callbackCreatedRow.created_at<=callbackCreateEnd);assert.equal(callbackCreatedRow.updated_at,callbackCreatedRow.created_at);assert(callbackCreatedRow.lease_expires_at>=callbackCreateStart+90000&&callbackCreatedRow.lease_expires_at<=callbackCreateEnd+90000);
    const duplicateClaim={operationId:randomUUID(),expectedVersion:1},duplicateStart=Date.now(),duplicates=await Promise.all([call(duplicateClaim,true),call(duplicateClaim,true)]),duplicateEnd=Date.now();
    const claimedState=expectState('running',2,'member2','Starting on this Mac');for(const r of duplicates){assert.equal(r.status,200);assert(Object.keys(r.data).every(k=>k==='job'||k==='replayed'));if('replayed'in r.data)assert.equal(r.data.replayed,true);await publicJob(r.data.job,callbackId,claimedState);}assert.deepEqual(duplicates[0].data.job,duplicates[1].data.job);await checkMutation(duplicateClaim,true,claimedState,duplicateStart,duplicateEnd);
    const progressBodies=['First concurrent callback','Second concurrent callback'].map(progressText=>({operationId:randomUUID(),expectedVersion:2,status:'running',progressText}));
    const progressStart=Date.now(),progressResults=await Promise.all(progressBodies.map(body=>call(body))),progressEnd=Date.now();assert.deepEqual(progressResults.map(r=>r.status).sort(),[200,409]);
    const progressWinner=progressResults.findIndex(r=>r.status===200),progressLoser=1-progressWinner,progressState=expectState('running',3,'member2',progressBodies[progressWinner].progressText);
    assert.deepEqual(progressResults[progressLoser].data,{error:{code:'job_conflict',message:conflictMessage}});await publicJob(progressResults[progressWinner].data.job,callbackId,progressState);await checkMutation(progressBodies[progressWinner],false,progressState,progressStart,progressEnd);
    response=await request(route('/'+callbackId),{role:'viewer'});assert.equal(response.status,200);await publicJob(response.data.job,callbackId,progressState);
    let callbackBefore=await business();response=await call(progressBodies[progressLoser]);assert.equal(response.status,409);assert.deepEqual(response.data,{error:{code:'job_conflict',message:conflictMessage}});assert.deepEqual(await business(),callbackBefore);
    const correctedProgress={...progressBodies[progressLoser],expectedVersion:3},correctedStart=Date.now(),correctedResult=await call(correctedProgress),correctedEnd=Date.now(),correctedState=expectState('running',4,'member2',correctedProgress.progressText);
    assert.equal(correctedResult.status,200);await publicJob(correctedResult.data.job,callbackId,correctedState);await checkMutation(correctedProgress,false,correctedState,correctedStart,correctedEnd);
    const completions=[0,1].map(()=>({operationId:randomUUID(),expectedVersion:4,status:'completed',outputImageId:randomUUID()}));
    const completionStart=Date.now(),completionResults=await Promise.all(completions.map(body=>call(body))),completionEnd=Date.now();assert.deepEqual(completionResults.map(r=>r.status).sort(),[200,409]);
    const completionWinner=completionResults.findIndex(r=>r.status===200),completionLoser=1-completionWinner,terminalState=expectState('completed',5,'member2','Completed',{outputImageId:completions[completionWinner].outputImageId});
    assert.deepEqual(completionResults[completionLoser].data,{error:{code:'job_conflict',message:conflictMessage}});await publicJob(completionResults[completionWinner].data.job,callbackId,terminalState);await checkMutation(completions[completionWinner],false,terminalState,completionStart,completionEnd);
    callbackBefore=await business();
    for(const [body,claim] of [[duplicateClaim,true],[progressBodies[progressWinner],false]]){response=await call(body,claim);assert.equal(response.status,200);assert.equal(response.data.replayed,true);await publicJob(response.data.job,callbackId,terminalState);assert.deepEqual(await business(),callbackBefore);}
    response=await call(completions[completionLoser]);assert.equal(response.status,409);assert.deepEqual(response.data,{error:{code:'job_conflict',message:conflictMessage}});assert.deepEqual(await business(),callbackBefore);
    response=await request(route('/'+callbackId),{role:'viewer'});assert.equal(response.status,200);await publicJob(response.data.job,callbackId,terminalState);
    for(const [body,claim] of [[{operationId:randomUUID(),expectedVersion:5,status:'cancelled'},false],[{operationId:randomUUID(),expectedVersion:5,recover:true},true]]){response=await call(body,claim);assert.equal(response.status,409);assert.deepEqual(response.data,{error:{code:'job_conflict',message:conflictMessage}});assert.deepEqual(await business(),callbackBefore);}
    const callbackFinal=await business();assert.deepEqual(callbackFinal.jobs.filter(r=>r.id!==callbackId),callbackBaseline.jobs);assert.equal(callbackFinal.jobs.length,callbackBaseline.jobs.length+1);assert.deepEqual(callbackFinal.receipts,[...callbackBaseline.receipts,...callbackReceipts]);assert.equal(callbackReceipts.length,4);
    for(const key of ['projects','teams','members','assets','objects'])assert.deepEqual(callbackFinal[key],callbackBaseline[key]);assert.deepEqual(await rows('users'),callbackUsers);assert.deepEqual(await rows('sessions'),callbackSessions);assert.equal(requests,80);assert.equal(outboundAttempts,0);
    console.log(JSON.stringify({kind:'generation-callback-concurrency-evidence',httpChecks:16,duplicateClaimResponses:2,duplicateClaimReceipts:1,competingPairs:2,winnersPerPair:1,correctedLoserSucceeds:true,finalVersion:5,newJobs:1,newReceipts:4,currentStateReplays:2,terminalRefusals:2,forcedInternalOverlap:false,nativeScenarios:0,outboundAttempts}));
    if (capture) await capture.end(await mf.ready, requests);
    console.log(JSON.stringify({result:'PASS',journey:'generation',requests,outboundAttempts,nativeScenarios:0,runtime:report}));
  } finally { await mf.dispose(); }
}
