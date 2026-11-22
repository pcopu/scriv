import assert from 'node:assert/strict';
import { fork } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { mkdtemp, mkdir, readFile, readdir, realpath, rm } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const cloud = fileURLToPath(new URL('../../../../cloud/', import.meta.url));
export const nativeFixtureEmail = 'synthetic-native@example.invalid';
export const nativeFixtureTeam = 'Synthetic Story Team';

export async function startNativeCloudFixture() {
  const require = createRequire(join(cloud, 'package.json'));
  const dependencies = dirname(dirname(require.resolve('miniflare/package.json')));
  const root = await realpath(await mkdtemp(join(tmpdir(), 'scriv-native-cloud-')));
  let child;
  let exited;
  let closePromise;
  function close() {
    closePromise ??= (async () => {
      if (child?.connected) child.disconnect();
      const kill = setTimeout(() => child?.kill('SIGKILL'), 5_000);
      try { await exited; } finally { clearTimeout(kill); await rm(root, { recursive: true, force: true }); }
    })();
    return closePromise;
  }
  try {
    for (const name of ['home', 'state', 'tmp']) await mkdir(join(root, name), { mode: 0o700 });
    // Workerd inherits process configuration. Use the same isolated environment
    // as the service journeys, with only the verified dependency search path.
    child = fork(fileURLToPath(import.meta.url), ['--owned-worker', root], {
      cwd: root, execArgv: [], stdio: ['ignore', 'ignore', 'inherit', 'ipc'],
      env: { PATH: dirname(process.execPath), HOME: join(root, 'home'), TMPDIR: join(root, 'tmp'),
        XDG_CONFIG_HOME: join(root, 'home'), XDG_CACHE_HOME: join(root, 'home'),
        WRANGLER_SEND_METRICS: 'false', CI: '1', NODE_PATH: dependencies },
    });
    exited = new Promise(resolve => {
      child.once('error', resolve);
      child.once('exit', resolve);
    });
    function response(message) {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => finish(reject, new Error('Native Worker fixture timed out')), 15_000);
        function finish(callback, value) {
          clearTimeout(timer);
          child.off('message', receive);
          child.off('close', disconnected);
          callback(value);
        }
        function receive(value) { finish(resolve, value); }
        function disconnected() { finish(reject, new Error('Native Worker fixture stopped')); }
        child.once('message', receive);
        child.once('close', disconnected);
        if (message !== undefined) {
          child.send(message, error => { if (error) finish(reject, error); });
        }
      });
    }
    const { origin } = await response();
    const base = new URL(origin);
    assert.equal(base.hostname, '127.0.0.1'); assert.equal(base.protocol, 'http:'); assert.ok(Number(base.port) > 0);
    return {
      origin,
      deliveries: async () => (await response('status')).deliveries,
      takeCode: () => response('take-code'),
      createFreeTeam: () => response('create-free-team'),
      projects: () => response('projects'),
      sessionStates: () => response('session-states'),
      assertNoOutbound: async () => assert.equal((await response('status')).outbound, 0),
      close,
    };
  } catch (error) { await close(); throw error; }
}

async function startWorker(root) {
  assert.equal(await realpath(process.cwd()), root);
  assert.equal(process.env.HOME, join(root, 'home'));
  const require = createRequire(join(cloud, 'package.json'));
  const { devDependencies } = JSON.parse(await readFile(join(cloud, 'package.json'), 'utf8'));
  for (const name of ['esbuild', 'miniflare', 'wrangler']) {
    assert.equal(require(`${name}/package.json`).version, devDependencies[name], `Use the pinned ${name} fixture dependency`);
  }
  const { build } = require('esbuild');
  const { Log, LogLevel, Miniflare, convertV4MiniflareOptions } = require('miniflare');
  const { unstable_splitSqlQuery } = require('wrangler');
  let fixture;
  let outbound = 0;
  try {
    const bundle = join(root, 'worker.mjs');
    await build({ entryPoints: [join(cloud, 'src/index.ts')], outfile: bundle, bundle: true,
      format: 'esm', platform: 'neutral', target: 'es2022', external: ['cloudflare:*'], logLevel: 'silent' });
    const denyOutbound = () => { outbound++; throw new Error('Unexpected fixture outbound request'); };
    const common = { unsafeInspectorProxy: false, compatibilityDate: '2026-10-29', modules: true, outboundService: denyOutbound };
    fixture = new Miniflare(convertV4MiniflareOptions({ host: '127.0.0.1', port: 0, cf: false, telemetry: { enabled: false },
      unsafeLocalExplorer: false, unsafeObservability: false, unsafeEnableSharedStorage: false, logRequests: false,
      log: new Log(LogLevel.ERROR), resourcePersistencePath: join(root, 'state'), resourceTmpPath: join(root, 'tmp'),
      workers: [{ ...common, name: 'scriv', scriptPath: bundle,
        bindings: { PUBLIC_URL: 'http://127.0.0.1', ENVIRONMENT: 'test', EMAIL_FROM: 'sender@example.invalid' },
        serviceBindings: { EMAIL: 'local-mailbox' }, d1Databases: { DB: 'native-journey-db' }, r2Buckets: ['ASSETS'],
        durableObjects: { PROJECTS: { className: 'ProjectRoom', useSQLite: true }, BILLING: { className: 'BillingCoordinator', useSQLite: true } },
      }, { ...common, name: 'local-mailbox', script: `import { WorkerEntrypoint } from 'cloudflare:workers';
        let delivered = 0;
        let code;
        export default class extends WorkerEntrypoint {
          async send(message) {
            const match = /^Your Scriv sign-in code is ([0-9]{6})\\./.exec(message.text);
            if (message.to !== ${JSON.stringify(nativeFixtureEmail)} || message.from.email !== 'sender@example.invalid'
                || message.subject !== 'Your Scriv sign-in code' || !match || code) {
              throw new Error('Invalid synthetic delivery');
            }
            code = match[1];
            delivered++;
          }
          async count() { return delivered; }
          async takeCode() { const value = code; code = undefined; return value ?? null; }
        }` }],
    }));
    const base = await fixture.ready;
    assert.equal(base.hostname, '127.0.0.1'); assert.equal(base.protocol, 'http:'); assert.ok(Number(base.port) > 0);
    const db = await fixture.getD1Database('DB', 'scriv');
    const migrations = (await readdir(join(cloud, 'migrations'))).filter(name => /^\d+_.+\.sql$/.test(name)).sort();
    assert.deepEqual(migrations, ['0001_identity_teams.sql', '0002_generation_jobs.sql', '0003_email_auth.sql']);
    for (const name of migrations) await db.batch(unstable_splitSqlQuery(await readFile(join(cloud, 'migrations', name), 'utf8')).map(sql => db.prepare(sql)));
    const mailbox = await fixture.getWorker('local-mailbox');
    async function post(path, expectedStatus, body, token) {
      const headers = { 'Content-Type': 'application/json' };
      if (token) headers.Authorization = `Bearer ${token}`;
      const response = await fixture.dispatchFetch(new URL(path, base), {
        method: 'POST', headers, body: JSON.stringify(body), redirect: 'error',
      });
      assert.equal(response.status, expectedStatus, `Unexpected fixture status for ${path}`);
      return response.json();
    }
    async function createFreeTeam() {
      // Set up an existing free-team owner through the public Worker. Only the
      // test adapter ever sees this setup session's code or credential.
      const codeVerifier = randomBytes(32).toString('base64url');
      const codeChallenge = createHash('sha256').update(codeVerifier).digest('base64url');
      const { challengeId } = await post('/auth/email/request', 202, { email: nativeFixtureEmail, codeChallenge });
      const code = await mailbox.takeCode();
      assert.ok(typeof code === 'string' && /^\d{6}$/.test(code), 'Fixture delivery must contain a code');
      const { token } = await post('/auth/email/verify', 200, { challengeId, code, codeVerifier, deviceName: 'Team fixture setup' });
      assert.ok(typeof token === 'string' && token.length > 0, 'Fixture authorization was issued');
      try {
        const { team } = await post('/v1/teams', 201, { name: nativeFixtureTeam }, token);
        return { name: team.name, role: team.role, plan: team.plan, billingCustomer: team.billingCustomer };
      } finally {
        await post('/auth/logout', 200, {}, token);
      }
    }
    return { origin: base.origin, createFreeTeam, status: async () => ({ deliveries: await mailbox.count(), outbound }),
      takeCode: () => mailbox.takeCode(),
      projects: async () => (await db.prepare(
        'SELECT projects.id, projects.title FROM projects JOIN users ON projects.owner_id = users.id WHERE email = ? AND archived_at IS NULL ORDER BY projects.id',
      ).bind(nativeFixtureEmail).all()).results,
      sessionStates: async () => (await db.prepare(
        'SELECT revoked_at IS NOT NULL AS revoked FROM sessions JOIN users ON sessions.user_id = users.id WHERE users.email = ? ORDER BY sessions.created_at, sessions.id',
      ).bind(nativeFixtureEmail).all()).results.map(({ revoked }) => ({ revoked: Boolean(revoked) })),
      close: () => fixture.dispose() };
  } catch (error) { await fixture?.dispose(); throw error; }
}

if (process.argv[2] === '--owned-worker' && process.send) {
  const disconnected = new Promise(resolve => process.once('disconnect', resolve));
  const worker = await startWorker(process.argv[3]);
  try {
    process.on('message', async message => {
      const operations = { status: worker.status, 'take-code': worker.takeCode, 'create-free-team': worker.createFreeTeam, projects: worker.projects, 'session-states': worker.sessionStates };
      assert.ok(Object.hasOwn(operations, message));
      const result = await operations[message]();
      if (process.connected) process.send(result);
    });
    if (process.connected) process.send({ origin: worker.origin });
    await disconnected;
  } finally { await worker.close(); }
}
