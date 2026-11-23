// Real HTTP service-process integration; not Catalyst/native application E2E.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, rm, readFile, readdir, copyFile, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, isAbsolute } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';

process.on('uncaughtException', () => { console.error('Peer signaling journey failed; no response or exception details were emitted.'); process.exitCode = 1; });
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
      root = await realpath(await mkdtemp(join(tmpdir(), 'scriv-peer-signaling-')));
      for (const name of ['home', 'tmp', 'state']) await mkdir(join(root, name), { mode: 0o700 });
      capture = process.env.SCRIV_SERVICE_COVERAGE_DIR
        ? await (await import(pathToFileURL(join(cloud, 'tests-e2e/capture-generation-coverage.mjs')).href))
          .prepareServiceCapture(process.env.SCRIV_SERVICE_COVERAGE_DIR, process.env.SCRIV_TRACER_CLI, { journeyPath: 'cloud/tests-e2e/peer-signaling-journey.mjs' }) : null;
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
      timer = setTimeout(() => killOwned('SIGKILL'), 150_000);
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
      bindings: { PUBLIC_URL: 'http://127.0.0.1', ENVIRONMENT: 'test', ...(capture?.options.bindings ?? {}) },
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
    // Fixture provisioning only, before HTTP: ephemeral identities, hashed sessions
    // and a synthetic paid team. This does not test provider login or billing.
    const now = Date.now(), teamId = randomUUID(), projectId = randomUUID();
    const actors = {};
    for (const role of ['owner', 'member', 'viewer', 'outsider']) {
      actors[role] = { id: randomUUID(), sessionId: randomUUID(), token: randomBytes(32).toString('base64url') };
      await db.prepare('INSERT INTO users(id,github_id,name,created_at) VALUES(?,?,?,?)').bind(actors[role].id, `email:${actors[role].id}`, `Synthetic ${role}`, now).run();
    }
    actors.retired = { id: actors.member.id, sessionId: randomUUID(), token: randomBytes(32).toString('base64url') };
    actors.expired = { id: actors.member.id, sessionId: randomUUID(), token: randomBytes(32).toString('base64url') };
    for (const [role, actor] of Object.entries(actors)) {
      await db.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at) VALUES(?,?,?,?,?,?)').bind(createHash('sha256').update(actor.token).digest('hex'), actor.sessionId, actor.id, 'Synthetic signaling device', now - 3600000, role === 'expired' ? now - 1000 : now + 3600000).run();
    }
    await db.prepare('INSERT INTO teams(id,name,owner_id,created_at,subscription_status,paid_until) VALUES(?,?,?,?,?,?)').bind(teamId, 'Synthetic signaling team', actors.owner.id, now, 'active', now + 3600000).run();
    for (const role of ['owner', 'member', 'viewer']) await db.prepare('INSERT INTO team_members(team_id,user_id,role,joined_at) VALUES(?,?,?,?)').bind(teamId, actors[role].id, role, now).run();
    const bucket = await mf.getR2Bucket('ASSETS', 'scriv');
    assert.deepEqual((await bucket.list()).objects, []);
    // All setup above is fixture provisioning, never production handler invocation.
    // Runtime pin loading is replaced with the explicitly approved published pins.
    const runtimePath = process.env.SCRIV_TRACER_RUNTIME;
    if (!runtimePath || !isAbsolute(runtimePath) || await realpath(runtimePath) !== runtimePath) throw new Error('Trusted local SCRIV_TRACER_RUNTIME is required');
    if (runtimePath !== join(dirname(runtimePath), 'scenario-runtime.mjs')) throw new Error('Invalid local runtime path');
    const modulePins = {
      "scenario-runtime.mjs": "b5f634d2d9318f216b044104f40636187ea6808f62ba78b64082ef5f6a2f829d",
      "scenarios.mjs": "1c2fce69d317e4397b39789f351b8700613c2289f5c50d900b61ae2e1822acee",
      "tracer.mjs": "97ab1e28255ee4b6a702ea9732b05c0532abd8179189ee3b02a7c09aa71b8eb6",
      "catalog.mjs": "a084193be6c6bdaf95c94b0df36545182eb3cf47e976abe268f811b7f5a1a1c1",
      "proposals.mjs": "8775d1938f43c707191636462f9897bd625935912f5ba6770282604eb7fedb1f"
};
    for (const [name, digest] of Object.entries(modulePins)) {
      const path = join(dirname(runtimePath), name);
      if (await realpath(path) !== path || createHash('sha256').update(await readFile(path)).digest('hex') !== digest) throw new Error('Untrusted local runtime module');
    }
    const { createScenarioRun } = await import(pathToFileURL(runtimePath).href);
    const catalog = JSON.parse(await readFile(join(cloud, '../docs/testing/peer-signaling-steps.json'), 'utf8'));
    const bundleSha256 = createHash('sha256').update(capture ? capture.options.script : await readFile(bundle)).digest('hex');
    const run = createScenarioRun({ catalog, scenarioId: 'peer-signaling-service', runId: randomUUID(), context: { build: bundleSha256, platform: process.platform, inputRoute: 'Scriv CLI loopback HTTP and WebSocket' } });
    const route = suffix => `/v1/projects/${projectId}/${suffix}`;
    const sockets = [];
    let websocketMessages = 0;
    async function request(path, { role = 'owner', method = 'GET', body, encoded } = {}) {
      const base = await mf.ready;
      assert.equal(base.hostname, '127.0.0.1'); assert.equal(base.protocol, 'http:'); assert(Number(base.port) > 0);
      const url = new URL(path, base); assert.equal(url.origin, base.origin);
      const text = encoded ?? (body === undefined ? undefined : JSON.stringify(body));
      assert(requests++ < 160); assert(Buffer.byteLength(text ?? '') <= 131072);
      if (capture) coverageActions.push(`${method} ${url.pathname.replace(/[0-9a-f]{8}-[0-9a-f-]{27}/gi, ':id')}`);
      const response = await fetch(url, { method, headers: { authorization: `Bearer ${actors[role].token}`, ...(text ? { 'content-type': 'application/json' } : {}) }, body: text, redirect: 'error', signal: AbortSignal.timeout(5000) });
      assert.equal(response.headers.get('cache-control'), 'no-store'); assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
      const parts = []; let size = 0;
      for await (const part of response.body) { size += part.length; assert(size <= 262144, 'Response bound'); parts.push(part); }
      return { status: response.status, data: JSON.parse(Buffer.concat(parts).toString('utf8')) };
    }
    const post = (body, role = 'owner') => ({ method: 'POST', body, role });
    const signal = (to, signalType = 'offer', payload = { marker: 'synthetic-offer' }) => ({ toDeviceId: actors[to].sessionId, signalType, payload });
    async function openSocket(role) {
      const { default: WebSocket } = await import('ws');
      const base = await mf.ready, url = new URL(route('socket'), base); url.protocol = 'ws:';
      assert.equal(url.hostname, '127.0.0.1');
      if (capture) coverageActions.push('WebSocket connect /v1/projects/:id/socket');
      const ws = new WebSocket(url, { headers: { authorization: `Bearer ${actors[role].token}` }, handshakeTimeout: 5000, maxPayload: 262144 });
      const entry = { ws, messages: [], errors: 0, closed: null }; sockets.push(entry);
      ws.on('message', data => { assert(data.length <= 262144); entry.messages.push(JSON.parse(data.toString('utf8'))); assert(entry.messages.length < 200); websocketMessages++; });
      ws.on('error', () => { entry.errors++; });
      ws.on('close', code => { entry.closed = code; });
      await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', () => reject(new Error('Local WebSocket connection failed'))); });
      await waitFor(() => entry.messages.some(value => value.type === 'hello'));
      return entry;
    }
    async function waitFor(predicate, timeout = 5000) {
      const end = Date.now() + timeout;
      while (!predicate()) { assert(Date.now() < end, 'Bounded observable event wait expired'); await new Promise(resolve => setTimeout(resolve, 10)); }
    }
    const signals = socket => socket.messages.filter(value => value.type === 'signal');
    const socketErrors = socket => socket.messages.filter(value => value.type === 'error');
    const sendSocket = async (socket, value, binary = false) => new Promise((resolve, reject) => socket.ws.send(binary ? Buffer.from(JSON.stringify(value)) : JSON.stringify(value), error => error ? reject(new Error('Local WebSocket send failed')) : resolve()));
    let result, inbox, third, forged, ownerSocket, memberSocket, viewerSocket, firstSignal, expiryAt, firstExpiryAt, preExpiryObservedAt, baseline, signalInboxBaseline;
    try {
      if (capture) { await capture.begin(await mf.ready); captureStarted = true; }
      await run.step('create-project', async step => {
        result = await step.action('POST /v1/projects synthetic signaling team project', () => request('/v1/projects', post({ id: projectId, title: 'Synthetic peer exchange', teamId })));
        await step.expect('observed', () => { assert.equal(result.status, 201); assert.equal(result.data.project.ownerId, actors.owner.id); });
      });
      await run.step('connect-three-devices', async step => {
        [ownerSocket, memberSocket, viewerSocket] = await step.action('Connect three authenticated loopback project WebSockets', () => Promise.all(['owner', 'member', 'viewer'].map(openSocket)));
        await step.expect('observed', () => { for (const [i, role] of ['owner', 'member', 'viewer'].entries()) { const hello = [ownerSocket, memberSocket, viewerSocket][i].messages.find(value => value.type === 'hello'); assert.equal(hello.projectId, projectId); assert.equal(hello.deviceId, actors[role].sessionId); assert.equal(hello.headSeq, 0); } });
      });
      await run.step('deliver-offer', async step => {
        result = await step.action('POST offer from A to B with forged sender fields', () => request(route('signals'), post({ ...signal('member'), fromDeviceId: actors.viewer.sessionId, fromUserId: actors.viewer.id })));
        await step.action('Wait for B signal and synchronize A and C sockets with ping watermarks', async () => { await waitFor(() => signals(memberSocket).length === 1); await Promise.all([ownerSocket, viewerSocket].map(s => sendSocket(s, { type: 'ping' }))); await waitFor(() => [ownerSocket, viewerSocket].every(s => s.messages.some(m => m.type === 'watermark'))); });
        [inbox, third, forged] = await step.action('Read B inbox, C own inbox and C forged B inbox', () => Promise.all([request(route('signals'), { role: 'member' }), request(route('signals'), { role: 'viewer' }), request(route(`signals?deviceId=${actors.member.sessionId}`), { role: 'viewer' })]));
        await step.expect('observed', () => { assert.equal(result.status, 200); assert.deepEqual(result.data, { ok: true }); assert.equal(inbox.status, 200); assert.equal(inbox.data.deviceId, actors.member.sessionId); assert.equal(inbox.data.signals.length, 1); firstSignal = inbox.data.signals[0]; assert.equal(firstSignal.type, 'offer'); assert.equal(firstSignal.fromDeviceId, actors.owner.sessionId); assert.equal(firstSignal.fromUserId, actors.owner.id); assert.deepEqual(firstSignal.payload, { marker: 'synthetic-offer' }); assert.deepEqual(signals(memberSocket)[0], { type: 'signal', fromDeviceId: actors.owner.sessionId, fromUserId: actors.owner.id, signalType: 'offer', payload: firstSignal.payload }); assert.deepEqual(signals(ownerSocket), []); assert.deepEqual(signals(viewerSocket), []); assert.equal(third.status, 200); assert.deepEqual(third.data.signals, []); assert.equal(forged.status, 403); assert.equal(forged.data.error.code, 'not_allowed'); expiryAt = firstSignal.at + 120000; });
      });
      await run.step('answer-through-websocket', async step => {
        await step.action('Send binary JSON answer from B to A over WebSocket', () => sendSocket(memberSocket, { type: 'signal', ...signal('owner', 'answer', { marker: 'synthetic-answer' }) }, true));
        await step.action('Wait for A answer and synchronize B and C watermark barriers', async () => { await waitFor(() => signals(ownerSocket).length === 1); await Promise.all([memberSocket, viewerSocket].map(async socket => { const n = socket.messages.filter(m => m.type === 'watermark').length; await sendSocket(socket, { type: 'ping' }); await waitFor(() => socket.messages.filter(m => m.type === 'watermark').length > n); })); });
        result = await step.action('Read A durable signaling inbox', () => request(route('signals')));
        await step.expect('observed', () => { assert.equal(result.status, 200); assert.equal(result.data.deviceId, actors.owner.sessionId); assert.equal(result.data.signals.length, 1); assert.equal(result.data.signals[0].type, 'answer'); assert.equal(result.data.signals[0].fromDeviceId, actors.member.sessionId); assert.equal(result.data.signals[0].fromUserId, actors.member.id); assert.deepEqual(result.data.signals[0].payload, { marker: 'synthetic-answer' }); assert.deepEqual(signals(ownerSocket), [{ type: 'signal', fromDeviceId: actors.member.sessionId, fromUserId: actors.member.id, signalType: 'answer', payload: { marker: 'synthetic-answer' } }]); assert.deepEqual(signals(memberSocket), [{ type: 'signal', fromDeviceId: actors.owner.sessionId, fromUserId: actors.owner.id, signalType: 'offer', payload: { marker: 'synthetic-offer' } }]); assert.deepEqual(signals(viewerSocket), []); });
      });
      const boundedPayload = { marker: '' };
      boundedPayload.marker = 'x'.repeat(50000 - Buffer.byteLength(JSON.stringify({ marker: 'éé' }))) + 'éé';
      assert.equal(Buffer.byteLength(JSON.stringify(boundedPayload)), 50000);
      await run.step('accept-bounded-payload', async step => {
        result = await step.action('POST exactly 50000 UTF-8 payload bytes as ICE', () => request(route('signals'), post(signal('member', 'ice', boundedPayload))));
        inbox = await step.action('Read B inbox after initial offer cursor', () => request(route(`signals?after=${firstSignal.id}`), { role: 'member' }));
        third = await step.action('Read complete B inbox as rejection baseline', () => request(route('signals'), { role: 'member' }));
        await step.expect('observed', () => { assert.equal(result.status, 200); assert.equal(inbox.status, 200); assert.equal(inbox.data.signals.length, 1); assert.equal(inbox.data.signals[0].type, 'ice'); assert.deepEqual(inbox.data.signals[0].payload, boundedPayload); assert(inbox.data.signals[0].id > firstSignal.id); assert.equal(third.status, 200); assert.deepEqual(third.data, { deviceId: actors.member.sessionId, signals: [firstSignal, inbox.data.signals[0]] }); signalInboxBaseline = structuredClone(third.data); });
      });
      const rejectionCases = [
        { id: 'reject-large-payload', body: signal('member', 'offer', { marker: boundedPayload.marker + 'x' }), status: 413, code: 'signal_too_large' },
        { id: 'reject-invalid-signal-type', body: signal('member', 'unrecognized'), status: 400, code: 'invalid_signal' },
        { id: 'reject-nonobject-payload', body: signal('member', 'ice', []), status: 400, code: 'invalid_field' },
        { id: 'reject-invalid-recipient', body: { ...signal('member'), toDeviceId: '../forged' }, status: 400, code: 'invalid_id' },
        { id: 'reject-expired-recipient', body: signal('expired'), status: 404, code: 'peer_unavailable' },
        { id: 'reject-outsider-recipient', body: signal('outsider'), status: 404, code: 'not_found' },
        { id: 'reject-oversized-envelope', encoded: JSON.stringify(signal('member')) + ' '.repeat(65537 - Buffer.byteLength(JSON.stringify(signal('member')))), status: 413, code: 'body_too_large' },
      ];
      for (const variant of rejectionCases) await run.step(variant.id, async step => {
        result = await step.action(`POST signaling variant ${variant.id}`, () => request(route('signals'), { method: 'POST', body: variant.body, encoded: variant.encoded }));
        inbox = await step.action('Read B inbox to verify rejected signal was not persisted', () => request(route('signals'), { role: 'member' }));
        await step.expect('observed', () => { assert.equal(result.status, variant.status); assert.equal(result.data.error.code, variant.code); assert.equal(inbox.status, 200); assert.deepEqual(inbox.data, signalInboxBaseline); });
      });
      await run.step('reject-websocket-signal-type', async step => {
        await step.action('Send unsupported signalType over authenticated WebSocket', async () => { await sendSocket(ownerSocket, { type: 'signal', ...signal('member', 'unrecognized') }); await waitFor(() => socketErrors(ownerSocket).length === 1); });
        inbox = await step.action('Read B inbox after rejected WebSocket signal', () => request(route('signals'), { role: 'member' }));
        await step.expect('observed', () => { assert.equal(socketErrors(ownerSocket)[0].error.code, 'invalid_signal'); assert.equal(ownerSocket.closed, null); assert.equal(inbox.status, 200); assert.deepEqual(inbox.data, signalInboxBaseline); });
      });
      await run.step('exchange-asset-notifications', async step => {
        result = await step.action('POST asset-request and asset-available signals from A to B', () => Promise.all(['asset-request', 'asset-available'].map(type => request(route('signals'), post(signal('member', type, { hash: 'a'.repeat(64) }))))));
        inbox = await step.action('Read B inbox with explicit authenticated deviceId', () => request(route(`signals?deviceId=${actors.member.sessionId}`), { role: 'member' }));
        await step.expect('observed', () => { assert(result.every(r => r.status === 200)); assert.equal(inbox.status, 200); assert.equal(inbox.data.signals.length, 4); assert.deepEqual(inbox.data.signals.slice(2).map(s => s.type).sort(), ['asset-available', 'asset-request']); assert(inbox.data.signals.slice(2).every(s => s.payload.hash === 'a'.repeat(64))); });
      });
      await run.step('inspect-session-inventory', async step => {
        result = await step.action('GET B current authenticated session inventory before revocation', () => request('/auth/sessions', { role: 'member' }));
        await step.expect('observed', () => { assert.equal(result.status, 200); assert.equal(result.data.currentSessionId, actors.member.sessionId); assert.deepEqual(result.data.sessions.map(session => session.id).sort(), [actors.member.sessionId, actors.retired.sessionId].sort()); });
      });
      await run.step('revoke-secondary-session', async step => {
        result = await step.action('DELETE B secondary session through public auth route', () => request(`/auth/sessions/${actors.retired.sessionId}`, { role: 'member', method: 'DELETE' }));
        [inbox, third, forged] = await step.action('Attempt revoked sender, revoked recipient and expired sender access', () => Promise.all([request(route('signals'), { role: 'retired' }), request(route('signals'), post(signal('retired'))), request(route('signals'), { role: 'expired' })]));
        await step.expect('observed', () => { assert.equal(result.status, 200); assert.deepEqual(result.data, { ok: true }); assert.equal(inbox.status, 401); assert.equal(inbox.data.error.code, 'session_expired'); assert.equal(third.status, 404); assert.equal(third.data.error.code, 'peer_unavailable'); assert.equal(forged.status, 401); assert.equal(forged.data.error.code, 'session_expired'); });
      });
      console.log('PASS peer signaling checkpoint: intended HTTP/WebSocket recipients, third-device privacy, binary answer, exact payload bounds, invalid inputs and session guards. Continuing content validation and real TTL observation.');
      const sceneId = randomUUID(), characterId = randomUUID(), entryId = randomUUID(), imageId = randomUUID(), cueId = randomUUID();
      const model = {
        scene: { id: sceneId, title: 'Peer review scene', order: 0 },
        character: { id: characterId, name: 'Alex', aliases: ['A'], biography: '', appearance: '', color: '' },
        entry: { id: entryId, sceneId, order: 0, kind: 'dialogue', text: 'Alex 👩‍🚀', ownedDurationMs: 1000, coverageDurationMs: 1000, color: '', characterId, characterLinks: [{ id: randomUUID(), location: 0, length: 4, text: 'Alex', isConfirmed: true, characterId }], words: [{ id: randomUUID(), text: 'Alex', startMs: 0, endMs: 400, timingSource: 'authored' }, { id: randomUUID(), text: '👩‍🚀', startMs: 400, endMs: 1000, timingSource: 'authored' }] },
        image: { id: imageId, version: 1, fileName: 'synthetic.png', sha256: 'a'.repeat(64), mimeType: 'image/png', byteCount: 32, characterIds: [characterId], prompt: '', generationPrompt: 'Synthetic prompt', createdAt: 0 },
        cue: { id: cueId, sceneId, startMs: 0, endMs: 1000, label: '', prompt: '', imageId, startAnchor: { entryId, offsetMs: 0 }, authoredDurationMs: 1000 },
      };
      const operation = (kind, data) => ({ op: 'put', id: data.id, kind, expectedVersion: 0, data });
      const command = (operations, timing = 0) => ({ commandId: randomUUID(), sessionId: actors.owner.sessionId, epoch: 1, expectedTimingVersion: timing, label: 'Synthetic public validation', operations });
      await run.step('commit-five-item-model', async step => {
        result = await step.action('POST fresh command with valid scene character dialogue image and anchored cue', () => request(route('commands'), post(command(Object.entries(model).map(([kind, data]) => operation(kind, data))))));
        inbox = await step.action('GET viewer snapshot after valid model command', () => request(route('snapshot'), { role: 'viewer' }));
        await step.expect('observed', () => { assert.equal(result.status, 200); assert.equal(result.data.seq, 1); assert.equal(result.data.timingVersion, 1); assert.equal(inbox.status, 200); assert.equal(inbox.data.headSeq, 1); assert.equal(inbox.data.timingVersion, 1); assert.equal(inbox.data.items.length, 5); for (const [kind, data] of Object.entries(model)) { const saved = inbox.data.items.find(item => item.id === data.id); assert.equal(saved.kind, kind); assert.deepEqual(saved.data, data); assert.equal(saved.version, 1); } baseline = inbox.data; });
      });
      const changed = (kind, patch) => ({ ...structuredClone(model[kind]), id: randomUUID(), ...patch });
      const malformedItems = [
        { id: 'reject-item-identity', kind: 'scene', data: changed('scene', {}), opId: randomUUID(), status: 400, code: 'item_identity' },
        { id: 'reject-item-byte-limit', kind: 'scene', data: changed('scene', { extra: 'é'.repeat(32769) }), status: 413, code: 'item_too_large' },
        { id: 'reject-scene-order', kind: 'scene', data: changed('scene', { order: '0' }), status: 400, code: 'invalid_order' },
        { id: 'reject-entry-word-order', kind: 'entry', data: changed('entry', { words: [{ id: randomUUID(), text: 'Wrong', startMs: 0, endMs: 400 }, { id: randomUUID(), text: '👩‍🚀', startMs: 400, endMs: 1000 }] }), status: 400, code: 'word_order' },
        { id: 'reject-entry-surrogate-link', kind: 'entry', data: changed('entry', { characterLinks: [{ id: randomUUID(), location: 5, length: 1, text: '\ud83d', isConfirmed: true, characterId }] }), status: 400, code: 'invalid_character_links' },
        { id: 'reject-unconfirmed-link', kind: 'entry', data: changed('entry', { characterLinks: [{ id: randomUUID(), location: 0, length: 4, text: 'Alex', isConfirmed: false }] }), status: 400, code: 'invalid_character_links' },
        { id: 'reject-direction-words', kind: 'entry', data: changed('entry', { kind: 'direction' }), status: 400, code: 'direction_timing' },
        { id: 'reject-word-timing-source', kind: 'entry', data: changed('entry', { words: model.entry.words.map(w => ({ ...w, timingSource: 'predicted' })) }), status: 400, code: 'invalid_word_timing_source' },
        { id: 'reject-empty-character-name', kind: 'character', data: changed('character', { name: '\u0085\u200b' }), status: 400, code: 'invalid_name' },
        { id: 'reject-character-alias-bound', kind: 'character', data: changed('character', { aliases: Array(101).fill('A') }), status: 400, code: 'invalid_field' },
        { id: 'reject-image-filename', kind: 'image', data: changed('image', { fileName: '../synthetic.png' }), status: 400, code: 'invalid_filename' },
        { id: 'reject-image-digest', kind: 'image', data: changed('image', { sha256: 'g'.repeat(64) }), status: 400, code: 'invalid_hash' },
        { id: 'reject-image-media', kind: 'image', data: changed('image', { mimeType: 'image/gif' }), status: 400, code: 'invalid_media' },
        { id: 'reject-image-duplicate-tags', kind: 'image', data: changed('image', { characterIds: [characterId, characterId] }), status: 400, code: 'duplicate_character' },
        { id: 'reject-unpaired-cue-anchor', kind: 'cue', data: changed('cue', { authoredDurationMs: null }), status: 400, code: 'invalid_cue_anchor' },
        { id: 'reject-cue-offset-bound', kind: 'cue', data: changed('cue', { startAnchor: { entryId, offsetMs: 3600000 } }), status: 400, code: 'invalid_field' },
        { id: 'reject-missing-scene-reference', kind: 'entry', data: changed('entry', { sceneId: randomUUID() }), status: 400, code: 'invalid_reference' },
      ];
      for (const variant of malformedItems) await run.step(variant.id, async step => {
        result = await step.action(`POST fresh public item command ${variant.id}`, () => request(route('commands'), post(command([{ ...operation(variant.kind, variant.data), ...(variant.opId ? { id: variant.opId } : {}) }], 1))));
        inbox = await step.action('GET viewer snapshot after rejected item command', () => request(route('snapshot'), { role: 'viewer' }));
        await step.expect('observed', () => { assert.equal(result.status, variant.status); assert.equal(result.data.error.code, variant.code); assert.equal(inbox.status, 200); assert.equal(inbox.data.headSeq, baseline.headSeq); assert.equal(inbox.data.timingVersion, baseline.timingVersion); assert.deepEqual(inbox.data.items, baseline.items); });
      });
      // Independently spelled Unicode fixtures. No import/call of scriptWords or native code.
      const unicodeCases = [
        { id: 'accept-nel-words', text: 'Alex\u0085arrives', words: ['Alex', 'arrives'] },
        { id: 'accept-bom-word', text: 'Alex\ufeffarrives', words: ['Alex\ufeffarrives'] },
        { id: 'accept-combining-whitespace', text: 'Alex \u0301arrives', words: ['Alex', 'arrives'] },
        { id: 'accept-emoji-word', text: '👩‍🚀 arrives', words: ['👩‍🚀', 'arrives'] },
        { id: 'accept-empty-dialogue', text: '', words: [] },
        { id: 'accept-whitespace-dialogue', text: '\u0085 \t\n', words: [] },
      ];
      let timing = 1;
      for (const [index, variant] of unicodeCases.entries()) await run.step(variant.id, async step => {
        const data = changed('entry', { order: index + 1, text: variant.text, characterLinks: [], words: variant.words.map((text, i) => ({ id: randomUUID(), text, startMs: i * 400, endMs: (i + 1) * 400, timingSource: 'authored' })) });
        result = await step.action(`POST fresh dialogue command ${variant.id}`, () => request(route('commands'), post(command([operation('entry', data)], timing))));
        inbox = await step.action('GET viewer snapshot for exact saved Unicode dialogue', () => request(route('snapshot'), { role: 'viewer' }));
        await step.expect('observed', () => { assert.equal(result.status, 200); assert.equal(result.data.timingVersion, timing + 1); assert.equal(inbox.status, 200); assert.equal(inbox.data.headSeq, index + 2); assert.deepEqual(inbox.data.items.find(item => item.id === data.id).data, data); timing++; });
      });
      await run.step('inspect-expired-signals', async step => {
        inbox = await step.action('Read B pre-expiry inbox and wait past actual stored signal TTL', async () => { const current = await request(route('signals'), { role: 'member' }); assert.equal(current.status, 200); assert.equal(current.data.signals.length, 4); firstExpiryAt = Math.min(...current.data.signals.map(s => s.at)) + 120000; expiryAt = Math.max(...current.data.signals.map(s => s.at)) + 120000; preExpiryObservedAt = Date.now(); assert(preExpiryObservedAt < firstExpiryAt); await new Promise(resolve => setTimeout(resolve, Math.max(0, expiryAt + 75 - Date.now()))); return current; });
        result = await step.action('Read B inbox after actual 120-second expiry without clock manipulation', () => request(route('signals'), { role: 'member' }));
        await step.expect('observed', () => { assert(preExpiryObservedAt < firstExpiryAt); assert(Date.now() > expiryAt); assert.equal(inbox.data.signals.length, 4); assert.equal(result.status, 200); assert.equal(result.data.deviceId, actors.member.sessionId); assert.deepEqual(result.data.signals, []); });
      });
      await run.step('revoke-live-recipient', async step => {
        result = await step.action('POST B logout then wait for its authenticated WebSocket close', async () => { const response = await request('/auth/logout', post({}, 'member')); await waitFor(() => memberSocket.closed !== null); return response; });
        [inbox, third] = await step.action('Attempt B inbox access and A send to revoked B', () => Promise.all([request(route('signals'), { role: 'member' }), request(route('signals'), post(signal('member')))]));
        await step.expect('observed', () => { assert.equal(result.status, 200); assert.equal(memberSocket.closed, 4001); assert.equal(inbox.status, 401); assert.equal(inbox.data.error.code, 'session_expired'); assert.equal(third.status, 404); assert.equal(third.data.error.code, 'peer_unavailable'); });
      });
      await run.step('verify-isolation', async step => {
        result = await step.action('Read final owner snapshot and isolated R2 object inventory', async () => ({ snapshot: await request(route('snapshot')), objects: (await bucket.list()).objects }));
        await step.expect('observed', () => { assert.equal(result.snapshot.status, 200); assert.equal(result.snapshot.data.headSeq, 7); assert.equal(result.snapshot.data.items.length, 11); assert.deepEqual(result.objects, []); assert.equal(outboundAttempts, 0); assert(sockets.every(s => s.errors === 0)); assert.deepEqual(signals(viewerSocket), []); });
      });
      await run.step('handle-oversize-transport', async step => {
        const observedPresence = messages => messages.filter(message => message.type === 'presence');
        const connected = (presence, id) => presence.peers.some(peer => peer.connectionId === id);
        const { failing, id } = await step.action('Connect a fresh viewer and observe its presence on the owner socket', async () => {
          const next = ownerSocket.messages.length;
          const failing = await openSocket('viewer');
          const id = failing.messages.find(message => message.type === 'hello').connectionId;
          assert.ok(id);
          await waitFor(() => observedPresence(ownerSocket.messages.slice(next)).some(presence => connected(presence, id)));
          return { failing, id };
        });
        await step.action('Cross the local Worker message size limit once', async () => {
          if (capture) coverageActions.push('WebSocket oversize transport message /v1/projects/:id/socket');
          // One owned loopback message crosses the transport's 32 MiB boundary.
          assert.equal(failing.ws.readyState, failing.ws.OPEN);
          await new Promise((resolve, reject) => {
            failing.ws.send(Buffer.alloc(32 * 1024 * 1024 + 1), { compress: false }, error => {
              // The receiver can reject the message before the last write completes.
              if (error && error.code !== 'EPIPE') reject(new Error('Unexpected local WebSocket send failure'));
              else resolve();
            });
          });
        });
        const { presence, reply } = await step.action('Reconnect the viewer and ping the healthy owner socket', async () => {
          const reopened = await openSocket('viewer');
          await waitFor(() => observedPresence(reopened.messages).length > 0);
          const presence = observedPresence(reopened.messages)[0];
          const next = ownerSocket.messages.length;
          await sendSocket(ownerSocket, { type: 'ping' });
          await waitFor(() => ownerSocket.messages.slice(next).some(message => message.type === 'watermark'));
          return { presence, reply: ownerSocket.messages.slice(next).find(message => message.type === 'watermark') };
        });
        await step.expect('observed', () => {
          assert.equal(connected(presence, id), false);
          assert.equal(reply.headSeq, 7);
          assert.equal(ownerSocket.closed, null);
          assert.equal(outboundAttempts, 0);
        });
      });
    } finally {
      const report = run.finish();
      console.log(JSON.stringify({ result: report.status === 'passed' ? 'PASS' : 'FAIL', journey: 'peer-signaling', requests, websocketMessages, outboundAttempts, bundleSha256, nativeScenarios: 0, loginFlowTested: false, runtime: report }));
      for (const socket of sockets) socket.ws.terminate();
      assert.equal(report.status, 'passed', 'Every planned action and assertion must pass');
    }
  } finally {
    try {
      if (captureStarted) await capture.end(await mf.ready, requests, coverageActions);
    } finally { await mf.dispose(); }
  }
}
