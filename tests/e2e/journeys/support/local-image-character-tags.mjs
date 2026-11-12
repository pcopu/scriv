import assert from 'node:assert/strict';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { audioProjectFixture } from './audio-library-fixtures.mjs';
import { audioLibrarySteps, sortedProjects } from './audio-library-steps.mjs';

// Independent synthetic acceptance slice, not fixture-equivalent legacy retirement.
// All writes after fixture import use actual UIKit controls and the real importer.
export const pictureTagCases = ['tags-import-versions', 'tags-select-historical',
  'tags-add-two', 'tags-remove-readd', 'tags-done-reopen', 'tags-remove-all', 'tags-browser-reopen'];
export const pictureTagCharacters = [
  { id: 'tag-ada', name: 'Synthetic Ada', aliases: [], biography: 'Unchanged Ada biography', appearance: 'Coral coat', color: 'purple' },
  { id: 'tag-bo', name: 'Synthetic Bo', aliases: [], biography: 'Unchanged Bo biography', appearance: 'Blue coat', color: 'blue' },
];
const hashes = ['827d9145314e931860ee40b45f8348ad3527c93e008d1490b687265d947fb577',
  '3fba282698b3df63c76fb40e529943fb6da6d28bafa6ff9e3a75c0c4a0cbb784'];
const button = (node, character) => node.label === character.name && node.enabled !== undefined;

export async function runPictureCharacterTags(app) {
  const session = await ScrivSession.launch(app), ui = audioLibrarySteps(session);
  let sample, current, first, immutableDates, completedAt, step = 'tags-setup';
  const completed = [];
  async function check(name, body) {
    step = name; await body(); completed.push(name); console.log(`PASS: AUT-J08/local-images/${name}`);
  }
  async function persisted() {
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), sortedProjects([sample, current]),
      'Complete saved models, other versions, text, cue attachment, characters and sample stay exact');
    assert.deepEqual(await session.command('presented-alerts'), []);
  }
  async function loaded() {
    const result = await session.command('loaded-project');
    assert.deepEqual(result.project, current);
    assert.deepEqual(Object.keys(result).sort(), ['dateReferenceTimeBits', 'project']);
    const dates = result.dateReferenceTimeBits;
    assert.deepEqual(Object.keys(dates).sort(), ['createdAt', 'images', 'modifiedAt']);
    assert.match(dates.createdAt, /^\d+$/); assert.match(dates.modifiedAt, /^\d+$/);
    assert.deepEqual(dates.images.map(image => image.id), current.images.map(image => image.id));
    for (const image of dates.images) {
      assert.deepEqual(Object.keys(image).sort(), ['createdAt', 'id']); assert.match(image.createdAt, /^\d+$/);
    }
    if (immutableDates) {
      assert.equal(result.dateReferenceTimeBits.createdAt, immutableDates.createdAt);
      assert.deepEqual(result.dateReferenceTimeBits.images, immutableDates.images);
    }
    return result;
  }
  async function pixels() {
    for (let attempt = 0; attempt < 60; attempt++) {
      let evidence;
      try { evidence = await session.command('local-image-evidence'); }
      catch (error) {
        assert.match(error.message, /local-image-evidence: Local image evidence is unavailable or inconsistent\.?$/);
        if (attempt === 59) throw error;
        await new Promise(resolve => setTimeout(resolve, 100)); continue;
      }
      assert.equal(evidence.projectID, current.id); assert.equal(evidence.analysisScanning, false);
      assert.equal(evidence.generationJobCount, 0); assert.equal(evidence.assets.length, 2);
      for (const [index, asset] of current.images.entries()) {
        const record = evidence.assets.find(value => value.assetID === asset.id);
        assert.ok(record); assert.equal(record.sha256, hashes[index]); assert.equal(record.byteCount, 73);
        assert.equal(record.decoded, true); assert.equal(record.width, 2); assert.equal(record.height, 2);
      }
      if (evidence.assets.find(value => value.assetID === first.id).visiblePreviewCount > 0) return;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert.fail('Historical version did not become visibly decoded');
  }
  async function states(ids) {
    await session.waitFor(nodes => pictureTagCharacters.every(character => {
      const matches = nodes.filter(node => button(node, character));
      return matches.length === 1 && matches[0].value === (ids.includes(character.id) ? 'Pictured in this image' : 'Not tagged');
    }));
  }
  async function openTags(ids) {
    await ui.activate(node => node.label === 'Edit pictured character tags' && node.enabled !== undefined);
    await states(ids); await persisted();
  }
  async function done() {
    await ui.activate(node => node.title === 'Done' && node.enabled !== undefined);
    await session.waitFor(nodes => nodes.every(node => !pictureTagCharacters.some(character => button(node, character)))
      && nodes.some(node => node.identifier === 'preview-inspect' && node.hittable));
    await persisted(); await pixels(); return loaded();
  }
  async function toggle(character, chosen, excluded, manual) {
    const before = current;
    await ui.activate(node => button(node, character));
    const after = await waitForSavedProject(session, project => project.id === before.id && project.revision > before.revision);
    assert.equal(after.revision, before.revision + 1, 'One actual toggle creates exactly one revision');
    assert.ok(Number.isFinite(after.modifiedAt) && after.modifiedAt >= before.modifiedAt);
    const expected = structuredClone(before);
    expected.revision++; expected.modifiedAt = after.modifiedAt;
    expected.images[0].characterIds = chosen;
    if (manual) {
      const marker = after.images[0].characterAnalysis;
      assert.ok(marker);
      if (completedAt === undefined) {
        assert.ok(Number.isFinite(marker.completedAt) && marker.completedAt >= before.modifiedAt && marker.completedAt <= after.modifiedAt,
          'First removal authors a bounded manual marker timestamp');
        completedAt = marker.completedAt;
      }
      expected.images[0].characterAnalysis = { imageSHA256: first.sha256, imageVersion: 1,
        providerID: 'manual', completedAt, annotations: [], excludedCharacterIDs: excluded, manualCharacterIDs: chosen };
    }
    assert.deepEqual(after, expected, 'Only historical tags, documented manual marker and edit envelope change');
    current = after; await states(chosen); await persisted();
  }
  try {
    const cap = await session.command('capabilities');
    assert.equal(cap.cloudIsolation.network, 'disabled');
    for (const name of ['import-json', 'import-local-image', 'local-image-evidence', 'loaded-project', 'persisted-projects']) assert.ok(cap.commands.includes(name));
    await ui.tab('Script'); await session.command('key', { input: 's', modifiers: ['command'] });
    sample = await waitForSavedProject(session, project => project.title === 'YAM MAN');
    const fixture = audioProjectFixture(); fixture.title = 'Synthetic picture character tags';
    fixture.characters = structuredClone(pictureTagCharacters);
    await session.command('import-json', { text: JSON.stringify(fixture) });
    current = await waitForSavedProject(session, project => project.id !== sample.id);
    const expected = structuredClone(fixture);
    for (const key of ['id', 'createdAt', 'modifiedAt']) expected[key] = current[key];
    assert.deepEqual(current, expected);
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.title === fixture.title));
    await check('tags-import-versions', async () => {
      for (const [index, token] of ['coral', 'blue'].entries()) {
        const before = current;
        assert.deepEqual(await session.command('import-local-image', { fixture: token }, 30000),
          { dispatched: true, imported: true, cleanupVerified: true });
        const after = await waitForSavedProject(session, project => project.id === before.id && project.images.length === index + 1);
        const asset = after.images[index]; assert.match(asset.id, /^[A-Fa-f0-9-]{36}$/);
        assert.ok(Number.isFinite(asset.createdAt));
        assert.deepEqual(asset, { id: asset.id, version: index + 1, fileName: hashes[index] + '.png', sha256: hashes[index],
          mimeType: 'image/png', byteCount: 73, characterIds: [], prompt: 'Imported image', createdAt: asset.createdAt,
          ...(index ? { previousVersionId: first.id } : {}) });
        const expected = structuredClone(before); expected.revision++; expected.modifiedAt = after.modifiedAt;
        expected.images.push(asset); expected.cues[0].imageId = asset.id;
        assert.ok(Number.isFinite(after.modifiedAt) && after.modifiedAt >= before.modifiedAt);
        assert.deepEqual(after, expected); current = after; if (!index) first = asset;
        await persisted(); await loaded();
      }
      immutableDates = (await loaded()).dateReferenceTimeBits;
    });
    await check('tags-select-historical', async () => {
      const before = current;
      await ui.activate(node => node.identifier === 'preview-version');
      const nodes = await session.waitFor(nodes => nodes.some(node => node.identifier === 'image-picker-use-selection'));
      const historical = nodes.filter(node => node.label?.includes('\nVersion 1') && node.hittable);
      assert.equal(historical.length, 1); await session.command('activate', { target: historical[0].path });
      await ui.activate(node => node.identifier === 'image-picker-use-selection');
      current = await waitForSavedProject(session, project => project.id === before.id && project.revision > before.revision);
      const expected = structuredClone(before); expected.revision++; expected.modifiedAt = current.modifiedAt; expected.cues[0].imageId = first.id;
      assert.ok(Number.isFinite(current.modifiedAt) && current.modifiedAt >= before.modifiedAt);
      assert.deepEqual(current, expected); await persisted();
      // Saving the choice can precede animated picker dismissal. Observe the
      // actual dismissal before asking a workspace-only model observer.
      await session.waitFor(nodes => !nodes.some(node => node.identifier === 'image-picker-use-selection')
        && nodes.some(node => node.identifier === 'preview-inspect' && node.hittable));
      await loaded(); await pixels();
    });
    const [ada, bo] = pictureTagCharacters;
    await check('tags-add-two', async () => {
      await openTags([]); await toggle(ada, [ada.id], [], false); await toggle(bo, [ada.id, bo.id], [], false);
    });
    await check('tags-remove-readd', async () => {
      await toggle(ada, [bo.id], [ada.id], true); await toggle(ada, [ada.id, bo.id], [], true);
    });
    await check('tags-done-reopen', async () => {
      const before = await done(); await openTags([ada.id, bo.id]);
      assert.deepEqual(await done(), before, 'Done and sheet reopen preserve full loaded model and exact date witnesses');
    });
    await check('tags-remove-all', async () => {
      await openTags([ada.id, bo.id]); await toggle(ada, [bo.id], [ada.id], true);
      await toggle(bo, [], [ada.id, bo.id], true); await done();
    });
    await check('tags-browser-reopen', async () => {
      const before = await loaded(); await ui.openProject(sample);
      assert.deepEqual(await ui.openProject(current), before, 'Browser reopen preserves complete loaded/date witnesses');
      await persisted(); await pixels(); await openTags([]);
      assert.deepEqual(await done(), before, 'Persisted empty tags and manual exclusions survive browser and sheet reopen');
    });
    assert.deepEqual(completed, pictureTagCases);
  } catch (error) { throw new Error(`AUT-J08/local-images/${step} failed`, { cause: error }); }
  finally { await session.close(); }
}
