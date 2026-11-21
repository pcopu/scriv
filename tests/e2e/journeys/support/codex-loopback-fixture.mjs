import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { lstat, realpath, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { basename, dirname, join } from 'node:path';

const model = 'scriv-fixture';
const refusal = 'Synthetic image turn refused';
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4EGADRAwQCgAsbgXx43oYYAAAAABJRU5ErkJggg==', 'base64');
const recoveredPng = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGNYEKIGRAwQCgAgzgRpm+PgmAAAAABJRU5ErkJggg==', 'base64');
export const fixtureImageHash = createHash('sha256').update(png).digest('hex');
export const recoveredImageHash = createHash('sha256').update(recoveredPng).digest('hex');
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// Model the app-server protocol at its socket boundary. No backend, account,
// tools, credentials, arbitrary file names, or real model are available here.
export function createCodexFixtureProtocol(root, outcomes) {
  const generation = join(root, 'Generation');
  const expected = ['initialize', 'initialized', 'account/read', 'model/list', ...outcomes.flatMap(outcome =>
    ['cancel', 'recover'].includes(outcome) ? ['thread/start', 'turn/start', 'turn/interrupt', 'thread/read'] : ['thread/start', 'turn/start'])];
  let position = 0;
  let job;
  let count = 0;
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
    switch (method) {
    case 'initialize':
      assert.equal(params.clientInfo.name, 'scriv_mac');
      return [reply({ userAgent: 'Scriv local fixture' })];
    case 'account/read':
      assert.equal(params.refreshToken, false);
      return [reply({ account: null, requiresOpenaiAuth: false })];
    case 'model/list':
      assert.equal(params.includeHidden, false);
      return [reply({ data: [{ id: model, model, isDefault: true, inputModalities: ['text', 'image'] }], nextCursor: null })];
    case 'thread/start': {
      // Resolve the app-created directory and tie it to this session's owned
      // verification root. A foreign path or symlink cannot receive an image.
      assert.equal(params.approvalPolicy, 'never');
      assert.equal(params.sandbox, 'workspace-write');
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
      const outcome = outcomes[count++];
      job = { outcome, cwd, threadId: `fixture-thread-${count}`, turnId: `fixture-turn-${count}` };
      return [reply({ thread: { id: job.threadId } })];
    }
    case 'turn/start': {
      assert.equal(params.threadId, job.threadId);
      assert.ok(params.input.length === 1 && params.input[0].type === 'text'
        && params.input[0].text?.includes(job.outcome === 'recover' ? 'know.' : 'Warm window light. Hold the room.'), 'Expected only the synthetic cue prompt');
      const replies = [reply({ turn: { id: job.turnId } }), { method: 'item/started',
        params: { threadId: job.threadId, item: { type: 'imageGeneration' } } }];
      if (job.outcome === 'cancel' || job.outcome === 'recover') return replies;
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
      return [reply({ thread: { id: job.threadId, turns: [{ id: job.turnId, status: 'interrupted' }] } })];
    default:
      throw new Error('Unhandled fixture method');
    }
  }
  return { receive, assertComplete: () => assert.equal(position, expected.length, 'Exact fixture request sequence completed') };
}

export async function startCodexFixture(root, outcomes) {
  const require = createRequire(new URL('../../../../cloud/package.json', import.meta.url));
  assert.equal(require('ws/package.json').version, '8.21.0', 'Fixture needs the lockfile-pinned cloud dependencies');
  const { WebSocketServer } = require('ws');
  const protocol = createCodexFixtureProtocol(root, outcomes);
  const server = new WebSocketServer({ host: '127.0.0.1', port: 0, maxPayload: 128 * 1024, perMessageDeflate: false });
  await once(server, 'listening');
  let failure;
  let connections = 0;
  let pending = Promise.resolve();
  const failed = new Promise((_, reject) => { server.once('error', reject); });
  // Retain failures for race()/close() without an unhandled rejection if no
  // app command is currently awaiting a socket message.
  failed.catch(error => { failure ??= error; });
  function fail(error) { failure ??= error; server.emit('error', failure); }
  server.on('error', error => { failure ??= error; });
  server.on('connection', socket => {
    socket.on('error', fail);
    if (++connections !== 1) {
      fail(new Error('Fixture allows only the owned app connection'));
      socket.terminate();
      return;
    }
    socket.on('message', (data, binary) => {
      pending = pending.then(async () => {
        if (failure) return;
        assert.equal(binary, false, 'Expected UTF-8 RPC');
        for (const reply of await protocol.receive(JSON.parse(data.toString('utf8')))) {
          await new Promise((resolve, reject) => socket.send(JSON.stringify(reply), error => error ? reject(error) : resolve()));
        }
      }).catch(error => { fail(error); socket.terminate(); });
    });
  });
  return {
    endpoint: `ws://127.0.0.1:${server.address().port}`,
    race: promise => Promise.race([failed, promise]),
    async close() {
      for (const socket of server.clients) socket.terminate();
      await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
      await pending;
      if (failure) throw new Error('The local Codex fixture rejected the connection or request sequence', { cause: failure });
      assert.equal(connections, 1, 'Exactly one app connected to its fixture');
      protocol.assertComplete();
    },
  };
}
