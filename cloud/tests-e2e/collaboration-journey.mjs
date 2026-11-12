// Real HTTP service-process integration; not Catalyst/native application E2E.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, rm, readFile, readdir, copyFile, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';

const here = await realpath(dirname(fileURLToPath(import.meta.url)));
// --cloud supports an outside-repository candidate without changing its sources.
const cloud = await realpath(process.argv[2] === '--owned-child' ? process.argv[4] :
  process.argv[2] === '--cloud' ? process.argv[3] : join(here, '..'));
const self = await realpath(fileURLToPath(import.meta.url));
if (process.argv[2] !== '--owned-child') {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'scriv-collaboration-')));
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
        WRANGLER_SEND_METRICS: 'false', CI: '1' },
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
      assert(requests++ < 110); assert(Buffer.byteLength(encoded ?? '') <= 16384);
      const response = await fetch(url, { method, headers: { authorization: `Bearer ${actors[role].token}`, ...(encoded ? { 'content-type': 'application/json' } : {}) }, body: encoded, redirect: 'error', signal: AbortSignal.timeout(5000) });
      // Never include response bodies or headers in errors: leases are secrets.
      assert.equal(response.status, status, `${method} ${path} status`);
      assert.equal(response.headers.get('cache-control'), 'no-store');
      assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
      const reader = response.body.getReader(); const parts = []; let size = 0;
      while (true) { const { done, value } = await reader.read(); if (done) break; size += value.length; assert(size <= 65536, 'Response bound'); parts.push(value); }
      const data = JSON.parse(Buffer.concat(parts).toString('utf8'));
      if (code) assert.equal(data.error?.code, code, `${method} ${path} error code`);
      return data;
    }
    const route = suffix => `/v1/projects/${projectId}/${suffix}`;
    const post = (body, extra = {}) => ({ method: 'POST', body, ...extra });
    const command = (title, version = 0, extra = {}) => ({ commandId: randomUUID(), sessionId: actors.member.sessionId, epoch: 1, label: 'Synthetic scene edit', operations: [{ op: 'put', id: itemId, kind: 'scene', expectedVersion: version, data: { id: itemId, title, order: 0 } }], ...extra });
    assert.equal((await request('/v1/me')).user.id, actors.owner.id);
    const project = { id: projectId, title: 'Synthetic story', teamId };
    const created = await request('/v1/projects', post(project, { role: 'member', status: 201 }));
    assert.equal(created.project.ownerId, actors.owner.id);
    assert.deepEqual(await request('/v1/projects', post(project, { role: 'member' })), created);
    await request('/v1/projects', post({ ...project, title: 'Different' }, { status: 409, code: 'project_exists' }));
    assert.equal((await request('/v1/projects', { role: 'viewer' })).projects.length, 1);
    await request(route('snapshot'), { role: 'outsider', status: 404, code: 'not_found' });
    const empty = await request(route('snapshot'), { role: 'viewer' });
    assert.equal(empty.headSeq, 0); assert.equal(empty.epoch, 1); assert.deepEqual(empty.items, []);
    const first = command('First draft');
    const receipt1 = await request(route('commands'), post(first, { role: 'member' }));
    assert.equal(receipt1.seq, 1); assert.equal(receipt1.items[0].version, 1);
    assert.deepEqual(await request(route('commands'), post(first, { role: 'member' })), receipt1);
    await request(route('commands'), post({ ...first, label: 'Changed retry' }, { role: 'member', status: 409, code: 'command_reused' }));
    await request(route('commands'), post(command('Denied', 1), { role: 'viewer', status: 403, code: 'read_only' }));
    await request(route('commands'), post(command('No lease', 1), { role: 'member', status: 423, code: 'lease_required' }));
    const leaseBody = { itemId, sessionId: actors.member.sessionId };
    const lease = await request(route('leases'), post(leaseBody, { role: 'member' }));
    assert.equal(lease.userId, actors.member.id); assert.equal(lease.fence, 1); assert.equal(typeof lease.token, 'string');
    await request(route('leases'), post({ itemId, sessionId: actors.owner.sessionId }, { status: 423, code: 'item_locked' }));
    const publicLease = (await request(route('leases'), { role: 'viewer' })).leases[0];
    assert.equal(Object.hasOwn(publicLease, 'token'), false);
    const second = command('Second draft', 1); second.operations[0].lease = { token: lease.token, fence: lease.fence };
    const receipt2 = await request(route('commands'), post(second, { role: 'member' }));
    assert.equal(receipt2.seq, 2); assert.equal(receipt2.items[0].version, 2);
    await request(route('commands'), post({ ...second, commandId: randomUUID() }, { role: 'member', status: 409, code: 'version_conflict' }));
    const snapshot = await request(route('snapshot'), { role: 'viewer' });
    assert.equal(snapshot.headSeq, 2); assert.equal(snapshot.items[0].data.title, 'Second draft');
    const historical = await request(route('snapshot?seq=1'), { role: 'viewer' });
    assert.equal(historical.items[0].data.title, 'First draft'); assert.equal(historical.items[0].version, 1);
    const history = await request(route('history?after=0&limit=1'));
    assert.equal(history.events.length, 1); assert.equal(history.hasMore, true); assert.equal(history.events[0].commandId, first.commandId);
    const events = await request(route('events?after=1'));
    assert.equal(events.events.length, 1); assert.equal(events.events[0].commandId, second.commandId);
    // Permission changes also exercise production D1 mutation and DO refresh.
    await request(`/v1/teams/${teamId}/members/${actors.member.id}`, { method: 'PATCH', body: { role: 'viewer' } });
    assert.deepEqual(await request(route('commands'), post(second, { role: 'member' })), receipt2);
    await request(route('commands'), post(command('After downgrade', 2), { role: 'member', status: 403, code: 'read_only' }));
    assert.deepEqual((await request(route('leases'))).leases, []);
    const restore = { commandId: randomUUID(), sessionId: actors.owner.sessionId, epoch: 1, seq: 1 };
    await request(route('restore'), post(restore, { role: 'viewer', status: 403, code: 'not_allowed' }));
    const restored = await request(route('restore'), post(restore));
    assert.equal(restored.seq, 3); assert.equal(restored.epoch, 2);
    assert.deepEqual(await request(route('restore'), post(restore)), restored);
    const restoredSnapshot = await request(route('snapshot'));
    assert.equal(restoredSnapshot.items[0].data.title, 'First draft'); assert.equal(restoredSnapshot.items[0].version, 3);
    await request(route('commands'), post(command('Old epoch', 3), { status: 409, code: 'stale_epoch' }));
    await request(`/v1/teams/${teamId}/members/${actors.member.id}`, { method: 'DELETE' });
    await request(route('snapshot'), { role: 'member', status: 404, code: 'not_found' });
    assert.equal((await request('/v1/projects', { role: 'member' })).projects.length, 0);
    await request('/auth/logout', post({}, { role: 'viewer' }));
    await request(route('snapshot'), { role: 'viewer', status: 401, code: 'session_expired' });
    assert.equal((await request(route('snapshot'))).headSeq, 3);
    assert.equal((await db.prepare('SELECT COUNT(*) n FROM projects').first()).n, 1);
    assert.equal((await db.prepare('SELECT COUNT(*) n FROM sessions WHERE revoked_at IS NOT NULL').first()).n, 1);
    assert.deepEqual((await bucket.list()).objects, []);
    // New chapter: exact device inventory, relay fallback and controlled provider responses.
    // Fixture-only identity preparation follows all unchanged collaboration assertions.
    const deviceNow = Date.now(), expiresAt = deviceNow + 3600000, deviceChecks = [];
    await db.prepare('INSERT INTO team_members(team_id,user_id,role,joined_at) VALUES(?,?,?,?)').bind(teamId, actors.member.id, 'member', deviceNow).run();
    const descriptors = {};
    async function sessionFixture(role, userRole, age, { fresh = false, expired = false, revoked = false } = {}) {
      const actor = fresh ? (actors[role] = { id: actors[userRole].id, sessionId: randomUUID(), token: randomBytes(32).toString('base64url') }) : actors[role];
      const descriptor = { id: actor.sessionId, deviceName: `Synthetic ${role} device`, userId: actor.id,
        name: `Synthetic ${userRole}`, createdAt: deviceNow - age, expiresAt: expired ? deviceNow - 1 : expiresAt };
      if (fresh) await db.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at,revoked_at) VALUES(?,?,?,?,?,?,?)')
        .bind(createHash('sha256').update(actor.token).digest('hex'), actor.sessionId, actor.id, descriptor.deviceName, descriptor.createdAt, descriptor.expiresAt, revoked ? deviceNow - 1 : null).run();
      else await db.prepare('UPDATE sessions SET device_name=?,created_at=?,expires_at=? WHERE id=?')
        .bind(descriptor.deviceName, descriptor.createdAt, descriptor.expiresAt, actor.sessionId).run();
      descriptors[role] = descriptor;
    }
    await sessionFixture('owner', 'owner', 40000);
    await sessionFixture('member', 'member', 30000);
    await sessionFixture('outsider', 'outsider', 2000);
    await sessionFixture('viewer', 'viewer', 1000); // Its earlier public logout remains revoked.
    await sessionFixture('ownerOther', 'owner', 10000, { fresh: true });
    await sessionFixture('ownerExpired', 'owner', 20000, { fresh: true, expired: true });
    await sessionFixture('ownerRevoked', 'owner', 5000, { fresh: true, revoked: true });
    await sessionFixture('memberOther', 'member', 15000, { fresh: true });
    const deviceOrder = roles => roles.map(role => descriptors[role]).sort((a, b) => b.createdAt - a.createdAt);
    async function inventory(label, role, expected) {
      const actual = await request(route('devices'), { role });
      assert.deepEqual(actual, { currentDeviceId: actors[role].sessionId, devices: deviceOrder(expected), onlineStatus: 'unknown' }, label);
      deviceChecks.push(label);
    }
    const personalId = randomUUID();
    const personal = await request('/v1/projects', post({ id: personalId, title: 'Synthetic separate personal project' }, { role: 'memberOther', status: 201 }));
    assert.equal(personal.project.ownerId, actors.member.id); assert.equal(personal.project.teamId, null);
    assert.deepEqual((await request(`/v1/projects/${personalId}/snapshot`, { role: 'memberOther' })).items, []);
    const allEligible = ['owner', 'ownerOther', 'member', 'memberOther'];
    await inventory('paid-owner-all-eligible', 'owner', allEligible);
    await inventory('paid-member-all-eligible', 'member', allEligible);
    await request(route('devices'), { role: 'outsider', status: 404, code: 'not_found' });
    await request(route('devices'), { role: 'viewer', status: 401, code: 'session_expired' });
    await request('/v1/projects/synthetic-absent-project/devices', { status: 404, code: 'not_found' });
    // Ordinary read-grace entitlement fixture; no billing provider is invoked.
    await db.prepare("UPDATE teams SET subscription_status='canceled',paid_until=?,canceled_at=? WHERE id=?").bind(deviceNow - 1, deviceNow, teamId).run();
    await inventory('grace-owner-own-only', 'owner', ['owner', 'ownerOther']);
    await inventory('grace-member-own-only', 'member', ['member', 'memberOther']);
    await db.prepare("UPDATE teams SET subscription_status='active',paid_until=?,canceled_at=NULL WHERE id=?").bind(expiresAt, teamId).run();
    await inventory('reactivated-all-eligible', 'owner', allEligible);
    assert.deepEqual(await request('/auth/logout', post({}, { role: 'memberOther' })), { ok: true });
    await inventory('revoked-teammate-device-absent', 'owner', ['owner', 'ownerOther', 'member']);
    await request(route('devices'), { role: 'memberOther', status: 401, code: 'session_expired' });
    await request(`/v1/teams/${teamId}/members/${actors.member.id}`, { method: 'DELETE' });
    await inventory('removed-teammate-absent', 'owner', ['owner', 'ownerOther']);
    await request(route('devices'), { role: 'member', status: 404, code: 'not_found' });
    assert.deepEqual((await request(`/v1/projects/${personalId}/snapshot`, { role: 'member' })).items, []);
    // Only real elapsed time may advance quota buckets; never seed/reset the quota.
    const hour = 3600000, remaining = hour - Date.now() % hour;
    if (remaining < 3000) await new Promise(resolve => setTimeout(resolve, remaining + 25));
    const quotaBucket = Math.floor(Date.now() / hour);
    const turnKey = role => `turn:${actors[role].sessionId}:${quotaBucket}`;
    const count = async role => (await db.prepare('SELECT count FROM security_limits WHERE key=?').bind(turnKey(role)).first())?.count ?? 0;
    assert.equal(await count('owner'), 0); assert.equal(await count('ownerOther'), 0);
    await request(route('ice-servers'), { role: 'outsider', status: 404, code: 'not_found' });
    await request(route('ice-servers'), { role: 'viewer', status: 401, code: 'session_expired' });
    assert.equal(await count('outsider'), 0); assert.equal(await count('viewer'), 0);
    async function relay(role, expectedServers, relayAvailable) {
      const before = Date.now();
      const response = await request(route('ice-servers'), { role });
      const after = Date.now();
      assert.deepEqual(Object.keys(response).sort(), ['expiresAt', 'iceServers', 'relayAvailable']);
      assert.deepEqual(response.iceServers, expectedServers); assert.equal(response.relayAvailable, relayAvailable);
      assert.ok(Number.isInteger(response.expiresAt)); assert.ok(response.expiresAt >= before + hour && response.expiresAt <= after + hour);
    }
    const fallback = [{ urls: ['stun:stun.cloudflare.com:3478'] }];
    for (let i = 0; i < 20; i++) await relay('owner', fallback, false);
    assert.equal(await count('owner'), 20);
    const limited = await request(route('ice-servers'), { status: 429, code: 'rate_limited' });
    assert.deepEqual(limited, { error: { code: 'rate_limited', message: 'Too many requests. Please wait and retry.' } });
    assert.equal(await count('owner'), 21);
    await relay('ownerOther', fallback, false); assert.equal(await count('ownerOther'), 1);
    assert.equal(Math.floor(Date.now() / hour), quotaBucket, 'Real quota window changed; no fixed-bucket result claimed');
    // Miniflare intercepts only this fake provider contract. Nothing reaches a live TURN service.
    let providerMode = 'valid', providerCalls = 0;
    const providerServers = [{ urls: ['turn:synthetic-relay.invalid:3478'], username: 'fixture-user', credential: 'fixture-not-a-real-credential' }];
    const provider = async request => {
      if (request.url !== 'https://rtc.live.cloudflare.com/v1/turn/keys/synthetic%20key/credentials/generate-ice-servers') {
        outboundAttempts++; throw new Error('Unexpected outbound request denied');
      }
      providerCalls++;
      assert.equal(request.method, 'POST'); assert.equal(request.headers.get('authorization'), 'Bearer fixture-not-a-real-api-token');
      assert.equal(request.headers.get('content-type'), 'application/json'); assert.deepEqual(await request.json(), { ttl: 3600 });
      if (providerMode === 'http-failure') return new Response('private fixture provider failure', { status: 503 });
      return Response.json(providerMode === 'invalid-shape' ? { iceServers: {} } : { iceServers: providerServers });
    };
    await mf.setOptions(convertV4MiniflareOptions({
      host: '127.0.0.1', port: 0, cf: false, telemetry: { enabled: false }, unsafeLocalExplorer: false,
      unsafeObservability: false, unsafeEnableSharedStorage: false, logRequests: false, log: new Log(LogLevel.ERROR),
      resourcePersistencePath: join(root, 'state'), resourceTmpPath: join(root, 'tmp'),
      workers: [{ ...common, outboundService: provider, name: 'scriv', scriptPath: bundle,
        bindings: { PUBLIC_URL: 'http://127.0.0.1', ENVIRONMENT: 'test', TURN_KEY_ID: 'synthetic key', TURN_API_TOKEN: 'fixture-not-a-real-api-token' },
        d1Databases: { DB: 'journey-db' }, r2Buckets: ['ASSETS'],
        durableObjects: { PROJECTS: { className: 'ProjectRoom', useSQLite: true }, BILLING: { className: 'BillingCoordinator', useSQLite: true } },
      }],
    }));
    await relay('ownerOther', providerServers, true);
    providerMode = 'http-failure';
    assert.deepEqual(await request(route('ice-servers'), { role: 'ownerOther', status: 502, code: 'turn_unavailable' }),
      { error: { code: 'turn_unavailable', message: 'The peer relay could not be configured. Retry or use the hosted image copy.' } });
    providerMode = 'invalid-shape';
    assert.deepEqual(await request(route('ice-servers'), { role: 'ownerOther', status: 502, code: 'turn_unavailable' }),
      { error: { code: 'turn_unavailable', message: 'Peer relay returned invalid credentials.' } });
    assert.equal(providerCalls, 3);
    // setOptions invalidates Miniflare handles; acquire fresh read-only fixture observers.
    const finalDB = await mf.getD1Database('DB', 'scriv');
    assert.equal((await finalDB.prepare('SELECT count FROM security_limits WHERE key=?').bind(turnKey('ownerOther')).first()).count, 4);
    assert.deepEqual(await request(route('snapshot')), restoredSnapshot);
    assert.deepEqual((await (await mf.getR2Bucket('ASSETS', 'scriv')).list()).objects, []);
    assert.equal(deviceChecks.length, 7);
    assert.equal(outboundAttempts, 0);
    console.log(JSON.stringify({ result: 'PASS', journey: 'collaboration', requests, deviceChecks, providerCalls, outboundAttempts, migrations: migrations.length, bundleSha256: createHash('sha256').update(await readFile(bundle)).digest('hex'), nativeScenarios: 0, loginFlowTested: false, fixture: 'four synthetic users; eight synthetic sessions; two synthetic projects; local entitlement fixtures; empty R2; intercepted TURN provider only' }));
  } finally { await mf.dispose(); }
}
