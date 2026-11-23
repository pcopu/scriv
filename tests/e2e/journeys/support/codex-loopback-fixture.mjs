import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { lstat, realpath, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { basename, dirname, join } from 'node:path';

const model = 'scriv-fixture';
const secondModel = 'scriv-fixture-extra';
const catalogCursor = 'fixture-catalog-page-2';
const refusal = 'Synthetic image turn refused';
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4EGADRAwQCgAsbgXx43oYYAAAAABJRU5ErkJggg==', 'base64');
const recoveredPng = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGNYEKIGRAwQCgAgzgRpm+PgmAAAAABJRU5ErkJggg==', 'base64');
export const fixtureImageHash = createHash('sha256').update(png).digest('hex');
export const recoveredImageHash = createHash('sha256').update(recoveredPng).digest('hex');
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const providerMethods = new Set(['item/commandExecution/requestApproval', 'item/fileChange/requestApproval',
  'item/permissions/requestApproval', 'mcpServer/elicitation/request', 'item/tool/requestUserInput', 'fixture/unsupported']);
const activeRequests = new Map([
  ['input-request', 'item/tool/requestUserInput'],
  ['analysis-approval', 'item/permissions/requestApproval'],
]);

// Model the app-server protocol at its socket boundary. No backend, account,
// tools, credentials, arbitrary file names, or real model are available here.
export function createCodexFixtureProtocol(root, outcomes, { accountRefresh = false, manualAccountCheck = false, ownedPort } = {}) {
  const handshake = ['initialize', 'initialized', 'account/read', 'model/list'];
  const anonymous = { account: null, requiresOpenaiAuth: true };
  const updated = { method: 'account/updated', params: {} };
  function finishLogin(loginId, success) {
    const params = { loginId, success };
    if (!success) params.error = 'Synthetic sign-in was declined';
    return { method: 'account/login/start', notice: { method: 'account/login/completed', params },
      reply: { result: { loginId, authUrl: `https://127.0.0.1:${ownedPort}/fixture-login` } } };
  }
  if (manualAccountCheck) {
    assert.ok(!accountRefresh && outcomes.length === 0, 'Manual account checks own the entire fixture');
    assert.ok(Number.isInteger(ownedPort) && ownedPort > 0 && ownedPort <= 65535, 'The sign-in fixture uses its own loopback port');
  }
  const manualAccountSteps = manualAccountCheck ? [
    { method: 'account/login/start', reply: { result: { loginId: 'synthetic-rejected-login', authUrl: 'http://127.0.0.1/fixture-login' } } },
    { method: 'account/read', reply: { result: anonymous } },
    { method: 'model/list' },
    finishLogin('synthetic-early-decline', false),
    finishLogin('synthetic-early-success', true),
    { method: 'account/read', reply: { result: { account: { type: 'chatgpt', email: 'signed-in-fixture@example.invalid' }, requiresOpenaiAuth: true } } },
    { method: 'model/list', reply: { result: { data: [{ model: 'scriv-fixture-after-login', isDefault: true }], nextCursor: null } } },
    { method: 'account/read', announce: true, notice: updated,
      reply: { result: { account: { type: 'chatgpt', email: 'stale-fixture@example.invalid' }, requiresOpenaiAuth: true } } },
    { method: 'account/read', notice: updated, reply: { error: { code: -32000, message: 'Superseded synthetic account error' } } },
    { method: 'account/read', reply: { result: anonymous } },
    { method: 'account/read', reply: { error: { code: -32000, message: 'Synthetic account refresh failed' } } },
  ] : [];
  const accountUpdates = accountRefresh ? [
    { result: { account: { type: 'chatgpt', email: 'synthetic-account@example.invalid' }, requiresOpenaiAuth: true } },
    { result: { account: { type: '' }, requiresOpenaiAuth: true } },
    { error: { code: -32000, message: 'Synthetic account check interrupted' } },
    { result: { account: null, requiresOpenaiAuth: true } },
    { result: { account: null, requiresOpenaiAuth: false } },
  ] : [];
  const expected = [...handshake, ...manualAccountSteps.map(step => step.method), ...accountUpdates.map(() => 'account/read'), ...outcomes.flatMap(outcome => {
    const turn = ['thread/start', 'turn/start'];
    if (outcome === 'cancel') return [...turn, 'turn/interrupt', 'transport-drop', ...handshake, 'model/list', 'thread/read', 'thread/read', 'thread/read'];
    if (outcome === 'recover' || outcome === 'missing-artifact') return [...turn, 'turn/interrupt', 'thread/read'];
    if (outcome === 'analysis-invalid-thread') return ['thread/start'];
    if (outcome === 'analysis-tool' || activeRequests.has(outcome)) return [...turn, 'turn/interrupt'];
    return turn;
  })];
  let position = 0;
  let reconnecting = false;
  let job;
  let count = 0;
  let accountUpdateAnnounced = false;
  const requestIDs = new Set();
  const jobDirectories = new Set();
  async function receive({ id, method, params }) {
    // Only print the fixture's expected method, never incoming arbitrary data.
    assert.ok(method === expected[position] && typeof method === 'string', `Unexpected fixture message; expected ${expected[position] ?? 'disconnect'}`);
    position++;
    if (method === 'initialized') {
      assert.equal(id, undefined);
      return [];
    }
    assert.ok(Number.isSafeInteger(id) && id > 0 && !requestIDs.has(id), 'Fixture requires a distinct numeric request ID');
    requestIDs.add(id);
    const reply = result => ({ id, result });
    const accountStep = manualAccountSteps[position - handshake.length - 1];
    const accountReplies = () => [...(accountStep.notice ? [accountStep.notice] : []), { id, ...accountStep.reply }];
    switch (method) {
    case 'initialize':
      assert.equal(params.clientInfo.name, 'scriv_mac');
      return [reply({ userAgent: 'Scriv local fixture' })];
    case 'account/read': {
      assert.equal(params.refreshToken, false);
      if (manualAccountCheck) {
        if (!accountStep) return [reply(anonymous)];
        if (accountStep.announce) {
          assert.equal(accountUpdateAnnounced, true, 'The burst begins with a scheduled provider notice');
          accountUpdateAnnounced = false;
        }
        return accountReplies();
      }
      const update = accountUpdates[position - handshake.length - 1];
      if (update) {
        assert.equal(accountUpdateAnnounced, true, 'A refresh must follow the owned account update notice');
        accountUpdateAnnounced = false;
        return [{ id, ...update }];
      }
      return [reply({ account: null, requiresOpenaiAuth: false })];
    }
    case 'account/login/start':
      assert.deepEqual(params, { type: 'chatgpt' });
      return accountReplies();
    case 'model/list': {
      assert.equal(params.includeHidden, false);
      if (accountStep?.reply) return accountReplies();
      const defaultModel = { id: model, model, isDefault: true, inputModalities: ['text', 'image'] };
      if (params.cursor === undefined) {
        return [reply({ data: [defaultModel], nextCursor: reconnecting ? catalogCursor : null })];
      }
      assert.equal(params.cursor, catalogCursor);
      const extraModel = { id: secondModel, model: secondModel, inputModalities: ['text'] };
      return [reply({ data: [defaultModel, extraModel], nextCursor: null })];
    }
    case 'thread/start': {
      const generation = join(typeof root === 'function' ? root() : root, 'Generation');
      const outcome = outcomes[count++];
      const analysis = outcome.startsWith('analysis-');
      // Resolve the app-created directory and tie it to this session's owned
      // verification root. A foreign path or symlink cannot receive an image.
      assert.equal(params.approvalPolicy, 'never');
      assert.equal(params.sandbox, analysis ? 'read-only' : 'workspace-write');
      assert.equal(params.model, model);
      const usualDir = params.cwd;
      assert.ok(typeof usualDir === 'string' && uuid.test(basename(usualDir)), 'Expected a generated job ID');
      const cwd = join(generation, basename(usualDir));
      assert.equal(await realpath(cwd), cwd, 'Job directories must be canonical and owned by this run');
      assert.equal(await realpath(usualDir), cwd, 'Fixture refuses another job directory');
      const info = await lstat(cwd);
      assert.ok(dirname(cwd) === generation && info.isDirectory() && !info.isSymbolicLink() && info.uid === process.getuid()
        && !jobDirectories.has(cwd), 'Expected a fresh app-owned job directory');
      jobDirectories.add(cwd);
      job = { outcome, cwd, threadId: `fixture-thread-${count}`, turnId: `fixture-turn-${count}`, inspections: 0 };
      if (analysis) {
        assert.equal(params.ephemeral, true);
        assert.ok(params.developerInstructions?.includes('Do not call tools'));
        return [reply({ thread: { id: job.threadId, ephemeral: true }, model, cwd,
          sandbox: { type: 'readOnly', networkAccess: outcome === 'analysis-invalid-thread' }, approvalPolicy: 'never' })];
      }
      return [reply({ thread: { id: job.threadId } })];
    }
    case 'turn/start': {
      assert.equal(params.threadId, job.threadId);
      if (job.outcome.startsWith('analysis-')) {
        assert.equal(params.cwd, job.cwd);
        assert.equal(params.approvalPolicy, 'never');
        assert.deepEqual(params.sandboxPolicy, { type: 'readOnly', networkAccess: false });
        assert.deepEqual(params.outputSchema.required, ['detections']);
        const [prompt, preview, ...extra] = params.input;
        assert.deepEqual(extra, []);
        assert.equal(prompt.type, 'text');
        assert.ok(prompt.text.includes('Green coat') && prompt.text.includes('one two three'));
        assert.equal(preview.type, 'image');
        const base64 = /^data:image\/jpeg;base64,([A-Za-z0-9+/=]+)$/.exec(preview.url);
        assert.ok(base64, 'Expected the bounded inline JPEG');
        assert.deepEqual([...Buffer.from(base64[1], 'base64').subarray(0, 3)], [255, 216, 255]);
        const accepted = reply({ turn: { id: job.turnId } });
        if (job.outcome === 'analysis-tool') return [accepted, { method: 'item/started',
          params: { threadId: job.threadId, turnId: job.turnId, item: { type: 'commandExecution' } } }];
        if (job.outcome === 'analysis-approval') return [accepted];
        assert.equal(job.outcome, 'analysis-success');
        const detections = [
          { region: { x: 0.05, y: 0.1, width: 0.4, height: 0.5 }, portraitRegion: { x: 0.1, y: 0.15, width: 0.3, height: 0.3 },
            kind: 'face', characterID: 'anna', suggestedName: null, confidence: 0.98, reason: 'Green coat', subjectKey: 'anna' },
          { region: { x: 0.6, y: 0.1, width: 0.3, height: 0.4 }, portraitRegion: null,
            kind: 'obscured', characterID: null, suggestedName: null, confidence: 0.3, reason: 'Identity obscured', subjectKey: 'unknown' },
        ];
        return [accepted, { method: 'turn/completed', params: { threadId: job.threadId,
          turn: { id: job.turnId, status: 'completed', items: [{ type: 'agentMessage', id: 'analysis-result', text: JSON.stringify({ detections }) }] } } }];
      }
      assert.ok(params.input.length === 1 && params.input[0].type === 'text'
        && params.input[0].text?.includes(job.outcome === 'recover' ? 'know.' : 'Warm window light. Hold the room.'), 'Expected only the synthetic cue prompt');
      const replies = [reply({ turn: { id: job.turnId } }), { method: 'item/started',
        params: { threadId: job.threadId, item: { type: 'imageGeneration' } } }];
      if (['cancel', 'recover', 'missing-artifact', 'input-request'].includes(job.outcome)) return replies;
      const turn = { id: job.turnId, items: [] };
      if (job.outcome === 'success') {
        const savedPath = join(job.cwd, 'storyboard.png');
        await writeFile(savedPath, png, { flag: 'wx', mode: 0o600 });
        turn.status = 'completed';
        turn.items.push({ type: 'imageGeneration', savedPath });
      } else {
        turn.status = 'failed';
        turn.error = { message: refusal };
      }
      return [...replies, { method: 'turn/completed', params: { threadId: job.threadId, turn } }];
    }
    case 'turn/interrupt':
      assert.deepEqual(params, { threadId: job.threadId, turnId: job.turnId });
      if (job.outcome === 'recover') {
        // The original turn finished at the interruption boundary. Its bytes
        // are durable, and its terminal response is only known on inspection.
        job.savedPath = join(job.cwd, 'recovered.png');
        await writeFile(job.savedPath, recoveredPng, { flag: 'wx', mode: 0o600 });
      }
      return [reply({})];
    case 'thread/read':
      assert.deepEqual(params, { threadId: job.threadId, includeTurns: true });
      if (job.outcome === 'recover') {
        assert.ok(job.savedPath);
        const turn = { id: job.turnId, status: 'completed', items: [{ type: 'imageGeneration', savedPath: job.savedPath }] };
        return [reply({ thread: { id: job.threadId, turns: [turn] } })];
      }
      if (job.outcome === 'missing-artifact') {
        const turn = { id: job.turnId, status: 'completed', items: [] };
        return [reply({ thread: { id: job.threadId, turns: [turn] } })];
      }
      const inspection = job.inspections++;
      const turns = inspection === 0 ? [] : [{ id: job.turnId, status: inspection === 1 ? 'inProgress' : 'interrupted' }];
      return [reply({ thread: { id: job.threadId, turns } })];
    default:
      throw new Error('Unhandled fixture method');
    }
  }
  return {
    receive,
    notice(variant) {
      assert.ok((accountRefresh || manualAccountCheck && variant === 'account-update')
        && position >= handshake.length && count === 0, 'Notices are scoped to this idle account fixture');
      switch (variant) {
      case 'warning': return { method: 'warning', params: { message: 'Synthetic provider warning' } };
      case 'config-warning': return { method: 'configWarning', params: { summary: 'Synthetic provider configuration warning' } };
      case 'error': return { method: 'error', params: { error: { message: 'Synthetic provider error' } } };
      case 'orphan-login': return { method: 'account/login/completed', params: {
        loginId: 'synthetic-unrelated-login', success: false, error: 'Synthetic unrelated login failure',
      } };
      case 'account-update':
        assert.ok((accountUpdates[position - handshake.length] || manualAccountSteps[position - handshake.length]?.announce)
          && !accountUpdateAnnounced, 'Expected one scheduled account refresh');
        accountUpdateAnnounced = true;
        return updated;
      default: throw new Error('Unknown fixture notice');
      }
    },
    requestParams(method, activeTurn) {
      assert.ok(providerMethods.has(method), 'Expected a fixture-owned provider request');
      if (!activeTurn) {
        assert.ok(position === handshake.length && count === 0, 'Idle requests follow the completed handshake');
        return {};
      }
      if (activeRequests.get(job?.outcome) === method && expected[position] === 'turn/interrupt') {
        return { threadId: job.threadId, turnId: job.turnId };
      }
    },
    assertNoTurns: () => assert.equal(count, 0, 'Connection alone did not start a turn'),
    dropTransport() {
      assert.equal(expected[position++], 'transport-drop', 'Only the scheduled cancellation can drop the owned socket');
      reconnecting = true;
    },
    assertComplete: () => assert.equal(position, expected.length, 'Exact fixture request sequence completed'),
  };
}

export async function startCodexFixture(root, outcomes, options) {
  const require = createRequire(new URL('../../../../cloud/package.json', import.meta.url));
  assert.equal(require('ws/package.json').version, '8.21.0', 'Fixture needs the lockfile-pinned cloud dependencies');
  const { WebSocketServer } = require('ws');
  const server = new WebSocketServer({ host: '127.0.0.1', port: 0, maxPayload: 128 * 1024, perMessageDeflate: false });
  await once(server, 'listening');
  const ownedPort = server.address().port;
  let protocol;
  try { protocol = createCodexFixtureProtocol(root, outcomes, { ...options, ownedPort }); }
  catch (error) { server.close(); throw error; }
  let failure;
  let connections = 0;
  let reconnectAllowed = false;
  let pending = Promise.resolve();
  let requestedID;
  let requestNumber = 0;
  const failed = new Promise((_, reject) => { server.once('error', reject); });
  // Retain failures for race()/close() without an unhandled rejection if no
  // app command is currently awaiting a socket message.
  failed.catch(error => { failure ??= error; });
  function fail(error) { failure ??= error; server.emit('error', failure); }
  const send = (socket, message) => new Promise((resolve, reject) => {
    socket.send(JSON.stringify(message), error => error ? reject(error) : resolve());
  });
  server.on('error', error => { failure ??= error; });
  server.on('connection', socket => {
    socket.on('error', fail);
    if (++connections > (reconnectAllowed ? 2 : 1) || server.clients.size !== 1) {
      fail(new Error('Fixture permits only the original owned connection and its scheduled reconnect'));
      socket.terminate();
      return;
    }
    socket.on('message', (data, binary) => {
      pending = pending.then(async () => {
        if (failure) return;
        assert.equal(binary, false, 'Expected UTF-8 RPC');
        const message = JSON.parse(data.toString('utf8'));
        if (requestedID && message.id === requestedID && message.method === undefined) {
          const { id, ...response } = message;
          requestedID = undefined;
          socket.emit('fixture-response', response);
          return;
        }
        for (const reply of await protocol.receive(message)) await send(socket, reply);
        if (message.method === 'turn/start') socket.emit('fixture-turn-started');
      }).catch(error => { fail(error); socket.terminate(); });
    });
  });
  return {
    endpoint: `ws://127.0.0.1:${ownedPort}`,
    race: promise => Promise.race([failed, promise]),
    assertNoTurns: protocol.assertNoTurns,
    async notify(variant) {
      await pending;
      if (failure) throw failure;
      assert.equal(server.clients.size, 1);
      const [socket] = server.clients;
      await send(socket, protocol.notice(variant));
    },
    async request(method, { activeTurn = false } = {}) {
      await pending;
      if (failure) throw failure;
      assert.equal(server.clients.size, 1);
      const [socket] = server.clients;
      const signal = AbortSignal.timeout(5000);
      let params = protocol.requestParams(method, activeTurn);
      if (!params) {
        await Promise.race([failed, once(socket, 'fixture-turn-started', { signal })]);
        params = protocol.requestParams(method, activeTurn);
      }
      assert.ok(params, 'The provider request belongs to the scheduled active turn');
      assert.equal(requestedID, undefined, 'Only one fixture request can be outstanding');
      const id = `fixture-provider-${++requestNumber}`;
      requestedID = id;
      try {
        const [result] = await Promise.race([failed, Promise.all([
          once(socket, 'fixture-response', { signal }), send(socket, { id, method, params }),
        ])]);
        return result[0];
      } finally {
        if (requestedID === id) requestedID = undefined;
      }
    },
    async dropAfterCancellation() {
      await pending;
      if (failure) throw failure;
      assert.equal(connections, 1);
      assert.equal(server.clients.size, 1);
      protocol.dropTransport();
      const [socket] = server.clients;
      const closed = once(socket, 'close');
      socket.terminate();
      await closed;
      reconnectAllowed = true;
    },
    async close() {
      for (const socket of server.clients) socket.terminate();
      await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
      await pending;
      if (failure) throw new Error('The local Codex fixture rejected the connection or request sequence', { cause: failure });
      assert.equal(connections, outcomes.includes('cancel') ? 2 : 1, 'Only the scheduled owned connections occurred');
      protocol.assertComplete();
    },
  };
}
