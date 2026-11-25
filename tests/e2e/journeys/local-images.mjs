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
const defaultGroups = ['versions', 'first-line', 'tags', 'source-navigation', 'boundary'];
const availableGroups = [...defaultGroups, 'picker-playback'];
const pickerCases = ['open the Storyboard image picker during playback and keep the saved script intact'];
let group;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--list-cases') continue;
  assert.equal(args[i], '--group', 'Expected --list-cases or --group ' + availableGroups.join('|'));
  assert.equal(group, undefined, 'Specify --group only once');
  group = args[++i]; assert.ok(availableGroups.includes(group), 'Unknown local-images group');
}
const listing = args.includes('--list-cases');
const groups = group ? [group] : listing ? availableGroups : defaultGroups;
if (listing) {
  const listedCases = { versions: cases, 'first-line': firstLineCases, tags: pictureTagCases,
    'source-navigation': sourceNavigationCases, boundary: imageBoundaryCases, 'picker-playback': pickerCases };
  console.log(JSON.stringify({ journey: 'AUT-J08', nativeVerified: false, groups,
    freshSessionPerGroup: true,
    groupWitnessPaths: groups.includes('first-line') ? { 'first-line': ['tests/e2e/support/first-line-image-case.mjs'] } : {},
    groupActions: groups.includes('picker-playback') ? { 'picker-playback': [{
      id: 'open-storyboard-image-picker', command: 'activate', trigger: 'Import image',
      condition: 'image-picker-opens-while-the-scene-is-playing', entryPoint: {
        path: 'apps/catalyst/ScrivUIKit/Images/StoryboardViewController.swift', start: 63, end: 63,
        sha256: 'e7ee0d2c0ebf0cd703447cdbdc0f6927e3ea7b7291f9a803f6f57cf9fd3a4cb7',
      }, branch: {
        path: 'apps/mac/Sources/ScrivApp/Services/WorkspaceStore.swift', start: 1378, end: 1387,
        sha256: '59797b464d6921388a78356ca034a428cf6e40d09af742294dcca8b30cfc6ce1',
      },
    }] } : {},
    sourceNavigationEvidence: 'Synthetic actual-UI source navigation; disabled unplaced historical version, placed exact-version cross-scene navigation and selected source-row witness. v48 scoped overlay passed; current composition evidence is recorded separately; no frozen baseline retirement.',
    pictureTagEvidence: 'Synthetic actual-UI acceptance, historical-version add/remove/readd and manual marker persistence; v47 tags overlay passed against v46 app; default composition evidence recorded separately, no legacy retirement.',
    cases: groups.flatMap(value => listedCases[value]),
    partialBaselineIDs: groups.includes('versions') ? [`${inspector}::0001`] : [],
    sourceCandidateBaselineIDs: groups.includes('first-line') ? [firstLineBaselineID] : [],
    relatedUncoveredBaselineIDs: [`${placement}::0004`, `${placement}::0005`],
    firstLineEvidence: 'Frozen ::0001 input and exact full saved/loaded model; native cue-label/playhead/missing-local routing, no decoded-pixel claim. Native and independent acceptance pending.',
    excluded: ['platform picker selection and cancellation', 'zero-owned placement fixture equivalence',
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
    else if (selected === 'picker-playback') await verifyPickerDuringPlayback();
    else await runFirstLineImageCase(process.env.SCRIV_E2E_APP);
  }
}
async function verifyPickerDuringPlayback() {
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const ui = audioLibrarySteps(session);
  const position = nodes => nodes.find(node => node.identifier === 'scene-playback-position')?.slider;
  const playback = (nodes, label) => nodes.some(node => node.label === label && node.enabled);
  try {
    assert.equal((await session.command('capabilities')).cloudIsolation.network, 'disabled');
    const input = audioProjectFixture();
    input.title = 'Synthetic image picker playback';
    input.entries.at(-1).ownedDurationMs = 60_000;
    await ui.tab('Script');
    await session.command('key', { input: 's', modifiers: ['command'] });
    await waitForSavedProject(session, project => project.title === 'YAM MAN');
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }),
      { dispatched: true, projectChanged: true });
    const loaded = await waitForSavedProject(session, project => project.title === input.title);
    const saved = await session.command('persisted-projects');
    assert.deepEqual((await session.command('loaded-project')).project, loaded);
    await ui.tab('Storyboard');
    await ui.activate(node => node.label === 'Play scene');
    await session.waitFor(nodes => playback(nodes, 'Pause scene') && position(nodes)?.value > 50);
    const importer = node => node.type === 'UIButton' && (node.label === 'Import image' || node.title === 'Import image');
    await ui.activate(importer);
    // The platform picker can be a separate window. The loaded-model guard
    // observes the modal on its UIKit presenter independent of hit-testing.
    assert.deepEqual(await session.command('persisted-projects'), saved);
    await assert.rejects(session.command('loaded-project'), /Synthetic loaded-project observation is unavailable or invalid/);
    assert.deepEqual(await session.command('presented-alerts'), []);
    console.log('PASS: the native image picker opens during playback and leaves saved projects unchanged');
  } finally { await session.close(); }
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
    const discussionBaseline = await session.command('loaded-project');
    const discussionPackages = await saved();
    for (let cycle = 0; cycle < 2; cycle++) {
      await ui.activate(node => node.identifier === 'preview-inspect');
      const discuss = await ui.reveal(node => node.title === 'Discuss this version' && node.enabled !== undefined);
      // Hittability precedes UIKit transition completion. Wait for the same
      // inspector control to remain attached at stable geometry for one second.
      let signature = '', stableSince = 0;
      await session.waitFor(nodes => {
        const target = nodes.find(node => node.path === discuss.path && node.hittable && node.enabled);
        const next = target ? JSON.stringify(target.frame) : '';
        if (!next || next !== signature) { signature = next; stableSince = Date.now(); return false; }
        return Date.now() - stableSince >= 1000;
      });
      await session.command('activate', { target: discuss.path });
      let nodes = await session.waitFor(nodes => nodes.some(node => node.text === 'Sign in to keep the conversation')
        && nodes.some(node => node.label === 'Close discussion' && node.hittable && node.enabled));
      assert.ok(nodes.some(node => node.text === 'Threads attach to lines, directions, characters and images. Shared projects include everyone on your team.'));
      assert.ok(nodes.some(node => node.text === 'Comments stay with this image.'));
      assert.equal(nodes.filter(node => node.title === 'Sign in to Scriv' && node.enabled && node.hittable).length, 1);
      assert.equal(nodes.some(node => node.type === 'DiscussionComposerTextView' && node.editable && node.hittable), false, 'Signed-out discussion offers no comment composer');
      const activity = nodes.filter(node => node.label === 'Project activity, 0 unread mentions');
      assert.equal(activity.length, 1);
      assert.equal(activity[0].enabled, false, 'Signed-out discussion cannot load project activity');
      assert.deepEqual(await session.command('loaded-project'), discussionBaseline, 'Opening image discussion preserves every loaded field and date');
      assert.deepEqual(await saved(), discussionPackages, 'Opening discussion preserves both complete saved packages');
      const scopes = nodes.filter(node => node.type === 'UISegmentedControl' && node.hittable && node.segments?.[0] === 'Project');
      assert.equal(scopes.length, 1);
      assert.deepEqual(scopes[0].segments, ['Project', 'This image']);
      assert.equal(scopes[0].selected, 1);
      await session.command('select', { target: scopes[0].path, index: 0 });
      await session.waitFor(nodes => nodes.some(node => node.text === 'Comments stay with this project.')
        && nodes.some(node => node.type === 'UISegmentedControl' && node.segments?.[0] === 'Project' && node.selected === 0));
      await ui.activate(node => node.label === 'Close discussion' && node.enabled !== undefined);
      await session.waitFor(nodes => !nodes.some(node => node.label === 'Close discussion')
        && nodes.some(node => node.identifier === 'preview-inspect' && node.hittable && node.enabled));
      assert.deepEqual(await session.command('loaded-project'), discussionBaseline, 'Changing signed-out scope and closing preserves every loaded field and date');
      assert.deepEqual(await saved(), discussionPackages, 'Discussion scope changes preserve both complete saved packages');
      await invariant(current); await visible(first);
    }
    console.log('PASS: AUT-J08/local-images/signed-out-image-discussion: real inspector route, image/project scopes, close/reopen and complete model preservation');
  } catch (error) { throw new Error(`AUT-J08/local-images/${step} failed`, { cause: error }); }
  finally { await session.close(); }
}
