import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

// Sequential public HTTP observations keep failed edits independent of lease time.
export async function revisionBoundaryCases({ request, route, actors, baseline, restoreInput, itemId }) {
  const observe = async () => {
    const snapshot = await request(route('snapshot'), { role: 'viewer' });
    const journal = await request(route('events?after=0'), { role: 'viewer' });
    assert.equal(snapshot.status, 200);
    assert.equal(journal.status, 200);
    const { leases, ...content } = snapshot.data;
    return { content, journal: journal.data };
  };
  const { leases, ...initialContent } = baseline.snapshot;
  const initial = { content: initialContent, journal: baseline.journal };
  assert.deepEqual(await observe(), initial);
  const reject = async (suffix, options, status, code) => {
    const response = await request(route(suffix), options);
    assert.equal(response.status, status);
    assert.equal(response.data.error.code, code);
    assert.deepEqual(await observe(), initial);
  };
  const sessionId = actors.member.sessionId;
  const acquired = await request(route('leases'), { role: 'member', method: 'POST', body: { itemId, sessionId } });
  assert.equal(acquired.status, 200);
  const proof = acquired.data;
  assert.equal(proof.epoch, 5);
  assert.equal(proof.fence, 5);
  assert.equal(proof.userId, actors.member.id);
  assert.equal(proof.sessionId, sessionId);
  assert.equal(proof.itemId, itemId);
  const repeated = await request(route('leases'), { role: 'member', method: 'POST', body: { itemId, sessionId } });
  assert.equal(repeated.status, 200);
  assert.deepEqual(repeated.data, proof);
  await reject('leases', { method: 'POST', body: { itemId, sessionId: actors.owner.sessionId } }, 423, 'item_locked');
  const proofBody = { itemId, sessionId, epoch: 5, token: proof.token, fence: proof.fence };
  await reject('leases', { role: 'member', method: 'PATCH', body: proofBody }, 405, 'method_not_allowed');
  const command = operations => ({ commandId: randomUUID(), sessionId, epoch: 5, label: 'Boundary recovery', operations });
  const newId = randomUUID();
  const newScene = { id: newId, kind: 'scene', data: { id: newId, title: 'Atomic recovery', order: 0 }, version: 1, deleted: false };
  const put = { op: 'put', id: newId, kind: 'scene', data: newScene.data, expectedVersion: 0 };
  const rollback = command([put, { op: 'delete', id: randomUUID(), expectedVersion: 0 }]);
  await reject('commands', { role: 'member', method: 'POST', body: rollback }, 404, 'not_found');
  const lease = { token: proof.token, fence: proof.fence };
  const character = { id: itemId, name: 'Boundary', aliases: [], biography: '', appearance: '', color: '' };
  await reject('commands', { role: 'member', method: 'POST', body: command([{ op: 'put', id: itemId, kind: 'character', data: character, expectedVersion: 6, lease }]) }, 409, 'kind_conflict');
  await reject('commands', { role: 'member', method: 'POST', body: command([{ op: 'delete', id: itemId, expectedVersion: 6, lease }]) }, 404, 'not_found');
  await reject('commands', { role: 'viewer', method: 'POST', body: command([put]) }, 403, 'read_only');
  await reject('restore', { role: 'member', method: 'POST', body: restoreInput }, 409, 'command_reused');
  await reject('restore', { method: 'POST', body: { ...restoreInput, seq: 1 } }, 409, 'command_reused');
  await reject('snapshot?seq=6&after=%40', {}, 400, 'invalid_id');
  await reject('unknown-revision-route', {}, 404, 'not_found');
  for (const suffix of ['snapshot?seq=6&limit=0', 'events?after=-1', 'history?limit=201']) {
    await reject(suffix, {}, 400, 'invalid_field');
  }
  const leaseList = await request(route('leases'));
  const { token, ...publicProof } = proof;
  assert.equal(leaseList.status, 200);
  assert.deepEqual(leaseList.data, { leases: [publicProof], epoch: 5 });
  // A refused transaction neither reserved its command ID nor left its first put.
  const retry = { ...rollback, operations: [put] };
  const start = Date.now();
  const saved = await request(route('commands'), { role: 'member', method: 'POST', body: retry });
  const end = Date.now();
  assert.equal(saved.status, 200);
  assert.deepEqual(saved.data, { commandId: retry.commandId, seq: 12, epoch: 5, timingVersion: 4, items: [newScene] });
  const after = await observe();
  assert.deepEqual(after.content, { ...initialContent, headSeq: 12, items: [newScene] });
  const event = after.journal.events.at(-1);
  assert(event.at >= start && event.at <= end);
  assert.deepEqual(event, { seq: 12, epoch: 5, commandId: retry.commandId, actorId: actors.member.id, kind: 'command', at: event.at, changes: [{ id: newId, before: null, after: newScene }], data: { label: 'Boundary recovery', timingVersion: 4 } });
  assert.deepEqual(after.journal, { ...initial.journal, headSeq: 12, events: [...initial.journal.events, event] });
  const replay = await request(route('commands'), { role: 'member', method: 'POST', body: retry });
  assert.equal(replay.status, 200);
  assert.deepEqual(replay.data, saved.data);
  assert.deepEqual(await observe(), after);
  return { rejectedBoundaries: 13, recoveredCommand: true };
}
