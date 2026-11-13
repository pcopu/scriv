import assert from 'node:assert/strict';
import { imageBoundaryCases, runImageBoundary } from './support/local-image-boundary-steps.mjs';
import { sourceNavigationCases, runImageSourceNavigation } from './support/local-image-source-navigation.mjs';
import { pictureTagCases, runPictureCharacterTags } from './support/local-image-character-tags.mjs';
import { firstLineBaselineID, firstLineCases, runFirstLineImageCase } from '../support/first-line-image-case.mjs';
import { validateLocalImageFixtures } from './support/local-image-fixtures.mjs';
validateLocalImageFixtures();
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { audioProjectFixture, stableContent, editedContent } from './support/audio-library-fixtures.mjs';
import { audioLibrarySteps, sortedProjects } from './support/audio-library-steps.mjs';

// Actual post-picker import of finite synthetic PNGs and existing UIKit controls.
// First-line alone retains frozen, intentionally missing old-asset metadata. No provider.
const cases = ['reject-inputs', 'import-original', 'inspect-original', 'import-successor', 'choose-historical', 'browser-reopen'];
const placement = 'apps/mac/Tests/ScrivCoreTests/ImageImportPlacementTests.swift';
const inspector = 'apps/mac/Tests/ScrivCoreTests/ImageInspectorInvariantTests.swift';
const fixtureHashes = {
  coral: '827d9145314e931860ee40b45f8348ad3527c93e008d1490b687265d947fb577',
  blue: '3fba282698b3df63c76fb40e529943fb6da6d28bafa6ff9e3a75c0c4a0cbb784',
};
const args = process.argv.slice(2);
let group;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--list-cases') continue;
  assert.equal(args[i], '--group', 'Expected --list-cases or --group versions|first-line|tags|source-navigation|boundary');
  assert.equal(group, undefined, 'Specify --group only once');
  group = args[++i]; assert.ok(['versions', 'first-line', 'tags', 'source-navigation', 'boundary'].includes(group), 'Unknown local-images group');
}
const groups = group ? [group] : ['versions', 'first-line', 'tags', 'source-navigation', 'boundary'];
if (args.includes('--list-cases')) {
  console.log(JSON.stringify({ journey: 'AUT-J08', nativeVerified: false, groups,
    freshSessionPerGroup: true,
    sourceNavigationEvidence: 'Synthetic actual-UI source navigation; disabled unplaced historical version, placed exact-version cross-scene navigation and selected source-row witness. v48 scoped overlay passed; current composition evidence is recorded separately; no frozen baseline retirement.',
    pictureTagEvidence: 'Synthetic actual-UI acceptance, historical-version add/remove/readd and manual marker persistence; v47 tags overlay passed against v46 app; default composition evidence recorded separately, no legacy retirement.',
    cases: groups.flatMap(value => value === 'boundary' ? imageBoundaryCases : value === 'versions' ? cases : value === 'tags' ? pictureTagCases : value === 'source-navigation' ? sourceNavigationCases : firstLineCases),
    partialBaselineIDs: groups.includes('versions') ? [`${inspector}::0001`] : [],
    sourceCandidateBaselineIDs: groups.includes('first-line') ? [firstLineBaselineID] : [],
    relatedUncoveredBaselineIDs: [`${placement}::0004`, `${placement}::0005`],
    firstLineEvidence: 'Frozen ::0001 input and exact full saved/loaded model; native cue-label/playhead/missing-local routing, no decoded-pixel claim. Native and independent acceptance pending.',
    excluded: ['picker/cancel/pause', 'zero-owned placement fixture equivalence',
      'captured-target stale races', 'provider generation/analysis', 'portrait and prompt menus',
      'literal overlapping anchored cue and captured-prompt fixture equivalence',
      'first-line save/reopen/history ::0005', 'fault injection', 'legacy retirement'],
  }, null, 2));
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'Requires the reviewed isolated automation-enabled Catalyst app');
  for (const selected of groups) {
    if (selected === 'boundary') await runImageBoundary(process.env.SCRIV_E2E_APP);
    else if (selected === 'versions') await run();
    else if (selected === 'source-navigation') await runImageSourceNavigation(process.env.SCRIV_E2E_APP);
    else if (selected === 'tags') await runPictureCharacterTags(process.env.SCRIV_E2E_APP);
    else await runFirstLineImageCase(process.env.SCRIV_E2E_APP);
  }
}
async function run() {
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const ui = audioLibrarySteps(session);
  let sample, current, step = 'setup';
  const completed = [];
  const saved = async () => sortedProjects(await session.command('persisted-projects'));
  async function check(name, body) { step = name; await body(); completed.push(name); console.log(`PASS: AUT-J08/local-images/${name}`); }
  async function invariant(expected) {
    assert.deepEqual(await saved(), sortedProjects([sample, expected]), 'Every saved project field is accounted for');
    assert.deepEqual(await session.command('presented-alerts'), []);
  }
  async function visible(asset) {
    // Bounded poll of actual decoded UIKit image state, never infer pixels from metadata.
    for (let i = 0; i < 60; i++) {
      let result;
      try { result = await session.command('local-image-evidence'); }
      catch (error) {
        // Read-only observation may reject while the native sheet is animating.
        assert.match(error.message, /local-image-evidence: Local image evidence is unavailable or inconsistent\.?$/);
        if (i === 59) throw error;
        await new Promise(resolve => setTimeout(resolve, 100)); continue;
      }
      assert.equal(result.projectID, current.id); assert.equal(result.generationJobCount, 0); assert.equal(result.analysisScanning, false);
      const record = result.assets.find(item => item.assetID === asset.id);
      assert.ok(record); assert.equal(record.sha256, asset.sha256); assert.equal(record.byteCount, 73);
      assert.equal(record.decoded, true); assert.equal(record.width, 2); assert.equal(record.height, 2);
      if (record.visiblePreviewCount > 0) return;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert.fail('Imported image never became visibly decoded in the active UIKit surface');
  }
  async function importVersion(fixture) {
    const before = current;
    assert.deepEqual(await session.command('import-local-image', { fixture }, 30000),
      { dispatched: true, imported: true, cleanupVerified: true });
    const after = await waitForSavedProject(session, p => p.id === before.id && p.images.length === before.images.length + 1);
    const asset = after.images.at(-1), previous = before.images.at(-1);
    assert.match(asset.id, /^[A-Fa-f0-9-]{36}$/); assert.equal(asset.sha256, fixtureHashes[fixture]);
    assert.equal(asset.fileName, fixtureHashes[fixture] + '.png'); assert.equal(asset.byteCount, 73);
    assert.equal(asset.mimeType, 'image/png'); assert.equal(asset.prompt, 'Imported image');
    assert.deepEqual(asset.characterIds, []); assert.ok(Number.isFinite(asset.createdAt));
    assert.deepEqual(Object.keys(asset).sort(), ['id', 'version', 'fileName', 'sha256', 'mimeType',
      'byteCount', 'characterIds', 'prompt', 'createdAt', ...(previous ? ['previousVersionId'] : [])].sort());
    assert.equal(asset.generationPrompt, undefined); assert.equal(asset.characterAnalysis, undefined);
    assert.equal(asset.version, previous ? previous.version + 1 : 1);
    assert.equal(asset.previousVersionId, previous?.id);
    assert.equal(after.revision, before.revision + 1);
    assert.deepEqual(stableContent(after), editedContent(before, p => {
      p.images.push(asset); p.cues.find(c => c.id === 'image1').imageId = asset.id;
    }), 'Importer changes only its target attachment and app-generated immutable asset');
    current = after; await invariant(current); await visible(asset);
    assert.deepEqual((await session.command('loaded-project')).project, current);
    return asset;
  }
  try {
    const cap = await session.command('capabilities');
    for (const command of ['import-local-image', 'local-image-evidence', 'loaded-project', 'import-json']) assert.ok(cap.commands.includes(command));
    assert.ok(cap.semanticApplicationCommands.includes('import-local-image'));
    assert.equal(cap.cloudIsolation.network, 'disabled');
    await ui.tab('Script'); await session.command('key', { input: 's', modifiers: ['command'] });
    sample = await waitForSavedProject(session, p => p.title === 'YAM MAN');
    const fixture = audioProjectFixture(); fixture.title = 'Synthetic local image versions';
    await session.command('import-json', { text: JSON.stringify(fixture) });
    current = await waitForSavedProject(session, p => p.id !== sample.id);
    const expected = structuredClone(fixture);
    for (const key of ['id', 'createdAt', 'modifiedAt']) expected[key] = current[key];
    assert.deepEqual(current, expected);
    await session.waitFor(nodes => nodes.some(n => n.identifier === 'workspace-project' && n.title === fixture.title));
    await check('reject-inputs', async () => {
      for (const request of [{}, { fixture: null }, { fixture: '../coral' }, { fixture: 'coral', path: '/tmp/image.png' }, { fixture: 'coral', base64: 'x' }]) {
        await assert.rejects(session.command('import-local-image', request), /import-local-image: Synthetic image import is unavailable or invalid\.?$/); await invariant(current);
      }
    });
    let first;
    await check('import-original', async () => { first = await importVersion('coral'); });
    await check('inspect-original', async () => {
      await ui.activate(n => n.identifier === 'preview-inspect');
      await session.waitFor(nodes => nodes.some(n => n.title === 'Show in script'));
      await visible(first); await invariant(current);
      await assert.rejects(session.command('import-local-image', { fixture: 'blue' }),
        /import-local-image: Synthetic image import is unavailable or invalid\.?$/,
        'An inspector cannot silently import into the covered workspace');
      await invariant(current);
      await ui.activate(n => n.title === 'Done' && n.enabled !== undefined);
      await session.waitFor(nodes => nodes.some(n => n.identifier === 'preview-inspect' && n.hittable));
      assert.deepEqual((await session.command('loaded-project')).project, current);
    });
    await check('import-successor', () => importVersion('blue'));
    await check('choose-historical', async () => {
      const before = current;
      await ui.activate(n => n.identifier === 'preview-version');
      const nodes = await session.waitFor(nodes => nodes.some(n => n.identifier === 'image-picker-use-selection'));
      const historical = nodes.filter(n => n.label?.includes('\nVersion 1') && n.hittable);
      assert.equal(historical.length, 1, 'Exactly one real historical collection cell');
      await session.command('activate', { target: historical[0].path });
      await ui.activate(n => n.identifier === 'image-picker-use-selection');
      current = await waitForSavedProject(session, p => p.id === before.id && p.revision > before.revision);
      assert.equal(current.revision, before.revision + 1);
      assert.deepEqual(stableContent(current), editedContent(before, p => { p.cues.find(c => c.id === 'image1').imageId = first.id; }),
        'Historical choice preserves all source, timing, other cues, assets, lineage and unrelated model fields');
      await invariant(current); await visible(first);
    });
    await check('browser-reopen', async () => {
      const before = await session.command('loaded-project');
      await ui.openProject(sample); assert.deepEqual(await ui.openProject(current), before);
      await invariant(current); await visible(first);
    });
    assert.deepEqual(completed, cases);
  } catch (error) { throw new Error(`AUT-J08/local-images/${step} failed`, { cause: error }); }
  finally { await session.close(); }
}
