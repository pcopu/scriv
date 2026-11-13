// Real HTTP service-process integration; not Catalyst/native application E2E.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, rm, readFile, readdir, copyFile, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, isAbsolute } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';

process.on('uncaughtException', error => { console.error('Team lifecycle journey failed at: ' + (error.stack?.split('\n').find(line => line.trimStart().startsWith('at ')) ?? 'unknown')); process.exitCode = 1; });
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
      root = await realpath(await mkdtemp(join(tmpdir(), 'scriv-team-lifecycle-')));
      for (const name of ['home', 'tmp', 'state']) await mkdir(join(root, name), { mode: 0o700 });
      capture = process.env.SCRIV_SERVICE_COVERAGE_DIR
        ? await (await import(pathToFileURL(join(cloud, 'tests-e2e/capture-generation-coverage.mjs')).href))
          .prepareServiceCapture(process.env.SCRIV_SERVICE_COVERAGE_DIR, process.env.SCRIV_TRACER_CLI, { journeyPath: 'cloud/tests-e2e/team-lifecycle-journey.mjs' }) : null;
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
      .loadServiceCapture(process.argv[5]) : null;
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
      bindings: { PUBLIC_URL: 'http://127.0.0.1', ENVIRONMENT: 'test', EMAIL_FROM: 'sender@example.invalid', ...(capture?.options.bindings ?? {}) },
      d1Databases: { DB: 'journey-db' }, r2Buckets: ['ASSETS'],
      durableObjects: { PROJECTS: { className: 'ProjectRoom', useSQLite: true }, BILLING: { className: 'BillingCoordinator', useSQLite: true } },
    }],
  });
  const mf = new Miniflare(config);
  let requests = 0, captureStarted = false;
  const coverageActions = [];
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
      assert(requests++ < 80); assert(Buffer.byteLength(encoded ?? '') <= 4096);
      if (capture) coverageActions.push(`${method} ${url.pathname.replace(/^\/v1\/join\/[^/]+$/, '/v1/join/:token').replace(/[0-9a-f]{8}-[0-9a-f-]{27}/gi, ':id')}`);
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
    const catalog = JSON.parse(await readFile(join(cloud, '../docs/testing/team-lifecycle-steps.json'), 'utf8'));
    const run = createScenarioRun({ catalog, scenarioId:'local-team-membership-lifecycle', runId:randomUUID(), context:{build:'local-worker-bundle',platform:process.platform,inputRoute:'Scriv CLI service HTTP'} });
    // Owned synthetic account/session fixtures only; no provider sign-in is claimed.
    const actors = {};
    const now = Date.now();
    for (const name of ['owner','member','viewer','outsider']) {
      const actor = actors[name] = { id:randomUUID(), sessionId:randomUUID(), token:randomBytes(32).toString('base64url') };
      await db.prepare('INSERT INTO users(id,github_id,name,created_at) VALUES(?,?,?,?)').bind(actor.id,`email:${actor.id}`,`Synthetic ${name}`,now).run();
      await db.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at) VALUES(?,?,?,?,?,?)').bind(createHash('sha256').update(actor.token).digest('hex'),actor.sessionId,actor.id,'Synthetic CLI device',now,now+3600000).run();
    }
    const call = (path, actor='owner', method='GET', body) => request(path,{token:actors[actor].token,method,body});
    const ok = (r,status=200) => assert.equal(r.status,status);
    const error = (r,status,code) => { assert.equal(r.status,status); assert.equal(r.data.error.code,code); };
    let result, teamId, memberInvite, viewerInvite, projectId;
    const team = () => '/v1/teams/'+teamId;
    const membership = actor => team()+'/members/'+actors[actor].id;
    if (capture) { await capture.begin(await mf.ready); captureStarted = true; }
    await run.step('create-free-team', async step => {
      result = await step.action('POST /v1/teams with padded synthetic name', () => call('/v1/teams','owner','POST',{name:'  Synthetic team  '}));
      await step.expect('observed', () => { ok(result,201); teamId=result.data.team.id; assert.equal(typeof teamId,'string'); assert.equal(result.data.team.name,'Synthetic team'); assert.equal(result.data.team.role,'owner'); assert.equal(result.data.team.plan,'free'); assert.equal(result.data.team.ownerId,actors.owner.id); });
    });
    await run.step('read-created-team', async step => {
      result = await step.action('GET created team as owner', () => call(team()));
      await step.expect('observed', () => { ok(result); assert.equal(result.data.team.id,teamId); assert.equal(result.data.members.length,1); assert.equal(result.data.members[0].id,actors.owner.id); assert.equal(result.data.members[0].role,'owner'); assert.deepEqual(result.data.joinLinks,[]); });
    });
    await run.step('create-member-invite', async step => {
      result = await step.action('POST member invitation as owner', () => call(team()+'/join-links','owner','POST',{role:'member',expiresInDays:1}));
      await step.expect('observed', () => { ok(result,201); memberInvite=result.data; assert.equal(memberInvite.link.role,'member'); assert.match(memberInvite.token,/^[A-Za-z0-9_-]{32,128}$/); assert.equal(memberInvite.url,'http://127.0.0.1/join/'+memberInvite.token); assert.equal(memberInvite.link.expiresAt-memberInvite.link.createdAt,86400000); });
    });
    await run.step('reject-unpaid-join', async step => {
      result = await step.action('POST member invitation join while team is free', () => call('/v1/join/'+memberInvite.token,'member','POST'));
      await step.expect('observed', () => { error(result,402,'team_subscription_required'); });
    });
    await run.step('read-rejected-join', async step => {
      result = await step.action('GET team after rejected free-plan join', () => call(team()));
      await step.expect('observed', () => { ok(result); assert.deepEqual(result.data.members.map(x=>x.id),[actors.owner.id]); });
    });
    await run.step('seed-synthetic-entitlement', async step => {
      result = await step.action('Fixture only: seed active entitlement in owned D1', () => db.prepare("UPDATE teams SET subscription_status='active',paid_until=? WHERE id=?").bind(Date.now()+3600000,teamId).run());
      await step.expect('observed', () => { assert.equal(result.meta.changes,1); });
    });
    await run.step('join-member', async step => {
      result = await step.action('POST valid member invitation after fixture entitlement', () => call('/v1/join/'+memberInvite.token,'member','POST'));
      await step.expect('observed', () => { ok(result); assert.equal(result.data.team.id,teamId); assert.equal(result.data.team.role,'member'); assert.equal(result.data.team.plan,'team'); });
    });
    await run.step('join-member-again', async step => {
      result = await step.action('POST same invitation again as existing member', () => call('/v1/join/'+memberInvite.token,'member','POST'));
      await step.expect('observed', () => { ok(result); assert.equal(result.data.team.id,teamId); assert.equal(result.data.team.role,'member'); });
    });
    await run.step('read-single-membership', async step => {
      result = await step.action('GET team after duplicate member join', () => call(team()));
      await step.expect('observed', () => { ok(result); assert.equal(result.data.members.length,2); assert.equal(result.data.members.filter(x=>x.id===actors.member.id).length,1); });
    });
    await run.step('create-viewer-invite', async step => {
      result = await step.action('POST viewer invitation as owner', () => call(team()+'/join-links','owner','POST',{role:'viewer'}));
      await step.expect('observed', () => { ok(result,201); viewerInvite=result.data; assert.equal(viewerInvite.link.role,'viewer'); assert.equal(viewerInvite.link.expiresAt-viewerInvite.link.createdAt,30*86400000); });
    });
    await run.step('join-viewer', async step => {
      result = await step.action('POST viewer invitation as viewer actor', () => call('/v1/join/'+viewerInvite.token,'viewer','POST'));
      await step.expect('observed', () => { ok(result); assert.equal(result.data.team.role,'viewer'); assert.equal(result.data.team.id,teamId); });
    });
    await run.step('member-keeps-role', async step => {
      result = await step.action('POST viewer invitation as existing member', () => call('/v1/join/'+viewerInvite.token,'member','POST'));
      await step.expect('observed', () => { ok(result); assert.equal(result.data.team.role,'member'); });
    });
    await run.step('hide-invites-from-member', async step => {
      result = await step.action('GET team as nonmanager member', () => call(team(),'member'));
      await step.expect('observed', () => { ok(result); assert.equal(result.data.members.length,3); assert.deepEqual(result.data.joinLinks,[]); });
    });
    await run.step('deny-member-invite', async step => {
      result = await step.action('POST invitation as nonmanager member', () => call(team()+'/join-links','member','POST',{role:'viewer'}));
      await step.expect('observed', () => { error(result,403,'not_allowed'); });
    });
    await run.step('deny-member-rename', async step => {
      result = await step.action('PATCH team name as nonmanager member', () => call(team(),'member','PATCH',{name:'Denied'}));
      await step.expect('observed', () => { error(result,403,'not_allowed'); });
    });
    await run.step('deny-owner-leave', async step => {
      result = await step.action('DELETE owner membership as owner', () => call(membership('owner'),'owner','DELETE'));
      await step.expect('observed', () => { error(result,409,'owner_required'); });
    });
    await run.step('appoint-admin', async step => {
      result = await step.action('PATCH member role to admin as owner', () => call(membership('member'),'owner','PATCH',{role:'admin'}));
      await step.expect('observed', () => { ok(result); assert.deepEqual(result.data,{ok:true}); });
    });
    await run.step('read-admin-role', async step => {
      result = await step.action('GET team as newly appointed admin', () => call(team(),'member'));
      await step.expect('observed', () => { ok(result); assert.equal(result.data.team.role,'admin'); assert.equal(result.data.team.name,'Synthetic team'); assert.equal(result.data.members.find(x=>x.id===actors.member.id).role,'admin'); assert.equal(result.data.joinLinks.length,2); });
    });
    await run.step('admin-rename', async step => {
      result = await step.action('PATCH team name as admin', () => call(team(),'member','PATCH',{name:'  Renamed team  '}));
      await step.expect('observed', () => { ok(result); assert.equal(result.data.team.name,'Renamed team'); assert.equal(result.data.team.role,'admin'); });
    });
    await run.step('read-renamed-team-list', async step => {
      result = await step.action('GET viewer team list after rename', () => call('/v1/teams','viewer'));
      await step.expect('observed', () => { ok(result); assert.equal(result.data.teams.length,1); assert.equal(result.data.teams[0].id,teamId); assert.equal(result.data.teams[0].name,'Renamed team'); assert.equal(result.data.teams[0].role,'viewer'); });
    });
    await run.step('deny-admin-appoint-admin', async step => {
      result = await step.action('PATCH viewer to admin as admin', () => call(membership('viewer'),'member','PATCH',{role:'admin'}));
      await step.expect('observed', () => { error(result,403,'not_allowed'); });
    });
    await run.step('deny-admin-change-owner', async step => {
      result = await step.action('PATCH owner role as admin', () => call(membership('owner'),'member','PATCH',{role:'viewer'}));
      await step.expect('observed', () => { error(result,409,'owner_required'); });
    });
    await run.step('create-team-project', async step => {
      result = await step.action('POST team project as admin', () => call('/v1/projects','member','POST',{title:'Synthetic project',teamId}));
      await step.expect('observed', () => { ok(result,201); projectId=result.data.project.id; assert.equal(result.data.project.teamId,teamId); assert.equal(result.data.project.ownerId,actors.owner.id); });
    });
    await run.step('read-viewer-project', async step => {
      result = await step.action('GET project as viewer', () => call('/v1/projects/'+projectId,'viewer'));
      await step.expect('observed', () => { ok(result); assert.equal(result.data.project.role,'viewer'); assert.equal(result.data.project.canWrite,false); assert.equal(result.data.project.premium,true); });
    });
    await run.step('admin-promote-viewer', async step => {
      result = await step.action('PATCH viewer to member as admin', () => call(membership('viewer'),'member','PATCH',{role:'member'}));
      await step.expect('observed', () => { ok(result); assert.deepEqual(result.data,{ok:true}); });
    });
    await run.step('read-promoted-project', async step => {
      result = await step.action('GET project after viewer promotion', () => call('/v1/projects/'+projectId,'viewer'));
      await step.expect('observed', () => { ok(result); assert.equal(result.data.project.role,'member'); assert.equal(result.data.project.canWrite,true); });
    });
    await run.step('deny-member-archive', async step => {
      result = await step.action('DELETE project as ordinary member', () => call('/v1/projects/'+projectId,'viewer','DELETE'));
      await step.expect('observed', () => { error(result,403,'not_allowed'); });
    });
    await run.step('member-self-leave', async step => {
      result = await step.action('DELETE own membership as ordinary member', () => call(membership('viewer'),'viewer','DELETE'));
      await step.expect('observed', () => { ok(result); assert.deepEqual(result.data,{ok:true}); });
    });
    await run.step('read-after-self-leave', async step => {
      result = await step.action('GET own identity after leaving team', () => call('/v1/me','viewer'));
      await step.expect('observed', () => { ok(result); assert.deepEqual(result.data.teams,[]); assert.deepEqual(result.data.projects,[]); });
    });
    await run.step('reject-left-project', async step => {
      result = await step.action('GET project after leaving team', () => call('/v1/projects/'+projectId,'viewer'));
      await step.expect('observed', () => { error(result,404,'not_found'); });
    });
    await run.step('revoke-viewer-invite', async step => {
      result = await step.action('DELETE viewer invitation as admin', () => call(team()+'/join-links/'+viewerInvite.link.id,'member','DELETE'));
      await step.expect('observed', () => { ok(result); assert.deepEqual(result.data,{ok:true}); });
    });
    await run.step('read-revoked-invite', async step => {
      result = await step.action('GET team invitation list after revocation', () => call(team()));
      await step.expect('observed', () => { ok(result); const link=result.data.joinLinks.find(x=>x.id===viewerInvite.link.id); assert.equal(typeof link.revokedAt,'number'); assert(link.revokedAt>=link.createdAt); assert.equal(result.data.joinLinks.find(x=>x.id===memberInvite.link.id).revokedAt,null); });
    });
    await run.step('reject-revoked-invite', async step => {
      result = await step.action('POST revoked invitation as outsider', () => call('/v1/join/'+viewerInvite.token,'outsider','POST'));
      await step.expect('observed', () => { error(result,404,'invite_invalid'); });
    });
    await run.step('read-no-outsider-membership', async step => {
      result = await step.action('GET outsider identity after revoked join', () => call('/v1/me','outsider'));
      await step.expect('observed', () => { ok(result); assert.deepEqual(result.data.teams,[]); assert.deepEqual(result.data.projects,[]); });
    });
    await run.step('owner-removes-admin', async step => {
      result = await step.action('DELETE admin membership as owner', () => call(membership('member'),'owner','DELETE'));
      await step.expect('observed', () => { ok(result); assert.deepEqual(result.data,{ok:true}); });
    });
    await run.step('read-after-admin-removal', async step => {
      result = await step.action('GET team after owner removed admin', () => call(team()));
      await step.expect('observed', () => { ok(result); assert.deepEqual(result.data.members.map(x=>x.id),[actors.owner.id]); });
    });
    await run.step('reject-removed-admin', async step => {
      result = await step.action('GET team as removed admin', () => call(team(),'member'));
      await step.expect('observed', () => { error(result,404,'not_found'); });
    });
    await run.step('archive-project', async step => {
      result = await step.action('DELETE team project as owner', () => call('/v1/projects/'+projectId,'owner','DELETE'));
      await step.expect('observed', () => { ok(result); assert.deepEqual(result.data,{ok:true}); });
    });
    await run.step('read-archived-list', async step => {
      result = await step.action('GET owner project list after archive', () => call('/v1/projects'));
      await step.expect('observed', () => { ok(result); assert.deepEqual(result.data.projects,[]); });
    });
    await run.step('reject-archived-get', async step => {
      result = await step.action('GET archived project as owner', () => call('/v1/projects/'+projectId));
      await step.expect('observed', () => { error(result,404,'not_found'); });
    });
    const report=run.finish(); assert.equal(report.status,'passed'); assert.equal(outboundAttempts,0);
    // Synthetic entitlement dates exercise grace rules without changing the clock.
    // canWrite below is the public capability projection, not a document-write test.
    assert.equal(requests,39);
    const businessRows=async()=>{
      const rows={};
      for(const table of ['users','sessions','teams','team_members','join_links','projects']) rows[table]=(await db.prepare(`SELECT * FROM ${table} ORDER BY 1,2`).all()).results;
      return rows;
    };
    const originalRows=await businessRows(); assert.equal(originalRows.teams.length,1); assert.equal(originalRows.projects.length,1); assert(originalRows.projects[0].archived_at); assert.equal(originalRows.team_members.length,1);
    const originalTeam=originalRows.teams[0]; assert.equal(originalTeam.subscription_status,'active'); assert(originalTeam.paid_until>Date.now());
    for(const actor of ['member','viewer']) { const joined=await call('/v1/join/'+memberInvite.token,actor,'POST'); ok(joined); assert.equal(joined.data.team.role,'member'); }
    const changedViewer=await call(membership('viewer'),'owner','PATCH',{role:'viewer'}); ok(changedViewer); assert.deepEqual(changedViewer.data,{ok:true});
    const create=await call('/v1/projects','owner','POST',{id:randomUUID(),title:'Synthetic entitlement grace project',teamId}); ok(create,201);
    const graceProject=create.data.project, gracePath='/v1/projects/'+graceProject.id; assert.equal(graceProject.ownerId,actors.owner.id); assert.equal(graceProject.teamId,teamId); assert.equal(graceProject.archivedAt,null);
    const preparedRows=await businessRows(); assert.deepEqual(preparedRows.users,originalRows.users); assert.deepEqual(preparedRows.sessions,originalRows.sessions); assert.deepEqual(preparedRows.teams,originalRows.teams); assert.deepEqual(preparedRows.join_links,originalRows.join_links);
    assert.deepEqual(preparedRows.projects.filter(p=>p.id!==graceProject.id),originalRows.projects); assert.equal(preparedRows.projects.length,2);
    assert.deepEqual(preparedRows.team_members.map(m=>[m.user_id,m.role]).sort(),[[actors.owner.id,'owner'],[actors.member.id,'member'],[actors.viewer.id,'viewer']].sort());
    const anchor=Date.now(), day=86400000;
    const phases=[
      {name:'active-future',status:'active',paid:anchor+3600000,canceled:null,premium:true,read:true},
      {name:'trialing-future',status:'trialing',paid:anchor+3600000,canceled:null,premium:true,read:true},
      {name:'past-due-future-paid',status:'past_due',paid:anchor+3600000,canceled:null,premium:false,read:true},
      {name:'active-expired-inside-grace',status:'active',paid:anchor-day,canceled:null,premium:false,read:true,rejectCreate:'member'},
      {name:'recent-cancel-overrides-old-paid',status:'canceled',paid:anchor-31*day,canceled:anchor-day,premium:false,read:true},
      {name:'old-cancel-overrides-recent-paid',status:'canceled',paid:anchor-day,canceled:anchor-31*day,premium:false,read:false,rejectCreate:'owner'},
      {name:'old-paid-without-cancel',status:'active',paid:anchor-31*day,canceled:null,premium:false,read:false},
    ];
    for(const phase of phases) {
      // Fixture-only entitlement state. Public provider reconciliation is not simulated here.
      await db.prepare('UPDATE teams SET subscription_status=?,paid_until=?,canceled_at=? WHERE id=?').bind(phase.status,phase.paid,phase.canceled,teamId).run();
      const phaseRows=await businessRows(); assert.deepEqual({...phaseRows,teams:originalRows.teams},preparedRows);
      assert.deepEqual(phaseRows.teams,[{...originalTeam,subscription_status:phase.status,paid_until:phase.paid,canceled_at:phase.canceled}]);
      for(const actor of ['owner','member','viewer']) {
        const read=await call(gracePath,actor);
        if(actor==='owner'||phase.read) { ok(read); assert.deepEqual(read.data,{project:{...graceProject,role:actor,premium:phase.premium,canWrite:actor==='owner'||(phase.premium&&actor!=='viewer')}}); }
        else error(read,402,'team_subscription_required');
      }
      const identity=await call('/v1/me','member'); ok(identity); assert.equal(identity.data.user.id,actors.member.id); assert.equal(identity.data.sessionId,actors.member.sessionId);
      assert.deepEqual(identity.data.projects,phase.read?[{...graceProject,role:'member',premium:phase.premium,canWrite:phase.premium}]:[]);
      assert.equal(identity.data.teams.length,1); assert.equal(identity.data.teams[0].id,teamId); assert.equal(identity.data.teams[0].role,'member'); assert.equal(identity.data.teams[0].plan,phase.premium?'team':'free'); assert.equal(identity.data.teams[0].status,phase.status);
      if(phase.rejectCreate) error(await call('/v1/projects',phase.rejectCreate,'POST',{id:randomUUID(),title:'Rejected synthetic entitlement project',teamId}),402,'team_subscription_required');
      assert.deepEqual(await businessRows(),phaseRows);
    }
    const ownerList=await call('/v1/projects'); ok(ownerList); assert.deepEqual(ownerList.data.projects,[{...graceProject,role:'owner',premium:false,canWrite:true}]);
    const beforeArchive=await businessRows(), archiveBefore=Date.now(); const archived=await call(gracePath,'owner','DELETE'); const archiveAfter=Date.now(); ok(archived); assert.deepEqual(archived.data,{ok:true});
    const afterArchive=await businessRows(), archivedRow=afterArchive.projects.find(p=>p.id===graceProject.id), unarchivedRow=beforeArchive.projects.find(p=>p.id===graceProject.id);
    assert(archivedRow.archived_at>=archiveBefore&&archivedRow.archived_at<=archiveAfter); assert.equal(archivedRow.updated_at,archivedRow.archived_at); assert.deepEqual({...archivedRow,archived_at:null,updated_at:unarchivedRow.updated_at},unarchivedRow);
    assert.deepEqual({...afterArchive,projects:afterArchive.projects.map(p=>p.id===graceProject.id?unarchivedRow:p)},beforeArchive);
    const hidden=await call('/v1/projects'); ok(hidden); assert.deepEqual(hidden.data.projects,[]); error(await call(gracePath),404,'not_found'); assert.deepEqual(await businessRows(),afterArchive);
    // Restore the three fixture entitlement fields, then leave through real membership routes.
    await db.prepare('UPDATE teams SET subscription_status=?,paid_until=?,canceled_at=? WHERE id=?').bind(originalTeam.subscription_status,originalTeam.paid_until,originalTeam.canceled_at,teamId).run();
    for(const actor of ['member','viewer']) { const left=await call(membership(actor),actor,'DELETE'); ok(left); assert.deepEqual(left.data,{ok:true}); }
    const finalTeam=await call(team()); ok(finalTeam); assert.deepEqual(finalTeam.data.members.map(m=>[m.id,m.role]),[[actors.owner.id,'owner']]); assert.equal(finalTeam.data.team.plan,'team');
    const finalRows=await businessRows(); assert.deepEqual({...finalRows,projects:finalRows.projects.filter(p=>p.id!==graceProject.id)},originalRows); assert.deepEqual(finalRows.projects.find(p=>p.id===graceProject.id),archivedRow);
    assert.equal(requests,80); assert.equal(outboundAttempts,0);
    console.log(JSON.stringify({kind:'team-entitlement-grace-evidence',httpChecks:41,entitlementStates:7,projectReads:21,memberIdentityReads:7,lapsedCreateRefusals:2,ownerArchiveAfterGrace:true,originalBusinessRowsRestored:true,clockAltered:false,capabilityProjectionOnly:true,nativeScenarios:0,outboundAttempts}));
    console.log(JSON.stringify({result:'PASS',journey:'team-lifecycle',requests,outboundAttempts,nativeScenarios:0,bundleSha256:createHash('sha256').update(capture ? capture.options.script : await readFile(bundle)).digest('hex'),runtime:report}));
  } finally {
    try {
      if (captureStarted) await capture.end(await mf.ready, requests, coverageActions);
    } finally { await mf.dispose(); }
  }
}
