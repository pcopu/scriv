import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from './saved-projects.mjs';
import { audioLibrarySteps, sortedProjects } from '../journeys/support/audio-library-steps.mjs';

export const firstLineBaselineID = 'apps/mac/Tests/ScrivCoreTests/ImageImportPlacementTests.swift::0001';
export const firstLineCases = ['first-line-input', 'first-line-import', 'later-line-route', 'first-line-return'];
const coralSHA = '827d9145314e931860ee40b45f8348ad3527c93e008d1490b687265d947fb577';

// Literal serialized input from frozen ::0001. Only initializer-generated IDs
// and dates are pinned. The old asset deliberately remains missing and fake:
// replacing its metadata with real pixels would change the frozen assertion.
export function firstLineImageFixture() {
  return {
    schemaVersion: 1, id: 'first-line-image-input', title: 'Synthetic first-line image',
    createdAt: 1700000000000, modifiedAt: 1700000000000, revision: 0,
    scenes: [{ id: 's', title: 'Untitled scene', order: 0 }],
    entries: [
      { id: 'direction', sceneId: 's', order: 0, kind: 'direction', text: 'A gate opens.',
        ownedDurationMs: 1500, coverageDurationMs: 8500, color: 'purple', words: [] },
      { id: 'dialogue', sceneId: 's', order: 1, kind: 'dialogue', text: 'Every word stays intact.',
        ownedDurationMs: 7000, coverageDurationMs: 0, color: 'purple', words: [
          { id: 'first-line-word-1', text: 'Every', startMs: 0, endMs: 1666 },
          { id: 'first-line-word-2', text: 'word', startMs: 1666, endMs: 3000 },
          { id: 'first-line-word-3', text: 'stays', startMs: 3000, endMs: 4667 },
          { id: 'first-line-word-4', text: 'intact.', startMs: 4667, endMs: 7000 },
        ] },
    ], characters: [],
    images: [{ id: 'old', version: 1, fileName: 'old.png', sha256: 'a'.repeat(64),
      mimeType: 'image/png', byteCount: 1, characterIds: [], prompt: '', createdAt: 1700000000000 }],
    cues: [{ id: 'later', sceneId: 's', imageId: 'old', label: 'Existing picture',
      startMs: 1500, endMs: 8500, prompt: '', startAnchor: { entryId: 'dialogue', offsetMs: 0 }, authoredDurationMs: 15300 }],
    audioAssets: [], audioClips: [], audioVolume: 1,
  };
}

export function verifyFirstLineImport(before, after) {
  assert.equal(after.images.length, 2); assert.equal(after.cues.length, 2);
  const asset = after.images[1], cue = after.cues[1];
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  assert.match(asset.id, uuid); assert.match(cue.id, uuid); assert.notEqual(asset.id, cue.id);
  assert.ok(Number.isFinite(asset.createdAt));
  assert.deepEqual(asset, { id: asset.id, version: 1, fileName: coralSHA + '.png', sha256: coralSHA,
    mimeType: 'image/png', byteCount: 73, characterIds: [], prompt: 'Imported image', createdAt: asset.createdAt });
  assert.deepEqual(cue, { id: cue.id, sceneId: 's', imageId: asset.id, label: 'Image 2', startMs: 0,
    endMs: 1500, prompt: '', startAnchor: { entryId: 'direction', offsetMs: 0 }, authoredDurationMs: 1500 });
  assert.equal(after.revision, before.revision + 1);
  assert.ok(Number.isFinite(after.modifiedAt) && after.modifiedAt > before.modifiedAt);
  const expected = structuredClone(before);
  expected.images.push(asset); expected.cues.push(cue);
  expected.revision += 1; expected.modifiedAt = after.modifiedAt;
  assert.deepEqual(after, expected, 'Every original field, word ID/time, old asset and later cue stays exact');
}

export async function runFirstLineImageCase(app) {
  const session = await ScrivSession.launch(app), ui = audioLibrarySteps(session);
  let sample, current, step = 'setup'; const completed = [];
  async function check(name, body) {
    step = name; await body(); completed.push(name); console.log(`PASS: AUT-J08/local-images/${name}`);
  }
  async function invariant() {
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), sortedProjects([sample, current]));
    assert.deepEqual((await session.command('loaded-project')).project, current);
    assert.deepEqual(await session.command('presented-alerts'), []);
  }
  async function selectLine(kind) {
    const disclosure = await ui.reveal(n => n.identifier === 'preview-layers-disclosure');
    if (disclosure.label === 'Expand Layers') await ui.activate(n => n.identifier === 'preview-layers-disclosure');
    await session.waitFor(nodes => nodes.some(n => n.identifier === 'preview-layers-disclosure' && n.label === 'Collapse Layers'));
    await ui.activate(n => n.enabled === true && (kind === 'direction'
      ? n.title?.startsWith('A gate opens.\n') && n.title.endsWith(' owned')
      : n.title === 'Dialogue\nEvery word stays intact.'));
    await ui.activate(n => n.identifier === 'preview-layers-disclosure');
    await session.waitFor(nodes => nodes.some(n => n.identifier === 'preview-layers-disclosure' && n.label === 'Expand Layers'));
  }
  async function route(time, subtitle, missing = false) {
    const nodes = await session.waitFor(nodes => nodes.some(n => n.text === subtitle)
      && nodes.some(n => n.identifier === 'scene-playback-position'
        && n.slider?.value === time && n.slider?.maximum === 8500)
      && (!missing || nodes.some(n => n.text === 'Image isn’t on this Mac')));
    assert.equal(nodes.filter(n => n.text === subtitle).length, 1, 'Unique native preview label identifies the routed cue');
    assert.ok(!nodes.some(n => n.text?.startsWith('Inspecting selected image')),
      'Preview follows the active playhead rather than a selected off-time cue');
    if (!missing) assert.ok(!nodes.some(n => n.text === 'Image isn’t on this Mac'));
    // This is routing/presentation evidence, NOT a decoded-pixel assertion.
    await invariant();
  }
  try {
    const cap = await session.command('capabilities');
    for (const command of ['import-local-image', 'loaded-project', 'import-json']) assert.ok(cap.commands.includes(command));
    assert.ok(cap.semanticApplicationCommands.includes('import-local-image')); assert.equal(cap.cloudIsolation.network, 'disabled');
    await ui.tab('Script'); await session.command('key', { input: 's', modifiers: ['command'] });
    sample = await waitForSavedProject(session, p => p.title === 'YAM MAN');
    const fixture = firstLineImageFixture();
    await session.command('import-json', { text: JSON.stringify(fixture) });
    current = await waitForSavedProject(session, p => p.id !== sample.id);
    const expected = structuredClone(fixture);
    for (const key of ['id', 'createdAt', 'modifiedAt']) expected[key] = current[key];
    assert.deepEqual(current, expected, 'Import envelope alone changes, including no repair of fake old asset');
    await session.waitFor(nodes => nodes.some(n => n.identifier === 'workspace-project' && n.title === fixture.title));
    await check('first-line-input', async () => {
      await selectLine('direction'); await route(0, 'Select a script moment or image');
    });
    await check('first-line-import', async () => {
      const before = current;
      assert.deepEqual(await session.command('import-local-image', { fixture: 'coral' }, 30000),
        { dispatched: true, imported: true, cleanupVerified: true });
      current = await waitForSavedProject(session, p => p.id === before.id && p.images.length === 2);
      verifyFirstLineImport(before, current); await route(0, 'Image 2 · Version 1');
    });
    await check('later-line-route', async () => {
      await selectLine('dialogue'); await route(1500, 'Existing picture · Version 1', true);
    });
    await check('first-line-return', async () => {
      await selectLine('direction'); await route(0, 'Image 2 · Version 1');
    });
    assert.deepEqual(completed, firstLineCases);
  } catch (error) { throw new Error(`AUT-J08/local-images/${step} failed`, { cause: error }); }
  finally { await session.close(); }
}

// Portable contract checks only, never reported as a native journey pass.
const literal = firstLineImageFixture();
assert.deepEqual(literal.entries.map(e => [e.id, e.ownedDurationMs, e.coverageDurationMs]),
  [['direction', 1500, 8500], ['dialogue', 7000, 0]]);
assert.deepEqual(literal.entries[1].words.map(w => [w.text, w.startMs, w.endMs]),
  [['Every', 0, 1666], ['word', 1666, 3000], ['stays', 3000, 4667], ['intact.', 4667, 7000]]);
const portableAfter = structuredClone(literal);
portableAfter.images.push({ id: '11111111-1111-4111-8111-111111111111', version: 1,
  fileName: coralSHA + '.png', sha256: coralSHA, mimeType: 'image/png', byteCount: 73,
  characterIds: [], prompt: 'Imported image', createdAt: 1700000001000 });
portableAfter.cues.push({ id: '22222222-2222-4222-8222-222222222222', sceneId: 's',
  imageId: portableAfter.images[1].id, label: 'Image 2', startMs: 0, endMs: 1500,
  prompt: '', startAnchor: { entryId: 'direction', offsetMs: 0 }, authoredDurationMs: 1500 });
portableAfter.revision++; portableAfter.modifiedAt++;
verifyFirstLineImport(literal, portableAfter);
for (const corrupt of [
  p => { p.images[0].sha256 = coralSHA; },
  p => { p.images[1].previousVersionId = 'old'; },
  p => { p.cues[0].authoredDurationMs = 7000; },
  p => { p.cues[1].startAnchor.entryId = 'dialogue'; },
  p => { p.entries[1].words[0].endMs++; },
  p => { p.entries[0].coverageDurationMs = 1500; },
  p => { p.revision++; },
  p => { p.modifiedAt = literal.modifiedAt; },
]) {
  const invalid = structuredClone(portableAfter); corrupt(invalid);
  assert.throws(() => verifyFirstLineImport(literal, invalid), assert.AssertionError);
}
