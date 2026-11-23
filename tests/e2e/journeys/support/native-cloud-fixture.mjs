import assert from 'node:assert/strict';
import { fork } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { mkdtemp, mkdir, readFile, readdir, realpath, rm, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const cloud = fileURLToPath(new URL('../../../../cloud/', import.meta.url));
export const nativeFixtureEmail = 'synthetic-native@example.invalid';
export const nativeFixtureTeam = 'Synthetic Story Team';
export const lostCloudEditReceipt = 'The cloud edit receipt could not be delivered. Try syncing again.';
export const interruptedCloudEdit = 'The connection was interrupted before saving this cloud edit.';
export const invitationLoadFailure = 'Invitation details were temporarily unavailable.';
export const invitationRevokeFailure = 'The invitation could not be revoked. Try again.';

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
      createPaidTeam: () => response('create-paid-team'),
      projects: () => response('projects'),
      projectTeams: () => response('project-teams'),
      sessionStates: () => response('session-states'),
      loseNextEditReceipt: projectId => response(['lose-edit-receipt', projectId]),
      editReceiptState: () => response('edit-receipt-state'),
      matchesPendingEdit: payload => response(['matches-pending-edit', payload]),
      interruptNextEdit: projectId => response(['interrupt-edit', projectId]),
      interruptedEditState: () => response('interrupted-edit-state'),
      watchEditingLease: (projectId, itemId) => response(['watch-editing-lease', { projectId, itemId }]),
      editingLeaseState: () => response('editing-lease-state'),
      watchStagedEdit: (projectId, dropReceipt) => response(['watch-staged-edit', { projectId, dropReceipt }]),
      stagedEditState: () => response('staged-edit-state'),
      prepareHostedImage: input => response(['prepare-hosted-image', input]),
      repairHostedImage: () => response('repair-hosted-image'),
      hostedImageResponses: () => response('hosted-image-responses'),
      prepareSharedGeneration: project => response(['prepare-shared-generation', project]),
      sharedGenerationState: () => response('shared-generation-state'),
      prepareInvitations: () => response('prepare-invitations'),
      interruptInvitationLoad: () => response('interrupt-invitation-load'),
      invitationState: () => response('invitation-state'),
      prepareTeamManagement: () => response('prepare-team-management'),
      addTeamManagementMember: teamId => response(['add-team-management-member', teamId]),
      teamManagementState: () => response('team-management-state'),
      prepareHistoryPages: () => response('prepare-history-pages'),
      changeHistoryPage: mode => response(['change-history-page', mode]),
      historyPageState: () => response('history-page-state'),
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
    const harness = join(root, 'native-worker.mjs');
    // Forward the exact request to the real Worker before dropping its first
    // receipt. Control is private RPC, with no additional public HTTP route.
    await writeFile(harness, `import { WorkerEntrypoint } from 'cloudflare:workers';
      import worker from './worker.mjs';
      export * from './worker.mjs';
      let target;
      let pending;
      let receipt;
      let attempts = 0;
      let interruption;
      let hostedImagePath;
      const hostedImageResponses = [];
      let invitations;
      let history;
      let editingLease;
      let stagedEdit;
      const withoutLeases = operations => JSON.stringify(operations.map(({ lease, ...item }) => item));
      const sameLease = (left, right) => left.token === right.token && left.fence === right.fence;
      async function interruptedCommand(payload, upstream) {
        const state = interruption;
        switch (state.phase) {
        case 'armed': {
          const item = payload.operations.find(item => item.kind === 'entry' && item.lease);
          if (!item || payload.label !== 'Edit script') throw new Error('Expected a leased script edit');
          Object.assign(state, { phase: 'interrupted', draft: payload, item });
          return Response.json({ error: { code: 'connection_interrupted', message: ${JSON.stringify(interruptedCloudEdit)} } }, { status: 503 });
        }
        case 'interrupted': {
          if (!state.leaseReleased || JSON.stringify(payload) !== JSON.stringify(state.draft)) throw new Error('Expected the original saved command after the app released its lease');
          const response = await upstream();
          const code = (await response.clone().json()).error?.code;
          if (response.status !== 423 || code !== 'lease_required') throw new Error('The Worker did not reject the expired lease');
          Object.assign(state, { phase: 'rejected', retryStatus: response.status, retryCode: code });
          return response;
        }
        case 'rejected': {
          if (payload.commandId === state.draft.commandId || payload.label !== 'Sync offline edits'
              || withoutLeases(payload.operations) !== withoutLeases(state.draft.operations)) throw new Error('Reconciliation changed the saved edit');
          const response = await upstream();
          const observed = await response.clone().json();
          if (!response.ok || observed.commandId !== payload.commandId || !Number.isSafeInteger(observed.seq)) throw new Error('The Worker did not accept the reconciled edit');
          Object.assign(state, { phase: 'reconciled', replacementID: observed.commandId, sequence: observed.seq });
          return response;
        }
        }
      }
      export default class extends WorkerEntrypoint {
        async fetch(request) {
          const upstream = () => worker.fetch(request, this.env, this.ctx);
          const { pathname: path, searchParams } = new URL(request.url);
          if (stagedEdit && (path === stagedEdit.path || path.startsWith(stagedEdit.path + '/'))) {
            const route = path.slice(stagedEdit.path.length);
            const payload = await request.clone().json();
            const response = await upstream();
            const reply = await response.clone().json();
            const entry = { route, method: request.method, status: response.status };
            if (request.method === 'PUT') {
              const bytes = new TextEncoder().encode(payload.content);
              const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
              entry.part = { bytes: bytes.byteLength, hash: Array.from(digest, n => n.toString(16).padStart(2, '0')).join(''),
                operations: JSON.parse(payload.content) };
            } else {
              entry.manifest = { commandID: payload.commandId, label: payload.label, count: payload.operationCount, parts: payload.parts };
              entry.reply = { commandID: reply.commandId, staged: reply.staged, sequence: reply.seq };
            }
            stagedEdit.requests.push(entry);
            if (stagedEdit.dropReceipt && route.endsWith('/commit') && response.ok) {
              stagedEdit.dropReceipt = false;
              return Response.json({ error: { code: 'receipt_unavailable', message: ${JSON.stringify(lostCloudEditReceipt)} } }, { status: 503 });
            }
            return response;
          }
          if (history && request.method === 'GET' && path === history.path + '/history') {
            const response = await upstream();
            if (response.ok) {
              const page = await response.clone().json();
              const after = Number(searchParams.get('after'));
              const record = { after, count: page.events.length, hasMore: page.hasMore };
              if (!history.events.some(item => item.after === after)) history.events.push(record);
            }
            return response;
          }
          if (history && request.method === 'GET' && path === history.path + '/snapshot'
              && searchParams.get('seq') === String(history.seq)) {
            const response = await upstream();
            if (!response.ok) return response;
            const page = await response.clone().json(), after = searchParams.get('after') ?? '';
            const mode = history.mode;
            history.snapshots.push({ after, next: page.nextCursor, count: page.items.length });
            if (mode === 'wrong-revision' && !after) page.headSeq++;
            else if (mode === 'different-epoch' && after) page.epoch++;
            else if (mode === 'repeated-cursor' && after) {
              page.hasMore = true;
              page.nextCursor = after;
            } else return response;
            history.mode = null;
            return Response.json(page);
          }
          if (invitations && request.method === 'GET' && path === invitations.teamPath && invitations.interruptLoad) {
            invitations.interruptLoad = false;
            invitations.interruptedLoads++;
            return Response.json({ error: { code: 'fixture_unavailable', message: ${JSON.stringify(invitationLoadFailure)} } }, { status: 503 });
          }
          if (invitations && request.method === 'DELETE' && path === invitations.revokePath) {
            if (!invitations.revocations.length) {
              invitations.revocations.push(503);
              return Response.json({ error: { code: 'fixture_unavailable', message: ${JSON.stringify(invitationRevokeFailure)} } }, { status: 503 });
            }
            const response = await upstream();
            invitations.revocations.push(response.status);
            return response;
          }
          if (request.method === 'GET' && path === hostedImagePath) {
            const response = await upstream();
            hostedImageResponses.push(response.status);
            return response;
          }
          if (editingLease && path === editingLease.path + '/leases' && ['POST', 'PUT'].includes(request.method)) {
            const proof = await request.clone().json();
            if (proof.itemId === editingLease.itemId) {
              if (request.method === 'POST') {
                const response = await upstream();
                if (response.ok && !editingLease.initial) editingLease.initial = await response.clone().json();
                return response;
              }
              const { initial, renewals } = editingLease;
              if (!initial || !sameLease(proof, initial) || proof.sessionId !== initial.sessionId || proof.epoch !== initial.epoch)
                throw new Error('Expected renewal of the watched editing lease');
              if (renewals.length === 1) {
                // Release the exact lease through the real authenticated Worker
                // API before forwarding the second renewal. No manufactured reply.
                const released = await worker.fetch(new Request(request.clone(), { method: 'DELETE' }), this.env, this.ctx);
                if (!released.ok) throw new Error('The local Worker did not release the watched lease');
              }
              const response = await upstream();
              const result = await response.clone().json();
              if (response.ok && !sameLease(result, initial)) throw new Error('Renewal changed lease proof');
              renewals.push({ status: response.status, expiresAt: response.ok ? result.expiresAt : null });
              return response;
            }
          }
          if (editingLease?.initial && request.method === 'POST' && path === editingLease.path + '/commands') {
            const payload = await request.clone().json();
            const response = await upstream();
            if (response.ok && payload.operations.some(item => item.id === editingLease.itemId
                && item.lease && sameLease(item.lease, editingLease.initial))) editingLease.acceptedEdits++;
            return response;
          }
          if (interruption?.phase === 'interrupted' && request.method === 'DELETE' && path === target.replace(/commands$/, 'leases')) {
            const released = await request.clone().json();
            const response = await upstream();
            const { item, draft } = interruption;
            if (response.ok && released.itemId === item.id && released.token === item.lease.token
                && released.fence === item.lease.fence && released.sessionId === draft.sessionId) interruption.leaseReleased = true;
            return response;
          }
          if (!target || request.method !== 'POST' || path !== target) return upstream();
          const payload = await request.clone().json();
          if (interruption && interruption.phase !== 'reconciled') return interruptedCommand(payload, upstream);
          if (receipt && attempts >= 2 && payload.commandId !== receipt.commandId) return upstream();
          const serialized = JSON.stringify(payload);
          if (pending !== undefined && pending !== serialized) throw new Error('The saved edit changed before its receipt was retried');
          pending = serialized;
          const response = await upstream();
          if (!response.ok) return response;
          const observed = await response.clone().json();
          if (observed.commandId !== payload.commandId || !Number.isSafeInteger(observed.seq)
              || receipt && JSON.stringify(observed) !== JSON.stringify(receipt)) throw new Error('The Worker returned a different edit receipt');
          receipt = observed;
          attempts++;
          if (attempts !== 1) return response;
          return Response.json({ error: { code: 'receipt_unavailable', message: ${JSON.stringify(lostCloudEditReceipt)} } }, { status: 503 });
        }
        scheduled(event) { return worker.scheduled(event, this.env, this.ctx); }
        loseEditReceipt(projectId) {
          if (target || typeof projectId !== 'string' || !/^[a-zA-Z0-9_-]{1,64}$/.test(projectId)) throw new Error('A single owned project is required');
          target = '/v1/projects/' + projectId + '/commands';
          return true;
        }
        editReceiptState() { return { attempts, commandID: receipt?.commandId ?? null, sequence: receipt?.seq ?? null }; }
        matchesPendingEdit(payload) { return pending !== undefined && pending === JSON.stringify(payload); }
        interruptEdit(projectId) {
          if (interruption || attempts !== 2 || target !== '/v1/projects/' + projectId + '/commands') throw new Error('Use the same isolated project after the receipt recovery');
          interruption = { phase: 'armed', leaseReleased: false };
          return true;
        }
        interruptedEditState() {
          const { phase, leaseReleased, draft, retryStatus, retryCode, replacementID, sequence } = interruption;
          return { phase, leaseReleased, commandID: draft?.commandId, retryStatus, retryCode, replacementID, sequence };
        }
        watchEditingLease({ projectId, itemId }) {
          if (editingLease || ![projectId, itemId].every(id => typeof id === 'string' && /^[a-zA-Z0-9_-]{1,64}$/.test(id)))
            throw new Error('A single owned editing lease is required');
          editingLease = { path: '/v1/projects/' + projectId, itemId, renewals: [], acceptedEdits: 0 };
          return true;
        }
        editingLeaseState() {
          if (!editingLease) throw new Error('No editing lease is being observed');
          return { initialExpiresAt: editingLease.initial?.expiresAt ?? null, renewals: [...editingLease.renewals], acceptedEdits: editingLease.acceptedEdits };
        }
        watchStagedEdit({ projectId, dropReceipt }) {
          if (stagedEdit || typeof dropReceipt !== 'boolean' || typeof projectId !== 'string'
              || !/^[a-zA-Z0-9_-]{1,64}$/.test(projectId))
            throw new Error('A single owned staged edit is required');
          stagedEdit = { path: '/v1/projects/' + projectId + '/batches', requests: [], dropReceipt };
          return true;
        }
        stagedEditState() { return stagedEdit.requests; }
        watchHostedImage(path) {
          if (hostedImagePath) throw new Error('A hosted image is already being observed');
          hostedImagePath = path;
        }
        hostedImageResponses() { return [...hostedImageResponses]; }
        watchInvitations(teamPath, revokePath) {
          if (invitations) throw new Error('A single owned invitation test is supported');
          invitations = { teamPath, revokePath, interruptLoad: false, interruptedLoads: 0, revocations: [] };
        }
        interruptInvitationLoad() {
          if (!invitations || invitations.interruptLoad || invitations.interruptedLoads) throw new Error('Use the one owned invitation load interruption');
          invitations.interruptLoad = true;
          return true;
        }
        invitationRequests() { return { interruptedLoads: invitations.interruptedLoads, revocations: [...invitations.revocations] }; }
        watchHistory(path, seq) {
          if (history || !Number.isSafeInteger(seq)) throw new Error('Use one owned project import revision');
          history = { path, seq, events: [], snapshots: [], mode: null };
        }
        changeHistoryPage(mode) {
          if (!history || history.mode || ![null, 'wrong-revision', 'different-epoch', 'repeated-cursor'].includes(mode))
            throw new Error('Use one owned historical response fault at a time');
          history.snapshots = [];
          history.mode = mode;
          return true;
        }
        historyPageState() {
          return { events: history.events, snapshots: history.snapshots, pending: history.mode };
        }
      }`, { mode: 0o600 });
    const denyOutbound = () => { outbound++; throw new Error('Unexpected fixture outbound request'); };
    const common = { unsafeInspectorProxy: false, compatibilityDate: '2026-10-29', modules: true, outboundService: denyOutbound };
    fixture = new Miniflare(convertV4MiniflareOptions({ host: '127.0.0.1', port: 0, cf: false, telemetry: { enabled: false },
      unsafeLocalExplorer: false, unsafeObservability: false, unsafeEnableSharedStorage: false, logRequests: false,
      log: new Log(LogLevel.ERROR), resourcePersistencePath: join(root, 'state'), resourceTmpPath: join(root, 'tmp'),
      workers: [{ ...common, name: 'scriv', modulesRoot: root,
        modules: [{ type: 'ESModule', path: harness }, { type: 'ESModule', path: bundle }],
        bindings: { PUBLIC_URL: 'http://127.0.0.1', ENVIRONMENT: 'test', EMAIL_FROM: 'sender@example.invalid' },
        serviceBindings: { EMAIL: 'local-mailbox' }, d1Databases: { DB: 'native-journey-db' }, r2Buckets: ['MEDIA'],
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
    const nativeWorker = await fixture.getWorker('scriv');
    async function post(path, expectedStatus, body, token) {
      const headers = { 'Content-Type': 'application/json' };
      if (token) headers.Authorization = `Bearer ${token}`;
      const response = await fixture.dispatchFetch(new URL(path, base), {
        method: 'POST', headers, body: JSON.stringify(body), redirect: 'error',
      });
      assert.equal(response.status, expectedStatus, `Unexpected fixture status for ${path}`);
      return response.json();
    }
    async function withFixtureOwner(action) {
      // Only the test adapter ever sees this setup session's code or credential.
      const codeVerifier = randomBytes(32).toString('base64url');
      const codeChallenge = createHash('sha256').update(codeVerifier).digest('base64url');
      const { challengeId } = await post('/auth/email/request', 202, { email: nativeFixtureEmail, codeChallenge });
      const code = await mailbox.takeCode();
      assert.ok(typeof code === 'string' && /^\d{6}$/.test(code), 'Fixture delivery must contain a code');
      const { token } = await post('/auth/email/verify', 200, { challengeId, code, codeVerifier, deviceName: 'Team fixture setup' });
      assert.ok(typeof token === 'string' && token.length > 0, 'Fixture authorization was issued');
      try { return await action(token); }
      finally { await post('/auth/logout', 200, {}, token); }
    }
    function createFreeTeam() {
      return withFixtureOwner(async token => {
        const { team } = await post('/v1/teams', 201, { name: nativeFixtureTeam }, token);
        return { name: team.name, role: team.role, plan: team.plan, billingCustomer: team.billingCustomer };
      });
    }
    async function seedPaidTeam(token) {
      const { team } = await post('/v1/teams', 201, { name: nativeFixtureTeam }, token);
      await db.prepare("UPDATE teams SET subscription_status='active', paid_until=? WHERE id=?")
        .bind(Date.now() + 5 * 60_000, team.id).run();
      return team;
    }
    async function seedProject(project, token, teamId) {
      const { project: remote } = await post('/v1/projects', 201, { title: project.title, teamId }, token);
      const path = '/v1/projects/' + remote.id;
      const headers = { Authorization: `Bearer ${token}` };
      const me = await fixture.dispatchFetch(new URL('/v1/me', base), { headers, redirect: 'error' });
      assert.equal(me.status, 200);
      const { sessionId } = await me.json();
      const groups = { scene: project.scenes, entry: project.entries, character: project.characters, image: project.images, cue: project.cues };
      const items = Object.entries(groups).flatMap(([kind, values]) => values.map(data => ({ id: data.id, kind, data })));
      const imported = await post(path + '/import', 200,
        { commandId: randomUUID(), sessionId, epoch: 1, expectedTimingVersion: 0, items }, token);
      assert.equal(imported.snapshotRequired, true);
      return { id: remote.id, path, teamId, headers, importSeq: imported.seq };
    }
    async function seedPaidTeamProject(project, token) {
      const team = await seedPaidTeam(token);
      return seedProject(project, token, team.id);
    }
    function prepareHistoryPages() {
      return withFixtureOwner(async token => {
        const title = 'Synthetic paged history';
        const scene = { id: 'history-scene', title: 'Paged script', order: 0 };
        const entries = Array.from({ length: 205 }, (_, order) => ({
          id: 'history-line-' + String(order).padStart(3, '0'), sceneId: scene.id, order, kind: 'direction',
          text: 'Historical direction ' + (order + 1), ownedDurationMs: 100, coverageDurationMs: 100,
          color: 'purple', words: [], characterLinks: [],
        }));
        const project = { title, scenes: [scene], entries, characters: [], images: [], cues: [] };
        const saved = await seedProject(project, token);
        const threads = saved.path + '/threads';
        const { thread } = await post(threads, 201, { itemId: null }, token);
        for (let index = 0; index < 100; index++) {
          await post(threads + '/' + thread.id + '/messages', 201,
            { id: randomUUID(), body: 'Synthetic history activity ' + (index + 1) }, token);
        }
        await nativeWorker.watchHistory(saved.path, saved.importSeq);
        return { id: saved.id, title, entries, importSeq: saved.importSeq };
      });
    }
    let sharedProjectID;
    async function prepareSharedGeneration(project) {
      assert.equal(sharedProjectID, undefined);
      assert.deepEqual(project.images, []);
      const seeded = await withFixtureOwner(token => seedPaidTeamProject(project, token));
      sharedProjectID = seeded.id;
      return { projectID: sharedProjectID };
    }
    async function sharedGenerationState() {
      assert.ok(sharedProjectID);
      const { results: jobs } = await db.prepare(`SELECT id, target_item_id AS cueID, source_revision AS sourceRevision,
        status, progress_text AS progress, version, lease_expires_at AS leaseExpiresAt,
        output_image_id AS imageID, error_code AS errorCode FROM generation_jobs WHERE project_id=? ORDER BY created_at,id`)
        .bind(sharedProjectID).all();
      const { results: operations } = await db.prepare(`SELECT o.job_id AS jobID, o.resulting_version AS version,
        o.actor_session_id=j.owner_device_id AS owner FROM generation_job_operations o JOIN generation_jobs j
        ON o.project_id=j.project_id AND o.job_id=j.id WHERE o.project_id=? ORDER BY o.job_id,o.resulting_version`)
        .bind(sharedProjectID).all();
      const { results: assets } = await db.prepare("SELECT asset_id, sha256, object_key FROM assets WHERE project_id=? AND state='ready' ORDER BY sha256")
        .bind(sharedProjectID).all();
      const bucket = await fixture.getR2Bucket('MEDIA', 'scriv');
      const hosted = await Promise.all(assets.map(async asset => {
        const object = await bucket.get(asset.object_key);
        assert.ok(object, 'The ready asset has actual hosted bytes');
        const data = Buffer.from(await object.arrayBuffer());
        assert.equal(createHash('sha256').update(data).digest('hex'), asset.sha256);
        return { id: asset.asset_id, sha256: asset.sha256, bytes: data.length };
      }));
      return { jobs, operations, hosted };
    }
    let hostedImage;
    async function prepareHostedImage({ project, png }) {
      assert.equal(hostedImage, undefined);
      const [image, ...otherImages] = project.images;
      const bytes = Buffer.from(png, 'base64');
      assert.equal(otherImages.length, 0);
      assert.equal(image.mimeType, 'image/png');
      assert.equal(image.byteCount, bytes.length);
      assert.equal(image.sha256, createHash('sha256').update(bytes).digest('hex'));
      return withFixtureOwner(async token => {
        const { id, path: projectPath, teamId, headers } = await seedPaidTeamProject(project, token);
        const assetPath = projectPath + '/assets/' + image.sha256;
        const uploaded = await fixture.dispatchFetch(new URL(assetPath, base), { method: 'PUT', body: bytes, redirect: 'error',
          headers: { ...headers, 'Content-Type': image.mimeType, 'X-Scriv-Asset-Id': image.id } });
        assert.equal(uploaded.status, 201);
        assert.deepEqual(await uploaded.json(), { sha256: image.sha256, bytes: bytes.length, hosted: true });
        const { object_key: key } = await db.prepare("SELECT object_key FROM assets WHERE project_id=? AND sha256=? AND state='ready'")
          .bind(id, image.sha256).first();
        const bucket = await fixture.getR2Bucket('MEDIA', 'scriv');
        hostedImage = { bucket, key, bytes };
        const corrupt = Buffer.from(bytes);
        corrupt[corrupt.length - 1] ^= 1;
        await bucket.put(key, corrupt);
        // The owner can still read the hosted copy after the test team lapses.
        await db.prepare("UPDATE teams SET subscription_status='canceled', paid_until=? WHERE id=?")
          .bind(Date.now() - 1000, teamId).run();
        await nativeWorker.watchHostedImage(assetPath);
        return { projectID: id };
      });
    }
    async function repairHostedImage() {
      const { bucket, key, bytes } = hostedImage;
      assert.deepEqual(await nativeWorker.hostedImageResponses(), [200]);
      await bucket.put(key, bytes);
      return true;
    }
    let invitationTeamID;
    async function prepareInvitations() {
      assert.equal(invitationTeamID, undefined);
      return withFixtureOwner(async token => {
        const team = await seedPaidTeam(token);
        invitationTeamID = team.id;
        const teamPath = '/v1/teams/' + team.id;
        const linksPath = teamPath + '/join-links';
        const { link: member } = await post(linksPath, 201, { role: 'member', expiresInDays: 7 }, token);
        const { link: viewer } = await post(linksPath, 201, { role: 'viewer', expiresInDays: 1 }, token);
        // The older link is an expired fixture. Neither secret leaves this Worker process.
        await db.prepare('UPDATE join_links SET expires_at=? WHERE team_id=? AND id=?')
          .bind(Date.now() - 1000, team.id, viewer.id).run();
        await nativeWorker.watchInvitations(teamPath, linksPath + '/' + member.id);
        return { memberID: member.id, viewerID: viewer.id };
      });
    }
    async function invitationState() {
      assert.ok(invitationTeamID);
      const { results: links } = await db.prepare('SELECT id,role,expires_at AS expiresAt,revoked_at AS revokedAt FROM join_links WHERE team_id=? ORDER BY role')
        .bind(invitationTeamID).all();
      const { results: members } = await db.prepare('SELECT role FROM team_members WHERE team_id=? ORDER BY role')
        .bind(invitationTeamID).all();
      return { links, members, ...await nativeWorker.invitationRequests() };
    }
    let managementMember;
    async function prepareTeamManagement() {
      assert.equal(managementMember, undefined);
      const other = randomUUID(), team = randomUUID(), now = Date.now();
      const invitation = randomBytes(32).toString('base64url');
      await db.batch([
        db.prepare('INSERT INTO users(id,github_id,name,created_at) VALUES(?,?,?,?)')
          .bind(other, 'fixture-' + other, 'Synthetic collaborator', now),
        db.prepare("INSERT INTO teams(id,name,owner_id,created_at,subscription_status,paid_until) VALUES(?,?,?,?,'active',?)")
          .bind(team, 'Synthetic guest Team', other, now, now + 300000),
        db.prepare("INSERT INTO team_members(team_id,user_id,role,joined_at) VALUES(?,?,'owner',?)").bind(team, other, now),
        db.prepare("INSERT INTO join_links(id,team_id,token_hash,role,created_by,created_at,expires_at) VALUES(?,?,?,'viewer',?,?,?)")
          .bind(randomUUID(), team, createHash('sha256').update(invitation).digest('hex'), other, now, now + 300000),
      ]);
      managementMember = other;
      return { memberID: other, invitedTeamID: team, invitation };
    }
    async function addTeamManagementMember(teamId) {
      assert.ok(managementMember);
      const team = await db.prepare('SELECT teams.id FROM teams JOIN users ON users.id=teams.owner_id WHERE teams.id=? AND users.email=?')
        .bind(teamId, nativeFixtureEmail).first();
      assert.equal(team?.id, teamId);
      await db.prepare("INSERT INTO team_members(team_id,user_id,role,joined_at) VALUES(?,?,'member',?)")
        .bind(teamId, managementMember, Date.now()).run();
      return true;
    }
    async function teamManagementState() {
      assert.ok(managementMember);
      const self = await db.prepare('SELECT id FROM users WHERE email=?').bind(nativeFixtureEmail).first();
      const { results: teams } = await db.prepare('SELECT id,name,subscription_status AS status FROM teams ORDER BY id').all();
      const { results: members } = await db.prepare('SELECT team_id AS teamID,user_id AS memberID,role FROM team_members ORDER BY team_id,user_id').all();
      return { selfID: self?.id ?? null, teams, members };
    }
    return { origin: base.origin, createFreeTeam,
      createPaidTeam: () => withFixtureOwner(async token => ({ id: (await seedPaidTeam(token)).id })),
      status: async () => ({ deliveries: await mailbox.count(), outbound }),
      loseEditReceipt: projectId => nativeWorker.loseEditReceipt(projectId),
      editReceiptState: () => nativeWorker.editReceiptState(),
      matchesPendingEdit: payload => nativeWorker.matchesPendingEdit(payload),
      interruptEdit: projectId => nativeWorker.interruptEdit(projectId),
      interruptedEditState: () => nativeWorker.interruptedEditState(),
      watchEditingLease: scope => nativeWorker.watchEditingLease(scope), editingLeaseState: () => nativeWorker.editingLeaseState(),
      watchStagedEdit: id => nativeWorker.watchStagedEdit(id), stagedEditState: () => nativeWorker.stagedEditState(),
      prepareHostedImage, repairHostedImage, hostedImageResponses: () => nativeWorker.hostedImageResponses(),
      prepareSharedGeneration, sharedGenerationState,
      prepareInvitations, invitationState, interruptInvitationLoad: () => nativeWorker.interruptInvitationLoad(),
      prepareTeamManagement, addTeamManagementMember, teamManagementState,
      prepareHistoryPages, changeHistoryPage: mode => nativeWorker.changeHistoryPage(mode),
      historyPageState: () => nativeWorker.historyPageState(),
      takeCode: () => mailbox.takeCode(),
      projects: async () => (await db.prepare(
        'SELECT projects.id, projects.title FROM projects JOIN users ON projects.owner_id = users.id WHERE email = ? AND archived_at IS NULL ORDER BY projects.id',
      ).bind(nativeFixtureEmail).all()).results,
      projectTeams: async () => (await db.prepare(
        'SELECT projects.id, projects.title, projects.team_id AS teamId FROM projects JOIN users ON projects.owner_id = users.id WHERE email = ? AND archived_at IS NULL ORDER BY projects.title, projects.id',
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
      const [operation, value] = Array.isArray(message) ? message : [message];
      const operations = { status: worker.status, 'take-code': worker.takeCode, 'create-free-team': worker.createFreeTeam,
        'create-paid-team': worker.createPaidTeam, projects: worker.projects, 'project-teams': worker.projectTeams,
        'session-states': worker.sessionStates, 'lose-edit-receipt': worker.loseEditReceipt,
        'edit-receipt-state': worker.editReceiptState, 'matches-pending-edit': worker.matchesPendingEdit,
        'interrupt-edit': worker.interruptEdit, 'interrupted-edit-state': worker.interruptedEditState,
        'watch-editing-lease': worker.watchEditingLease, 'editing-lease-state': worker.editingLeaseState,
        'prepare-hosted-image': worker.prepareHostedImage, 'repair-hosted-image': worker.repairHostedImage,
        'watch-staged-edit': worker.watchStagedEdit, 'staged-edit-state': worker.stagedEditState,
        'hosted-image-responses': worker.hostedImageResponses, 'prepare-shared-generation': worker.prepareSharedGeneration,
        'shared-generation-state': worker.sharedGenerationState, 'prepare-invitations': worker.prepareInvitations,
        'interrupt-invitation-load': worker.interruptInvitationLoad, 'invitation-state': worker.invitationState,
        'prepare-team-management': worker.prepareTeamManagement, 'add-team-management-member': worker.addTeamManagementMember,
        'team-management-state': worker.teamManagementState,
        'prepare-history-pages': worker.prepareHistoryPages, 'change-history-page': worker.changeHistoryPage,
        'history-page-state': worker.historyPageState };
      assert.ok(Object.hasOwn(operations, operation));
      const result = await operations[operation](value);
      if (process.connected) process.send(result);
    });
    if (process.connected) process.send({ origin: worker.origin });
    await disconnected;
  } finally { await worker.close(); }
}
