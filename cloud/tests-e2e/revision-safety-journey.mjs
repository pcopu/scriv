// Real HTTP service-process integration; not Catalyst/native application E2E.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, rm, readFile, readdir, copyFile, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, isAbsolute } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';

process.on('uncaughtException', error => { console.error('Revision safety journey failed; only stack locations follow.', String(error.stack).split('\n').filter(line=>/^\s+at /.test(line)).join('\n')); process.exitCode = 1; });
if (process.argv[2] !== '--owned-child' && (!process.env.SCRIV_TRACER_RUNTIME || !isAbsolute(process.env.SCRIV_TRACER_RUNTIME))) { console.error('Set SCRIV_TRACER_RUNTIME to the absolute path of the reviewed local Tracer runtime.'); process.exit(2); }
const here = await realpath(dirname(fileURLToPath(import.meta.url)));
// --cloud supports an outside-repository candidate without changing its sources.
const cloud = await realpath(process.argv[2] === '--owned-child' ? process.argv[4] :
  process.argv[2] === '--cloud' ? process.argv[3] : join(here, '..'));
const self = await realpath(fileURLToPath(import.meta.url));
if (process.argv[2] !== '--owned-child') {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'scriv-revision-safety-')));
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
      assert(requests++ < 200); assert(Buffer.byteLength(encoded ?? '') <= 16384);
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
    const catalog = JSON.parse(await readFile(join(cloud, '../docs/testing/revision-safety-steps.json'), 'utf8'));
    const run = createScenarioRun({ catalog, scenarioId:'revision-safety', runId:randomUUID(), context:{build:'local-worker-bundle',platform:process.platform,inputRoute:'Scriv CLI service HTTP'} });

    const route = suffix => `/v1/projects/${projectId}/${suffix}`;
    const post = body => ({method:'POST',body,role:'member'});
    const a=itemId,b=randomUUID(),c=randomUUID();
    const data=(id,title,order)=>({id,title,order});
    const item=(id,title,order,version,deleted=false)=>({id,kind:'scene',data:data(id,title,order),version,deleted});
    const originalA=item(a,'Opening',0,1), originalB=item(b,'Ending',1,1);
    let expected=[originalA,originalB], head=0, epoch=1, timing=0, expectedEvents=[], lease, nextLease, leaseStart, leaseEnd; const observedEventTimes=new Map();
    const sort=rows=>rows.slice().sort((x,y)=>x.id.localeCompare(y.id));
    const project=()=>({projectId,headSeq:head,epoch,timingVersion:timing,items:sort(expected.filter(x=>!x.deleted)),deletedItems:sort(expected.filter(x=>x.deleted).map(x=>({...x,data:{}}))),canImport:false,threads:[]});
    const cmd=(operations,extra={})=>({commandId:randomUUID(),sessionId:actors.member.sessionId,epoch,label:'Revision safety',operations,...extra});
    const put=(row,version,proof)=>({op:'put',id:row.id,kind:row.kind,data:row.data,expectedVersion:version,...(proof?{lease:{token:proof.token,fence:proof.fence}}:{})});
    const initial=cmd([put(originalA,0),put(originalB,0)]);
    const proofBody=(proof=lease)=>({itemId:a,sessionId:actors.member.sessionId,epoch:proof.epoch,token:proof.token,fence:proof.fence});
    const expectedReceipt=(command,seq,ep,items,tv=0)=>({commandId:command.commandId,seq,epoch:ep,timingVersion:tv,items});
    function accept(command,seq,changes,ep=epoch,tv=timing){
      head=seq;epoch=ep;timing=tv;
      expectedEvents.push({seq,epoch:ep,commandId:command.commandId,actorId:actors.member.id,kind:'command',changes:sort(changes),data:{label:'Revision safety',timingVersion:tv}});
    }
    function state(snap,events){
      assert.equal(snap.status,200);assert.equal(events.status,200);
      const {leases,...publicState}=snap.data;assert.deepEqual(publicState,project());
      assert.deepEqual(events.data,{events:events.data.events,headSeq:head,epoch,timingVersion:timing,hasMore:false});
      assert.equal(events.data.events.length,expectedEvents.length);
      for(let i=0;i<expectedEvents.length;i++){const {at,...event}=events.data.events[i];assert.equal(Number.isSafeInteger(at),true);assert(at>=now&&at<=Date.now());if(observedEventTimes.has(event.seq))assert.equal(at,observedEventTimes.get(event.seq));else observedEventTimes.set(event.seq,at);assert.deepEqual(event,expectedEvents[i]);}
    }
    function publicLease(result,proof){
      assert.equal(result.status,200);const {token,...value}=proof;
      assert.deepEqual(result.data,{leases:[value],epoch});assert.equal(Object.hasOwn(result.data.leases[0],'token'),false);
    }
    async function perform(id,actions,verify){
      try { await run.step(id,async step=>{
        const results=[];
        for(const [name,fn] of actions)results.push(await step.action(name,fn));
        const snap=await step.action(`GET snapshot ${id}`,()=>request(route('snapshot')));
        const events=await step.action(`GET events ${id}`,()=>request(route('events?after=0')));
        await step.expect('observed',()=>{verify(...results);state(snap,events);});
      }); } catch(error) { console.error(JSON.stringify({result:'FAIL',journey:'revision-safety',runtime:run.finish()})); throw error; }
    }
    await perform('create-revision-base',[
      ["POST project revision base",()=>request('/v1/projects',post({id:projectId,title:'Revision safety',teamId}))],
      ["POST commands original scenes",()=>request(route('commands'),post(initial))]
    ],(created,saved)=>{assert.equal(created.status,201);assert.equal(saved.status,200);assert.deepEqual(saved.data,expectedReceipt(initial,1,1,[originalA,originalB]));accept(initial,1,[{id:a,before:null,after:originalA},{id:b,before:null,after:originalB}]);});
    await perform('acquire-and-renew',[
      ["POST leases opening",()=>request(route('leases'),post({itemId:a,sessionId:actors.member.sessionId})).then(r=>{lease=r.data;return r;})],
      ["Wait past initial lease timestamp",()=>new Promise(resolve=>setTimeout(resolve,25))],
      ["PUT leases renew opening",()=>(async()=>{leaseStart=Date.now();const r=await request(route('leases'),{...post(proofBody()),method:'PUT'});leaseEnd=Date.now();return r;})()],
      ["GET leases renewed opening",()=>request(route('leases'))]
    ],(acquired,wait,renewed,listed)=>{assert.equal(acquired.status,200);assert.equal(lease.itemId,a);assert.equal(lease.userId,actors.member.id);assert.equal(lease.sessionId,actors.member.sessionId);assert.equal(lease.fence,1);assert.equal(lease.epoch,1);assert.equal(typeof lease.token,'string');assert.equal(renewed.status,200);const {expiresAt,...identity}=renewed.data;assert.equal(JSON.stringify(identity)===JSON.stringify((({expiresAt,...v})=>v)(lease)),true);assert(expiresAt>lease.expiresAt);assert(expiresAt>=leaseStart+30000&&expiresAt<=leaseEnd+30000);lease=renewed.data;publicLease(listed,lease);});
    await perform('release-owned-lease',[
      ["DELETE leases opening",()=>request(route('leases'),{...post(proofBody()),method:'DELETE'})],
      ["GET leases after release",()=>request(route('leases'))]
    ],(released,listed)=>{assert.equal(released.status,200);assert.deepEqual(released.data,{ok:true});assert.equal(listed.status,200);assert.deepEqual(listed.data,{leases:[],epoch:1});});
    await perform('reacquire-new-fence',[
      ["POST leases reacquire opening",()=>request(route('leases'),post({itemId:a,sessionId:actors.member.sessionId})).then(r=>{nextLease=r.data;return r;})],
      ["POST commands released proof",()=>request(route('commands'),post(cmd([put(item(a,'Forbidden',0,2),1,lease)])))],
      ["GET leases current fence",()=>request(route('leases'))]
    ],(acquired,refused,listed)=>{assert.equal(acquired.status,200);assert.equal(nextLease.fence,2);assert.equal(nextLease.token!==lease.token,true);assert.equal(nextLease.epoch,1);assert.equal(refused.status,423);assert.equal(refused.data.error.code,'lease_required');publicLease(listed,nextLease);lease=nextLease;});
    await perform('reject-wrong-session',[
      ["POST commands mismatched session",()=>request(route('commands'),post(cmd([put(item(a,'Forbidden',0,2),1,lease)],{sessionId:randomUUID()})))],
      ["GET leases after session refusal",()=>request(route('leases'))]
    ],(refused,listed)=>{assert.equal(refused.status,423);assert.equal(refused.data.error.code,'lease_required');publicLease(listed,lease);});
    const deletion=cmd([{op:'delete',id:a,expectedVersion:1,lease:{token:lease.token,fence:lease.fence}}]);
    await perform('delete-opening',[
      ["POST commands delete opening",()=>request(route('commands'),post(deletion))]
    ],saved=>{const tombstone={...originalA,version:2,deleted:true};assert.equal(saved.status,200);assert.deepEqual(saved.data,expectedReceipt(deletion,2,1,[tombstone]));expected=[tombstone,originalB];accept(deletion,2,[{id:a,before:originalA,after:tombstone}]);});
    const undoItem=item(a,'Recovered opening',0,3); const undo=cmd([put(undoItem,2,lease)]);
    await perform('undo-deletion',[
      ["POST commands undo deletion",()=>request(route('commands'),post(undo))]
    ],saved=>{const before={...originalA,version:2,deleted:true};assert.equal(saved.status,200);assert.deepEqual(saved.data,expectedReceipt(undo,3,1,[undoItem]));expected=[undoItem,originalB];accept(undo,3,[{id:a,before,after:undoItem}]);});
    let bLease;const newC=item(c,'Later scene',2,1);let later;
    await perform('prepare-restore-divergence',[
      ["POST leases ending",()=>request(route('leases'),post({itemId:b,sessionId:actors.member.sessionId})).then(r=>{bLease=r.data;return r;})],
      ["POST commands ending deletion and new scene",()=>(async()=>{later=cmd([{op:'delete',id:b,expectedVersion:1,lease:{token:bLease.token,fence:bLease.fence}},put(newC,0)]);return request(route('commands'),post(later));})()]
    ],(acquired,saved)=>{assert.equal(acquired.status,200);const tombstone={...originalB,version:2,deleted:true};assert.equal(saved.status,200);assert.deepEqual(saved.data,expectedReceipt(later,4,1,[tombstone,newC]));expected=[undoItem,tombstone,newC];accept(later,4,[{id:b,before:originalB,after:tombstone},{id:c,before:null,after:newC}]);});
    await perform('read-historical-tombstone',[
      ["GET snapshot deleted revision",()=>request(route('snapshot?seq=2&epoch=1'))],
      ["GET snapshot undone revision",()=>request(route('snapshot?seq=3&epoch=1'))],
      ["GET snapshot wrong historical epoch",()=>request(route('snapshot?seq=2&epoch=2'))]
    ],(deleted,undone,refused)=>{for(const [r,seq,live,dead] of [[deleted,2,[originalB],[{...originalA,version:2,deleted:true,data:{}}]],[undone,3,sort([undoItem,originalB]),[]]]){assert.equal(r.status,200);const {historyEvent,...snapshot}=r.data;assert.deepEqual(snapshot,{projectId,epoch:1,headSeq:seq,timingVersion:0,items:live,deletedItems:dead,canImport:false,threads:[],leases:[],hasMore:false,nextCursor:null});const {at,...event}=historyEvent;assert(Number.isSafeInteger(at));assert.equal(at,observedEventTimes.get(seq));assert.deepEqual(event,{seq,epoch:1,actorId:actors.member.id,kind:'command'});}assert.equal(refused.status,409);assert.equal(refused.data.error.code,'history_epoch_mismatch');});
    const restore={commandId:randomUUID(),sessionId:actors.owner.sessionId,epoch:1,seq:1};
    await perform('restore-original-revision',[
      ["POST restore original revision",()=>request(route('restore'),{method:'POST',body:restore})],
      ["GET leases after restore",()=>request(route('leases'))]
    ],(saved,listed)=>{assert.equal(saved.status,200);assert.deepEqual(saved.data,{commandId:restore.commandId,seq:5,epoch:2,timingVersion:1,items:[],snapshotRequired:true});expected=[{...originalA,version:4},{...originalB,version:3},{...newC,version:2,deleted:true}];head=5;epoch=2;timing=1;expectedEvents.push({seq:5,epoch:2,commandId:restore.commandId,actorId:actors.owner.id,kind:'restore',changes:[],data:{label:'Restore history 1',restoreSeq:1,snapshotRequired:true,timingVersion:1}});assert.equal(listed.status,200);assert.deepEqual(listed.data,{leases:[],epoch:2});});
    await perform('replay-after-epoch-change',[
      ["POST commands replay old delete",()=>request(route('commands'),post(deletion))],
      ["POST commands changed old delete",()=>request(route('commands'),post({...deletion,label:'Changed retry'}))],
      ["POST restore replay original",()=>request(route('restore'),{method:'POST',body:restore})]
    ],(replayed,refused,restored)=>{assert.equal(replayed.status,200);assert.deepEqual(replayed.data,expectedReceipt(deletion,2,1,[{...originalA,version:2,deleted:true}]));assert.equal(refused.status,409);assert.equal(refused.data.error.code,'command_reused');assert.equal(restored.status,200);assert.deepEqual(restored.data,{commandId:restore.commandId,seq:5,epoch:2,timingVersion:1,items:[],snapshotRequired:true});});
    await perform('reject-stale-epoch',[
      ["POST commands old epoch",()=>request(route('commands'),post(cmd([put(item(a,'Forbidden',0,5),4,lease)],{epoch:1})))]
    ],refused=>{assert.equal(refused.status,409);assert.equal(refused.data.error.code,'stale_epoch');});
    await perform('reject-invalidated-proof',[
      ["POST commands old lease current epoch",()=>request(route('commands'),post(cmd([put(item(a,'Forbidden',0,5),4,lease)])))],
      ["GET leases remain invalidated",()=>request(route('leases'))]
    ],(refused,listed)=>{assert.equal(refused.status,423);assert.equal(refused.data.error.code,'lease_required');assert.equal(listed.status,200);assert.deepEqual(listed.data,{leases:[],epoch:2});});
    let refusedVersionCommand;
    await perform('reacquire-after-restore',[
      ["POST leases after restore",()=>request(route('leases'),post({itemId:a,sessionId:actors.member.sessionId})).then(r=>{lease=r.data;return r;})],
      ["POST commands stale item version",()=>{refusedVersionCommand=cmd([put(item(a,'Forbidden',0,5),3,lease)]);return request(route('commands'),post(refusedVersionCommand));}],
      ["GET leases after version refusal",()=>request(route('leases'))]
    ],(acquired,refused,listed)=>{assert.equal(acquired.status,200);assert.equal(lease.fence,3);assert.equal(lease.epoch,2);assert.equal(refused.status,409);assert.equal(refused.data.error.code,'version_conflict');publicLease(listed,lease);});
    await perform('reject-invalid-restores',[
      ["POST restore beyond head",()=>request(route('restore'),{method:'POST',body:{...restore,commandId:randomUUID(),epoch:2,seq:6}})],
      ["POST restore stale epoch",()=>request(route('restore'),{method:'POST',body:{...restore,commandId:randomUUID()}})]
    ],(future,stale)=>{assert.equal(future.status,400);assert.equal(future.data.error.code,'invalid_sequence');assert.equal(stale.status,409);assert.equal(stale.data.error.code,'stale_epoch');});
    await perform('read-ordered-history',[
      ["GET history first page",()=>request(route('history?after=3&limit=1'))],
      ["GET history terminal page",()=>request(route('history?after=4&limit=1'))]
    ],(first,last)=>{for(const [r,index,more] of [[first,3,true],[last,4,false]]){assert.equal(r.status,200);assert.equal(r.data.events.length,1);const {at,...event}=r.data.events[0];assert(Number.isSafeInteger(at));assert.deepEqual(event,expectedEvents[index]);assert.deepEqual({...r.data,events:[]},{events:[],headSeq:5,epoch:2,timingVersion:1,hasMore:more});}});
    await perform('expire-lease-naturally',[
      ["Wait until lease expiration",()=>new Promise(resolve=>setTimeout(resolve,Math.max(0,lease.expiresAt-Date.now()+50)))],
      ["POST commands expired proof",()=>request(route('commands'),post(cmd([put(item(a,'Forbidden',0,5),4,lease)])))],
      ["GET leases after natural expiry",()=>request(route('leases'))]
    ],(wait,refused,listed)=>{assert(Date.now()>lease.expiresAt);assert.equal(refused.status,423);assert.equal(refused.data.error.code,'lease_required');assert.equal(listed.status,200);assert.deepEqual(listed.data,{leases:[],epoch:2});});
    const finalItem=item(a,'Saved after recovery',0,5);let finalCommand;
    await perform('save-after-recovery',[
      ["POST leases after expiry",()=>request(route('leases'),post({itemId:a,sessionId:actors.member.sessionId})).then(r=>{nextLease=r.data;return r;})],
      ["POST commands recovered edit",()=>(async()=>{finalCommand=cmd([put(finalItem,4,nextLease)],{commandId:refusedVersionCommand.commandId});return request(route('commands'),post(finalCommand));})()]
    ],(acquired,saved)=>{assert.equal(acquired.status,200);assert.equal(nextLease.fence,4);assert.equal(nextLease.epoch,2);assert.equal(nextLease.token!==lease.token,true);assert.equal(saved.status,200);assert.deepEqual(saved.data,expectedReceipt(finalCommand,6,2,[finalItem],1));expected=[finalItem,{...originalB,version:3},{...newC,version:2,deleted:true}];accept(finalCommand,6,[{id:a,before:{...originalA,version:4},after:finalItem}],2,1);});
    const report=run.finish();
    assert.equal(report.status,'passed');assert.equal(outboundAttempts,0);
    assert.deepEqual((await bucket.list()).objects,[]);
    // Restore recovery preserves discussions and never turns tombstones into an import target.
    assert.equal(requests,74);
    const priorSnapshot=await request(route('snapshot')),priorJournal=await request(route('events?after=0')); state(priorSnapshot,priorJournal);
    const originalUsers=(await db.prepare('SELECT * FROM users ORDER BY id').all()).results,originalSessions=(await db.prepare('SELECT * FROM sessions ORDER BY id').all()).results;
    const threadStart=Date.now(),threadResult=await request(route('threads'),post({})),threadEnd=Date.now(); assert.equal(threadResult.status,201);
    const discussion=threadResult.data.thread; assert.match(discussion.id,/^[a-f0-9-]{36}$/);assert(discussion.createdAt>=threadStart&&discussion.createdAt<=threadEnd);
    assert.deepEqual(discussion,{id:discussion.id,itemId:null,anchor:{},resolved:false,createdAt:discussion.createdAt,updatedAt:discussion.createdAt});
    const messageInput={id:randomUUID(),body:'Keep this discussion through document recovery'},messageStart=Date.now();
    const messageResult=await request(route(`threads/${discussion.id}/messages`),post(messageInput)),messageEnd=Date.now();assert.equal(messageResult.status,201);
    const message=messageResult.data.message;assert(message.at>=messageStart&&message.at<=messageEnd);
    assert.deepEqual(message,{id:messageInput.id,threadId:discussion.id,userId:actors.member.id,name:'Synthetic member',body:messageInput.body,replyToId:null,attachments:[],mentionedUserIds:[],at:message.at});
    const currentThread={...discussion,updatedAt:message.at},withoutLeases=({leases,...snapshot})=>snapshot;
    const captureRecovery=async()=>{const responses=await Promise.all([request(route('snapshot'),{role:'viewer'}),request(route('events?after=0'),{role:'viewer'}),request(route(`threads/${discussion.id}`),{role:'viewer'}),request(route(`threads/${discussion.id}/messages`),{role:'viewer'})]);assert(responses.every(r=>r.status===200));return {snapshot:responses[0].data,journal:responses[1].data,thread:responses[2].data,messages:responses[3].data};};
    const stableRecovery=value=>({...value,snapshot:withoutLeases(value.snapshot)}),unchangedRecovery=(before,after)=>assert.deepEqual(stableRecovery(after),stableRecovery(before));
    const recoveryBase=await captureRecovery();assert.deepEqual(withoutLeases(recoveryBase.snapshot),{...withoutLeases(priorSnapshot.data),headSeq:8,threads:[currentThread]});
    assert.deepEqual(recoveryBase.thread,{thread:currentThread});assert.deepEqual(recoveryBase.messages,{messages:[message],hasMore:false,nextCursor:{at:message.at,id:message.id}});
    const addedDiscussion=recoveryBase.journal.events.slice(6);assert.equal(addedDiscussion.length,2);assert.deepEqual(recoveryBase.journal.events.slice(0,6),priorJournal.data.events);
    for(const [index,kind,payload,start,end] of [[0,'discussion.thread-created',{label:'Start discussion',thread:discussion},threadStart,threadEnd],[1,'discussion.message-created',{label:'Send message',message},messageStart,messageEnd]]){const e=addedDiscussion[index];assert(e.at>=start&&e.at<=end);assert.match(e.commandId,/^[a-f0-9-]{36}$/);assert.deepEqual(e,{seq:7+index,epoch:2,commandId:e.commandId,actorId:actors.member.id,kind,at:e.at,changes:[],data:{...payload,timingVersion:1}});}
    assert.deepEqual({...recoveryBase.journal,events:[]},{events:[],headSeq:8,epoch:2,timingVersion:1,hasMore:false});
    const restoreInput=(ep,seq,role='owner')=>({commandId:randomUUID(),sessionId:actors[role].sessionId,epoch:ep,seq});
    for(const role of ['member','viewer']){const denied=await request(route('restore'),{role,method:'POST',body:restoreInput(2,6,role)});assert.equal(denied.status,403);assert.equal(denied.data.error.code,'not_allowed');}
    unchangedRecovery(recoveryBase,await captureRecovery());
    const assertRestore=(before,after,input,receipt,start,end,items,deletedItems)=>{
      const seq=before.snapshot.headSeq+1,ep=before.snapshot.epoch+1,tv=before.snapshot.timingVersion+1;
      assert.equal(receipt.status,200);assert.deepEqual(receipt.data,{commandId:input.commandId,seq,epoch:ep,timingVersion:tv,items:[],snapshotRequired:true});
      assert.deepEqual(after.snapshot,{...withoutLeases(before.snapshot),headSeq:seq,epoch:ep,timingVersion:tv,items:sort(items),deletedItems:sort(deletedItems),leases:[]});
      assert.deepEqual(after.thread,before.thread);assert.deepEqual(after.messages,before.messages);
      const event=after.journal.events.at(-1);assert(event.at>=start&&event.at<=end);assert.deepEqual(event,{seq,epoch:ep,commandId:input.commandId,actorId:actors.owner.id,kind:'restore',at:event.at,changes:[],data:{label:`Restore history ${input.seq}`,restoreSeq:input.seq,snapshotRequired:true,timingVersion:tv}});
      assert.deepEqual(after.journal,{events:[...before.journal.events,event],headSeq:seq,epoch:ep,timingVersion:tv,hasMore:false});
    };
    const sameInput=restoreInput(2,6),sameStart=Date.now(),sameReceipt=await request(route('restore'),{method:'POST',body:sameInput}),sameEnd=Date.now(),sameState=await captureRecovery();
    assertRestore(recoveryBase,sameState,sameInput,sameReceipt,sameStart,sameEnd,recoveryBase.snapshot.items,recoveryBase.snapshot.deletedItems);
    const emptyInput=restoreInput(3,0),emptyStart=Date.now(),emptyReceipt=await request(route('restore'),{method:'POST',body:emptyInput}),emptyEnd=Date.now(),emptyState=await captureRecovery();
    const emptyTombstones=sort([{id:a,kind:'scene',version:6,deleted:true,data:{}},{id:b,kind:'scene',version:4,deleted:true,data:{}},{id:c,kind:'scene',version:2,deleted:true,data:{}}]);
    assertRestore(sameState,emptyState,emptyInput,emptyReceipt,emptyStart,emptyEnd,[],emptyTombstones);assert.equal(emptyState.snapshot.canImport,false);
    const importedId=randomUUID(),blockedImport=await request(route('import'),{method:'POST',body:{commandId:randomUUID(),sessionId:actors.owner.sessionId,epoch:4,items:[{id:importedId,kind:'scene',data:data(importedId,'Must not replace restored history',0)}]}});
    assert.equal(blockedImport.status,409);assert.equal(blockedImport.data.error.code,'project_not_empty');unchangedRecovery(emptyState,await captureRecovery());
    const againInput=restoreInput(4,0),againStart=Date.now(),againReceipt=await request(route('restore'),{method:'POST',body:againInput}),againEnd=Date.now(),againState=await captureRecovery();
    assertRestore(emptyState,againState,againInput,againReceipt,againStart,againEnd,[],emptyTombstones);
    for(const [input,receipt] of [[sameInput,sameReceipt],[emptyInput,emptyReceipt],[againInput,againReceipt]]){const replay=await request(route('restore'),{method:'POST',body:input});assert.equal(replay.status,200);assert.deepEqual(replay.data,receipt.data);}
    unchangedRecovery(againState,await captureRecovery());
    const zeroHistory=await request(route('snapshot?seq=0&epoch=1'));assert.equal(zeroHistory.status,200);assert.deepEqual(zeroHistory.data,{projectId,epoch:1,headSeq:0,timingVersion:0,items:[],deletedItems:[],canImport:false,threads:[],leases:[],hasMore:false,nextCursor:null,historyEvent:null});
    const historicRows=sort([...priorSnapshot.data.items,...priorSnapshot.data.deletedItems]);let cursor='';
    for(let i=0;i<3;i++){const page=await request(route(`snapshot?seq=6&epoch=2&limit=1${cursor?`&after=${cursor}`:''}`));assert.equal(page.status,200);const row=historicRows[i],more=i<2;assert.deepEqual(page.data,{projectId,epoch:2,headSeq:6,timingVersion:1,items:row.deleted?[]:[row],deletedItems:row.deleted?[row]:[],canImport:false,threads:[],leases:[],hasMore:more,nextCursor:more?row.id:null,historyEvent:{seq:6,epoch:2,actorId:actors.member.id,kind:'command',at:priorJournal.data.events[5].at}});cursor=row.id;}
    unchangedRecovery(againState,await captureRecovery());
    assert.deepEqual((await db.prepare('SELECT * FROM users ORDER BY id').all()).results,originalUsers);assert.deepEqual((await db.prepare('SELECT * FROM sessions ORDER BY id').all()).results,originalSessions);assert.deepEqual((await bucket.list()).objects,[]);assert.equal(outboundAttempts,0);assert.equal(requests,123);
    console.log(JSON.stringify({kind:'restore-empty-history-evidence',httpChecks:49,restores:3,exactReceiptReplays:3,permissionRefusals:2,blockedImports:1,historicalPages:3,discussionMessagesPreserved:1,tombstones:3,unchangedNoopVersions:true,originalEventsPreserved:6,nativeScenarios:0,outboundAttempts}));
    console.log(JSON.stringify({result:'PASS',journey:'revision-safety',requests,outboundAttempts,nativeScenarios:0,workerBundleSHA256:createHash('sha256').update(await readFile(bundle)).digest('hex'),runtime:report}));
  } finally { await mf.dispose(); }
}
