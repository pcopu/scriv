import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { stableContent } from './support/audio-library-fixtures.mjs';
import { audioLibrarySteps, sortedProjects } from './support/audio-library-steps.mjs';
import { packageFixtureToken, packageImageFixture, validatePackageImageFixture } from './support/package-image-fixture.mjs';
import { coverageSteps } from './support/picture-coverage-steps.mjs';

assert.ok(process.env.SCRIV_E2E_APP, 'Requires a signed Catalyst automation build');
validatePackageImageFixture();
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const ui = audioLibrarySteps(session);
const history = coverageSteps(session).history;
const byID = id => node => node.identifier === id;
const isReady = node => node.enabled && node.hittable;
const cutSlider = byID('split-picture-cut-preview');
const playback = byID('scene-playback-position');
let step = 'open the owned picture package and select the foreground';

try {
  assert.equal((await session.command('capabilities')).cloudIsolation.network, 'disabled');
  await ui.tab('Script');
  await session.command('key', { input: 's', modifiers: ['command'] });
  const sample = await waitForSavedProject(session, project => project.title === 'YAM MAN');
  const staged = await session.command('stage-package-fixture', { fixture: packageFixtureToken });
  const before = { ...packageImageFixture(), id: staged.projectID };
  assert.deepEqual((await ui.openProject(before)).project, before);
  await ui.tab('Script');
  const seek = await ui.reveal(playback);
  await session.command('slider', { target: seek.path, value: 1500 });
  const beforeLoaded = await session.command('loaded-project');
  assert.deepEqual(beforeLoaded.project, before);

  const packages = async () => sortedProjects(await session.command('persisted-projects'));
  const unchanged = async () => assert.deepEqual(await packages(), sortedProjects([sample, before]));
  const assets = async () => (await session.command('local-image-evidence')).assets
    .map(({ assetID, sha256, byteCount, decoded }) => ({ assetID, sha256, byteCount, decoded }));
  const originalAssets = await assets();
  assert.deepEqual(originalAssets, before.images.map(image => ({ assetID: image.id, sha256: image.sha256, byteCount: 73, decoded: true })));

  async function previewCut() {
    const selected = node => byID('script-picture-split')(node) && isReady(node);
    const source = await session.waitFor(nodes => nodes.filter(selected).length === 1
      && nodes.some(node => node.text === 'Foreground · Version 2'));
    await session.command('activate', { target: source.find(selected).path });
    const open = await session.waitFor(nodes => nodes.some(node => cutSlider(node) && isReady(node))
      && nodes.some(node => node.text === 'Split Foreground'));
    const slider = open.find(node => cutSlider(node) && isReady(node));
    assert.deepEqual(slider.slider, { minimum: 1001, maximum: 1999, value: 1500 });
    await assert.rejects(session.command('slider', { target: slider.path, value: 1000 }), /within its range/);
    await session.command('slider', { target: slider.path, value: 1700 });
    await session.waitFor(nodes => nodes.some(node => cutSlider(node) && node.slider?.value === 1700)
      && nodes.some(node => node.text === 'Before · 0.7s') && nodes.some(node => node.text === 'After · 0.3s'));
    await unchanged();
    return slider.windowPath;
  }
  async function dismissed() {
    await session.waitFor(nodes => !nodes.some(cutSlider)
      && nodes.some(node => playback(node) && isReady(node) && node.slider?.value === 1500));
  }

  step = 'cancel a cut preview without seeking or saving a change';
  const sheet = await previewCut();
  await ui.activate(node => node.type === 'UIButton' && node.title === 'Cancel' && node.windowPath === sheet && isReady(node));
  await dismissed();
  await unchanged();
  assert.deepEqual(await session.command('loaded-project'), beforeLoaded);

  step = 'commit the picture-only cut';
  await previewCut();
  await ui.activate(node => byID('split-picture-commit')(node) && isReady(node));
  await dismissed();
  const split = await waitForSavedProject(session, project => project.id === before.id && project.revision === before.revision + 1);
  const right = split.cues.find(cue => !before.cues.some(old => old.id === cue.id));
  assert.match(right.id, /^[0-9a-f-]{36}$/i);
  const [background, foreground] = before.cues;
  const expected = { ...before, cues: [background, { ...foreground, endMs: 1700, authoredDurationMs: 700 },
    { ...foreground, id: right.id, label: 'ForegroundB', startMs: 1700, authoredDurationMs: 300,
      startAnchor: { entryId: 'b', offsetMs: 700 } }] };
  assert.deepEqual(stableContent(split), stableContent(expected));
  assert.deepEqual(await assets(), originalAssets);
  const loadedSplit = await session.command('loaded-project');
  assert.deepEqual(loadedSplit.project, split);
  assert.equal(loadedSplit.dateReferenceTimeBits.createdAt, beforeLoaded.dateReferenceTimeBits.createdAt);
  assert.deepEqual(loadedSplit.dateReferenceTimeBits.images, beforeLoaded.dateReferenceTimeBits.images);

  step = 'undo, redo and reopen the split without replacing either image';
  // Close Projects to restore the workspace keyboard scope after the popover.
  await ui.activate(byID('workspace-project'));
  await ui.activate(node => node.label === 'Close Projects' && isReady(node));
  await session.waitFor(nodes => nodes.some(node => byID('workspace-project')(node) && isReady(node)));
  // History restore materializes the optional character metadata of old packages.
  const restoredContent = project => stableContent({ ...project, entries: project.entries.map(entry => ({ ...entry, characterLinks: [] })) });
  await history();
  const undone = await waitForSavedProject(session, project => project.id === before.id && project.revision === split.revision + 1);
  assert.deepEqual(stableContent(undone), restoredContent(before));
  await history(true);
  const redone = await waitForSavedProject(session, project => project.id === before.id && project.revision === undone.revision + 1);
  assert.deepEqual(stableContent(redone), restoredContent(expected));
  await ui.openProject(sample);
  assert.deepEqual((await ui.openProject(redone)).project, redone);
  assert.deepEqual(await assets(), originalAssets);
  assert.deepEqual(await packages(), sortedProjects([sample, redone]));
  assert.deepEqual(await session.command('presented-alerts'), []);
} catch (error) { throw new Error(`Native picture split failed during ${step}`, { cause: error }); }
finally { await session.close(); }
