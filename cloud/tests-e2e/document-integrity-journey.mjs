// Real HTTP service-process integration; not Catalyst/native application E2E.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, rm, readFile, readdir, copyFile, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, isAbsolute } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';

process.on('uncaughtException', () => { console.error('Document integrity journey failed; no response or exception details were emitted.'); process.exitCode = 1; });
if (process.argv[2] !== '--owned-child' && (!process.env.SCRIV_TRACER_RUNTIME || !isAbsolute(process.env.SCRIV_TRACER_RUNTIME))) { console.error('Set SCRIV_TRACER_RUNTIME to the absolute path of the reviewed local Tracer runtime.'); process.exit(2); }
const here = await realpath(dirname(fileURLToPath(import.meta.url)));
// --cloud supports an outside-repository candidate without changing its sources.
const cloud = await realpath(process.argv[2] === '--owned-child' ? process.argv[4] :
  process.argv[2] === '--cloud' ? process.argv[3] : join(here, '..'));
const self = await realpath(fileURLToPath(import.meta.url));
if (process.argv[2] !== '--owned-child') {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'scriv-document-integrity-')));
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
      assert(requests++ < 300); assert(Buffer.byteLength(encoded ?? '') <= 16384);
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
    const catalog = JSON.parse(await readFile(join(cloud, '../docs/testing/document-integrity-steps.json'), 'utf8'));
    const run = createScenarioRun({ catalog, scenarioId:'document-integrity', runId:randomUUID(), context:{build:'local-worker-bundle',platform:process.platform,inputRoute:'Scriv CLI service HTTP'} });
    const route = suffix => `/v1/projects/${projectId}/${suffix}`;
    const post = body => ({method:'POST',body,role:'member'});
    const scene=randomUUID(), character=randomUUID(), entry=randomUUID(), image=randomUUID(), cue=randomUUID(), word=randomUUID(), annotation=randomUUID();
    const region={x:0.1,y:0.1,width:0.5,height:0.5};
    const analysis={imageSHA256:'a'.repeat(64),imageVersion:1,providerID:'synthetic-metadata',completedAt:1,excludedCharacterIDs:[],manualCharacterIDs:[character],annotations:[{id:annotation,region,portraitRegion:region,kind:'face',decision:'confirmed',characterID:character,confidence:0.8,reason:'Synthetic annotation'}]};
    const graph=[
      {id:scene,kind:'scene',data:{id:scene,title:'Synthetic graph',order:0}},
      {id:character,kind:'character',data:{id:character,name:'Ada',aliases:[],biography:'',appearance:'',color:'',portraitImageId:image,portraitRegion:{imageID:image,imageSHA256:'a'.repeat(64),isAutomatic:false,region}}},
      {id:entry,kind:'entry',data:{id:entry,sceneId:scene,order:0,kind:'dialogue',text:'Ada',characterId:character,characterLinks:[{id:randomUUID(),location:0,length:3,text:'Ada',isConfirmed:true,characterId:character}],ownedDurationMs:1000,coverageDurationMs:1000,color:'',words:[{id:word,text:'Ada',startMs:0,endMs:1000,timingSource:'authored'}]}},
      {id:image,kind:'image',data:{id:image,version:1,fileName:'synthetic.png',sha256:'a'.repeat(64),mimeType:'image/png',byteCount:1,characterIds:[character],prompt:'Editable direction',generationPrompt:'Captured prompt',createdAt:0,characterAnalysis:analysis}},
      {id:cue,kind:'cue',data:{id:cue,sceneId:scene,startMs:0,endMs:1000,startAnchor:{entryId:entry,offsetMs:0},authoredDurationMs:1000,label:'Portrait',prompt:'',imageId:image}},
    ];
    let baseline, eventsBaseline;
    const leases=new Map();
    const command=operations=>({commandId:randomUUID(),sessionId:actors.member.sessionId,epoch:1,expectedTimingVersion:baseline?.timingVersion??0,label:'Synthetic document integrity',operations});
    const operation=(id,change)=>{const item=baseline.items.find(x=>x.id===id);return {op:'put',id,kind:item.kind,expectedVersion:item.version,lease:leases.get(id),data:change(structuredClone(item.data))};};
    await run.step('create-graph', async step=>{
      const created=await step.action('POST synthetic project',()=>request('/v1/projects',post({id:projectId,title:'Synthetic document integrity',teamId})));
      const saved=await step.action('POST commands complete typed graph',()=>request(route('commands'),post(command(graph.map(item=>({...item,op:'put',expectedVersion:0}))))));
      const snap=await step.action('GET snapshot typed graph',()=>request(route('snapshot')));
      const events=await step.action('GET events typed graph',()=>request(route('events?after=0')));
      await step.expect('observed',()=>{assert.equal(created.status,201);assert.equal(saved.status,200);assert.equal(snap.status,200);assert.equal(events.status,200);assert.deepEqual(snap.data.deletedItems,[]);assert.equal(snap.data.headSeq,1);assert.equal(snap.data.timingVersion,1);assert.equal(snap.data.epoch,1);assert.deepEqual(snap.data.items.map(x=>({id:x.id,kind:x.kind,data:x.data,version:x.version,deleted:x.deleted})).sort((a,b)=>a.id.localeCompare(b.id)),graph.map(x=>({...x,version:1,deleted:false})).sort((a,b)=>a.id.localeCompare(b.id)));assert.equal(events.data.events.length,1);assert.deepEqual(events.data.events[0].changes.map(x=>x.after).sort((a,b)=>a.id.localeCompare(b.id)),snap.data.items.slice().sort((a,b)=>a.id.localeCompare(b.id)));baseline=snap.data;eventsBaseline=events.data;});
    });
    await run.step('acquire-edit-leases',async step=>{
      const results=[];
      for(const [name,id] of [['entry',entry],['image',image],['character',character],['cue',cue]]) results.push([id,await step.action(`POST leases ${name}`,()=>request(route('leases'),post({itemId:id,sessionId:actors.member.sessionId})))]);
      await step.expect('observed',()=>{for(const [id,res] of results){assert.equal(res.status,200);assert.equal(res.data.userId,actors.member.id);assert.equal(res.data.fence,1);assert.equal(typeof res.data.token,'string');leases.set(id,{token:res.data.token,fence:res.data.fence});}});
    });
    async function reject(stepId,operations,status,code){
      await run.step(stepId,async step=>{
        const result=await step.action(`POST commands ${stepId}`,()=>request(route('commands'),post(command(operations))));
        const snap=await step.action(`GET snapshot ${stepId}`,()=>request(route('snapshot')));
        const events=await step.action(`GET events ${stepId}`,()=>request(route('events?after=0')));
        await step.expect('observed',()=>{assert.equal(result.status,status);assert.equal(result.data.error.code,code);assert.equal(snap.status,200);assert.equal(events.status,200);assert.deepEqual(snap.data.items,baseline.items);assert.deepEqual(snap.data.deletedItems,baseline.deletedItems);assert.equal(snap.data.headSeq,baseline.headSeq);assert.equal(snap.data.epoch,baseline.epoch);assert.equal(snap.data.timingVersion,baseline.timingVersion);assert.deepEqual(events.data,eventsBaseline);});
      });
    }
    await reject('dangling-character-link',[operation(entry,d=>({...d,characterLinks:d.characterLinks.map(l=>({...l,characterId:randomUUID()}))}))],400,'invalid_reference');
    await reject('duplicate-project-word',[{op:'put',id:itemId,kind:'entry',expectedVersion:0,data:{...structuredClone(graph[2].data),id:itemId,order:1}}],400,'duplicate_word');
    await reject('stale-analysis',[operation(image,d=>({...d,characterAnalysis:{...d.characterAnalysis,imageVersion:2}}))],400,'stale_character_analysis');
    await reject('invalid-analysis-region',[operation(image,d=>{d.characterAnalysis.annotations[0].region.width=1;return d;})],400,'invalid_character_region');
    await reject('invalid-analysis-decision',[operation(image,d=>{d.characterAnalysis.annotations[0].decision='approved';return d;})],400,'invalid_character_analysis');
    await reject('accepted-region-needs-identity',[operation(image,d=>{delete d.characterAnalysis.annotations[0].characterID;return d;})],400,'invalid_character_analysis');
    await reject('duplicate-analysis-identity',[operation(image,d=>{d.characterAnalysis.manualCharacterIDs.push(character);return d;})],400,'invalid_character_analysis');
    await reject('duplicate-region-id',[operation(image,d=>{d.characterAnalysis.annotations.push(structuredClone(d.characterAnalysis.annotations[0]));return d;})],400,'invalid_character_analysis');
    await reject('invalid-region-confidence',[operation(image,d=>{d.characterAnalysis.annotations[0].confidence=1.1;return d;})],400,'invalid_character_analysis');
    await reject('dangling-analysis-identity',[operation(image,d=>{d.characterAnalysis.manualCharacterIDs=[randomUUID()];return d;})],400,'invalid_reference');
    await reject('portrait-selected-image-mismatch',[operation(character,d=>{d.portraitRegion.imageID=randomUUID();return d;})],400,'invalid_character_portrait');
    await reject('portrait-stale-digest',[operation(character,d=>{d.portraitRegion.imageSHA256='b'.repeat(64);return d;})],400,'stale_character_portrait');
    await reject('portrait-invalid-provenance',[operation(character,d=>{d.portraitRegion.isAutomatic='yes';return d;})],400,'invalid_character_portrait');
    await reject('immutable-image-bytes',[operation(image,d=>({...d,byteCount:2}))],409,'immutable_image');
    await reject('immutable-generation-prompt',[operation(image,d=>({...d,generationPrompt:'Changed capture'}))],409,'immutable_image');
    await reject('preserve-character-links',[operation(entry,d=>{delete d.characterLinks;return d;})],409,'schema_upgrade_required');
    await reject('preserve-cue-anchor',[operation(cue,d=>{delete d.startAnchor;delete d.authoredDurationMs;return d;})],409,'schema_upgrade_required');
    await reject('preserve-word-provenance',[operation(entry,d=>{delete d.words[0].timingSource;return d;})],409,'schema_upgrade_required');
    await reject('referenced-image-delete',[{op:'delete',id:image,expectedVersion:1,lease:leases.get(image)}],409,'item_in_use');
    await run.step('save-valid-metadata',async step=>{
      const ops=[operation(image,d=>({...d,prompt:'Revised direction'})),operation(character,d=>({...d,biography:'Synthetic biography'})),operation(entry,d=>({...d,color:'blue'})),operation(cue,d=>({...d,label:'Revised portrait'}))];
      const result=await step.action('POST commands valid editable metadata',()=>request(route('commands'),post(command(ops))));
      const snap=await step.action('GET snapshot edited graph',()=>request(route('snapshot')));
      const events=await step.action('GET events edited graph',()=>request(route('events?after=0')));
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(snap.status,200);assert.equal(events.status,200);const expected=baseline.items.map(item=>{const op=ops.find(x=>x.id===item.id);return op?{...item,data:op.data,version:2}:item;});assert.deepEqual(snap.data.items,expected);assert.deepEqual(snap.data.deletedItems,[]);assert.equal(snap.data.headSeq,2);assert.equal(snap.data.epoch,1);assert.equal(snap.data.timingVersion,1);assert.equal(events.data.events.length,2);assert.deepEqual(events.data.events[0],eventsBaseline.events[0]);const expectedChanged=ops.map(op=>({id:op.id,kind:op.kind,data:op.data,version:2,deleted:false})).sort((a,b)=>a.id.localeCompare(b.id));assert.deepEqual(events.data.events[1].changes.map(x=>x.after).sort((a,b)=>a.id.localeCompare(b.id)),expectedChanged);assert.deepEqual(result.data.items.slice().sort((a,b)=>a.id.localeCompare(b.id)),expectedChanged);});
    });
    const report=run.finish();
    assert.equal(report.status,'passed');assert.equal(outboundAttempts,0);
    // Delete a connected graph through public commands, not internal store writes.
    assert.equal(requests,68);
    const sceneLease=await request(route('leases'),post({itemId:scene,sessionId:actors.member.sessionId})); assert.equal(sceneLease.status,200); assert.equal(sceneLease.data.itemId,scene); assert.equal(sceneLease.data.userId,actors.member.id); assert.equal(sceneLease.data.epoch,1); assert.equal(sceneLease.data.fence,1); assert(sceneLease.data.expiresAt>Date.now()); leases.set(scene,{token:sceneLease.data.token,fence:sceneLease.data.fence});
    const priorSnapshot=await request(route('snapshot')), priorEvents=await request(route('events?after=0')); assert.equal(priorSnapshot.status,200); assert.equal(priorEvents.status,200);
    const prior=priorSnapshot.data; assert.equal(prior.headSeq,2); assert.equal(prior.epoch,1); assert.equal(prior.timingVersion,1); assert.equal(prior.items.length,5); assert.deepEqual(prior.deletedItems,[]); assert.equal(prior.canImport,false); assert.equal(priorEvents.data.events.length,2);
    assert.deepEqual(prior.leases.map(l=>l.itemId).sort(),[scene,character,image,entry,cue].sort()); assert(prior.leases.every(l=>l.expiresAt>Date.now()&&!Object.hasOwn(l,'token')));
    const withoutLeases=({leases,...snapshot})=>snapshot;
    const retryId=randomUUID(), deleteLabel='Synthetic connected graph delete';
    const deletion=id=>({op:'delete',id,expectedVersion:prior.items.find(item=>item.id===id).version,lease:leases.get(id)});
    const attempted={commandId:retryId,sessionId:actors.member.sessionId,epoch:prior.epoch,expectedTimingVersion:prior.timingVersion,label:deleteLabel,operations:[deletion(character)]};
    const refused=await request(route('commands'),post(attempted)); assert.equal(refused.status,409); assert.equal(refused.data.error.code,'item_in_use');
    const rejectedSnapshot=await request(route('snapshot')), rejectedEvents=await request(route('events?after=0')); assert.equal(rejectedSnapshot.status,200); assert.equal(rejectedEvents.status,200); assert.deepEqual(withoutLeases(rejectedSnapshot.data),withoutLeases(prior)); assert.deepEqual(rejectedEvents.data,priorEvents.data);
    // Parents precede dependants deliberately. Validation sees the complete command result.
    const order=[scene,character,image,entry,cue], repaired={...attempted,operations:order.map(deletion)};
    const expectedDeleted=order.map(id=>{const item=prior.items.find(item=>item.id===id);return {...item,version:item.version+1,deleted:true};});
    const deletionBefore=Date.now(); const deleted=await request(route('commands'),post(repaired)); const deletionAfter=Date.now(); assert.equal(deleted.status,200);
    assert.deepEqual(deleted.data,{commandId:retryId,seq:3,epoch:1,timingVersion:2,items:expectedDeleted});
    const deletedSnapshot=await request(route('snapshot')), deletedEvents=await request(route('events?after=0')); assert.equal(deletedSnapshot.status,200); assert.equal(deletedEvents.status,200);
    const sortItems=items=>[...items].sort((a,b)=>a.id.localeCompare(b.id));
    assert.deepEqual(deletedSnapshot.data.items,[]); assert.deepEqual(sortItems(deletedSnapshot.data.deletedItems),sortItems(expectedDeleted.map(item=>({...item,data:{}}))));
    assert.deepEqual(withoutLeases(deletedSnapshot.data),{...withoutLeases(prior),headSeq:3,timingVersion:2,items:[],deletedItems:deletedSnapshot.data.deletedItems,canImport:false});
    assert.deepEqual(deletedEvents.data.events.slice(0,2),priorEvents.data.events); assert.equal(deletedEvents.data.events.length,3); const deletionEvent=deletedEvents.data.events[2];
    assert(deletionEvent.at>=deletionBefore&&deletionEvent.at<=deletionAfter);
    const expectedChanges=sortItems(expectedDeleted).map(after=>({id:after.id,before:prior.items.find(item=>item.id===after.id),after}));
    assert.deepEqual(deletionEvent,{seq:3,epoch:1,commandId:retryId,actorId:actors.member.id,kind:'command',at:deletionEvent.at,changes:expectedChanges,data:{label:deleteLabel,timingVersion:2}});
    assert.deepEqual(deletedEvents.data,{events:[...priorEvents.data.events,deletionEvent],headSeq:3,epoch:1,timingVersion:2,hasMore:false});
    // Repaired reuse proves the refused ID did not block retry; exact success replay is stable.
    const replay=await request(route('commands'),post(repaired)); assert.equal(replay.status,200); assert.deepEqual(replay.data,deleted.data);
    const replaySnapshot=await request(route('snapshot')), replayEvents=await request(route('events?after=0')); assert.equal(replaySnapshot.status,200); assert.equal(replayEvents.status,200); assert.deepEqual(withoutLeases(replaySnapshot.data),withoutLeases(deletedSnapshot.data)); assert.deepEqual(replayEvents.data,deletedEvents.data);
    assert.deepEqual((await bucket.list()).objects,[]); assert.equal(requests,80); assert.equal(outboundAttempts,0);
    console.log(JSON.stringify({kind:'document-graph-deletion-evidence',httpChecks:12,rejectedReferencedDelete:true,repairedCommandIdAccepted:true,deletedItems:5,metadataOnlyTombstones:5,newEvents:1,timingVersionIncrement:1,exactReplayStable:true,controlledFailureInjection:false,nativeScenarios:0,outboundAttempts}));
    const { documentBoundaryCases } = await import(pathToFileURL(join(cloud, 'tests-e2e/document-boundary-cases.mjs')).href);
    try { console.log(JSON.stringify(await documentBoundaryCases({request,route,post,graph,leases,member:actors.member,deletedEvents}))); }
    catch (error) { console.error('Document boundary continuation failed; stack locations only.', String(error.stack).split('\n').filter(line=>/^\s+at /.test(line)).join('\n')); throw error; }
    assert.equal(requests,167); assert.equal(outboundAttempts,0); assert.deepEqual((await bucket.list()).objects,[]);
    const { documentTimelineCases } = await import(pathToFileURL(join(cloud, 'tests-e2e/document-timeline-cases.mjs')).href);
    try { console.log(JSON.stringify(await documentTimelineCases({ request, post, teamId, member: actors.member }))); }
    catch (error) { console.error('Document timeline continuation failed; stack locations only.', String(error.stack).split('\n').filter(line=>/^\s+at /.test(line)).join('\n')); throw error; }
    assert.equal(requests,223); assert.equal(outboundAttempts,0); assert.deepEqual((await bucket.list()).objects,[]);
    const { documentGraphTransitionCases } = await import(pathToFileURL(join(cloud, 'tests-e2e/document-graph-transition-cases.mjs')).href);
    try { console.log(JSON.stringify(await documentGraphTransitionCases({ request, post, teamId, member: actors.member }))); }
    catch (error) { console.error('Document graph transition continuation failed; stack locations only.', String(error.stack).split('\n').filter(line=>/^\s+at /.test(line)).join('\n')); throw error; }
    assert.equal(requests,278); assert.equal(outboundAttempts,0); assert.deepEqual((await bucket.list()).objects,[]);
    console.log(JSON.stringify({result:'PASS',journey:'document-integrity',requests,outboundAttempts,nativeScenarios:0,workerBundleSHA256:createHash('sha256').update(await readFile(bundle)).digest('hex'),runtime:report}));
  } finally { await mf.dispose(); }
}
