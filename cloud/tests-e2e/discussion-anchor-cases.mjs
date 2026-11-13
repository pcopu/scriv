// Public HTTP continuation; independent expected document and discussion state.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

export async function discussionAnchorCases({ base, token, actor }) {
  assert.equal(base.hostname, '127.0.0.1'); assert.equal(base.protocol, 'http:');
  const projectId = randomUUID(), sceneId = randomUUID(), entryId = randomUUID();
  const wordA = randomUUID(), wordB = randomUUID();
  const rootA = randomUUID(), childA = randomUUID(), leafA = randomUUID();
  const rootB = randomUUID(), childB = randomUUID(), deletedId = randomUUID();
  const route = suffix => `/v1/projects/${projectId}/${suffix}`;
  let httpChecks = 0;
  async function request(path, { method = 'GET', body, status = 200, code } = {}) {
    const url = new URL(path, base); assert.equal(url.origin, base.origin);
    const encoded = body === undefined ? undefined : JSON.stringify(body);
    assert(httpChecks++ < 100); assert(Buffer.byteLength(encoded ?? '') <= 16384);
    const response = await fetch(url, { method, body: encoded, redirect: 'error', signal: AbortSignal.timeout(5000),
      headers: { authorization: `Bearer ${token}`, ...(encoded ? { 'content-type': 'application/json' } : {}) } });
    assert.equal(response.status, status, `${method} synthetic discussion route status`);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
    const parts = []; let size = 0; const reader = response.body.getReader();
    while (true) { const { done, value } = await reader.read(); if (done) break; size += value.length; assert(size <= 65536); parts.push(value); }
    const result = JSON.parse(Buffer.concat(parts).toString('utf8'));
    if (code) assert.equal(result.error?.code, code);
    return result;
  }
  const post = (body, extra = {}) => ({ method: 'POST', body, ...extra });
  const sorted = rows => rows.slice().sort((a, b) => a.id.localeCompare(b.id));
  const uuid = value => assert.match(value, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  const timeWithin = (value, start, end) => { assert(Number.isSafeInteger(value)); assert(value >= start && value <= end); };
  const withoutLeases = ({ leases: ignored, items, deletedItems, threads, ...rest }) =>
    ({ ...rest, items: sorted(items), deletedItems: sorted(deletedItems), threads: sorted(threads) });
  const image = (id, version, name, previousVersionId) => ({ id, kind: 'image', version: 1, deleted: false,
    data: { id, version, fileName: `${name}.png`, sha256: name[0].repeat(64), mimeType: 'image/png', byteCount: 1,
      characterIds: [], prompt: '', createdAt: 0, ...(previousVersionId ? { previousVersionId } : {}) } });
  const graph = [
    { id: sceneId, kind: 'scene', version: 1, deleted: false, data: { id: sceneId, title: 'Synthetic anchors', order: 0 } },
    { id: entryId, kind: 'entry', version: 1, deleted: false,
      data: { id: entryId, sceneId, order: 0, kind: 'dialogue', text: 'First second', color: '', ownedDurationMs: 1000,
        coverageDurationMs: 1000, words: [{ id: wordA, text: 'First', startMs: 0, endMs: 500 }, { id: wordB, text: 'second', startMs: 500, endMs: 1000 }] } },
    image(rootA, 1, 'a-root'), image(childA, 2, 'b-child', rootA), image(leafA, 3, 'c-leaf', childA),
    image(rootB, 1, 'd-root'), image(childB, 2, 'e-child', rootB), image(deletedId, 1, 'f-deleted'),
  ];
  const created = await request('/v1/projects', post({ id: projectId, title: 'Synthetic discussion anchors' }, { status: 201 }));
  assert.equal(created.project.id, projectId); assert.equal(created.project.ownerId, actor.id); assert.equal(created.project.teamId, null);
  const commandId = randomUUID(), seedStart = Date.now();
  const receipt = await request(route('commands'), post({ commandId, sessionId: actor.sessionId, epoch: 1,
    expectedTimingVersion: 0, label: 'Seed independent anchor graph', operations: graph.map(item => ({ op: 'put', id: item.id,
      kind: item.kind, data: item.data, expectedVersion: 0 })) }));
  const seedEnd = Date.now();
  assert.deepEqual(receipt, { commandId, seq: 1, epoch: 1, timingVersion: 1, items: graph });
  let expectedItems = graph, expectedThreads = [], expectedEvents;
  let sequence = 1;
  async function readback() {
    const snapshot = withoutLeases(await request(route('snapshot'))), events = await request(route('events?after=0'));
    assert.deepEqual(snapshot, { projectId, epoch: 1, headSeq: sequence, timingVersion: 1,
      items: sorted(expectedItems.filter(item => !item.deleted)),
      deletedItems: sorted(expectedItems.filter(item => item.deleted).map(item => ({ ...item, data: {} }))),
      canImport: false, threads: sorted(expectedThreads) });
    assert.equal(events.headSeq, sequence); assert.equal(events.epoch, 1); assert.equal(events.timingVersion, 1); assert.equal(events.hasMore, false);
    if (expectedEvents) assert.deepEqual(events.events, expectedEvents);
    return events.events;
  }
  expectedEvents = await readback();
  assert.equal(expectedEvents.length, 1);
  timeWithin(expectedEvents[0].at, seedStart, seedEnd);
  assert.deepEqual(expectedEvents, [{ seq: 1, epoch: 1, commandId, actorId: actor.id, kind: 'command',
    at: expectedEvents[0].at, changes: sorted(graph).map(after => ({ id: after.id, before: null, after })),
    data: { label: 'Seed independent anchor graph', timingVersion: 1 } }]);
  const lease = await request(route('leases'), post({ itemId: deletedId, sessionId: actor.sessionId }));
  assert.equal(lease.itemId, deletedId); assert.equal(lease.userId, actor.id); assert.equal(lease.fence, 1);
  const deleteCommand = randomUUID(), deleteStart = Date.now();
  const deletion = await request(route('commands'), post({ commandId: deleteCommand, sessionId: actor.sessionId,
    epoch: 1, expectedTimingVersion: 1, label: 'Delete unused anchor image',
    operations: [{ op: 'delete', id: deletedId, expectedVersion: 1, lease: { token: lease.token, fence: lease.fence } }] }));
  const deleteEnd = Date.now();
  const beforeDeleted = graph.find(item => item.id === deletedId), afterDeleted = { ...beforeDeleted, version: 2, deleted: true };
  assert.deepEqual(deletion, { commandId: deleteCommand, seq: 2, epoch: 1, timingVersion: 1, items: [afterDeleted] });
  expectedItems = graph.map(item => item.id === deletedId ? afterDeleted : item); sequence = 2;
  let events = await request(route('events?after=0')); assert.deepEqual(events.events.slice(0, 1), expectedEvents);
  assert.equal(events.events.length, 2); timeWithin(events.events[1].at, deleteStart, deleteEnd);
  assert.deepEqual(events.events[1], { seq: 2, epoch: 1, commandId: deleteCommand, actorId: actor.id, kind: 'command',
    at: events.events[1].at, changes: [{ id: deletedId, before: beforeDeleted, after: afterDeleted }],
    data: { label: 'Delete unused anchor image', timingVersion: 1 } });
  expectedEvents = events.events; await readback();
  const rejected = [];
  async function reject(name, input, message) {
    const response = await request(route('threads'), post(input, { status: 400, code: 'invalid_anchor' }));
    if (message) assert.deepEqual(response, { error: { code: 'invalid_anchor', message } });
    await readback(); rejected.push(name);
  }
  const sizeMessage = 'A word anchor must contain at most 1,000 word IDs.';
  await reject('word-list-type', { itemId: entryId, anchor: { wordIds: 'invalid' } }, sizeMessage);
  await reject('word-list-bound', { itemId: entryId, anchor: { wordIds: Array(1001).fill('x') } }, sizeMessage);
  await reject('words-without-entry', { anchor: { wordIds: [] } });
  await reject('words-on-image', { itemId: rootA, anchor: { wordIds: [] } });
  await reject('duplicate-words', { itemId: entryId, anchor: { wordIds: [wordA, wordA] } });
  await reject('foreign-word', { itemId: entryId, anchor: { wordIds: [randomUUID()] } });
  await reject('missing-image-anchor', { itemId: rootA, anchor: { imageVersionId: randomUUID() } });
  await reject('non-image-anchor', { itemId: rootA, anchor: { imageVersionId: entryId } });
  await reject('deleted-image-anchor', { itemId: rootA, anchor: { imageVersionId: deletedId } });
  await reject('different-image-family', { itemId: leafA, anchor: { imageVersionId: childB } });
  async function createThread(name, input, itemId, anchor) {
    const started = Date.now(), response = await request(route('threads'), post(input, { status: 201 })), ended = Date.now();
    const thread = response.thread;
    uuid(thread.id); timeWithin(thread.createdAt, started, ended);
    assert.deepEqual(response, { thread: { id: thread.id, itemId, anchor, resolved: false, createdAt: thread.createdAt, updatedAt: thread.createdAt } });
    sequence++; expectedThreads.push(thread);
    events = await request(route('events?after=0'));
    assert.deepEqual(events.events.slice(0, -1), expectedEvents); assert.equal(events.events.length, sequence);
    const event = events.events.at(-1); uuid(event.commandId);
    timeWithin(event.at, started, ended);
    assert.deepEqual(event, { seq: sequence, epoch: 1, commandId: event.commandId, actorId: actor.id,
      kind: 'discussion.thread-created', at: event.at, changes: [], data: { label: 'Start discussion', thread, timingVersion: 1 } });
    expectedEvents = events.events; await readback(); return thread;
  }
  const wordThread = await createThread('ordered-word-anchor', { itemId: entryId, anchor: { wordIds: [wordB, wordA] } }, entryId, { wordIds: [wordB, wordA] });
  const imageThread = await createThread('automatic-image-version', { itemId: leafA }, rootA, { imageVersionId: leafA });
  const explicitThread = await createThread('explicit-family-version', { itemId: rootB, anchor: { imageVersionId: childB } }, rootB, { imageVersionId: childB });
  for (const itemId of [rootA, childA, leafA]) {
    assert.deepEqual(await request(route(`threads?itemId=${itemId}`)), { threads: [imageThread] });
    assert.deepEqual(await request(route('threads'), post({ itemId, anchor: { imageVersionId: childB } })), { thread: imageThread });
  }
  // Existing-thread lookup deliberately precedes new-anchor validation: reopening
  // a canonical discussion preserves its first anchor and emits no new event.
  assert.deepEqual(await request(route(`threads?itemId=${entryId}`)), { threads: [wordThread] });
  assert.deepEqual(await request(route(`threads?itemId=${childB}`)), { threads: [explicitThread] });
  await readback();
  const ordered = sorted(expectedThreads); let after = '';
  for (let index = 0; index < ordered.length; index++) {
    const page = await request(route(`threads?scope=all&limit=1${after ? `&after=${after}` : ''}`));
    assert.deepEqual(page, { threads: [ordered[index]], hasMore: index < ordered.length - 1,
      nextCursor: index < ordered.length - 1 ? ordered[index].id : null });
    after = ordered[index].id;
  }
  assert.deepEqual(await request(route(`threads?scope=all&limit=1&after=${after}`)), { threads: [], hasMore: false, nextCursor: null });
  await readback();
  assert.equal(httpChecks, 67); assert.equal(rejected.length, 10);
  const result = { kind: 'discussion-anchor-evidence', httpChecks, rejectedCases: rejected,
    independentImageFamilies: 2, canonicalRevisionLookups: 3, createdThreads: 3,
    documentStateUnchangedByThreads: true, exactPriorEventsPreserved: true,
    nativeScenarios: 0, measuredLineCoverage: false };
  console.log(JSON.stringify(result)); return result;
}
