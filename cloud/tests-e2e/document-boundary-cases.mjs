// Public HTTP continuation of document-integrity. No production implementation imports.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

export async function documentBoundaryCases({ request, route, post, graph, leases, member, deletedEvents }) {
  let httpChecks = 0;
  const send = (...args) => { httpChecks++; return request(...args); };
  const sorted = rows => rows.slice().sort((a, b) => a.id.localeCompare(b.id));
  const withoutLeases = ({ leases: ignored, items, ...snapshot }) => ({ ...snapshot, items: sorted(items) });
  const byKind = kind => graph.find(item => item.kind === kind);
  const character = byKind('character').id;
  const entry = byKind('entry').id, image = byKind('image').id, cue = byKind('cue').id;
  // Expectations start with independently authored input, not a response-derived model.
  const restored = graph.map(item => {
    const data = structuredClone(item.data);
    if (item.kind === 'character') data.biography = 'Synthetic biography';
    if (item.kind === 'image') data.prompt = 'Revised direction';
    if (item.kind === 'cue') data.label = 'Revised portrait';
    if (item.kind === 'entry') {
      data.color = 'blue';
      data.text = 'Ada\u0085😀\uFEFF';
      data.words = [
        { ...data.words[0], text: 'Ada', startMs: 0, endMs: 400 },
        { id: randomUUID(), text: '😀\uFEFF', startMs: 400, endMs: 1000, timingSource: 'authored' },
      ];
      data.characterLinks = [data.characterLinks[0],
        { id: randomUUID(), location: 4, length: 2, text: '😀', isConfirmed: true, characterId: null }];
    }
    return { ...item, data, version: item.kind === 'scene' ? 3 : 4, deleted: false };
  });
  const envelope = operations => ({ commandId: randomUUID(), sessionId: member.sessionId,
    epoch: 1, expectedTimingVersion: 3, label: 'Synthetic document boundaries', operations });
  const restore = { ...envelope(restored.map(item => ({ op: 'put', id: item.id, kind: item.kind,
    data: item.data, expectedVersion: item.version - 1, lease: leases.get(item.id) }))), expectedTimingVersion: 2 };
  const restoreStart = Date.now();
  const accepted = await send(route('commands'), post(restore));
  const restoreEnd = Date.now();
  assert.equal(accepted.status, 200, 'restore connected Unicode graph');
  assert.deepEqual(accepted.data, { commandId: restore.commandId, seq: 4, epoch: 1, timingVersion: 3, items: restored });
  const snapshot = await send(route('snapshot')), events = await send(route('events?after=0'));
  assert.equal(snapshot.status, 200); assert.equal(events.status, 200);
  assert.deepEqual(withoutLeases(snapshot.data), { projectId: snapshot.data.projectId, headSeq: 4, epoch: 1,
    timingVersion: 3, items: sorted(restored), deletedItems: [], canImport: false, threads: [] });
  assert.equal(snapshot.data.projectId, route('snapshot').split('/')[3]);
  const restoredEvent = events.data.events[3];
  assert(Number.isSafeInteger(restoredEvent.at) && restoredEvent.at >= restoreStart && restoredEvent.at <= restoreEnd);
  const originalTombstones = graph.map(item => {
    const data = structuredClone(item.data);
    if (item.kind === 'character') data.biography = 'Synthetic biography';
    if (item.kind === 'image') data.prompt = 'Revised direction';
    if (item.kind === 'cue') data.label = 'Revised portrait';
    if (item.kind === 'entry') data.color = 'blue';
    return { ...item, data, version: item.kind === 'scene' ? 2 : 3, deleted: true };
  });
  assert.deepEqual(restoredEvent, { seq: 4, epoch: 1, commandId: restore.commandId, actorId: member.id,
    kind: 'command', at: restoredEvent.at, changes: sorted(restored).map(after => ({ id: after.id,
      before: originalTombstones.find(item => item.id === after.id), after })),
    data: { label: restore.label, timingVersion: 3 } });
  assert.deepEqual(events.data, { events: [...deletedEvents.data.events, restoredEvent], headSeq: 4,
    epoch: 1, timingVersion: 3, hasMore: false });
  const baseline = snapshot.data, eventBaseline = events.data;
  const operation = (id, change) => {
    const item = restored.find(value => value.id === id);
    return { op: 'put', id, kind: item.kind, expectedVersion: item.version,
      lease: leases.get(id), data: change(structuredClone(item.data)) };
  };
  const cases = [
    ['blank-character-name', character, d => { d.name = ' \u200B\t'; return d; }, 400, 'invalid_name'],
    ['oversized-character-alias', character, d => { d.aliases = ['x'.repeat(501)]; return d; }, 400, 'invalid_field'],
    ['duplicate-link-id', entry, d => { d.characterLinks[1].id = d.characterLinks[0].id; return d; }, 400, 'invalid_character_links'],
    ['overlapping-link-ranges', entry, d => { d.characterLinks[1] = { ...d.characterLinks[1], location: 2, length: 1, text: 'a' }; return d; }, 400, 'invalid_field'],
    ['mismatched-link-text', entry, d => { d.characterLinks[0].text = 'Eve'; return d; }, 400, 'invalid_character_links'],
    ['unconfirmed-unlinked-range', entry, d => { d.characterLinks[1].isConfirmed = false; return d; }, 400, 'invalid_character_links'],
    ['surrogate-start-split', entry, d => { d.characterLinks[1] = { ...d.characterLinks[1], location: 5, length: 1, text: '\uDE00' }; return d; }, 400, 'invalid_character_links'],
    ['surrogate-end-split', entry, d => { d.characterLinks[1] = { ...d.characterLinks[1], length: 1, text: '\uD83D' }; return d; }, 400, 'invalid_character_links'],
    ['duplicate-word-id', entry, d => { d.words[1].id = d.words[0].id; return d; }, 400, 'duplicate_word'],
    ['invalid-word-provenance', entry, d => { d.words[1].timingSource = 'generated'; return d; }, 400, 'invalid_word_timing_source'],
    ['overlapping-word-timing', entry, d => { d.words[1].startMs = 399; return d; }, 400, 'invalid_field'],
    ['spoken-direction', entry, d => { d.kind = 'direction'; return d; }, 400, 'direction_timing'],
    ['unsafe-image-filename', image, d => { d.fileName = '../synthetic.png'; return d; }, 400, 'invalid_filename'],
    ['immutable-image-version', image, d => { d.version = 2; d.characterAnalysis.imageVersion = 2; return d; }, 409, 'immutable_image'],
    ['immutable-image-filename', image, d => { d.fileName = 'replacement.png'; return d; }, 409, 'immutable_image'],
    ['immutable-image-digest', image, d => { d.sha256 = 'b'.repeat(64); d.characterAnalysis.imageSHA256 = d.sha256; return d; }, 409, 'immutable_image'],
    ['immutable-image-mime', image, d => { d.mimeType = 'image/jpeg'; return d; }, 409, 'immutable_image'],
    ['immutable-image-created-at', image, d => { d.createdAt = 1; return d; }, 409, 'immutable_image'],
    ['immutable-image-lineage', image, d => { d.previousVersionId = randomUUID(); return d; }, 409, 'immutable_image'],
    ['unknown-analysis-kind', image, d => { d.characterAnalysis.annotations[0].kind = 'unknown'; return d; }, 400, 'invalid_character_analysis'],
    ['negative-analysis-time', image, d => { d.characterAnalysis.completedAt = -1; return d; }, 400, 'invalid_character_analysis'],
    ['unpaired-cue-anchor', cue, d => { delete d.authoredDurationMs; return d; }, 400, 'invalid_cue_anchor'],
    ['cue-beyond-scene', cue, d => { d.endMs = 1001; d.authoredDurationMs = 1001; return d; }, 409, 'cue_timing'],
    ['cue-anchor-offset-mismatch', cue, d => { d.startMs = 1; return d; }, 409, 'cue_anchor'],
    ['missing-cue-source', cue, d => { d.startAnchor.entryId = randomUUID(); return d; }, 409, 'cue_anchor'],
  ];
  const observedCases = [];
  async function reject(name, command, status, code) {
    try {
      const result = await send(route('commands'), post(command));
      const after = await send(route('snapshot')), afterEvents = await send(route('events?after=0'));
      assert.equal(result.status, status); assert.equal(result.data.error.code, code);
      assert.equal(after.status, 200); assert.equal(afterEvents.status, 200);
      assert.deepEqual(withoutLeases(after.data), withoutLeases(baseline));
      assert.deepEqual(afterEvents.data, eventBaseline);
      observedCases.push(name);
    } catch (error) { console.error(`Document boundary case failed: ${name}`); throw error; }
  }
  for (const [name, id, change, status, code] of cases)
    await reject(name, envelope([operation(id, change)]), status, code);
  const failedAtomic = envelope([
    operation(character, d => ({ ...d, biography: 'Validated recovery' })),
    operation(entry, d => ({ ...d, characterId: randomUUID() })),
  ]);
  await reject('rollback-earlier-valid-operation', failedAtomic, 400, 'invalid_reference');
  // Reuse the rejected ID after repairing only the invalid reference.
  const repaired = structuredClone(failedAtomic);
  repaired.operations[1].data.characterId = character;
  const repairedItems = repaired.operations.map(op => ({ id: op.id, kind: op.kind, data: op.data, version: 5, deleted: false }));
  const repairStart = Date.now();
  const saved = await send(route('commands'), post(repaired));
  const repairEnd = Date.now();
  assert.equal(saved.status, 200);
  assert.deepEqual(saved.data, { commandId: repaired.commandId, seq: 5, epoch: 1, timingVersion: 3, items: repairedItems });
  const repairedSnapshot = await send(route('snapshot')), repairedEvents = await send(route('events?after=0'));
  assert.equal(repairedSnapshot.status, 200); assert.equal(repairedEvents.status, 200);
  assert.deepEqual(withoutLeases(repairedSnapshot.data), { ...withoutLeases(baseline), headSeq: 5,
    items: sorted(restored.map(item => repairedItems.find(after => after.id === item.id) ?? item)) });
  const repairEvent = repairedEvents.data.events[4];
  assert(Number.isSafeInteger(repairEvent.at) && repairEvent.at >= repairStart && repairEvent.at <= repairEnd);
  assert.deepEqual(repairEvent, { seq: 5, epoch: 1, commandId: repaired.commandId, actorId: member.id,
    kind: 'command', at: repairEvent.at, changes: sorted(repairedItems).map(after => ({ id: after.id,
      before: restored.find(item => item.id === after.id), after })), data: { label: repaired.label, timingVersion: 3 } });
  assert.deepEqual(repairedEvents.data, { ...eventBaseline, headSeq: 5, events: [...eventBaseline.events, repairEvent] });
  const replay = await send(route('commands'), post(repaired));
  const replaySnapshot = await send(route('snapshot')), replayEvents = await send(route('events?after=0'));
  assert.equal(replay.status, 200); assert.deepEqual(replay.data, saved.data);
  assert.equal(replaySnapshot.status, 200); assert.equal(replayEvents.status, 200);
  assert.deepEqual(withoutLeases(replaySnapshot.data), withoutLeases(repairedSnapshot.data));
  assert.deepEqual(replayEvents.data, repairedEvents.data);
  assert.equal(observedCases.length, 26); assert.equal(httpChecks, 87);
  return { kind: 'document-boundary-evidence', httpChecks, rejectedCases: observedCases,
    unicodeGraphRestored: true, failedAtomicCommandRolledBack: true, repairedIDAccepted: true,
    exactReplayStable: true, nativeScenarios: 0, measuredLineCoverage: false };
}
