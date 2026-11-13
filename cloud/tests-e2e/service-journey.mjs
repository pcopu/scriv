// Real HTTP service-process integration; not Catalyst/native application E2E.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, rm, readFile, readdir, copyFile, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
import { request as httpRequest } from 'node:http';
import { createHash } from 'node:crypto';

const here = await realpath(dirname(fileURLToPath(import.meta.url)));
// --cloud supports an outside-repository candidate without changing its sources.
const cloud = await realpath(process.argv[2] === '--owned-child' ? process.argv[4] :
  process.argv[2] === '--cloud' ? process.argv[3] : join(here, '..'));
const self = await realpath(fileURLToPath(import.meta.url));
if (process.argv[2] !== '--owned-child') {
  let root, capture, child, timer, journeyError, interrupted = false;
  const killOwned = signal => {
    if (child?.pid) {
      try { process.kill(-child.pid, signal); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    }
  };
  const interrupt = () => { interrupted = true; killOwned('SIGTERM'); };
  process.on('SIGINT', interrupt); process.on('SIGTERM', interrupt);
  try {
    try {
      root = await realpath(await mkdtemp(join(tmpdir(), 'scriv-service-')));
      for (const name of ['home', 'tmp', 'state']) await mkdir(join(root, name), { mode: 0o700 });
      capture = process.env.SCRIV_SERVICE_COVERAGE_DIR
        ? await (await import(pathToFileURL(join(cloud, 'tests-e2e/capture-generation-coverage.mjs')).href))
          .prepareServiceCapture(process.env.SCRIV_SERVICE_COVERAGE_DIR, process.env.SCRIV_TRACER_CLI, { journeyPath: 'cloud/tests-e2e/service-journey.mjs' }) : null;
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
    } catch (error) { journeyError = error; }
    finally {
      clearTimeout(timer); killOwned('SIGKILL');
      if (root) await rm(root, { recursive: true, force: true });
      console.log('Owned service process group and temporary state cleaned.');
    }
    assert.equal(interrupted, false, 'Cancelled before measurement import');
    if (capture) await capture.finish(() => interrupted);
    assert.equal(interrupted, false, 'Cancelled during measurement import; inspect preserved evidence');
    if (journeyError) throw journeyError;
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
  const captureModule = process.argv[5]
    ? await import(pathToFileURL(join(cloud, 'tests-e2e/capture-generation-coverage.mjs')).href) : null;
  const capture = captureModule ? await captureModule.loadServiceCapture(process.argv[5]) : null;
  const bundle = join(root, 'worker.mjs');
  await build({ entryPoints: [join(cloud, 'src/index.ts')], outfile: bundle,
    bundle: true, format: 'esm', platform: 'neutral', target: 'es2022',
    external: ['cloudflare:*'], logLevel: 'silent' });
  let outboundAttempts = 0;
  const denyOutbound = () => { outboundAttempts++; throw new Error('Unexpected outbound request denied'); };
  // The installed Miniflare 5 adapter translates this explicit, local-only config.
  const common = { unsafeInspectorProxy: false, compatibilityDate: '2026-10-29', modules: true, outboundService: denyOutbound };
  const config = mailBinding => convertV4MiniflareOptions({
    host: '127.0.0.1', port: 0, cf: false, telemetry: { enabled: false },
    unsafeLocalExplorer: false, unsafeObservability: false,
    unsafeEnableSharedStorage: false, logRequests: false, log: new Log(LogLevel.ERROR),
    resourcePersistencePath: join(root, 'state'), resourceTmpPath: join(root, 'tmp'),
    workers: [{ ...common, name: 'scriv', ...(capture ? { script: capture.options.script } : { scriptPath: bundle }),
      bindings: { PUBLIC_URL: 'http://127.0.0.1', ENVIRONMENT: 'test', EMAIL_FROM: 'no-delivery@example.invalid', ...(capture?.options.bindings ?? {}) },
      d1Databases: { DB: 'journey-db' }, r2Buckets: ['ASSETS'],
      durableObjects: { PROJECTS: { className: 'ProjectRoom', useSQLite: true }, BILLING: { className: 'BillingCoordinator', useSQLite: true } },
      ...(mailBinding ? { serviceBindings: { EMAIL: 'deny-mail' } } : {}),
    }, { ...common, name: 'deny-mail', script: `import { WorkerEntrypoint } from 'cloudflare:workers';
      let sends = 0;
      export default class extends WorkerEntrypoint {
        async send() { sends = Math.min(sends + 1, 26); throw new Error('Email delivery forbidden in this journey'); }
        async getSendCount() { return sends; }
      }` }],
  });
  const mf = new Miniflare(config(false));
  let requests = 0;
  let captureRequestStart = 0;
  let chunkedRequests = 0;
  const ordinaryRequests = () => requests;
  let serviceObserver;
  async function beginCapturePhase() {
    if (!capture) return;
    await capture.begin(await mf.ready);
    serviceObserver = captureModule.observeServiceRequests();
  }
  async function endCapturePhase() {
    if (!serviceObserver) return;
    const observer = serviceObserver;
    serviceObserver = undefined;
    observer.stop();
    if (observer.actions.length) await capture.end(await mf.ready, observer.actions.length, observer.actions);
  }
  try {
    const migrations = [];
    for (const name of (await readdir(join(cloud, 'migrations'))).filter(name => /^\d+_.+\.sql$/.test(name)).sort()) {
      migrations.push({ name, queries: unstable_splitSqlQuery(await readFile(join(cloud, 'migrations', name), 'utf8')) });
    }
    assert.deepEqual(migrations.map(m => m.name), ['0001_identity_teams.sql', '0002_generation_jobs.sql', '0003_email_auth.sql']);
    let db = await mf.getD1Database('DB', 'scriv');
    for (const migration of migrations) await db.batch(migration.queries.map(query => db.prepare(query)));
    await beginCapturePhase();
    async function chunkedResponse(url, options) {
      // node:http writes HTTP/1.1 chunk framing here, not fetch's auto-sized string.
      return new Promise((resolve, reject) => {
        serviceObserver?.record('POST', url);
        const outgoing = httpRequest(url, {
          method: 'POST', headers: { ...options.headers, 'transfer-encoding': 'chunked' },
          signal: AbortSignal.timeout(5000), agent: false,
        }, incoming => {
          const parts = []; let size = 0;
          incoming.on('error', reject);
          incoming.on('data', part => {
            size += part.length;
            if (size > 16384) incoming.destroy(new Error('Response body bound'));
            else parts.push(part);
          });
          incoming.on('end', () => resolve(new Response(Buffer.concat(parts), {
            status: incoming.statusCode, headers: incoming.headers,
          })));
        });
        outgoing.on('error', reject);
        assert.equal(outgoing.getHeader('content-length'), undefined);
        assert.equal(outgoing.getHeader('transfer-encoding'), 'chunked');
        const payload = Buffer.from(options.body);
        assert(payload.length === 4096 || payload.length === 4097);
        outgoing.flushHeaders();
        outgoing.write(payload.subarray(0, 2048));
        setImmediate(() => outgoing.end(payload.subarray(2048)));
        chunkedRequests++;
      });
    }
    async function request(path, status, code, options = {}, chunked = false) {
      const base = await mf.ready;
      assert.equal(base.hostname, '127.0.0.1'); assert.equal(base.protocol, 'http:');
      assert(Number(base.port) > 0);
      const url = new URL(path, base); assert.equal(url.origin, base.origin);
      assert(requests++ < 80); assert(Buffer.byteLength(options.body ?? '') < 8192);
      const response = chunked ? await chunkedResponse(url, options) :
        await fetch(url, { ...options, redirect: 'error', signal: AbortSignal.timeout(5000) });
      assert.equal(response.status, status, `${path} status`);
      const reader = response.body?.getReader(); let text = ''; let size = 0;
      if (reader) while (true) {
        const { done, value } = await reader.read(); if (done) break;
        size += value.length; assert(size <= 16384, 'Response body bound');
        text += new TextDecoder().decode(value);
      }
      if (status === 204) { assert.equal(text, ''); assert.equal(response.headers.get('allow'), 'GET,POST,PUT,PATCH,DELETE,OPTIONS'); return; }
      assert.equal(response.headers.get('cache-control'), 'no-store');
      assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
      assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
      assert.equal(response.headers.get('content-type'), 'application/json; charset=utf-8');
      const data = JSON.parse(text);
      if (code) assert.equal(data.error?.code, code, `${path} error code`);
      else assert.deepEqual(data, { ok: true, service: 'scriv', version: '0.1.0' });
    }
    async function assertNoEmailSends() {
      // Fixture RPC observation only: never calls production exports or sends mail.
      const fixture = await mf.getWorker('deny-mail');
      assert.equal(await fixture.getSendCount(), 0, 'EMAIL.send must never be invoked');
    }
    const post = payload => ({ method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload) });
    await request('/health', 200);
    await request('/health', 404, 'not_found', { method: 'POST' });
    await request('/missing', 404, 'not_found');
    await request('/auth/email/request', 404, 'not_found');
    await request('/v1/me', 401, 'sign_in_required');
    await request('/v1/projects/synthetic/snapshot', 401, 'sign_in_required');
    await request('/v1/me', 204, undefined, { method: 'OPTIONS' });
    await request('/auth/github/start', 503, 'auth_not_configured');
    await request('/auth/email/request', 503, 'auth_not_configured', post({}));
    await request('/auth/email/request', 415, 'unsupported_media_type', { method: 'POST', headers: { 'content-type': 'text/plain' }, body: '{}' });
    await request('/auth/email/request', 403, 'invalid_origin', { ...post({}), headers: { 'content-type': 'application/json', origin: 'https://other.invalid' } });
    // Frozen email-auth.test.ts::0018: sender exists, EMAIL absent, valid body.
    await request('/auth/email/request', 503, 'auth_not_configured', post({
      email: 'alex@example.com', codeChallenge: createHash('sha256').update('v'.repeat(50)).digest('base64url'),
    }));
    await assertNoEmailSends();
    if (serviceObserver) assert.equal(serviceObserver.actions.length, ordinaryRequests() - captureRequestStart, 'Every ordinary request has one ordered action');
    await endCapturePhase();
    await mf.setOptions(config(true));
    captureRequestStart = ordinaryRequests();
    await beginCapturePhase();
    db = await mf.getD1Database('DB', 'scriv');
    // Same frozen test: EMAIL is configured, but oversized input must never send.
    await request('/auth/email/request', 413, 'body_too_large', post({ email: 'x'.repeat(5000) }));
    await assertNoEmailSends();
    await request('/auth/email/request', 400, 'invalid_json', { ...post({}), body: '{' });
    await request('/auth/email/request', 400, 'invalid_email', post({ email: 'not-an-email', codeChallenge: 'A'.repeat(43) }));
    await request('/auth/email/request', 400, 'invalid_challenge', post({ email: 'synthetic@example.invalid', codeChallenge: '!'.repeat(43) }));
    await request('/auth/email/verify', 400, 'invalid_field', post({}));
    await request('/auth/email/verify', 400, 'invalid_verifier', post({ challengeId: 'A'.repeat(43), code: '000000', codeVerifier: '!'.repeat(43) }));
    // Exercise bytes()'s streaming branch before exhausting any client quota.
    for (const [length, status, code] of [[4096, 400, 'invalid_field'], [4097, 413, 'body_too_large']]) {
      const payload = '{}' + ' '.repeat(length - 2); // Valid JSON with no email field.
      assert.equal(Buffer.byteLength(payload), length);
      await request('/auth/email/request', status, code, { ...post({}), body: payload }, true);
    }
    assert.equal(chunkedRequests, 2);
    await assertNoEmailSends();
    if (serviceObserver) assert.equal(serviceObserver.actions.length, ordinaryRequests() - captureRequestStart, 'Every ordinary request has one ordered action');
    await endCapturePhase();
    await mf.setOptions(config(false));
    captureRequestStart = ordinaryRequests();
    await beginCapturePhase();
    db = await mf.getD1Database('DB', 'scriv');
    // Different synthetic clients isolate quotas without seeding or resetting D1.
    const windowMs = 600_000;
    const started = Date.now(), bucket = Math.floor(started / windowMs);
    assert((bucket + 1) * windowMs - started >= 60_000,
      'Quota witness too close to real window boundary; rerun later, no result claimed');
    const quotaEvidence = [];
    for (const [action, ip, limit, status, code] of [
      ['request', '192.0.2.70', 20, 503, 'auth_not_configured'],
      ['verify', '192.0.2.71', 30, 400, 'invalid_field'],
    ]) {
      const prefix = `email-${action}-ip:${createHash('sha256').update(ip).digest('hex')}:`;
      const before = await db.prepare('SELECT COUNT(*) AS n FROM security_limits WHERE substr(key,1,?)=?').bind(prefix.length, prefix).first();
      assert.equal(before.n, 0, `${action} synthetic client must have no prior quota state`);
      const options = { ...post({}), headers: { ...post({}).headers, 'cf-connecting-ip': ip } };
      for (let i = 0; i < limit; i++) await request(`/auth/email/${action}`, status, code, options);
      const count = async () => (await db.prepare('SELECT count FROM security_limits WHERE key=?').bind(`${prefix}${bucket}`).first())?.count;
      assert.equal(await count(), limit, `${action} actual stored allowed-attempt count`);
      await request(`/auth/email/${action}`, 429, 'rate_limited', options);
      assert.equal(await count(), limit + 1, `${action} actual stored rejected-attempt count`);
      const after = await db.prepare('SELECT COUNT(*) AS n FROM security_limits WHERE substr(key,1,?)=?').bind(prefix.length, prefix).first();
      assert.equal(after.n, 1, `${action} must not span or reset quota windows`);
      assert.equal(Math.floor(Date.now() / windowMs), bucket, 'Real quota window rolled over; no result claimed');
      quotaEvidence.push(`${action}:0→${limit}→${limit + 1}`);
    }
    const finished = Date.now();
    assert.equal(Math.floor(finished / windowMs), bucket);
    console.log(`Quota witness: real bucket ${bucket}, start ${started}, end ${finished}; ${quotaEvidence.join('; ')}.`);
    console.log('Stream witness: 2 HTTP/1.1 chunked requests, Content-Length absent, 4096/4097 bytes in two writes each.');
    for (const table of ['users', 'sessions', 'email_identities', 'email_auth_challenges', 'oauth_states', 'auth_codes']) {
      const result = await db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first();
      assert.equal(result.n, 0, `${table} must stay empty`);
    }
    await assertNoEmailSends();
    assert.equal(outboundAttempts, 0, 'No outbound requests permitted');
    // Maintenance is invoked through Miniflare's reserved local HTTP event adapter,
    // not a direct application export or a new production endpoint. No clock override.
    const { randomUUID, randomBytes } = await import('node:crypto');
    if (serviceObserver) assert.equal(serviceObserver.actions.length, ordinaryRequests() - captureRequestStart, 'Every ordinary request has one ordered action');
    await endCapturePhase();
    await mf.setOptions(convertV4MiniflareOptions({
      host: '127.0.0.1', port: 0, cf: false, telemetry: { enabled: false }, unsafeTriggerHandlers: true,
      unsafeLocalExplorer: false, unsafeObservability: false, unsafeEnableSharedStorage: false,
      logRequests: false, log: new Log(LogLevel.ERROR), resourcePersistencePath: join(root, 'state'), resourceTmpPath: join(root, 'tmp'),
      workers: [{ ...common, name: 'scriv', ...(capture ? { script: capture.options.script } : { scriptPath: bundle }),
        bindings: { PUBLIC_URL: 'http://127.0.0.1', ENVIRONMENT: 'test', ...(capture?.options.bindings ?? {}) },
        d1Databases: { DB: 'journey-db' }, r2Buckets: ['ASSETS', 'MEDIA'],
        durableObjects: { PROJECTS: { className: 'ProjectRoom', useSQLite: true }, BILLING: { className: 'BillingCoordinator', useSQLite: true } },
      }],
    }));
    captureRequestStart = ordinaryRequests();
    await beginCapturePhase();
    db = await mf.getD1Database('DB', 'scriv');
    const mediaBucket = await mf.getR2Bucket('MEDIA', 'scriv');
    const fixtureTime = Date.now(), hour = 3600000, ownerId = randomUUID(), sessionId = randomUUID();
    const token = randomBytes(32).toString('base64url'), teamId = randomUUID(), sentinelTeamId = randomUUID();
    const projectId = randomUUID(), sentinelProjectId = randomUUID();
    await db.prepare('INSERT INTO users(id,github_id,name,created_at) VALUES(?,?,?,?)').bind(ownerId, `email:${ownerId}`, 'Synthetic maintenance owner', fixtureTime).run();
    await db.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at) VALUES(?,?,?,?,?,?)')
      .bind(createHash('sha256').update(token).digest('hex'), sessionId, ownerId, 'Synthetic maintenance device', fixtureTime, fixtureTime + hour).run();
    for (const id of [teamId, sentinelTeamId]) {
      await db.prepare("INSERT INTO teams(id,name,owner_id,created_at,subscription_status,paid_until) VALUES(?,?,?,?,'active',?)")
        .bind(id, 'Synthetic maintenance team', ownerId, fixtureTime, fixtureTime + hour).run();
      await db.prepare("INSERT INTO team_members(team_id,user_id,role,joined_at) VALUES(?,?,'owner',?)").bind(id, ownerId, fixtureTime).run();
    }
    let scheduledTriggers = 0, maintenanceRequests = 0;
    async function maintenanceHTTP(path, { method = 'GET', body, status = 200, code, event = false } = {}) {
      const base = await mf.ready; assert.equal(base.hostname, '127.0.0.1'); assert.equal(base.protocol, 'http:');
      const url = new URL(path, base); assert.equal(url.origin, base.origin);
      const payload = body === undefined ? undefined : JSON.stringify(body); assert(Buffer.byteLength(payload ?? '') < 4096);
      assert(requests++ < 110); maintenanceRequests++;
      const response = await fetch(url, { method, headers: { ...(event ? {} : { authorization: `Bearer ${token}` }), ...(payload ? { 'content-type': 'application/json' } : {}) }, body: payload, redirect: 'error', signal: AbortSignal.timeout(10000) });
      assert.equal(response.status, status, `maintenance ${method} ${path}`);
      const chunks = []; let size = 0;
      for await (const chunk of response.body) { size += chunk.length; assert(size <= 65536); chunks.push(chunk); }
      const bytes = Buffer.concat(chunks);
      if (event) { assert.equal(JSON.parse(bytes).outcome, 'ok'); scheduledTriggers++; }
      else if (code) assert.equal(JSON.parse(bytes).error?.code, code);
      return { response, bytes };
    }
    for (const [id, team] of [[projectId, teamId], [sentinelProjectId, sentinelTeamId]]) {
      const created = await maintenanceHTTP('/v1/projects', { method: 'POST', status: 201, body: { id, teamId: team, title: 'Synthetic maintenance project' } });
      const data = JSON.parse(created.bytes); assert.equal(data.project.id, id); assert.equal(data.project.teamId, team); assert.equal(data.project.ownerId, ownerId);
    }
    // Only isolated preconditions are staged: these are interrupted replica states,
    // not proof that a real upload failed or a process crashed at a chosen instant.
    const fixtureRows = [], fixtureObjects = [];
    const png = label => Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), Buffer.from(label)]);
    async function asset(label, { state = 'uploading', age = 2 * hour, missing = false, wrongSize = false, wrongHash = false, noMetadata = false, content = png(label), project = projectId, team = teamId } = {}) {
      const digest = createHash('sha256').update(content).digest('hex'), objectKey = `projects/${project}/${digest}/${label}`;
      const row = { project_id: project, sha256: digest, team_id: team, asset_id: label, object_key: objectKey,
        content_type: 'image/png', bytes: content.length + (wrongSize ? 1 : 0), state, uploaded_by: ownerId, created_at: fixtureTime - age };
      await db.prepare('INSERT INTO assets(project_id,sha256,team_id,asset_id,object_key,content_type,bytes,state,uploaded_by,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)')
        .bind(...Object.values(row)).run(); fixtureRows.push(row);
      if (!missing) {
        const metadata = noMetadata ? {} : { sha256: wrongHash ? '0'.repeat(64) : digest, projectId: project, teamId: team };
        await mediaBucket.put(objectKey, content, { httpMetadata: { contentType: 'image/png' }, customMetadata: metadata });
        fixtureObjects.push({ key: objectKey, bytes: content.toString('hex'), contentType: 'image/png', metadata });
      }
      return { row, content };
    }
    const recovered = await asset('recover');
    const missing = await asset('missing', { missing: true });
    const wrongSize = await asset('wrong-size', { wrongSize: true });
    const wrongHash = await asset('wrong-hash', { wrongHash: true });
    const noMetadata = await asset('no-metadata', { noMetadata: true });
    const deleting = await asset('deleting', { state: 'deleting' });
    const fresh = await asset('fresh', { age: 0 });
    const ready = await asset('ready', { state: 'ready' });
    // Same digest as the rejected-size replica, but another project/team and R2 key.
    const sentinel = await asset('sentinel', { state: 'ready', content: wrongSize.content, project: sentinelProjectId, team: sentinelTeamId });
    const removed = [missing, wrongSize, wrongHash, noMetadata, deleting];
    const rowSort = rows => [...rows].sort((a, b) => (a.project_id + ':' + a.sha256).localeCompare(b.project_id + ':' + b.sha256));
    const objectSort = objects => [...objects].sort((a, b) => a.key.localeCompare(b.key));
    async function state() {
      const rows = (await db.prepare('SELECT * FROM assets ORDER BY project_id,sha256').all()).results;
      const objects = [];
      for (const item of (await mediaBucket.list()).objects) {
        const object = await mediaBucket.get(item.key); assert.ok(object);
        objects.push({ key: item.key, bytes: Buffer.from(await object.arrayBuffer()).toString('hex'), contentType: object.httpMetadata?.contentType, metadata: object.customMetadata });
      }
      const teams = (await db.prepare('SELECT id,storage_used FROM teams ORDER BY id').all()).results;
      return { rows: rowSort(rows), objects: objectSort(objects), teams };
    }
    const expectedState = rows => ({ rows: rowSort(rows), objects: objectSort(fixtureObjects.filter(object => rows.some(row => row.object_key === object.key))),
      teams: [teamId, sentinelTeamId].sort().map(id => ({ id, storage_used: rows.filter(row => row.team_id === id).reduce((n, row) => n + row.bytes, 0) })) });
    assert.deepEqual(await state(), expectedState(fixtureRows));
    const projectsBefore = (await db.prepare('SELECT * FROM projects ORDER BY id').all()).results;
    // Independent expiration records: no sign-in, code redemption, email or real credentials.
    for (const [label, expires] of [['expired', fixtureTime - hour], ['live', fixtureTime + hour]]) {
      await db.prepare('INSERT INTO oauth_states(state_hash,client_state,challenge,expires_at) VALUES(?,?,?,?)').bind(`maintenance-oauth-${label}`, label, label, expires).run();
      await db.prepare('INSERT INTO auth_codes(code_hash,user_id,challenge,expires_at) VALUES(?,?,?,?)').bind(`maintenance-code-${label}`, ownerId, label, expires).run();
      await db.prepare('INSERT INTO email_auth_challenges(id_hash,email,pkce_challenge,created_at,expires_at) VALUES(?,?,?,?,?)').bind(`maintenance-email-${label}`, `${label}@example.invalid`, label, fixtureTime - 2 * hour, expires).run();
      await db.prepare('INSERT INTO security_limits(key,count,expires_at) VALUES(?,?,?)').bind(`maintenance-limit-${label}`, 7, expires).run();
    }
    for (const [label, expires, revoked] of [['old-expired', fixtureTime - 31 * 86400000, null], ['recent-expired', fixtureTime - hour, null], ['revoked-live', fixtureTime + hour, fixtureTime - hour]]) {
      await db.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at,revoked_at) VALUES(?,?,?,?,?,?,?)')
        .bind(`maintenance-session-${label}`, `maintenance-session-${label}`, ownerId, label, fixtureTime - 32 * 86400000, expires, revoked).run();
    }
    async function expiryState() {
      const result = {};
      for (const [table, order] of [['oauth_states','state_hash'], ['auth_codes','code_hash'], ['email_auth_challenges','id_hash'], ['sessions','id'], ['security_limits','key']]) result[table] = (await db.prepare(`SELECT * FROM ${table} ORDER BY ${order}`).all()).results;
      return result;
    }
    const mediaPath = item => `/v1/projects/${item.row.project_id}/assets/${item.row.sha256}`;
    await maintenanceHTTP(mediaPath(recovered), { status: 404, code: 'asset_unavailable' });
    assert.deepEqual((await maintenanceHTTP(mediaPath(ready))).bytes, ready.content);
    const expiryBefore = await expiryState();
    // The expected removals name authored fixture records, not a copy of the production predicate.
    const expiredKeys = { oauth_states: ['state_hash', 'maintenance-oauth-expired'], auth_codes: ['code_hash', 'maintenance-code-expired'],
      email_auth_challenges: ['id_hash', 'maintenance-email-expired'], sessions: ['id', 'maintenance-session-old-expired'], security_limits: ['key', 'maintenance-limit-expired'] };
    const expectedExpiry = Object.fromEntries(Object.entries(expiryBefore).map(([table, rows]) => [table, rows.filter(row => row[expiredKeys[table][0]] !== expiredKeys[table][1])]));
    const afterRows = fixtureRows.filter(row => !removed.some(item => item.row === row)).map(row => row === recovered.row ? { ...row, state: 'ready' } : row);
    const expectedAfter = expectedState(afterRows);
    await maintenanceHTTP('/cdn-cgi/local/scheduled?format=json', { event: true });
    // The platform event is invoked once. Poll only bounded read-only observations.
    const deadline = Date.now() + 5000;
    while (JSON.stringify(await state()) !== JSON.stringify(expectedAfter)) {
      assert.ok(Date.now() < deadline, 'Scheduled media state did not settle'); await new Promise(resolve => setTimeout(resolve, 20));
    }
    assert.deepEqual(await state(), expectedAfter);
    assert.deepEqual(await expiryState(), expectedExpiry);
    assert.deepEqual((await db.prepare('SELECT * FROM projects ORDER BY id').all()).results, projectsBefore);
    for (const item of [recovered, ready, sentinel]) {
      const downloaded = await maintenanceHTTP(mediaPath(item));
      assert.deepEqual(downloaded.bytes, item.content); assert.equal(downloaded.response.headers.get('content-type'), 'image/png');
      assert.equal(downloaded.response.headers.get('x-scriv-sha256'), item.row.sha256);
    }
    for (const item of [...removed, fresh]) await maintenanceHTTP(mediaPath(item), { status: 404, code: 'asset_unavailable' });
    const secondExpiryBaseline = await expiryState();
    await maintenanceHTTP('/cdn-cgi/local/scheduled?format=json', { event: true });
    assert.deepEqual(await state(), expectedAfter); assert.deepEqual(await expiryState(), secondExpiryBaseline);
    assert.deepEqual((await maintenanceHTTP(mediaPath(recovered))).bytes, recovered.content);
    assert.deepEqual((await (await mf.getR2Bucket('ASSETS', 'scriv')).list()).objects, []);
    assert.equal(scheduledTriggers, 2); assert.equal(outboundAttempts, 0);
    console.log(JSON.stringify({ kind: 'scheduled-maintenance-evidence', scheduledTriggers, maintenanceRequests,
      initialAssets: fixtureRows.length, retainedAssets: afterRows.length, removedAssets: removed.length,
      quotaReleased: removed.reduce((n, item) => n + item.row.bytes, 0), sentinelTeamQuotaUnchanged: true,
      nativeScenarios: 0, productionCrashSimulated: false, outboundAttempts }));
    // Public logout after observed authentication, before a held JSON body can finish.
    // Only declared fixture setup and read-only observations touch D1 directly in this chapter.
    const targetMember = randomUUID();
    await db.prepare('INSERT INTO users(id,github_id,name,created_at) VALUES(?,?,?,?)').bind(targetMember, `email:${targetMember}`, 'Synthetic interrupted-write target', fixtureTime).run();
    await db.prepare("INSERT INTO team_members(team_id,user_id,role,joined_at) VALUES(?,?,'member',?)").bind(teamId, targetMember, fixtureTime).run();
    const interruptedCases = [], protectedMedia = await state();
    const tables = [['teams','id'], ['team_members','team_id,user_id'], ['join_links','id'], ['projects','id'], ['billing_events','id']];
    async function businessState() {
      const snapshot = {};
      for (const [table, order] of tables) snapshot[table] = (await db.prepare(`SELECT * FROM ${table} ORDER BY ${order}`).all()).results;
      snapshot.media = await state(); return snapshot;
    }
    async function guardHTTP(path, { method = 'GET', body, bearer = token } = {}) {
      const base = await mf.ready; assert.equal(base.hostname, '127.0.0.1'); assert.equal(base.protocol, 'http:');
      const url = new URL(path, base); assert.equal(url.origin, base.origin);
      const encoded = body === undefined ? undefined : JSON.stringify(body); assert(Buffer.byteLength(encoded ?? '') < 4096); assert(requests++ < 160);
      const response = await fetch(url, { method, headers: { authorization: `Bearer ${bearer}`, ...(encoded ? { 'content-type': 'application/json' } : {}) }, body: encoded, redirect: 'error', signal: AbortSignal.timeout(5000) });
      const parts = []; let size = 0;
      for await (const chunk of response.body) { size += chunk.length; assert(size <= 16384); parts.push(chunk); }
      assert.equal(response.headers.get('cache-control'), 'no-store'); assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
      return { status: response.status, data: JSON.parse(Buffer.concat(parts).toString('utf8')) };
    }
    async function interruptedWrite(label, path, method, body, expectedStatus, expectedCode, recoveryStatus, recover) {
      const attemptToken = randomBytes(32).toString('base64url'), attemptId = randomUUID(), started = Date.now();
      await db.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at) VALUES(?,?,?,?,?,?)')
        .bind(createHash('sha256').update(attemptToken).digest('hex'), attemptId, ownerId, 'Synthetic held-body device', started, started + hour).run();
      const prefix = `request:${attemptId}:`;
      const requestCounters = async () => (await db.prepare('SELECT * FROM security_limits WHERE substr(key,1,?)=? ORDER BY key').bind(prefix.length, prefix).all()).results;
      assert.deepEqual(await requestCounters(), []);
      const before = await businessState();
      const base = await mf.ready; const url = new URL(path, base);
      assert.equal(base.hostname, '127.0.0.1'); assert.equal(base.protocol, 'http:'); assert.equal(url.origin, base.origin);
      const payload = Buffer.from(JSON.stringify(body)); assert(payload.length > 2 && payload.length < 4096); assert(requests++ < 160);
      let outgoing, responseStarted = false, bodyReleased = false;
      const completion = new Promise((resolve, reject) => {
        serviceObserver?.record(method, url);
        outgoing = httpRequest(url, { method, headers: { authorization: `Bearer ${attemptToken}`, 'content-type': 'application/json', 'content-length': String(payload.length) }, agent: false, signal: AbortSignal.timeout(10000) }, incoming => {
          responseStarted = true;
          const chunks = []; let size = 0;
          incoming.on('error', reject);
          incoming.on('data', chunk => { size += chunk.length; if (size > 16384) incoming.destroy(new Error('Bounded held-body response')); else chunks.push(chunk); });
          incoming.on('end', () => resolve({ status: incoming.statusCode, headers: incoming.headers, bytes: Buffer.concat(chunks) }));
        });
        outgoing.on('error', reject); outgoing.flushHeaders(); outgoing.write(payload.subarray(0, 1));
      });
      // Prevent an unhandled rejection if the owned request fails while the barrier is polled.
      completion.catch(() => {});
      try {
        const deadline = Date.now() + 5000; let observed;
        while (true) {
          observed = await requestCounters();
          if (observed.length) break;
          assert.ok(Date.now() < deadline, 'Initial authentication marker did not appear');
          assert.equal(responseStarted, false); await new Promise(resolve => setTimeout(resolve, 5));
        }
        assert.equal(observed.length, 1); assert.equal(observed[0].count, 1);
        assert.equal(responseStarted, false); assert.equal(bodyReleased, false);
        // index.ts writes this per-session counter only after authenticate returns.
        // The one-byte JSON prefix cannot satisfy the pending body parse.
        const logout = await guardHTTP('/auth/logout', { method: 'POST', bearer: attemptToken });
        assert.equal(logout.status, 200); assert.deepEqual(logout.data, { ok: true });
        const revoked = await db.prepare('SELECT revoked_at,expires_at FROM sessions WHERE id=?').bind(attemptId).first();
        assert.equal(typeof revoked.revoked_at, 'number'); assert.ok(revoked.revoked_at >= started && revoked.revoked_at <= Date.now()); assert.ok(revoked.expires_at > Date.now());
        const retainedOwner = await db.prepare('SELECT revoked_at,expires_at FROM sessions WHERE id=?').bind(sessionId).first();
        assert.equal(retainedOwner.revoked_at, null); assert.ok(retainedOwner.expires_at > Date.now());
        assert.equal(responseStarted, false); bodyReleased = true; outgoing.end(payload.subarray(1));
        const rejected = await completion;
        assert.equal(rejected.status, expectedStatus, label); assert.equal(JSON.parse(rejected.bytes).error?.code, expectedCode, label);
        assert.equal(rejected.headers['cache-control'], 'no-store'); assert.equal(rejected.headers['x-content-type-options'], 'nosniff');
        assert.deepEqual(await businessState(), before, `${label} must not partially mutate business state`);
        assert.deepEqual(await requestCounters(), observed, 'Logout and later rejected authorization must not change the held-write marker');
        const staleRead = await guardHTTP('/v1/me', { bearer: attemptToken });
        assert.equal(staleRead.status, 401); assert.equal(staleRead.data.error?.code, 'session_expired');
        assert.deepEqual(await requestCounters(), observed);
        const recovered = await guardHTTP(path, { method, body }); assert.equal(recovered.status, recoveryStatus, `${label} fresh-session retry`);
        await recover(recovered.data, before);
        interruptedCases.push({ label, rejectionStatus: expectedStatus, rejectionCode: expectedCode, recoveryStatus });
      } finally { outgoing?.destroy(); }
    }
    let recoveredTeam, recoveredPersonal, recoveredTeamProject;
    await interruptedWrite('team-create', '/v1/teams', 'POST', { name: 'Recovered synthetic team' }, 401, 'session_expired', 201, async (data, before) => {
      recoveredTeam = data.team.id; assert.equal(data.team.name, 'Recovered synthetic team'); assert.equal(data.team.ownerId, ownerId); assert.equal(data.team.role, 'owner');
      assert.equal((await db.prepare('SELECT name FROM teams WHERE id=?').bind(recoveredTeam).first()).name, data.team.name);
      assert.deepEqual((await db.prepare('SELECT user_id,role FROM team_members WHERE team_id=?').bind(recoveredTeam).all()).results, [{ user_id: ownerId, role: 'owner' }]);
      assert.deepEqual((await db.prepare('SELECT * FROM teams WHERE id<>? ORDER BY id').bind(recoveredTeam).all()).results, before.teams);
      assert.deepEqual((await db.prepare('SELECT * FROM team_members WHERE team_id<>? ORDER BY team_id,user_id').bind(recoveredTeam).all()).results, before.team_members);
    });
    await interruptedWrite('team-rename', `/v1/teams/${teamId}`, 'PATCH', { name: 'Recovered team rename' }, 409, 'access_changed', 200, async data => {
      assert.equal(data.team.id, teamId); assert.equal(data.team.name, 'Recovered team rename');
      assert.equal((await db.prepare('SELECT name FROM teams WHERE id=?').bind(teamId).first()).name, 'Recovered team rename');
    });
    await interruptedWrite('join-link-create', `/v1/teams/${teamId}/join-links`, 'POST', { role: 'viewer', expiresInDays: 1 }, 409, 'access_changed', 201, async data => {
      assert.equal(data.link.role, 'viewer'); assert.equal(data.link.expiresAt - data.link.createdAt, 86400000);
      assert.equal(data.url, `http://127.0.0.1/join/${data.token}`);
      const link = await db.prepare('SELECT team_id,token_hash,role,created_by,created_at,expires_at,revoked_at FROM join_links WHERE id=?').bind(data.link.id).first();
      assert.deepEqual(link, { team_id: teamId, token_hash: createHash('sha256').update(data.token).digest('hex'), role: 'viewer', created_by: ownerId, created_at: data.link.createdAt, expires_at: data.link.expiresAt, revoked_at: null });
    });
    await interruptedWrite('membership-role', `/v1/teams/${teamId}/members/${targetMember}`, 'PATCH', { role: 'viewer' }, 409, 'membership_changed', 200, async data => {
      assert.deepEqual(data, { ok: true }); assert.equal((await db.prepare('SELECT role FROM team_members WHERE team_id=? AND user_id=?').bind(teamId, targetMember).first()).role, 'viewer');
    });
    const personalId = randomUUID(), newTeamProjectId = randomUUID();
    await interruptedWrite('personal-project-create', '/v1/projects', 'POST', { id: personalId, title: 'Recovered personal project' }, 409, 'access_changed', 201, async data => {
      recoveredPersonal = data.project.id; assert.equal(recoveredPersonal, personalId); assert.equal(data.project.teamId, null); assert.equal(data.project.ownerId, ownerId);
      assert.deepEqual(await db.prepare('SELECT title,owner_id,team_id FROM projects WHERE id=?').bind(personalId).first(), { title: 'Recovered personal project', owner_id: ownerId, team_id: null });
    });
    await interruptedWrite('team-project-create', '/v1/projects', 'POST', { id: newTeamProjectId, title: 'Recovered team project', teamId }, 409, 'access_changed', 201, async data => {
      recoveredTeamProject = data.project.id; assert.equal(recoveredTeamProject, newTeamProjectId); assert.equal(data.project.teamId, teamId); assert.equal(data.project.ownerId, ownerId);
      assert.deepEqual(await db.prepare('SELECT title,owner_id,team_id FROM projects WHERE id=?').bind(newTeamProjectId).first(), { title: 'Recovered team project', owner_id: ownerId, team_id: teamId });
    });
    for (const [label, id] of [['personal-project-rename', recoveredPersonal], ['team-project-rename', recoveredTeamProject]]) {
      await interruptedWrite(label, `/v1/projects/${id}`, 'PATCH', { title: `Recovered ${label}` }, 409, 'access_changed', 200, async data => {
        assert.equal(data.project.id, id); assert.equal(data.project.title, `Recovered ${label}`);
        assert.equal((await db.prepare('SELECT title FROM projects WHERE id=?').bind(id).first()).title, `Recovered ${label}`);
      });
    }
    const finalMedia = await state(); assert.deepEqual(finalMedia.rows, protectedMedia.rows); assert.deepEqual(finalMedia.objects, protectedMedia.objects);
    for (const team of protectedMedia.teams) assert.deepEqual(finalMedia.teams.find(row => row.id === team.id), team);
    assert.equal(interruptedCases.length, 8); assert.equal(outboundAttempts, 0);
    console.log(JSON.stringify({ kind: 'interrupted-authorization-evidence', cases: interruptedCases, marker: 'post-authentication per-session request counter', sentBodyPrefixBytes: 1, realLogout: true, arbitraryRaceCoverage: false, outboundAttempts, nativeScenarios: 0 }));
    const hash = createHash('sha256').update(capture ? capture.options.script : await readFile(bundle)).digest('hex');
    console.log(`PASS service-process integration: ${requests} loopback HTTP checks; 3 original migrations; initial empty-identity guards plus scheduled-maintenance fixtures; zero EMAIL.send RPC invocations; zero outbound attempts.`);
    console.log(`${capture ? 'Instrumented capture' : 'Production entry'} bundle SHA-256: ${hash}`);
    console.log('No successful login, email delivery, OAuth grant, native launch, or Catalyst E2E claimed; later sessions are synthetic service fixtures.');
    if (serviceObserver) assert.equal(serviceObserver.actions.length, ordinaryRequests() - captureRequestStart, 'Every ordinary request has one ordered action');
  } finally {
    try { await endCapturePhase(); } finally { await mf.dispose(); }
  }
}
