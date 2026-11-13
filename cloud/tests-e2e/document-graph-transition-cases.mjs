// Public HTTP continuation; the expected document graph is authored independently.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

export async function documentGraphTransitionCases({ request, post, teamId, member }) {
  let httpChecks = 0;
  const send = (...args) => { httpChecks++; return request(...args); };
  const projectId = randomUUID(), sceneAId = randomUUID(), sceneBId = randomUUID();
  const entryAId = randomUUID(), entryBId = randomUUID(), cueAId = randomUUID(), cueBId = randomUUID();
  const characterId = randomUUID(), originalId = randomUUID(), revisionId = randomUUID();
  const route = suffix => `/v1/projects/${projectId}/${suffix}`;
  const sorted = rows => rows.slice().sort((a, b) => a.id.localeCompare(b.id));
  const withoutLeases = ({ leases: ignored, items, deletedItems, ...rest }) =>
    ({ ...rest, items: sorted(items), deletedItems: sorted(deletedItems) });
  const item = (id, kind, data) => ({ id, kind, data: { id, ...data }, version: 1, deleted: false });
  const sceneA = item(sceneAId, 'scene', { title: 'Source scene', order: 0 });
  const sceneB = item(sceneBId, 'scene', { title: 'Destination scene', order: 1 });
  const direction = (id, sceneId, text) => item(id, 'entry', { sceneId, order: 0, kind: 'direction',
    text, ownedDurationMs: 1000, coverageDurationMs: 1000, color: '', words: [] });
  const entryA = direction(entryAId, sceneAId, 'Move with its image coverage.');
  const entryB = direction(entryBId, sceneBId, 'Follow the moved source.');
  const coverage = (id, sceneId, entryId) => item(id, 'cue', { sceneId, startMs: 0, endMs: 1000,
    startAnchor: { entryId, offsetMs: 0 }, authoredDurationMs: 1000, label: 'Authored coverage', prompt: '' });
  const cueA = coverage(cueAId, sceneAId, entryAId), cueB = coverage(cueBId, sceneBId, entryBId);
  const character = item(characterId, 'character', { name: 'Synthetic character', aliases: [], biography: '', appearance: '', color: '' });
  const initial = [sceneA, sceneB, entryA, entryB, cueA, cueB, character];
  const movedEntry = { ...entryA, version: 2, data: { ...entryA.data, sceneId: sceneBId, order: -1 } };
  const movedCue = { ...cueA, version: 2, data: { ...cueA.data, sceneId: sceneBId } };
  const shiftedCue = { ...cueB, version: 2, data: { ...cueB.data, startMs: 1000, endMs: 2000 } };
  const moved = [sceneA, sceneB, movedEntry, entryB, movedCue, shiftedCue, character];
  const original = item(originalId, 'image', { version: 1, fileName: 'original.png', sha256: 'c'.repeat(64),
    mimeType: 'image/png', byteCount: 1, characterIds: [characterId], prompt: '', createdAt: 0 });
  const revision = item(revisionId, 'image', { ...original.data, id: revisionId, version: 2,
    fileName: 'revision.png', sha256: 'd'.repeat(64), previousVersionId: originalId });
  const leases = new Map(), observed = [];
  let expectedItems = [], expectedEvents = [], sequence = 0, timingVersion = 0;
  const command = operations => ({ commandId: randomUUID(), sessionId: member.sessionId, epoch: 1,
    expectedTimingVersion: timingVersion, label: 'Synthetic graph transitions', operations });
  const put = value => ({ op: 'put', id: value.id, kind: value.kind, data: value.data,
    expectedVersion: value.version - 1, ...(leases.has(value.id) ? { lease: leases.get(value.id) } : {}) });
  async function readback() {
    const snapshot = await send(route('snapshot')), events = await send(route('events?after=0'));
    assert.equal(snapshot.status, 200); assert.equal(events.status, 200);
    assert.deepEqual(withoutLeases(snapshot.data), { projectId, headSeq: sequence, epoch: 1, timingVersion,
      items: sorted(expectedItems), deletedItems: [], canImport: expectedItems.length === 0, threads: [] });
    assert.deepEqual(events.data, { events: expectedEvents, headSeq: sequence, epoch: 1, timingVersion, hasMore: false });
  }
  async function acquire(id) {
    const before = Date.now(), result = await send(route('leases'), post({ itemId: id, sessionId: member.sessionId })), after = Date.now();
    assert.equal(result.status, 200); assert.equal(result.data.itemId, id);
    assert.equal(result.data.userId, member.id); assert.equal(result.data.sessionId, member.sessionId);
    assert.equal(result.data.epoch, 1); assert.equal(result.data.fence, 1);
    assert.equal(typeof result.data.token, 'string'); assert(result.data.token.length > 0);
    assert(result.data.expiresAt >= before + 30000 && result.data.expiresAt <= after + 30000);
    leases.set(id, { token: result.data.token, fence: result.data.fence });
  }
  async function accept(name, input, changed, allItems, nextTiming) {
    const nextSequence = sequence + 1;
    const before = Date.now(), result = await send(route('commands'), post(input)), after = Date.now();
    assert.equal(result.status, 200, name);
    const receipt = { commandId: input.commandId, seq: nextSequence, epoch: 1, timingVersion: nextTiming, items: changed };
    assert.deepEqual(result.data, receipt);
    const events = await send(route('events?after=0'));
    assert.equal(events.status, 200);
    const event = events.data.events[nextSequence - 1];
    assert(Number.isSafeInteger(event?.at) && event.at >= before && event.at <= after);
    expectedEvents = [...expectedEvents, { seq: nextSequence, epoch: 1, commandId: input.commandId,
      actorId: member.id, kind: 'command', at: event.at, changes: sorted(changed).map(value => ({ id: value.id,
        before: expectedItems.find(prior => prior.id === value.id) ?? null, after: value })),
      data: { label: input.label, timingVersion: nextTiming } }];
    expectedItems = allItems; sequence = nextSequence; timingVersion = nextTiming;
    assert.deepEqual(events.data, { events: expectedEvents, headSeq: sequence, epoch: 1, timingVersion, hasMore: false });
    await readback(); observed.push(name);
    return receipt;
  }
  async function reject(name, input, status, code) {
    const result = await send(route('commands'), post(input));
    assert.equal(result.status, status, name); assert.equal(result.data.error.code, code, name);
    await readback(); observed.push(name);
  }
  const created = await send('/v1/projects', post({ id: projectId, title: 'Synthetic graph transitions', teamId }));
  assert.equal(created.status, 201); assert.equal(created.data.project.id, projectId);
  await readback();
  await accept('create-two-scene-graph', command(initial.map(put)), initial, initial, 1);
  for (const id of [entryAId, cueAId, cueBId]) await acquire(id);
  await reject('move-leaves-source-cue', command([put(movedEntry)]), 409, 'cue_timing');
  const incompleteMove = command([put(movedEntry), put(movedCue)]);
  await reject('move-leaves-destination-cue-stale', incompleteMove, 409, 'cue_anchor');
  const repairedMove = { ...incompleteMove, operations: [...incompleteMove.operations, put(shiftedCue)] };
  const moveReceipt = await accept('repair-cross-scene-move', repairedMove, [movedEntry, movedCue, shiftedCue], moved, 2);
  const replay = await send(route('commands'), post(repairedMove));
  assert.equal(replay.status, 200); assert.deepEqual(replay.data, moveReceipt);
  await readback(); observed.push('replay-cross-scene-move');
  const candidate = (changes = {}) => ({ ...revision, data: { ...revision.data, ...changes } });
  await reject('invalid-predecessor-id', command([put(candidate({ previousVersionId: 'invalid/id' }))]), 400, 'invalid_id');
  await reject('missing-predecessor', command([put(candidate({ previousVersionId: randomUUID() }))]), 400, 'invalid_reference');
  await reject('wrong-kind-predecessor', command([put(candidate({ previousVersionId: sceneBId }))]), 400, 'invalid_reference');
  await reject('self-predecessor', command([put(candidate({ previousVersionId: revisionId }))]), 400, 'image_version');
  await reject('equal-revision-version', command([put(candidate({ version: 1 })), put(original)]), 400, 'image_version');
  await reject('backwards-revision-version', command([put(candidate({ version: 1 })),
    put({ ...original, data: { ...original.data, version: 2 } })]), 400, 'image_version');
  await reject('missing-image-character', command([put(candidate({ characterIds: [randomUUID()] })), put(original)]), 400, 'invalid_reference');
  await reject('wrong-kind-image-character', command([put(candidate({ characterIds: [sceneBId] })), put(original)]), 400, 'invalid_reference');
  // Dependent first: reference validation must see the complete command candidate graph.
  await accept('create-forward-image-lineage', command([put(revision), put(original)]),
    [revision, original], [...moved, revision, original], 2);
  await acquire(originalId);
  await reject('delete-referenced-predecessor', command([{ op: 'delete', id: originalId,
    expectedVersion: 1, lease: leases.get(originalId) }]), 409, 'item_in_use');
  assert.equal(observed.length, 15); assert.equal(httpChecks, 55);
  return { kind: 'document-graph-transition-evidence', httpChecks, observedCases: observed,
    acceptedEdits: 3, rejectedEdits: 11, exactReplays: 1, nativeScenarios: 0, measuredLineCoverage: false };
}
