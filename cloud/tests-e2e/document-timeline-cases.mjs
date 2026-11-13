// Real public HTTP continuation. Expected graphs are authored independently.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

export async function documentTimelineCases({ request, post, teamId, member }) {
  let httpChecks = 0;
  const send = (...args) => { httpChecks++; return request(...args); };
  const projectId = randomUUID(), sceneId = randomUUID(), directionId = randomUUID();
  const cueId = randomUUID(), tailId = randomUUID(), prefixId = randomUUID(), legacyId = randomUUID();
  const route = suffix => `/v1/projects/${projectId}/${suffix}`;
  const sorted = rows => rows.slice().sort((a, b) => a.id.localeCompare(b.id));
  const withoutLeases = ({ leases: ignored, items, deletedItems, ...rest }) =>
    ({ ...rest, items: sorted(items), deletedItems: sorted(deletedItems) });
  const scene = { id: sceneId, kind: 'scene', version: 1, deleted: false,
    data: { id: sceneId, title: 'Dormant image coverage', order: 0 } };
  const direction = { id: directionId, kind: 'entry', version: 1, deleted: false,
    data: { id: directionId, sceneId, order: 0, kind: 'direction', text: 'Hold the image.',
      ownedDurationMs: 0, coverageDurationMs: 750, color: '', words: [] } };
  const dormant = { id: cueId, kind: 'cue', version: 1, deleted: false,
    data: { id: cueId, sceneId, startMs: 0, endMs: 0, startAnchor: { entryId: directionId, offsetMs: 0 },
      authoredDurationMs: 750, label: 'Retained authored extent', prompt: '' } };
  const tail = { id: tailId, kind: 'entry', version: 1, deleted: false,
    data: { id: tailId, sceneId, order: 1, kind: 'dialogue', text: 'Continue',
      ownedDurationMs: 1000, coverageDurationMs: 1000, color: '',
      words: [{ id: randomUUID(), text: 'Continue', startMs: 0, endMs: 1000, timingSource: 'authored' }] } };
  const prefix = { id: prefixId, kind: 'entry', version: 1, deleted: false,
    data: { id: prefixId, sceneId, order: -1, kind: 'direction', text: 'Before the hold.',
      ownedDurationMs: 500, coverageDurationMs: 500, color: '', words: [] } };
  const legacy = { id: legacyId, kind: 'cue', version: 1, deleted: false,
    data: { id: legacyId, sceneId, startMs: 0, endMs: 500, label: 'Legacy coverage', prompt: '' } };
  const active = { ...dormant, version: 2, data: { ...dormant.data, endMs: 750 } };
  const shifted = { ...dormant, version: 3, data: { ...dormant.data, startMs: 500, endMs: 1250 } };
  const migrated = { ...legacy, version: 2, data: { ...legacy.data, endMs: 750,
    startAnchor: { entryId: prefixId, offsetMs: 0 }, authoredDurationMs: 750 } };
  const collapsed = { ...dormant, version: 4 };
  const returned = { ...dormant, version: 5, data: { ...dormant.data, endMs: 750 } };
  const removed = item => ({ ...item, version: item.version + 1, deleted: true });
  const restoredTail = { ...tail, version: 3 };
  const leases = new Map();
  let expectedItems = [], expectedEvents = [], sequence = 0, timingVersion = 0;
  const observed = [];
  const command = operations => ({ commandId: randomUUID(), sessionId: member.sessionId,
    epoch: 1, expectedTimingVersion: timingVersion, label: 'Synthetic timeline continuation', operations });
  const put = item => ({ op: 'put', id: item.id, kind: item.kind, data: item.data,
    expectedVersion: item.version - 1, ...(leases.has(item.id) ? { lease: leases.get(item.id) } : {}) });
  const del = item => ({ op: 'delete', id: item.id, expectedVersion: item.version,
    lease: leases.get(item.id) });
  async function readback() {
    const snapshot = await send(route('snapshot')), events = await send(route('events?after=0'));
    assert.equal(snapshot.status, 200); assert.equal(events.status, 200);
    assert.deepEqual(withoutLeases(snapshot.data), { projectId, headSeq: sequence, epoch: 1, timingVersion,
      items: sorted(expectedItems.filter(item => !item.deleted)),
      deletedItems: sorted(expectedItems.filter(item => item.deleted).map(item => ({ ...item, data: {} }))),
      canImport: expectedItems.length === 0, threads: [] });
    assert.deepEqual(events.data, { events: expectedEvents, headSeq: sequence, epoch: 1, timingVersion, hasMore: false });
  }
  async function acquire(id) {
    const before = Date.now();
    const lease = await send(route('leases'), post({ itemId: id, sessionId: member.sessionId }));
    const after = Date.now();
    assert.equal(lease.status, 200); assert.equal(lease.data.itemId, id);
    assert.equal(lease.data.userId, member.id); assert.equal(lease.data.sessionId, member.sessionId);
    assert.equal(lease.data.epoch, 1); assert.equal(lease.data.fence, 1);
    assert.equal(typeof lease.data.token, 'string'); assert(lease.data.token.length > 0);
    assert(lease.data.expiresAt >= before + 30000 && lease.data.expiresAt <= after + 30000);
    leases.set(id, { token: lease.data.token, fence: lease.data.fence });
  }
  async function accept(name, input, changed, allItems, nextSequence, nextTiming) {
    assert.equal(nextSequence, sequence + 1);
    const before = Date.now(), result = await send(route('commands'), post(input)), after = Date.now();
    assert.equal(result.status, 200, name);
    const receipt = { commandId: input.commandId, seq: nextSequence, epoch: 1, timingVersion: nextTiming, items: changed };
    assert.deepEqual(result.data, receipt);
    const eventRead = await send(route('events?after=0'));
    assert.equal(eventRead.status, 200);
    const event = eventRead.data.events[nextSequence - 1];
    assert(Number.isSafeInteger(event?.at) && event.at >= before && event.at <= after);
    expectedEvents = [...expectedEvents, { seq: nextSequence, epoch: 1, commandId: input.commandId,
      actorId: member.id, kind: 'command', at: event.at,
      changes: sorted(changed).map(item => ({ id: item.id,
        before: expectedItems.find(prior => prior.id === item.id) ?? null, after: item })),
      data: { label: input.label, timingVersion: nextTiming } }];
    expectedItems = allItems; sequence = nextSequence; timingVersion = nextTiming;
    assert.deepEqual(eventRead.data, { events: expectedEvents, headSeq: sequence, epoch: 1, timingVersion, hasMore: false });
    // The full readback repeats events deliberately; every successful edit checks saved items too.
    await readback(); observed.push(name);
    return receipt;
  }
  async function reject(name, input, code) {
    const result = await send(route('commands'), post(input));
    assert.equal(result.status, 409, name); assert.equal(result.data.error.code, code, name);
    await readback(); observed.push(name);
  }
  async function replay(name, input, receipt) {
    const result = await send(route('commands'), post(input));
    assert.equal(result.status, 200, name); assert.deepEqual(result.data, receipt);
    await readback(); observed.push(name);
  }
  const created = await send('/v1/projects', post({ id: projectId, title: 'Synthetic dormant cues', teamId }));
  assert.equal(created.status, 201); assert.equal(created.data.project.id, projectId);
  await readback();
  await accept('create-dormant-cue', command([put(scene), put(direction), put(dormant)]),
    [scene, direction, dormant], [scene, direction, dormant], 1, 1);
  await acquire(cueId);
  await reject('zero-direction-offset', command([put({ ...dormant, version: 2,
    data: { ...dormant.data, startAnchor: { entryId: directionId, offsetMs: 1 } } })]), 'cue_anchor');
  const extend = command([put(tail)]);
  await reject('append-with-stale-cue', extend, 'cue_anchor');
  const repairedExtend = { ...extend, operations: [...extend.operations, put(active)] };
  await accept('repair-append-with-same-id', repairedExtend, [tail, active], [scene, direction, tail, active], 2, 2);
  await accept('shift-source-with-prefix', command([put(prefix), put(shifted)]),
    [prefix, shifted], [scene, direction, tail, prefix, shifted], 3, 3);
  await reject('legacy-crosses-anchor', command([put({ ...legacy, data: { ...legacy.data, endMs: 600 } })]), 'cue_timing');
  await reject('legacy-overlaps-earlier-anchor', command([put({ ...legacy,
    data: { ...legacy.data, startMs: 700, endMs: 1000 } })]), 'cue_timing');
  await accept('legacy-meets-anchor-exactly', command([put(legacy)]), [legacy],
    [scene, direction, tail, prefix, shifted, legacy], 4, 4);
  await acquire(legacyId);
  const migration = command([put(migrated)]);
  const migrationReceipt = await accept('migrate-overlapping-coverage', migration, [migrated],
    [scene, direction, tail, prefix, shifted, migrated], 5, 5);
  await replay('replay-migration', migration, migrationReceipt);
  await acquire(prefixId); await acquire(tailId);
  const shrink = command([del(prefix), del(tail)]);
  await reject('collapse-with-stale-cues', shrink, 'cue_timing');
  const repairedShrink = { ...shrink, operations: [...shrink.operations, del(migrated), put(collapsed)] };
  const collapsedItems = [scene, direction, removed(prefix), removed(tail), removed(migrated), collapsed];
  const shrinkReceipt = await accept('repair-collapse-with-same-id', repairedShrink,
    [removed(prefix), removed(tail), removed(migrated), collapsed], collapsedItems, 6, 6);
  await replay('replay-collapse', repairedShrink, shrinkReceipt);
  await accept('restore-tail-and-coverage', command([put(restoredTail), put(returned)]),
    [restoredTail, returned], [scene, direction, removed(prefix), restoredTail, removed(migrated), returned], 7, 7);
  assert.equal(observed.length, 14); assert.equal(httpChecks, 56);
  return { kind: 'document-timeline-evidence', httpChecks, observedCases: observed,
    acceptedEdits: 7, rejectedEdits: 5, exactReplays: 2, nativeScenarios: 0, measuredLineCoverage: false };
}
