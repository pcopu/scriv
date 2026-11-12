import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { audioLibrarySteps, sortedProjects } from './support/audio-library-steps.mjs';
import { stableContent, editedContent } from './support/audio-library-fixtures.mjs';
import { reviewFixtureToken, characterReviewFixture, validateCharacterReviewFixture,
  characterImageReviewSteps } from './support/character-image-review-steps.mjs';

const cases = ['stage-and-open-exact-package', 'source-image-pixels', 'disabled-save-and-skip-done-reopen',
  'existing-character-save-and-next', 'ignore-and-untouched-successor', 'skip-final-done-and-browser-reopen'];
validateCharacterReviewFixture();
assert.ok(process.argv.slice(2).every(arg => arg === '--list-cases'));
if (process.argv.includes('--list-cases')) {
  console.log(JSON.stringify({ journey: 'character-image-review', nativeVerified: false, cases,
    scope: 'Actual UI review of explicitly seeded prior analysis; no provider execution',
    pixels: 'Known source PNG bytes and decoded Script previews, not modal crop or face detection evidence',
    excluded: ['provider/scan execution', 'new-name alert', 'review crop pixel proof', 'disk portrait cache',
      'physical input', 'login/teams', 'legacy retirement'] }, null, 2));
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'Requires isolated automation-enabled Catalyst app');
  await run();
}
async function run() {
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const ui = audioLibrarySteps(session), review = characterImageReviewSteps(session, ui);
  let sample, current, initialLoaded, step = 'setup';
  const completed = [];
  const saved = async () => sortedProjects(await session.command('persisted-projects'));
  const exactSaved = async () => assert.deepEqual(await saved(), sortedProjects([sample, current]));
  async function check(name, body) {
    step = name; await body(); completed.push(name); console.log(`PASS character-image-review/${name}`);
  }
  async function loadedInvariant() {
    await exactSaved();
    const loaded = await session.command('loaded-project');
    assert.deepEqual(loaded.project, current);
    assert.equal(loaded.dateReferenceTimeBits.createdAt, initialLoaded.dateReferenceTimeBits.createdAt);
    assert.deepEqual(loaded.dateReferenceTimeBits.images, initialLoaded.dateReferenceTimeBits.images);
    assert.deepEqual(await session.command('presented-alerts'), []);
    return loaded;
  }
  async function mutation(change) {
    const before = current;
    current = await waitForSavedProject(session, p => p.id === before.id && p.revision > before.revision);
    assert.equal(current.revision, before.revision + 1);
    assert.ok(Number.isFinite(current.modifiedAt) && current.modifiedAt >= before.modifiedAt);
    assert.deepEqual(stableContent(current), editedContent(before, change),
      'Only the exact reviewed annotation/tag/portrait delta may change; preserve all other package fields');
    assert.deepEqual(current.images[1], before.images[1], 'Successor bytes metadata, version and absent analysis stay exact');
    await exactSaved();
  }
  async function verifySourceImagePixels() {
    // Only called outside review; re-read real PNG bytes after each edit.
    const before = await loadedInvariant(); await ui.tab('Script');
    for (const [ms, id] of [[0, 'v1'], [1500, 'v2']]) {
      const slider = await ui.reveal(n => n.identifier === 'scene-playback-position');
      await session.command('slider', { target: slider.path, value: ms });
      let visible = false;
      for (let attempt = 0; attempt < 60; attempt++) {
        const evidence = await session.command('local-image-evidence');
        assert.equal(evidence.projectID, current.id); assert.equal(evidence.generationJobCount, 0);
        assert.equal(evidence.analysisScanning, false); assert.equal(evidence.assets.length, 2);
        for (const asset of current.images) {
          const actual = evidence.assets.find(a => a.assetID === asset.id);
          assert.ok(actual); assert.equal(actual.sha256, asset.sha256); assert.equal(actual.byteCount, 73);
          assert.equal(actual.decoded, true); assert.equal(actual.width, 2); assert.equal(actual.height, 2);
        }
        if (evidence.assets.find(a => a.assetID === id).visiblePreviewCount > 0) { visible = true; break; }
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      assert.ok(visible, `Actual Script preview must decode ${id}, not merely expose its saved metadata`);
    }
    assert.deepEqual(await loadedInvariant(), before);
  }
  try {
    const cap = await session.command('capabilities');
    for (const c of ['stage-package-fixture', 'persisted-projects', 'loaded-project', 'local-image-evidence']) assert.ok(cap.commands.includes(c));
    assert.equal(cap.cloudIsolation.network, 'disabled');
    await ui.tab('Script'); await session.command('key', { input: 's', modifiers: ['command'] });
    sample = await waitForSavedProject(session, p => p.title === 'YAM MAN');
    await check(cases[0], async () => {
      const before = await session.command('loaded-project');
      const staged = await session.command('stage-package-fixture', { fixture: reviewFixtureToken });
      assert.deepEqual(Object.keys(staged).sort(), ['fixture', 'projectID', 'title']);
      assert.equal(staged.fixture, reviewFixtureToken); assert.match(staged.projectID, /^[A-Fa-f0-9-]{36}$/);
      current = characterReviewFixture(); current.id = staged.projectID;
      assert.equal(staged.title, current.title); assert.notEqual(current.id, sample.id);
      assert.deepEqual(await session.command('loaded-project'), before);
      await exactSaved();
      await assert.rejects(session.command('stage-package-fixture', { fixture: reviewFixtureToken }), /Synthetic package fixture is unavailable or invalid\.?$/);
      await exactSaved(); assert.deepEqual(await session.command('loaded-project'), before);
      initialLoaded = await ui.openProject(current);
      assert.deepEqual(initialLoaded.project, current); await loadedInvariant();
    });
    await check(cases[1], verifySourceImagePixels);
    await check(cases[2], async () => {
      const before = await loadedInvariant();
      await review.open(1, 3); await review.rejectDisabledSave(); await exactSaved();
      await review.skip(); await review.candidate(2, 2); await exactSaved();
      await review.done(); assert.deepEqual(await loadedInvariant(), before);
      await review.open(1, 3); await exactSaved();
      await review.done(); assert.deepEqual(await loadedInvariant(), before);
    });
    await check(cases[3], async () => {
      await review.open(1, 3); await review.chooseExisting(); await exactSaved();
      await review.save(); await review.candidate(2, 2);
      await mutation(p => {
        p.images[0].characterAnalysis.annotations[0].characterID = 'synthetic-existing';
        p.images[0].characterAnalysis.annotations[0].decision = 'confirmed';
        p.images[0].characterIds = ['synthetic-existing'];
        p.characters[0].portraitImageId = 'v1';
        p.characters[0].portraitRegion = { imageID: 'v1', imageSHA256: p.images[0].sha256,
          region: { x: 0, y: 0, width: 0.5, height: 0.5 }, isAutomatic: true };
      });
      await review.done(); await loadedInvariant(); await verifySourceImagePixels();
    });
    await check(cases[4], async () => {
      await review.open(2, 2); await review.ignore(); await review.candidate(3, 1);
      await mutation(p => { p.images[0].characterAnalysis.annotations[1].decision = 'ignored'; });
      await review.done(); await loadedInvariant(); await verifySourceImagePixels();
    });
    await check(cases[5], async () => {
      const before = await loadedInvariant();
      await review.open(3, 1); await review.skip();
      await session.waitFor(nodes => nodes.some(n => n.text === 'Nothing else to review')
        && nodes.some(n => n.text === 'Skipped candidates remain in Characters, ready when you are.'));
      await exactSaved(); await review.done(); assert.deepEqual(await loadedInvariant(), before);
      await ui.openProject(sample); assert.deepEqual(await ui.openProject(current), before);
      await review.open(3, 1); await exactSaved(); await review.done();
      assert.deepEqual(await loadedInvariant(), before);
    });
    assert.deepEqual(completed, cases);
  } catch (error) { throw new Error(`character-image-review/${step} failed`, { cause: error }); }
  finally { await session.close(); }
}
