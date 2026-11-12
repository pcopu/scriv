import assert from 'node:assert/strict';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { audioProjectFixture, syntheticPCM, verifyImportedAsset } from './audio-library-fixtures.mjs';
import { audioLibrarySteps } from './audio-library-steps.mjs';
import { coverageSteps, sorted } from './picture-coverage-steps.mjs';

export const mergeListing = {
  journey: 'AUT-J09', portion: 'storyboard-original-menu-merge', nativeVerified: false, optIn: true,
  cases: ['unsupported-actions-rejected', 'merge-two-anchored-pictures', 'undo-redo', 'browser-reopen', 'no-next-rejected'],
  inputRoute: 'Production JSON/audio/image import > mounted Storyboard ellipsis UIButton original UIAction',
  additionalAcceptance: ['left image/version and both image assets preserved', 'entire model and exact revision',
    'script/words/audio preserved', 'real Undo/Redo', 'startup package unchanged'],
  excluded: ['Remove confirmation', 'split', 'fill', 'providers', 'physical menu selection', 'drag', 'restart recovery', 'legacy retirement'],
};
export function mergeFixture() {
  const source = audioProjectFixture();
  source.title = 'Synthetic original storyboard merge';
  for (const entry of source.entries) entry.characterLinks = [];
  source.cues[0] = { ...source.cues[0], label: 'Left coral', prompt: 'Keep left direction',
    startAnchor: { entryId: 'line1', offsetMs: 0 }, authoredDurationMs: 3000 };
  source.cues[1] = { ...source.cues[1], label: 'Right blue', prompt: 'Keep right asset',
    startAnchor: { entryId: 'line2', offsetMs: 0 }, authoredDurationMs: 2000 };
  return source;
}
function content(project) {
  const result = structuredClone(project); delete result.revision; delete result.modifiedAt; return result;
}
const hashes = { coral: '827d9145314e931860ee40b45f8348ad3527c93e008d1490b687265d947fb577',
  blue: '3fba282698b3df63c76fb40e529943fb6da6d28bafa6ff9e3a75c0c4a0cbb784' };
const mergeTitle = 'Merge with next placement';
const scope = 'storyboard-merge';
export async function runMergeJourney() {
  assert.ok(process.env.SCRIV_E2E_APP, 'Requires an isolated automation-enabled Catalyst app');
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const ui = coverageSteps(session), browser = audioLibrarySteps(session);
  let current, sample, stage = 'setup';
  async function invariant() {
    assert.deepEqual(sorted(await session.command('persisted-projects')), sorted([sample, current]));
    assert.deepEqual((await session.command('loaded-project')).project, current);
    assert.deepEqual(await session.command('presented-alerts'), []);
  }
  async function saveAfter(before, expected) {
    const saved = await waitForSavedProject(session, p => p.id === before.id && p.revision > before.revision);
    assert.equal(saved.revision, before.revision + 1);
    assert.ok(Number.isFinite(saved.modifiedAt) && saved.modifiedAt >= before.modifiedAt,
      'Commit timestamp is finite and does not move backward');
    assert.deepEqual(content(saved), expected, 'Complete model changes only in the explicitly expected fields');
    current = saved; await invariant(); return saved;
  }
  async function target(label = 'Left coral') {
    return ui.reveal(n => n.label === `Picture actions for ${label}`);
  }
  async function reject(request) {
    const before = await session.command('loaded-project');
    await assert.rejects(session.command('menu-action', request), /outside the supported/);
    assert.deepEqual(await session.command('loaded-project'), before, 'Rejected request changes no loaded field or Date bits');
    await invariant();
  }
  async function image(token, wordID, cueID) {
    await ui.tab('Storyboard'); await ui.activate(n => n.identifier === `storyboard-word-${wordID}`);
    const before = current;
    assert.deepEqual(await session.command('import-local-image', { fixture: token }, 30000),
      { dispatched: true, imported: true, cleanupVerified: true });
    const saved = await waitForSavedProject(session, p => p.id === before.id && p.images.length === before.images.length + 1);
    const asset = saved.images.find(a => !before.images.some(b => b.id === a.id));
    assert.ok(asset); assert.equal(asset.sha256, hashes[token]); assert.equal(asset.version, 1);
    assert.equal(asset.previousVersionId, undefined); assert.equal(asset.byteCount, 73);
    const expected = content(before); expected.images.push(asset);
    expected.cues.find(c => c.id === cueID).imageId = asset.id;
    await saveAfter(before, expected);
    const evidence = await session.command('local-image-evidence');
    assert.equal(evidence.projectID, current.id);
    assert.ok(evidence.assets.some(a => a.assetID === asset.id && a.decoded && a.sha256 === hashes[token]));
    return asset;
  }
  try {
    const capabilities = await session.command('capabilities');
    assert.equal(capabilities.cloudIsolation.network, 'disabled');
    for (const command of ['menu-action', 'import-json', 'import-local-image', 'local-image-evidence',
      'import-audio', 'loaded-project', 'persisted-projects', 'keys', 'key']) assert.ok(capabilities.commands.includes(command));
    await ui.tab('Script'); await session.command('key', { input: 's', modifiers: ['command'] });
    sample = await waitForSavedProject(session, p => p.entries.length > 0);
    assert.equal((await session.command('persisted-projects')).length, 1);
    const source = mergeFixture();
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(source) }),
      { dispatched: true, projectChanged: true });
    current = await waitForSavedProject(session, p => p.id !== sample.id);
    const expected = structuredClone(source);
    for (const key of ['id', 'createdAt', 'modifiedAt']) expected[key] = current[key];
    assert.notEqual(current.id, source.id);
    assert.match(current.id, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
    assert.ok(Number.isFinite(current.createdAt) && Number.isFinite(current.modifiedAt));
    assert.equal(current.createdAt, current.modifiedAt);
    assert.deepEqual(current, expected);
    // Real bounded synthetic audio import makes audio-preservation non-vacuous.
    const beforeAudio = current, bytes = syntheticPCM();
    const audioResult = await session.command('import-audio', { base64: bytes.toString('base64'), attachment: 'scene' }, 30000);
    assert.equal(audioResult.imported, true);
    current = await waitForSavedProject(session, p => p.id === beforeAudio.id && p.audioAssets.length === 1);
    verifyImportedAsset(current.audioAssets[0], bytes);
    assert.equal(current.audioClips.length, 1); assert.equal(current.revision, beforeAudio.revision + 1);
    const audioExpected = content(beforeAudio);
    audioExpected.audioAssets = current.audioAssets; audioExpected.audioClips = current.audioClips;
    assert.deepEqual(content(current), audioExpected); await invariant();
    const left = await image('coral', 'w1', 'image1');
    const right = await image('blue', 'line2-word', 'image2');
    assert.notEqual(left.id, right.id);
    await session.command('end-editing');
    stage = 'unsupported-actions-rejected';
    for (const action of ['Remove placement…', 'Import image…', 'Generate image', 'Preview picture split…',
      'Discuss image', 'Choose existing image…', 'Inspect image…', 'Picture source…', 'Fetch image']) {
      await reject({ target: (await target()).path, scope, action });
    }
    await reject({ target: (await target()).path, scope, action: mergeTitle, cueID: 'image1' });
    await reject({ target: (await target()).path, scope: 'unsupported-storyboard', action: mergeTitle });
    await reject({ target: (await target('Right blue')).path, scope, action: mergeTitle });
    console.log('PASS AUT-J09/merge/unsupported-actions-rejected');
    stage = 'merge-two-anchored-pictures';
    const before = current;
    const merged = content(before); merged.cues = [structuredClone(before.cues[0])];
    merged.cues[0].endMs = 5000; merged.cues[0].authoredDurationMs = 5000;
    assert.deepEqual(await session.command('menu-action', { target: (await target()).path, scope, action: mergeTitle }),
      { dispatched: true, coverage: 'semantic-menu-action' });
    await saveAfter(before, merged);
    assert.equal(current.cues[0].imageId, left.id);
    assert.deepEqual(current.images, before.images); assert.equal(current.images.length, 2);
    assert.deepEqual(current.audioAssets, before.audioAssets); assert.deepEqual(current.audioClips, before.audioClips);
    assert.deepEqual(current.entries, before.entries);
    console.log('PASS AUT-J09/merge/merge-two-anchored-pictures');
    stage = 'undo-redo';
    await ui.history(); await saveAfter(current, content(before));
    await ui.history(true); await saveAfter(current, merged);
    console.log('PASS AUT-J09/merge/undo-redo');
    stage = 'browser-reopen';
    const loaded = await session.command('loaded-project');
    assert.deepEqual((await browser.openProject(sample)).project, sample);
    assert.deepEqual(await browser.openProject(current), loaded);
    await invariant(); await ui.tab('Storyboard');
    console.log('PASS AUT-J09/merge/browser-reopen');
    stage = 'no-next-rejected';
    await reject({ target: (await target()).path, scope, action: mergeTitle });
    console.log('PASS AUT-J09/merge/no-next-rejected');
    console.log('PASS AUT-J09 merge: original stored UIAction semantic dispatch. No delete/fill/split or legacy retirement claim.');
  } catch (error) { console.error(`FAIL AUT-J09/merge/${stage}`); throw error; }
  finally { await session.close(); }
}
const fixture = mergeFixture();
assert.equal(fixture.cues.length, 2); assert.equal(fixture.entries.flatMap(e => e.words).length, 4);
assert.deepEqual(fixture.cues.map(c => [c.startMs, c.endMs, c.authoredDurationMs]), [[0, 3000, 3000], [3000, 5000, 2000]]);
