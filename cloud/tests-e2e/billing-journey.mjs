// Real HTTP service-process integration; not Catalyst/native application E2E.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, rm, readFile, readdir, copyFile, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, isAbsolute } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
import { createHash, createHmac, randomBytes, randomUUID } from 'node:crypto';

process.on('uncaughtException', () => { console.error('Billing journey failed; no response or exception details were emitted.'); process.exitCode = 1; });
if (process.argv[2] !== '--owned-child' && (!process.env.SCRIV_TRACER_RUNTIME || !isAbsolute(process.env.SCRIV_TRACER_RUNTIME))) { console.error('Set SCRIV_TRACER_RUNTIME to the absolute path of the reviewed local Tracer runtime.'); process.exit(2); }
const here = await realpath(dirname(fileURLToPath(import.meta.url)));
// --cloud supports an outside-repository candidate without changing its sources.
const cloud = await realpath(process.argv[2] === '--owned-child' ? process.argv[4] :
  process.argv[2] === '--cloud' ? process.argv[3] : join(here, '..'));
const self = await realpath(fileURLToPath(import.meta.url));
if (process.argv[2] !== '--owned-child') {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'scriv-billing-')));
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
  let providerCalls = 0, unexpectedCalls = 0, subscription = null, providerFails = false;
  const denyOutbound = async request => {
    const url = new URL(request.url);
    if (url.origin !== 'https://api.stripe.com' || url.pathname !== '/v1/subscriptions' || request.method !== 'GET' || url.searchParams.get('customer') !== 'cus_synthetic' || url.searchParams.get('status') !== 'all' || url.searchParams.get('limit') !== '100' || [...url.searchParams.keys()].length !== 3 || request.headers.get('authorization') !== 'Bearer sk_test_synthetic_only') { unexpectedCalls++; throw new Error('Unexpected outbound request denied'); }
    providerCalls++;
    if (providerFails) return new Response('synthetic outage', {status:503});
    return Response.json({data:subscription ? [subscription] : [],has_more:false});
  };
  // The installed Miniflare 5 adapter translates this explicit, local-only config.
  const common = { unsafeInspectorProxy: false, compatibilityDate: '2026-10-29', modules: true, outboundService: denyOutbound };
  const config = convertV4MiniflareOptions({
    host: '127.0.0.1', port: 0, cf: false, telemetry: { enabled: false },
    unsafeLocalExplorer: false, unsafeObservability: false,
    unsafeEnableSharedStorage: false, logRequests: false, log: new Log(LogLevel.ERROR),
    resourcePersistencePath: join(root, 'state'), resourceTmpPath: join(root, 'tmp'),
    workers: [{ ...common, name: 'scriv', scriptPath: bundle,
      bindings: { PUBLIC_URL: 'http://127.0.0.1', ENVIRONMENT: 'test', STRIPE_SECRET_KEY:'sk_test_synthetic_only', STRIPE_WEBHOOK_SECRET:'whsec_synthetic_only', STRIPE_TEAM_PRICE_ID:'price_synthetic' },
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
    const now = Date.now(), teamId = randomUUID(), projectId = randomUUID();
    const actors = {};
    for (const role of ['owner', 'member', 'viewer', 'outsider']) {
      const actor = actors[role] = { id: randomUUID(), sessionId: randomUUID(), token: randomBytes(32).toString('base64url') };
      await db.prepare('INSERT INTO users(id,github_id,name,created_at) VALUES(?,?,?,?)').bind(actor.id, `email:${actor.id}`, `Synthetic ${role}`, now).run();
      await db.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at) VALUES(?,?,?,?,?,?)').bind(createHash('sha256').update(actor.token).digest('hex'), actor.sessionId, actor.id, 'Synthetic CLI device', now, now + 3600000).run();
    }
    await db.prepare('INSERT INTO teams(id,name,owner_id,created_at,stripe_customer_id) VALUES(?,?,?,?,?)').bind(teamId, 'Synthetic billing team', actors.owner.id, now, 'cus_synthetic').run();
    for (const role of ['owner', 'member', 'viewer']) await db.prepare('INSERT INTO team_members(team_id,user_id,role,joined_at) VALUES(?,?,?,?)').bind(teamId, actors[role].id, role, now).run();
    let requests=0;
    async function request(path,{role='owner',method='GET',body,signature}={}) {
      const base=await mf.ready; assert.equal(base.hostname,'127.0.0.1'); assert.equal(base.protocol,'http:'); assert(Number(base.port)>0);
      const url=new URL(path,base); assert.equal(url.origin,base.origin);
      const encoded=body===undefined?undefined:JSON.stringify(body); assert(requests++<80); assert(Buffer.byteLength(encoded??'')<=16384);
      const response=await fetch(url,{method,headers:{authorization:`Bearer ${actors[role].token}`,...(encoded?{'content-type':'application/json'}:{}),...(signature?{'stripe-signature':signature}:{})},body:encoded,redirect:'error',signal:AbortSignal.timeout(5000)});
      assert.equal(response.headers.get('cache-control'),'no-store'); assert.equal(response.headers.get('x-content-type-options'),'nosniff');
      const reader=response.body.getReader(), parts=[];let size=0;while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;assert(size<=65536);parts.push(value);}
      return {status:response.status,data:JSON.parse(Buffer.concat(parts).toString('utf8'))};
    }
    const sign=(event,t=Math.floor(Date.now()/1000))=>`t=${t},v1=${createHmac('sha256','whsec_synthetic_only').update(`${t}.${JSON.stringify(event)}`).digest('hex')}`;
    const event=(id,type='customer.subscription.updated',created=Math.floor(Date.now()/1000),customer='cus_synthetic')=>({id,type,created,data:{object:{customer}}});
    const sendWebhook=(body,signature=sign(body))=>request('/billing/webhook',{method:'POST',body,signature});
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
    const catalog = JSON.parse(await readFile(join(cloud, '../docs/testing/billing-steps.json'), 'utf8'));
    const run = createScenarioRun({ catalog, scenarioId:'billing-entitlement-lifecycle', runId:randomUUID(), context:{build:'local-worker-bundle',platform:process.platform,inputRoute:'Scriv CLI service HTTP'} });
    const teamPath=`/v1/teams/${teamId}`;
    let result;
    await run.step('read-free-team', async step => {
      result=await step.action('GET synthetic free team as owner',()=>request(teamPath));
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.team.plan,'free');assert.equal(result.data.team.status,'free');assert.equal(result.data.team.billingCustomer,true);});
    });
    await run.step('reject-member-billing', async step => {
      result=await step.action('POST billing portal as member',()=>request(`${teamPath}/billing/portal`,{role:'member',method:'POST'}));
      await step.expect('observed',()=>{assert.equal(result.status,403);assert.equal(result.data.error.code,'not_allowed');assert.equal(providerCalls,0);});
    });
    await run.step('reject-outsider-billing', async step => {
      result=await step.action('POST billing portal as outsider',()=>request(`${teamPath}/billing/portal`,{role:'outsider',method:'POST'}));
      await step.expect('observed',()=>{assert.equal(result.status,404);assert.equal(result.data.error.code,'not_found');assert.equal(providerCalls,0);});
    });
    const activeEvent=event('evt_synthetic_active');
    await run.step('reject-invalid-signature', async step => {
      result=await step.action('POST webhook with invalid synthetic signature',()=>sendWebhook(activeEvent,`t=${Math.floor(Date.now()/1000)},v1=${'0'.repeat(64)}`));
      await step.expect('observed',()=>{assert.equal(result.status,400);assert.equal(result.data.error.code,'invalid_signature');assert.equal(providerCalls,0);});
    });
    await run.step('ignore-unknown-event', async step => {
      result=await step.action('POST signed unrecognized webhook event',()=>sendWebhook(event('evt_synthetic_unknown','synthetic.unknown')));
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.received,true);assert.equal(result.data.ignored,true);assert.equal(providerCalls,0);});
    });
    await run.step('ignore-unknown-customer', async step => {
      result=await step.action('POST signed event for unknown synthetic customer',()=>sendWebhook(event('evt_unknown_customer','customer.subscription.updated',Math.floor(Date.now()/1000),'cus_other_synthetic')));
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.ignored,true);assert.equal(providerCalls,0);});
    });
    const endSeconds=Math.floor(Date.now()/1000)+3600;
    const makeSubscription=(status,overrides={})=>({id:'sub_synthetic',customer:'cus_synthetic',metadata:{teamId},status,created:Math.floor(now/1000),items:{has_more:false,data:[{price:{id:'price_synthetic'},quantity:1,current_period_end:endSeconds}]},...overrides});
    await run.step('activate-subscription', async step => {
      result=await step.action('POST signed activation with synthetic active provider snapshot',()=>{subscription=makeSubscription('active');return sendWebhook(activeEvent);});
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.received,true);assert.equal(providerCalls,1);assert.equal(unexpectedCalls,0);});
    });
    await run.step('read-active-team', async step => {
      result=await step.action('GET synthetic active team as member',()=>request(teamPath,{role:'member'}));
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.team.plan,'team');assert.equal(result.data.team.status,'active');assert.equal(result.data.team.currentPeriodEnd,endSeconds*1000);assert.equal('billingCustomer' in result.data.team,false);});
    });
    await run.step('create-paid-project', async step => {
      result=await step.action('POST team project as member with active entitlement',()=>request('/v1/projects',{role:'member',method:'POST',body:{id:projectId,title:'Synthetic entitlement story',teamId}}));
      await step.expect('observed',()=>{assert.equal(result.status,201);assert.equal(result.data.project.id,projectId);assert.equal(result.data.project.ownerId,actors.owner.id);});
    });
    await run.step('read-paid-access', async step => {
      result=await step.action('GET team project access as member while active',()=>request(`/v1/projects/${projectId}`,{role:'member'}));
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.project.premium,true);assert.equal(result.data.project.canWrite,true);assert.equal(result.data.project.role,'member');});
    });
    await run.step('replay-receipt', async step => {
      result=await step.action('POST duplicate activation after provider snapshot changes',()=>{subscription=makeSubscription('canceled',{ended_at:Math.floor(Date.now()/1000)-30});return sendWebhook(activeEvent);});
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.received,true);assert.equal(providerCalls,1);});
    });
    await run.step('read-replay-state', async step => {
      result=await step.action('GET team after duplicate receipt',()=>request(teamPath));
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.team.plan,'team');assert.equal(result.data.team.status,'active');});
    });
    const canceledEvent=event('evt_synthetic_cancel','customer.subscription.deleted');
    await run.step('cancel-subscription', async step => {
      result=await step.action('POST signed cancellation with synthetic canceled provider snapshot',()=>sendWebhook(canceledEvent));
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.received,true);assert.equal(providerCalls,2);});
    });
    await run.step('read-canceled-team', async step => {
      result=await step.action('GET synthetic canceled team',()=>request(teamPath));
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.team.plan,'free');assert.equal(result.data.team.status,'canceled');});
    });
    await run.step('read-canceled-member-access', async step => {
      result=await step.action('GET team project access as member in cancellation grace',()=>request(`/v1/projects/${projectId}`,{role:'member'}));
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.project.premium,false);assert.equal(result.data.project.canWrite,false);});
    });
    await run.step('reject-canceled-member-write', async step => {
      result=await step.action('POST project command as member after cancellation',()=>request(`/v1/projects/${projectId}/commands`,{role:'member',method:'POST',body:{commandId:randomUUID(),sessionId:actors.member.sessionId,epoch:1,label:'Synthetic denied edit',operations:[{op:'put',id:projectId,kind:'scene',expectedVersion:0,data:{id:projectId,title:'Denied edit',order:0}}]}}));
      await step.expect('observed',()=>{assert.equal(result.status,403);assert.equal(result.data.error.code,'read_only');});
    });
    await run.step('read-canceled-owner-access', async step => {
      result=await step.action('GET team project access as owner after cancellation',()=>request(`/v1/projects/${projectId}`));
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.project.premium,false);assert.equal(result.data.project.canWrite,true);assert.equal(result.data.project.role,'owner');});
    });
    const delayedEvent=event('evt_synthetic_delayed','customer.subscription.deleted',Math.floor(now/1000)-120);
    await run.step('reconcile-delayed-event', async step => {
      result=await step.action('POST older cancellation after synthetic provider reactivation',()=>{subscription=makeSubscription('trialing');return sendWebhook(delayedEvent);});
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.received,true);assert.equal(providerCalls,3);});
    });
    await run.step('read-reactivated-team', async step => {
      result=await step.action('GET team after delayed cancellation reconciliation',()=>request(teamPath));
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.team.plan,'team');assert.equal(result.data.team.status,'trialing');assert.equal(result.data.team.currentPeriodEnd,endSeconds*1000);});
    });
    await run.step('read-restored-member-access', async step => {
      result=await step.action('GET team project access as member after reactivation',()=>request(`/v1/projects/${projectId}`,{role:'member'}));
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.project.premium,true);assert.equal(result.data.project.canWrite,true);});
    });
    const retryEvent=event('evt_synthetic_retry','invoice.paid');
    await run.step('provider-outage', async step => {
      result=await step.action('POST signed event during synthetic provider outage',()=>{subscription=makeSubscription('active');providerFails=true;return sendWebhook(retryEvent);});
      await step.expect('observed',()=>{assert.equal(result.status,502);assert.equal(result.data.error.code,'billing_reconciliation_failed');assert.equal(providerCalls,4);});
    });
    await run.step('read-after-outage', async step => {
      result=await step.action('GET team after failed reconciliation',()=>request(teamPath));
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.team.plan,'team');assert.equal(result.data.team.status,'trialing');});
    });
    await run.step('retry-provider-outage', async step => {
      result=await step.action('POST same signed event after synthetic provider recovery',()=>{providerFails=false;return sendWebhook(retryEvent);});
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.received,true);assert.equal(providerCalls,5);});
    });
    await run.step('read-after-retry', async step => {
      result=await step.action('GET team after successful reconciliation retry',()=>request(teamPath));
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.team.plan,'team');assert.equal(result.data.team.status,'active');});
    });
    const mismatchEvent=event('evt_synthetic_wrong_price','customer.subscription.updated');
    await run.step('reject-mismatched-price', async step => {
      result=await step.action('POST signed update with wrong-price synthetic subscription',()=>{subscription=makeSubscription('active',{items:{has_more:false,data:[{price:{id:'price_wrong_synthetic'},quantity:1,current_period_end:endSeconds}]}});return sendWebhook(mismatchEvent);});
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.received,true);assert.equal(providerCalls,6);});
    });
    await run.step('read-mismatched-price', async step => {
      result=await step.action('GET team after mismatched-price reconciliation',()=>request(teamPath));
      await step.expect('observed',()=>{assert.equal(result.status,200);assert.equal(result.data.team.plan,'free');assert.equal(result.data.team.status,'free');});
    });
    const staleEvent=event('evt_synthetic_stale');
    await run.step('reject-stale-signature', async step => {
      result=await step.action('POST webhook with expired synthetic signature',()=>sendWebhook(staleEvent,sign(staleEvent,Math.floor(Date.now()/1000)-301)));
      await step.expect('observed',()=>{assert.equal(result.status,400);assert.equal(result.data.error.code,'invalid_signature');assert.equal(providerCalls,6);});
    });
    const report=run.finish();assert.equal(report.status,'passed');assert.equal(unexpectedCalls,0);
    // Checkout is a separate appended chapter; the original 27 named steps remain intact.
    // All provider traffic is intercepted locally. No real customer, payment or account is created.
    const checkoutTeam = randomUUID(), checkoutCustomer = 'cus_checkout_synthetic';
    const checkoutPath = `/v1/teams/${checkoutTeam}/billing/checkout`, portalPath = `/v1/teams/${checkoutTeam}/billing/portal`;
    const publicOrigin = 'https://scriv.example.invalid';
    const originalTeam = await db.prepare('SELECT * FROM teams WHERE id=?').bind(teamId).first();
    const originalProjects = (await db.prepare('SELECT * FROM projects ORDER BY id').all()).results;
    const originalReceipts = (await db.prepare('SELECT * FROM billing_events ORDER BY id').all()).results;
    let pendingProvider = [], checkoutProviderCalls = 0, checkoutCreates = 0, customerCreates = 0;
    const checkoutCases = [], checkoutKeys = [];
    const checkoutProvider = async incoming => {
      try {
        const expected = pendingProvider.shift(); assert.ok(expected, 'No unplanned provider request');
        assert.equal(incoming.url, `https://api.stripe.com/v1${expected.path}`); assert.equal(incoming.method, expected.method);
        assert.equal(incoming.headers.get('authorization'), 'Bearer sk_test_synthetic_only');
        assert.equal(incoming.headers.get('stripe-version'), '2025-04-30.basil');
        if (expected.body) {
          assert.equal(incoming.headers.get('content-type'), 'application/x-www-form-urlencoded');
          const actual = new URLSearchParams(await incoming.text());
          assert.deepEqual([...actual].sort(([a], [b]) => a.localeCompare(b)), Object.entries(expected.body).sort(([a], [b]) => a.localeCompare(b)));
        } else assert.equal(await incoming.text(), '');
        const key = incoming.headers.get('idempotency-key');
        if (expected.key === 'checkout') {
          assert.match(key ?? '', new RegExp(`^scriv-checkout-${checkoutTeam}-[0-9a-f-]{36}$`));
          assert.ok(!checkoutKeys.includes(key), 'Successful replacement needs a new request key'); checkoutKeys.push(key); checkoutCreates++;
        } else { assert.equal(key, expected.key ?? null); if (expected.path === '/customers') customerCreates++; }
        checkoutProviderCalls++;
        return typeof expected.reply === 'function' ? await expected.reply() : Response.json(expected.reply);
      } catch { unexpectedCalls++; throw new Error('Unexpected synthetic checkout provider request'); }
    };
    await mf.setOptions(convertV4MiniflareOptions({
      host: '127.0.0.1', port: 0, cf: false, telemetry: { enabled: false }, unsafeLocalExplorer: false,
      unsafeObservability: false, unsafeEnableSharedStorage: false, logRequests: false, log: new Log(LogLevel.ERROR),
      resourcePersistencePath: join(root, 'state'), resourceTmpPath: join(root, 'tmp'),
      workers: [{ ...common, outboundService: checkoutProvider, name: 'scriv', scriptPath: bundle,
        bindings: { PUBLIC_URL: publicOrigin, ENVIRONMENT: 'test', STRIPE_SECRET_KEY: 'sk_test_synthetic_only', STRIPE_WEBHOOK_SECRET: 'whsec_synthetic_only', STRIPE_TEAM_PRICE_ID: 'price_synthetic' },
        d1Databases: { DB: 'journey-db' }, r2Buckets: ['ASSETS'],
        durableObjects: { PROJECTS: { className: 'ProjectRoom', useSQLite: true }, BILLING: { className: 'BillingCoordinator', useSQLite: true } },
      }],
    }));
    const checkoutDB = await mf.getD1Database('DB', 'scriv');
    await checkoutDB.prepare('INSERT INTO teams(id,name,owner_id,created_at) VALUES(?,?,?,?)').bind(checkoutTeam, 'Synthetic checkout team', actors.owner.id, now).run();
    await checkoutDB.prepare("INSERT INTO team_members(team_id,user_id,role,joined_at) VALUES(?,?,'owner',?)").bind(checkoutTeam, actors.owner.id, now).run();
    const teamRow = () => checkoutDB.prepare('SELECT * FROM teams WHERE id=?').bind(checkoutTeam).first();
    const price = { id: 'price_synthetic', active: true, currency: 'usd', unit_amount: 999, type: 'recurring', billing_scheme: 'per_unit', recurring: { interval: 'month', interval_count: 1, usage_type: 'licensed' } };
    const priceStep = reply => ({ method: 'GET', path: '/prices/price_synthetic', reply: reply ?? price });
    const subscriptionsStep = data => ({ method: 'GET', path: '/subscriptions?customer=cus_checkout_synthetic&status=all&limit=100', reply: { data, has_more: false } });
    const lookupStep = (id, reply) => ({ method: 'GET', path: `/checkout/sessions/${id}`, reply });
    const returnURL = `${publicOrigin}/billing/return?team=${checkoutTeam}`;
    const checkoutBody = { mode: 'subscription', customer: checkoutCustomer, currency: 'usd', client_reference_id: checkoutTeam, 'metadata[teamId]': checkoutTeam, 'subscription_data[metadata][teamId]': checkoutTeam, 'line_items[0][price]': 'price_synthetic', 'line_items[0][quantity]': '1', allow_promotion_codes: 'false', success_url: returnURL, cancel_url: `${returnURL}&canceled=1` };
    const createStep = reply => ({ method: 'POST', path: '/checkout/sessions', body: checkoutBody, key: 'checkout', reply });
    const cached = (id, status, overrides = {}) => ({ id, customer: checkoutCustomer, client_reference_id: checkoutTeam, mode: 'subscription', status, url: `https://checkout.stripe.com/c/pay/${id}`, ...overrides });
    async function checkoutCase(label, steps, expectedStatus, expectedData, path = checkoutPath, clientBody) {
      assert.equal(pendingProvider.length, 0); pendingProvider = [...steps]; const before = checkoutProviderCalls;
      const response = await request(path, { method: 'POST', body: clientBody });
      assert.equal(response.status, expectedStatus, label); assert.equal(pendingProvider.length, 0, `${label} consumes every expected provider request`);
      assert.equal(checkoutProviderCalls - before, steps.length); assert.equal(unexpectedCalls, 0);
      if (typeof expectedData === 'string') assert.equal(response.data.error?.code, expectedData);
      else assert.deepEqual(response.data, expectedData);
      assert.deepEqual(await checkoutDB.prepare('SELECT * FROM teams WHERE id=?').bind(teamId).first(), originalTeam);
      assert.deepEqual((await checkoutDB.prepare('SELECT * FROM projects ORDER BY id').all()).results, originalProjects);
      assert.deepEqual((await checkoutDB.prepare('SELECT * FROM billing_events ORDER BY id').all()).results, originalReceipts);
      checkoutCases.push(label); return response;
    }
    const initialCheckoutTeam = await teamRow();
    for (const [label, reply, status, code] of [
      ['reject-wrong-fixed-amount', { ...price, unit_amount: 1000 }, 503, 'invalid_team_price'],
      ['reject-provider-http-error', () => new Response('synthetic outage', { status: 503 }), 502, 'billing_provider_error'],
      ['reject-provider-invalid-json', () => new Response('{', { headers: { 'content-type': 'application/json' } }), 502, 'billing_provider_error'],
      ['reject-provider-array', [], 502, 'billing_provider_error'],
    ]) {
      await checkoutCase(label, [priceStep(reply)], status, code); assert.deepEqual(await teamRow(), initialCheckoutTeam);
      assert.equal(customerCreates, 0); assert.equal(checkoutCreates, 0);
    }
    await checkoutCase('recheck-owner-after-price', [priceStep(async () => {
      await checkoutDB.prepare("UPDATE team_members SET role='member' WHERE team_id=? AND user_id=?").bind(checkoutTeam, actors.owner.id).run();
      return Response.json(price);
    })], 403, 'not_allowed');
    assert.deepEqual(await teamRow(), initialCheckoutTeam); assert.equal(customerCreates, 0); assert.equal(checkoutCreates, 0);
    await checkoutDB.prepare("UPDATE team_members SET role='owner' WHERE team_id=? AND user_id=?").bind(checkoutTeam, actors.owner.id).run();
    let firstExpiry;
    const firstCheckoutURL = 'https://checkout.stripe.com/c/pay/cs_first_synthetic';
    const beforeCreation = Date.now();
    await checkoutCase('create-first-checkout', [priceStep(),
      { method: 'POST', path: '/customers', key: `scriv-customer-${checkoutTeam}`, body: { name: 'Synthetic checkout team', 'metadata[teamId]': checkoutTeam }, reply: { id: checkoutCustomer } },
      subscriptionsStep([]), createStep(() => { firstExpiry = Math.floor(Date.now() / 1000) + 2; return Response.json({ id: 'cs_first_synthetic', url: firstCheckoutURL, expires_at: firstExpiry }); }),
    ], 200, { url: firstCheckoutURL }, checkoutPath, { price: 'price_untrusted', quantity: 99, currency: 'eur', success_url: 'https://other.invalid' });
    const createdTeam = await teamRow();
    assert.deepEqual(createdTeam, { ...initialCheckoutTeam, stripe_customer_id: checkoutCustomer, current_period_end: 0, paid_until: 0, canceled_at: createdTeam.canceled_at, billing_checked_at: createdTeam.billing_checked_at });
    assert.equal(createdTeam.stripe_customer_id, checkoutCustomer); assert.equal(createdTeam.subscription_status, 'free');
    assert.ok(createdTeam.canceled_at >= beforeCreation && createdTeam.canceled_at <= Date.now());
    assert.ok(createdTeam.billing_checked_at >= beforeCreation && createdTeam.billing_checked_at <= Date.now());
    assert.equal(customerCreates, 1); assert.equal(checkoutCreates, 1);
    // Let the real saved expiresAt elapse; an authoritative provider-open result must still be reused.
    const waitMs = firstExpiry * 1000 - Date.now() + 25; assert.ok(waitMs > 0 && waitMs < 3000);
    await new Promise(resolve => setTimeout(resolve, waitMs)); assert.ok(Date.now() > firstExpiry * 1000);
    await checkoutCase('reuse-open-after-local-expiry', [priceStep(), subscriptionsStep([]), lookupStep('cs_first_synthetic', cached('cs_first_synthetic', 'open', { expires_at: firstExpiry, url: 'https://checkout.stripe.com/c/pay/authoritative-open' }))], 200, { url: 'https://checkout.stripe.com/c/pay/authoritative-open' });
    assert.equal(customerCreates, 1); assert.equal(checkoutCreates, 1);
    await checkoutCase('retain-complete-unconfirmed', [priceStep(), subscriptionsStep([]), lookupStep('cs_first_synthetic', cached('cs_first_synthetic', 'complete', { subscription: 'sub_terminal_synthetic' }))], 409, 'billing_processing');
    assert.equal(checkoutCreates, 1);
    const terminal = { id: 'sub_terminal_synthetic', customer: checkoutCustomer, metadata: { teamId: checkoutTeam }, status: 'canceled', created: Math.floor(now / 1000), ended_at: Math.floor(now / 1000) - 60, items: { has_more: false, data: [{ price: { id: 'price_synthetic' }, quantity: 1, current_period_end: Math.floor(now / 1000) - 60 }] } };
    const newReceipt = id => ({ id, url: `https://checkout.stripe.com/c/pay/${id}`, expires_at: Math.floor(Date.now() / 1000) + 3600 });
    await checkoutCase('replace-complete-terminal', [priceStep(), subscriptionsStep([terminal]), lookupStep('cs_first_synthetic', cached('cs_first_synthetic', 'complete', { subscription: terminal.id })), createStep(newReceipt('cs_second_synthetic'))], 200, { url: 'https://checkout.stripe.com/c/pay/cs_second_synthetic' });
    assert.equal(checkoutCreates, 2);
    await checkoutCase('replace-expired-checkout', [priceStep(), subscriptionsStep([]), lookupStep('cs_second_synthetic', cached('cs_second_synthetic', 'expired')), createStep(newReceipt('cs_third_synthetic'))], 200, { url: 'https://checkout.stripe.com/c/pay/cs_third_synthetic' });
    assert.equal(checkoutCreates, 3); assert.equal(new Set(checkoutKeys).size, 3);
    await checkoutCase('reject-cached-customer-mismatch', [priceStep(), subscriptionsStep([]), lookupStep('cs_third_synthetic', cached('cs_third_synthetic', 'open', { customer: 'cus_other_synthetic' }))], 502, 'billing_provider_error');
    for (const [label, url] of [
      ['http', 'http://checkout.stripe.com/c/pay/fixture'],
      ['wrong-host', 'https://checkout.stripe.com.other.invalid/c/pay/fixture'],
      ['userinfo', 'https://synthetic:fixture@checkout.stripe.com/c/pay/fixture'],
      ['port', 'https://checkout.stripe.com:8443/c/pay/fixture'],
      ['malformed', 'not a URL'],
    ]) await checkoutCase(`reject-cached-url-${label}`, [priceStep(), subscriptionsStep([]), lookupStep('cs_third_synthetic', cached('cs_third_synthetic', 'open', { url }))], 502, 'billing_provider_error');
    await checkoutCase('retain-cache-after-refusals', [priceStep(), subscriptionsStep([]), lookupStep('cs_third_synthetic', cached('cs_third_synthetic', 'open'))], 200, { url: 'https://checkout.stripe.com/c/pay/cs_third_synthetic' });
    assert.equal(customerCreates, 1); assert.equal(checkoutCreates, 3);
    const active = { ...terminal, id: 'sub_active_checkout', status: 'active', ended_at: null, items: { ...terminal.items, data: [{ price: { id: 'price_synthetic' }, quantity: 1, current_period_end: Math.floor(Date.now() / 1000) + 3600 }] } };
    await checkoutCase('block-active-subscription', [priceStep(), subscriptionsStep([active])], 409, 'already_subscribed');
    assert.equal((await teamRow()).subscription_id, active.id); assert.equal((await teamRow()).subscription_status, 'active');
    const nonterminal = { ...terminal, id: 'sub_unrelated_past_due', status: 'past_due', items: { ...terminal.items, data: [{ ...terminal.items.data[0], price: { id: 'price_other_synthetic' } }] } };
    await checkoutCase('block-any-nonterminal-subscription', [priceStep(), subscriptionsStep([nonterminal])], 409, 'subscription_exists');
    assert.equal((await teamRow()).subscription_status, 'free'); assert.equal(checkoutCreates, 3);
    const portalStep = reply => ({ method: 'POST', path: '/billing_portal/sessions', body: { customer: checkoutCustomer, return_url: returnURL }, reply });
    const portalURL = 'https://billing.stripe.com/p/session/synthetic';
    await checkoutCase('open-owner-portal', [portalStep({ url: portalURL })], 200, { url: portalURL }, portalPath);
    await checkoutCase('reject-unsafe-portal-url', [portalStep({ url: 'https://billing.stripe.com.other.invalid/session' })], 502, 'billing_provider_error', portalPath);
    const beforePortalRevocation = await teamRow();
    const revokedPortalResponse=await checkoutCase('recheck-session-after-portal', [portalStep(async () => {
      await checkoutDB.prepare('UPDATE sessions SET revoked_at=? WHERE id=?').bind(Date.now(), actors.owner.sessionId).run();
      return Response.json({ url: portalURL });
    })], 401, 'session_expired', portalPath);assert.deepEqual(revokedPortalResponse.data,{error:{code:'session_expired',message:'Your Scriv session has expired. Sign in again.'}});
    // The provider call did occur. Only its URL release is denied; no remote rollback is claimed.
    assert.deepEqual(await teamRow(), beforePortalRevocation);
    await checkoutDB.prepare('UPDATE sessions SET revoked_at=NULL WHERE id=?').bind(actors.owner.sessionId).run();
    assert.equal(pendingProvider.length, 0); assert.equal(unexpectedCalls, 0); assert.equal(checkoutCases.length, 22);
    assert.equal(customerCreates, 1); assert.equal(checkoutCreates, 3); assert.equal(providerCalls, 6);
    assert.deepEqual((await (await mf.getR2Bucket('ASSETS', 'scriv')).list()).objects, []);
    console.log(JSON.stringify({ kind: 'checkout-safety-evidence', cases: checkoutCases, checkoutProviderCalls, customerCreates, checkoutCreates, distinctSuccessfulCheckoutKeys: new Set(checkoutKeys).size, unexpectedCalls, nativeScenarios: 0, liveProvider: false }));
    // Signed webhook boundary chapter: public HTTP, synthetic HMAC/provider only.
    assert.equal(requests,49); const webhookStart=requests, webhookProviderStart=providerCalls;
    const webhookTables=['users','sessions','teams','team_members','projects','billing_events','generation_jobs','generation_job_operations','assets'];
    async function webhookState(database) {
      const state={}; for(const name of webhookTables)state[name]=(await database.prepare(`SELECT * FROM ${name} ORDER BY rowid`).all()).results;
      state.objects=(await (await mf.getR2Bucket('ASSETS','scriv')).list()).objects; return state;
    }
    const webhookBeforeRestart=await webhookState(checkoutDB);
    await mf.setOptions(config); const webhookDB=await mf.getD1Database('DB','scriv');
    assert.deepEqual(await webhookState(webhookDB),webhookBeforeRestart);
    const webhookBaseline=await webhookState(webhookDB), webhookCases=[];
    const rawSignature=(raw,t=Math.floor(Date.now()/1000))=>`t=${t},v1=${createHmac('sha256','whsec_synthetic_only').update(`${t}.${raw}`).digest('hex')}`;
    async function rawWebhook(raw,signature) {
      const base=await mf.ready;assert.equal(base.hostname,'127.0.0.1');assert.equal(base.protocol,'http:');assert(Number(base.port)>0);
      assert(requests++<80);assert(Buffer.byteLength(raw)<=16384);
      const response=await fetch(new URL('/billing/webhook',base),{method:'POST',headers:{'content-type':'application/json',...(signature===undefined?{}:{'stripe-signature':signature})},body:raw,redirect:'error',signal:AbortSignal.timeout(5000)});
      assert.equal(response.headers.get('cache-control'),'no-store');assert.equal(response.headers.get('x-content-type-options'),'nosniff');
      const reader=response.body.getReader(),parts=[];let size=0;while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;assert(size<=65536);parts.push(value);}
      return {status:response.status,data:JSON.parse(Buffer.concat(parts).toString('utf8'))};
    }
    async function webhookUnchanged(label,raw,signature,status,expected) {
      const before=await webhookState(webhookDB),calls=providerCalls;const response=await rawWebhook(raw,signature);
      assert.equal(response.status,status,label);assert.deepEqual(response.data,expected,label);assert.equal(providerCalls,calls,label);assert.equal(unexpectedCalls,0);
      assert.deepEqual(await webhookState(webhookDB),before,label);webhookCases.push(label);return response;
    }
    const invalidSignature={error:{code:'invalid_signature',message:'Invalid Stripe signature.'}};
    const signatureEvent=event('evt_signature_boundary'),signatureRaw=JSON.stringify(signatureEvent),signatureNow=Math.floor(Date.now()/1000),validSignature=rawSignature(signatureRaw,signatureNow);
    for(const [label,raw,signature] of [
      ['missing-signature',signatureRaw,undefined],
      ['missing-timestamp',signatureRaw,validSignature.split(',')[1]],
      ['fractional-timestamp',signatureRaw,validSignature.replace(`t=${signatureNow}`,`t=${signatureNow}.5`)],
      ['future-signature',signatureRaw,rawSignature(signatureRaw,signatureNow+600)],
      ['stale-signature',signatureRaw,rawSignature(signatureRaw,signatureNow-600)],
      ['wrong-digest',signatureRaw,`t=${signatureNow},v1=${'0'.repeat(64)}`],
      ['unsupported-signature-version',signatureRaw,validSignature.replace(',v1=',',v0=')],
      ['tampered-signed-payload',JSON.stringify({...signatureEvent,id:'evt_tampered_boundary'}),validSignature],
    ])await webhookUnchanged(label,raw,signature,400,invalidSignature);
    const ignoredEvent=event('evt_signature_rotation','synthetic.unrecognized'),ignoredRaw=JSON.stringify(ignoredEvent),ignoredSignature=rawSignature(ignoredRaw);
    await webhookUnchanged('valid-secondary-signature',ignoredRaw,ignoredSignature.replace(',v1=',`,v1=${'0'.repeat(64)},v1=`),200,{received:true,ignored:true});
    await webhookUnchanged('trimmed-signature-fields',ignoredRaw,ignoredSignature.replace(',v1=',',  v1=')+'  ',200,{received:true,ignored:true});
    const envelopeEvent=event('evt_envelope_boundary');
    for(const [label,body,code,message] of [
      ['array-event',[],'invalid_field','event must be an object.'],
      ['null-event',null,'invalid_field','event must be an object.'],
      ['missing-event-id',{...envelopeEvent,id:undefined},'invalid_field','event.id must be 1–128 characters.'],
      ['empty-event-type',{...envelopeEvent,type:''},'invalid_field','event.type must be 1–128 characters.'],
      ['missing-event-data',{...envelopeEvent,data:undefined},'invalid_event','Webhook object is missing.'],
      ['array-event-object',{...envelopeEvent,data:{object:[]}},'invalid_event','Webhook object is missing.'],
      ['missing-customer',{...envelopeEvent,data:{object:{}}},'invalid_customer','Webhook customer is missing.'],
      ['zero-created-at',{...envelopeEvent,created:0},'invalid_event','Webhook creation time is missing or invalid.'],
      ['overflow-created-at',{...envelopeEvent,created:Number.MAX_SAFE_INTEGER},'invalid_event','Webhook creation time is missing or invalid.'],
    ]){const raw=JSON.stringify(body);await webhookUnchanged(label,raw,rawSignature(raw),400,{error:{code,message}});}
    await webhookUnchanged('signed-malformed-json','{',rawSignature('{'),400,{error:{code:'invalid_json',message:'Invalid webhook body.'}});
    const unknownRaw=JSON.stringify(event('evt_expanded_unknown','invoice.paid',Math.floor(Date.now()/1000),{id:'cus_missing_boundary'}));
    await webhookUnchanged('expanded-unknown-customer',unknownRaw,rawSignature(unknownRaw),200,{received:true,ignored:true});
    const reusedRaw=JSON.stringify({...activeEvent,data:{object:{customer:checkoutCustomer}}});
    await webhookUnchanged('cross-team-event-reuse',reusedRaw,rawSignature(reusedRaw),502,{error:{code:'billing_reconciliation_failed',message:'Billing confirmation is temporarily unavailable. The provider should retry this event.'}});
    const boundaryEvent=event('evt_webhook_retry_boundary','invoice.paid'),boundaryRaw=JSON.stringify(boundaryEvent);
    subscription=makeSubscription('active');providerFails=true;let mutationBefore=await webhookState(webhookDB),callsBefore=providerCalls;
    let boundaryResponse=await rawWebhook(boundaryRaw,rawSignature(boundaryRaw));assert.equal(boundaryResponse.status,502);
    assert.deepEqual(boundaryResponse.data,{error:{code:'billing_reconciliation_failed',message:'Billing confirmation is temporarily unavailable. The provider should retry this event.'}});
    assert.equal(providerCalls,callsBefore+1);assert.deepEqual(await webhookState(webhookDB),mutationBefore);webhookCases.push('provider-failure-no-receipt');
    providerFails=false;const boundaryStart=Date.now();boundaryResponse=await rawWebhook(boundaryRaw,rawSignature(boundaryRaw));const boundaryEnd=Date.now();
    assert.equal(boundaryResponse.status,200);assert.deepEqual(boundaryResponse.data,{received:true});assert.equal(providerCalls,callsBefore+2);
    const mutationAfter=await webhookState(webhookDB),priorTeam=mutationBefore.teams.find(t=>t.id===teamId),newTeam=mutationAfter.teams.find(t=>t.id===teamId);
    assert(newTeam.billing_checked_at>=boundaryStart&&newTeam.billing_checked_at<=boundaryEnd);
    assert.deepEqual(newTeam,{...priorTeam,subscription_id:'sub_synthetic',subscription_status:'active',current_period_end:endSeconds*1000,paid_until:endSeconds*1000,canceled_at:null,billing_checked_at:newTeam.billing_checked_at});
    assert.deepEqual(mutationAfter.teams.filter(t=>t.id!==teamId),mutationBefore.teams.filter(t=>t.id!==teamId));
    const expectedEvent={id:boundaryEvent.id,team_id:teamId,event_type:'invoice.paid',created_at:boundaryEvent.created*1000,processed_at:newTeam.billing_checked_at};
    assert.deepEqual(mutationAfter.billing_events,[...mutationBefore.billing_events,expectedEvent]);
    for(const name of [...webhookTables,'objects'].filter(n=>!['teams','billing_events'].includes(n)))assert.deepEqual(mutationAfter[name],mutationBefore[name]);
    webhookCases.push('same-event-retry-commits-once');
    subscription=makeSubscription('canceled',{ended_at:Math.floor(Date.now()/1000)-60});
    await webhookUnchanged('replay-keeps-accepted-state',boundaryRaw,rawSignature(boundaryRaw),200,{received:true});
    boundaryResponse=await request(teamPath,{role:'viewer'});assert.equal(boundaryResponse.status,200);assert.equal(boundaryResponse.data.team.plan,'team');assert.equal(boundaryResponse.data.team.status,'active');assert.equal(boundaryResponse.data.team.currentPeriodEnd,endSeconds*1000);
    assert.deepEqual(await webhookState(webhookDB),mutationAfter);webhookCases.push('viewer-reads-accepted-entitlement');
    assert.equal(webhookCases.length,26);assert.equal(requests-webhookStart,26);assert.equal(requests,75);assert.equal(providerCalls-webhookProviderStart,2);assert.equal(unexpectedCalls,0);
    assert.deepEqual(mutationAfter.billing_events.filter(e=>e.id!==boundaryEvent.id),webhookBaseline.billing_events);
    console.log(JSON.stringify({kind:'webhook-boundary-evidence',httpChecks:26,signatureRefusals:8,acceptedSignatureVariants:2,envelopeRefusals:10,ignoredExpandedCustomer:1,crossTeamEventRefusals:1,syntheticProviderAttempts:2,newReceipts:1,currentStateReplays:1,webhookAuthHeaderSent:false,nativeScenarios:0,liveProvider:false,unexpectedCalls}));
    console.log(JSON.stringify({result:'PASS',journey:'billing',requests,providerCalls:providerCalls+checkoutProviderCalls,entitlementProviderCalls:providerCalls,checkoutProviderCalls,unexpectedCalls,nativeScenarios:0,runtime:report}));
  } finally { await mf.dispose(); }
}
