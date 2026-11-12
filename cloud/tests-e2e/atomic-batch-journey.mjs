// Real HTTP service-process integration; not Catalyst/native application E2E.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, rm, readFile, readdir, copyFile, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, isAbsolute } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';

process.on('uncaughtException', () => { console.error('Atomic batch journey failed; no response or exception details were emitted.'); process.exitCode = 1; });
if (process.argv[2] !== '--owned-child' && (!process.env.SCRIV_TRACER_RUNTIME || !isAbsolute(process.env.SCRIV_TRACER_RUNTIME))) { console.error('Set SCRIV_TRACER_RUNTIME to the absolute path of the reviewed local Tracer runtime.'); process.exit(2); }
const here = await realpath(dirname(fileURLToPath(import.meta.url)));
// --cloud supports an outside-repository candidate without changing its sources.
const cloud = await realpath(process.argv[2] === '--owned-child' ? process.argv[4] :
  process.argv[2] === '--cloud' ? process.argv[3] : join(here, '..'));
const self = await realpath(fileURLToPath(import.meta.url));
if (process.argv[2] !== '--owned-child') {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'scriv-atomic-batch-')));
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
      bindings: { PUBLIC_URL: 'http://127.0.0.1', ENVIRONMENT: 'test' },
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
    const catalog = JSON.parse(await readFile(join(cloud, '../docs/testing/atomic-batch-steps.json'), 'utf8'));
    const run = createScenarioRun({ catalog, scenarioId:'atomic-batch-structural-edit', runId:randomUUID(), context:{build:'local-worker-bundle',platform:process.platform,inputRoute:'Scriv CLI service HTTP'} });
    const route = suffix => `/v1/projects/${projectId}/${suffix}`;
    const post = (body, extra = {}) => ({ method:'POST', body, role:'member', ...extra });
    const put = content => ({ method:'PUT', body:{content}, role:'member' });
    const project = { id:projectId, title:'Synthetic atomic story', teamId };
    const scene = randomUUID(), character = randomUUID(), entry = randomUUID();
    const ops = [
      { op:'put', id:scene, kind:'scene', expectedVersion:0, data:{id:scene,title:'Opening',order:0} },
      { op:'put', id:character, kind:'character', expectedVersion:0, data:{id:character,name:'Synthetic actor',aliases:[],biography:'',appearance:'',color:''} },
      { op:'put', id:entry, kind:'entry', expectedVersion:0, data:{id:entry,sceneId:scene,order:0,kind:'direction',text:'A door opens.',ownedDurationMs:1000,coverageDurationMs:1000,color:'',words:[]} },
    ];
    const contents = [JSON.stringify(ops.slice(0,2)), JSON.stringify(ops.slice(2))];
    const makeManifest = (parts, counts, overrides={}) => ({commandId:randomUUID(),sessionId:actors.member.sessionId,epoch:1,expectedTimingVersion:0,label:'Atomic structural edit',operationCount:counts.reduce((a,b)=>a+b,0),parts:parts.map((content,index)=>({hash:createHash('sha256').update(content).digest('hex'),bytes:Buffer.byteLength(content),count:counts[index]})),...overrides});
    const manifest = makeManifest(contents,[2,1]);
    const batch = (m,suffix) => route(`batches/${m.commandId}/${suffix}`);
    let result, receipt, baseline;
    await run.step('create-project', async step => {
      result = await step.action('POST /v1/projects synthetic team project', () => request('/v1/projects', post(project)));
      await step.expect('observed', () => { assert.equal(result.status,201); assert.equal(result.data.project.ownerId,actors.owner.id); });
    });
    await run.step('inspect-empty-project', async step => {
      result = await step.action('GET /v1/projects/:project/snapshot as viewer', () => request(route('snapshot'), {role:'viewer'}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.headSeq,0); assert.deepEqual(result.data.items,[]); });
    });
    await run.step('reject-invalid-manifest', async step => {
      result = await step.action('POST /v1/projects/:project/batches manifest with mismatched count', () => request(route('batches'),post({...manifest,operationCount:4})));
      await step.expect('observed', () => { assert.equal(result.status,400); assert.equal(result.data.error.code,'invalid_batch'); });
    });
    await run.step('prepare-edit', async step => {
      result = await step.action('POST /v1/projects/:project/batches valid two-part manifest', () => request(route('batches'),post(manifest)));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.staged,true); assert.equal(result.data.commandId,manifest.commandId); });
    });
    await run.step('retry-prepare', async step => {
      result = await step.action('POST /v1/projects/:project/batches identical manifest', () => request(route('batches'),post(manifest)));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.staged,true); });
    });
    await run.step('conflict-prepare', async step => {
      result = await step.action('POST /v1/projects/:project/batches changed label same command', () => request(route('batches'),post({...manifest,label:'Changed'})));
      await step.expect('observed', () => { assert.equal(result.status,409); assert.equal(result.data.error.code,'command_reused'); });
    });
    await run.step('incomplete-no-parts', async step => {
      result = await step.action('POST /v1/projects/:project/batches/:batch/commit before uploads', () => request(batch(manifest,'commit'),post(manifest)));
      await step.expect('observed', () => { assert.equal(result.status,409); assert.equal(result.data.error.code,'batch_incomplete'); });
    });
    await run.step('reject-part-bytes', async step => {
      result = await step.action('PUT /v1/projects/:project/batches/:batch/parts/0 mismatched bytes', () => request(batch(manifest,'parts/0'),put('[]')));
      await step.expect('observed', () => { assert.equal(result.status,400); assert.equal(result.data.error.code,'batch_part_mismatch'); });
    });
    await run.step('upload-first-part', async step => {
      result = await step.action('PUT /v1/projects/:project/batches/:batch/parts/0 scene and character', () => request(batch(manifest,'parts/0'),put(contents[0])));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.partIndex,0); assert.equal(result.data.staged,true); });
    });
    await run.step('retry-first-part', async step => {
      result = await step.action('PUT /v1/projects/:project/batches/:batch/parts/0 identical bytes', () => request(batch(manifest,'parts/0'),put(contents[0])));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.partIndex,0); });
    });
    await run.step('incomplete-one-part', async step => {
      result = await step.action('POST /v1/projects/:project/batches/:batch/commit after first part', () => request(batch(manifest,'commit'),post(manifest)));
      await step.expect('observed', () => { assert.equal(result.status,409); assert.equal(result.data.error.code,'batch_incomplete'); });
    });
    await run.step('inspect-before-commit', async step => {
      result = await step.action('GET /v1/projects/:project/snapshot before final part', () => request(route('snapshot'),{role:'viewer'}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.headSeq,0); assert.deepEqual(result.data.items,[]); });
    });
    await run.step('reject-viewer-upload', async step => {
      result = await step.action('PUT /v1/projects/:project/batches/:batch/parts/1 as viewer', () => request(batch(manifest,'parts/1'),{...put(contents[1]),role:'viewer'}));
      await step.expect('observed', () => { assert.equal(result.status,403); assert.equal(result.data.error.code,'read_only'); });
    });
    await run.step('upload-second-part', async step => {
      result = await step.action('PUT /v1/projects/:project/batches/:batch/parts/1 direction', () => request(batch(manifest,'parts/1'),put(contents[1])));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.partIndex,1); assert.equal(result.data.staged,true); });
    });
    await run.step('commit-edit', async step => {
      result = await step.action('POST /v1/projects/:project/batches/:batch/commit complete', () => request(batch(manifest,'commit'),post(manifest)));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.seq,1); assert.equal(result.data.timingVersion,1); assert.equal(result.data.snapshotRequired,true); receipt=result.data; });
    });
    await run.step('inspect-committed-project', async step => {
      result = await step.action('GET /v1/projects/:project/snapshot after commit', () => request(route('snapshot'),{role:'viewer'}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.headSeq,1); assert.equal(result.data.timingVersion,1); assert.equal(result.data.items.length,3); assert.deepEqual(new Set(result.data.items.map(item=>item.kind)),new Set(['scene','character','entry'])); assert.equal(result.data.items.find(item=>item.id===entry).data.sceneId,scene); baseline=result.data; });
    });
    await run.step('retry-commit', async step => {
      result = await step.action('POST /v1/projects/:project/batches/:batch/commit identical manifest', () => request(batch(manifest,'commit'),post(manifest)));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.deepEqual(result.data,receipt); });
    });
    await run.step('conflict-receipt', async step => {
      result = await step.action('POST /v1/projects/:project/batches/:batch/commit changed label', () => request(batch(manifest,'commit'),post({...manifest,label:'Changed'})));
      await step.expect('observed', () => { assert.equal(result.status,409); assert.equal(result.data.error.code,'command_reused'); });
    });
    const image=randomUUID(), cue=randomUUID();
    const visualOps=[{op:'put',id:scene,kind:'scene',expectedVersion:1,data:{...ops[0].data,title:'Revised opening'}},{op:'put',id:image,kind:'image',expectedVersion:0,data:{id:image,version:1,fileName:'synthetic.png',sha256:'a'.repeat(64),mimeType:'image/png',byteCount:1,characterIds:[character],prompt:'',createdAt:0}},{op:'put',id:cue,kind:'cue',expectedVersion:0,data:{id:cue,sceneId:scene,startMs:0,endMs:1000,startAnchor:{entryId:entry,offsetMs:0},authoredDurationMs:1000,label:'Door',prompt:'',imageId:image}}];
    const visualContents=[JSON.stringify(visualOps.slice(0,2)),JSON.stringify(visualOps.slice(2))];
    const visualManifest=makeManifest(visualContents,[2,1],{expectedTimingVersion:1,label:'Image cue edit'});
    await run.step('prepare-image-cue', async step => {
      result = await step.action('POST /v1/projects/:project/batches image and cue manifest', () => request(route('batches'),post(visualManifest)));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.staged,true); });
    });
    await run.step('upload-image-part', async step => {
      result = await step.action('PUT /v1/projects/:project/batches/:batch/parts/0 image and scene update', () => request(batch(visualManifest,'parts/0'),put(visualContents[0])));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.partIndex,0); });
    });
    await run.step('upload-cue-part', async step => {
      result = await step.action('PUT /v1/projects/:project/batches/:batch/parts/1 anchored cue', () => request(batch(visualManifest,'parts/1'),put(visualContents[1])));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.partIndex,1); });
    });
    await run.step('commit-image-cue', async step => {
      result = await step.action('POST /v1/projects/:project/batches/:batch/commit image and cue', () => request(batch(visualManifest,'commit'),post(visualManifest)));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.seq,2); assert.equal(result.data.timingVersion,2); assert.equal(result.data.snapshotRequired,true); });
    });
    await run.step('inspect-image-cue', async step => {
      result = await step.action('GET /v1/projects/:project/snapshot after image and cue', () => request(route('snapshot'),{role:'viewer'}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.headSeq,2); assert.equal(result.data.timingVersion,2); assert.equal(result.data.items.length,5); assert.equal(result.data.items.find(item=>item.id===scene).data.title,'Revised opening'); assert.equal(result.data.items.find(item=>item.id===scene).version,2); assert.equal(result.data.items.find(item=>item.id===cue).data.startAnchor.entryId,entry); assert.equal(result.data.items.find(item=>item.id===cue).data.imageId,image); assert.equal(result.data.items.find(item=>item.id===image).data.characterIds[0],character); baseline=result.data; });
    });
    const invalidOp = {...ops[2],id:randomUUID(),data:{...ops[2].data,id:randomUUID(),words:[{id:randomUUID(),text:'A',startMs:0,endMs:1}]}}; invalidOp.data.id=invalidOp.id;
    const invalidContent=JSON.stringify([invalidOp]); const invalidManifest=makeManifest([invalidContent],[1],{expectedTimingVersion:2});
    await run.step('reject-invalid-part-prepare', async step => {
      result = await step.action('POST /v1/projects/:project/batches invalid direction manifest', () => request(route('batches'),post(invalidManifest)));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.staged,true); });
    });
    await run.step('reject-invalid-direction', async step => {
      result = await step.action('PUT /v1/projects/:project/batches/:batch/parts/0 direction with words', () => request(batch(invalidManifest,'parts/0'),put(invalidContent)));
      await step.expect('observed', () => { assert.equal(result.status,400); assert.equal(result.data.error.code,'direction_timing'); });
    });
    const extraScene=randomUUID(), orphan=randomUUID();
    const rollbackContent=JSON.stringify([{op:'put',id:extraScene,kind:'scene',expectedVersion:0,data:{id:extraScene,title:'Must roll back',order:1}},{op:'put',id:orphan,kind:'entry',expectedVersion:0,data:{...ops[2].data,id:orphan,sceneId:randomUUID()}}]);
    const rollbackManifest=makeManifest([rollbackContent],[2],{expectedTimingVersion:2});
    await run.step('prepare-rollback', async step => {
      result = await step.action('POST /v1/projects/:project/batches missing reference manifest', () => request(route('batches'),post(rollbackManifest)));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.staged,true); });
    });
    await run.step('upload-rollback', async step => {
      result = await step.action('PUT /v1/projects/:project/batches/:batch/parts/0 scene and orphan entry', () => request(batch(rollbackManifest,'parts/0'),put(rollbackContent)));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.staged,true); });
    });
    await run.step('reject-reference-commit', async step => {
      result = await step.action('POST /v1/projects/:project/batches/:batch/commit missing scene reference', () => request(batch(rollbackManifest,'commit'),post(rollbackManifest)));
      await step.expect('observed', () => { assert.equal(result.status,400); assert.equal(result.data.error.code,'invalid_reference'); });
    });
    await run.step('inspect-rollback', async step => {
      result = await step.action('GET /v1/projects/:project/snapshot after failed commit', () => request(route('snapshot'),{role:'viewer'}));
      await step.expect('observed', () => { assert.equal(result.status,200); assert.equal(result.data.headSeq,baseline.headSeq); assert.equal(result.data.timingVersion,baseline.timingVersion); assert.deepEqual(result.data.items,baseline.items); });
    });
    const report=run.finish();
    assert.equal(report.status,'passed');
    assert.equal(outboundAttempts,0);
    // Staging is device-bound; accepted receipts remain recoverable by the same user.
    assert.equal(requests,29);
    const initialUsers=(await db.prepare('SELECT * FROM users ORDER BY id').all()).results, initialSessions=(await db.prepare('SELECT * FROM sessions ORDER BY id').all()).results;
    const second=actors.second={...actors.member,sessionId:randomUUID(),token:randomBytes(32).toString('base64url')}, secondAt=Date.now();
    await db.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at) VALUES(?,?,?,?,?,?)').bind(createHash('sha256').update(second.token).digest('hex'),second.sessionId,second.id,'Synthetic second batch device',secondAt,secondAt+3600000).run();
    const seededSessions=(await db.prepare('SELECT * FROM sessions ORDER BY id').all()).results; assert.equal(seededSessions.length,initialSessions.length+1); assert.deepEqual(seededSessions.filter(s=>s.id!==second.sessionId),initialSessions);
    const withoutLeases=({leases,...snapshot})=>snapshot, byId=items=>[...items].sort((a,b)=>a.id.localeCompare(b.id));
    const observe=async()=>{const snapshot=await request(route('snapshot'),{role:'viewer'}),events=await request(route('events?after=0'),{role:'viewer'});assert.equal(snapshot.status,200);assert.equal(events.status,200);return {snapshot:snapshot.data,events:events.data};};
    const unchanged=(a,b)=>{assert.deepEqual(withoutLeases(a.snapshot),withoutLeases(b.snapshot));assert.deepEqual(a.events,b.events);};
    const rejected=(r,status,code)=>{assert.equal(r.status,status);assert.equal(r.data.error.code,code);};
    const prepare=(m,role='member')=>request(route('batches'),post(m,{role}));
    const upload=(m,content,role='member')=>request(batch(m,'parts/0'),{...put(content),role});
    const commitBatch=(m,role='member')=>request(batch(m,'commit'),post(m,{role}));
    const staged=(r,m)=>{assert.equal(r.status,200);assert.deepEqual(r.data,{commandId:m.commandId,staged:true});};
    const original=await observe(); assert.equal(original.snapshot.headSeq,2); assert.equal(original.snapshot.timingVersion,2); assert.equal(original.snapshot.epoch,1); assert.equal(original.snapshot.items.length,5); assert.deepEqual(original.snapshot.deletedItems,[]); assert.equal(original.events.events.length,2);
    const sceneA=randomUUID(),sceneB=randomUUID();
    const opA={op:'put',id:sceneA,kind:'scene',expectedVersion:0,data:{id:sceneA,title:'Recovered first-device scene',order:1}},opB={op:'put',id:sceneB,kind:'scene',expectedVersion:0,data:{id:sceneB,title:'Second-device scene',order:2}};
    const contentA=JSON.stringify([opA]),contentB=JSON.stringify([opB]);
    const draftA=makeManifest([contentA],[1],{expectedTimingVersion:2,label:'First-device staged edit'}),draftB=makeManifest([contentB],[1],{sessionId:second.sessionId,expectedTimingVersion:2,label:'Second-device staged edit'});
    const probeScene=randomUUID(), probeContent=JSON.stringify([{op:'put',id:probeScene,kind:'scene',expectedVersion:0,data:{id:probeScene,title:'Uncommitted capacity probe',order:3}}]);
    const capacityProbe=makeManifest([probeContent],[1],{expectedTimingVersion:2,label:'Uncommitted capacity probe'});
    staged(await prepare(draftA),draftA);
    // The original invalid-part manifest still occupies the first of two user slots.
    rejected(await prepare(draftB,'second'),429,'batch_capacity');
    rejected(await upload(draftA,contentA,'owner'),409,'batch_session_changed');
    rejected(await upload(draftA,contentA,'second'),409,'batch_session_changed');
    const uploadedA=await upload(draftA,contentA); assert.equal(uploadedA.status,200); assert.deepEqual(uploadedA.data,{commandId:draftA.commandId,partIndex:0,staged:true});
    rejected(await prepare(draftA,'owner'),409,'command_reused');
    rejected(await prepare(draftA,'second'),409,'batch_session_changed');
    rejected(await upload(draftA,contentA),409,'batch_incomplete');
    staged(await prepare(draftB,'second'),draftB);
    rejected(await prepare(capacityProbe),429,'batch_capacity');
    const uploadedB=await upload(draftB,contentB,'second'); assert.equal(uploadedB.status,200); assert.deepEqual(uploadedB.data,{commandId:draftB.commandId,partIndex:0,staged:true});
    const beforeB=Date.now(),committedB=await commitBatch(draftB,'second'),afterB=Date.now(); assert.equal(committedB.status,200); assert.deepEqual(committedB.data,{commandId:draftB.commandId,seq:3,epoch:1,timingVersion:2,items:[],snapshotRequired:true});
    const stateB=await observe();
    const assertAppend=(before,after,op,m,start,end)=>{
      assert.deepEqual(byId(after.snapshot.items),byId([...before.snapshot.items,{id:op.id,kind:op.kind,data:op.data,version:1,deleted:false}]));
      assert.deepEqual(withoutLeases(after.snapshot),{...withoutLeases(before.snapshot),headSeq:before.snapshot.headSeq+1,items:after.snapshot.items});
      const event=after.events.events.at(-1); assert(event.at>=start&&event.at<=end);
      assert.deepEqual(event,{seq:before.snapshot.headSeq+1,epoch:1,commandId:m.commandId,actorId:actors.member.id,kind:'command',at:event.at,changes:[],data:{label:m.label,timingVersion:2,snapshotRequired:true}});
      assert.deepEqual(after.events,{events:[...before.events.events,event],headSeq:before.snapshot.headSeq+1,epoch:1,timingVersion:2,hasMore:false});
    };
    assertAppend(original,stateB,opB,draftB,beforeB,afterB);
    const replayB=await commitBatch(draftB); assert.equal(replayB.status,200); assert.deepEqual(replayB.data,committedB.data);
    rejected(await commitBatch(draftB,'owner'),409,'command_reused'); rejected(await commitBatch({...draftB,label:'Different retry'},'second'),409,'command_reused'); unchanged(await observe(),stateB);
    // Semantic commit failure must free capacity without changing the document/history.
    staged(await prepare(rollbackManifest),rollbackManifest); assert.equal((await upload(rollbackManifest,rollbackContent)).status,200);
    rejected(await prepare(capacityProbe),429,'batch_capacity');
    rejected(await commitBatch(rollbackManifest),400,'invalid_reference'); unchanged(await observe(),stateB);
    // Re-preparing the discarded first-device edit must not resurrect its uploaded part.
    staged(await prepare(draftA),draftA); rejected(await commitBatch(draftA),409,'batch_incomplete');
    rejected(await prepare(capacityProbe),429,'batch_capacity');
    assert.equal((await upload(draftA,contentA)).status,200);
    const beforeA=Date.now(),committedA=await commitBatch(draftA),afterA=Date.now(); assert.equal(committedA.status,200); assert.deepEqual(committedA.data,{commandId:draftA.commandId,seq:4,epoch:1,timingVersion:2,items:[],snapshotRequired:true});
    const stateA=await observe(); assertAppend(stateB,stateA,opA,draftA,beforeA,afterA);
    const recoveredA=await commitBatch(draftA,'second'),recoveredB=await commitBatch(draftB,'second'); assert.equal(recoveredA.status,200);assert.deepEqual(recoveredA.data,committedA.data);assert.equal(recoveredB.status,200);assert.deepEqual(recoveredB.data,committedB.data); unchanged(await observe(),stateA);
    // Fill the other slot: the original draft must remain reusable without new capacity.
    staged(await prepare(capacityProbe),capacityProbe); rejected(await prepare({...capacityProbe,commandId:randomUUID()}),429,'batch_capacity');
    staged(await prepare(invalidManifest),invalidManifest); rejected(await upload(invalidManifest,invalidContent),400,'direction_timing'); rejected(await commitBatch(invalidManifest),409,'batch_incomplete'); unchanged(await observe(),stateA);
    assert.deepEqual((await db.prepare('SELECT * FROM users ORDER BY id').all()).results,initialUsers); assert.deepEqual((await db.prepare('SELECT * FROM sessions ORDER BY id').all()).results,seededSessions);
    assert.deepEqual((await bucket.list()).objects,[]); assert.equal(requests,74); assert.equal(outboundAttempts,0);
    console.log(JSON.stringify({kind:'batch-session-capacity-evidence',httpChecks:45,capacityRefusals:5,sharedUserCapacityStatus:429,crossSessionStagingStatus:409,discardedPartRequiresUpload:true,failedCommitFreesCapacity:true,successfulCommits:2,acceptedReceiptRecoveries:3,newEvents:2,originalItemsPreserved:5,syntheticAuthSessionsAdded:1,internalStagingRowsObserved:false,nativeScenarios:0,outboundAttempts}));
    console.log(JSON.stringify({result:'PASS', journey:'atomic-batch', requests, outboundAttempts, nativeScenarios:0, runtime:report}));
  } finally { await mf.dispose(); }
}
