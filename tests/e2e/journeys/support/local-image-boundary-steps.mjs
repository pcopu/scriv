import assert from 'node:assert/strict';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { firstLineImageFixture } from '../../support/first-line-image-case.mjs';
import { audioLibrarySteps, sortedProjects } from './audio-library-steps.mjs';

export const imageBoundaryCases = ['zero-owned-source', 'zero-owned-import', 'zero-owned-reopen'];
const coralSHA = '827d9145314e931860ee40b45f8348ad3527c93e008d1490b687265d947fb577';

// Independent acceptance input. Keep the existing later cue as an exact sentinel,
// with no unavailable asset, so decoded evidence can examine the complete package.
export function imageBoundaryFixture() {
  const fixture = firstLineImageFixture();
  fixture.title = 'Synthetic zero-owned image boundary';
  fixture.entries[0].ownedDurationMs = 0;
  fixture.entries[1].ownedDurationMs = 8500;
  fixture.images = [];
  delete fixture.cues[0].imageId;
  fixture.cues[0].startAnchor.offsetMs = 1500;
  return fixture;
}

export function verifyBoundaryImport(before, after) {
  assert.equal(after.images.length, 1); assert.equal(after.cues.length, 2);
  const asset = after.images[0], cue = after.cues[1];
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  assert.match(asset.id, uuid); assert.match(cue.id, uuid); assert.notEqual(asset.id, cue.id);
  assert.ok(Number.isFinite(asset.createdAt));
  assert.deepEqual(asset, { id: asset.id, version: 1, fileName: coralSHA + '.png', sha256: coralSHA,
    mimeType: 'image/png', byteCount: 73, characterIds: [], prompt: 'Imported image', createdAt: asset.createdAt });
  assert.deepEqual(cue, { id: cue.id, sceneId: 's', imageId: asset.id, label: 'Image 2', startMs: 0,
    endMs: 1500, prompt: '', startAnchor: { entryId: 'direction', offsetMs: 0 }, authoredDurationMs: 1500 });
  const expected = structuredClone(before);
  expected.images.push(asset); expected.cues.push(cue); expected.revision++;
  assert.ok(Number.isFinite(after.modifiedAt) && after.modifiedAt > before.modifiedAt);
  expected.modifiedAt = after.modifiedAt;
  assert.deepEqual(after, expected, 'Zero-owned source, full forward coverage, dialogue words and later authored cue stay exact');
}

export async function runImageBoundary(app) {
  const session = await ScrivSession.launch(app), ui = audioLibrarySteps(session);
  let sample, current, frozen, step = 'boundary-setup'; const completed = [];
  async function check(name, body) {
    step = name; await body(); completed.push(name); console.log(`PASS: AUT-J08/local-images/${name}`);
  }
  async function invariant() {
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), sortedProjects([sample, current]));
    assert.deepEqual((await session.command('loaded-project')).project, current);
    assert.deepEqual(await session.command('presented-alerts'), []);
  }
  async function decoded() {
    for (let attempt = 0; attempt < 60; attempt++) {
      const result = await session.command('local-image-evidence');
      assert.equal(result.projectID, current.id); assert.equal(result.generationJobCount, 0);
      assert.equal(result.analysisScanning, false); assert.equal(result.assets.length, 1);
      const asset = result.assets[0];
      assert.equal(asset.assetID, current.images[0].id); assert.equal(asset.sha256, coralSHA);
      assert.equal(asset.byteCount, 73); assert.equal(asset.decoded, true);
      assert.equal(asset.width, 2); assert.equal(asset.height, 2);
      if (asset.visiblePreviewCount > 0) return;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert.fail('Zero-owned imported image did not become visibly decoded');
  }
  try {
    const cap = await session.command('capabilities'); assert.equal(cap.cloudIsolation.network, 'disabled');
    for (const command of ['import-json', 'import-local-image', 'local-image-evidence', 'loaded-project']) assert.ok(cap.commands.includes(command));
    await ui.tab('Script'); await session.command('key', { input: 's', modifiers: ['command'] });
    sample = await waitForSavedProject(session, p => p.title === 'YAM MAN');
    const fixture = imageBoundaryFixture();
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(fixture) }), { dispatched: true, projectChanged: true });
    current = await waitForSavedProject(session, p => p.id !== sample.id);
    const expected = structuredClone(fixture);
    for (const key of ['id', 'createdAt', 'modifiedAt']) expected[key] = current[key];
    assert.deepEqual(current, expected);
    await session.waitFor(nodes => nodes.some(n => n.identifier === 'workspace-project' && n.title === fixture.title));
    await check('zero-owned-source', async () => {
      const disclosure = await ui.reveal(n => n.identifier === 'preview-layers-disclosure');
      if (disclosure.label === 'Expand Layers') await ui.activate(n => n.identifier === 'preview-layers-disclosure');
      await session.waitFor(nodes => nodes.some(n => n.identifier === 'preview-layers-disclosure' && n.label === 'Collapse Layers'));
      await ui.activate(n => n.enabled === true && n.title?.startsWith('A gate opens.\n') && n.title.endsWith(' owned'));
      await ui.activate(n => n.identifier === 'preview-layers-disclosure');
      await session.waitFor(nodes => nodes.some(n => n.identifier === 'preview-layers-disclosure' && n.label === 'Expand Layers')
        && nodes.some(n => n.identifier === 'scene-playback-position' && n.slider?.value === 0 && n.slider.maximum === 8500)
        && nodes.some(n => n.text === 'Select a script moment or image'));
      await invariant();
    });
    await check('zero-owned-import', async () => {
      const before = current;
      assert.deepEqual(await session.command('import-local-image', { fixture: 'coral' }, 30000),
        { dispatched: true, imported: true, cleanupVerified: true });
      current = await waitForSavedProject(session, p => p.id === before.id && p.images.length === 1);
      verifyBoundaryImport(before, current);
      await session.waitFor(nodes => nodes.some(n => n.text === 'Image 2 · Version 1'));
      await invariant(); await decoded(); frozen = await session.command('loaded-project');
    });
    await check('zero-owned-reopen', async () => {
      await ui.openProject(sample); assert.deepEqual(await ui.openProject(current), frozen);
      await invariant(); await decoded();
    });
    assert.deepEqual(completed, imageBoundaryCases);
  } catch (error) { throw new Error(`AUT-J08/local-images/${step} failed`, { cause: error }); }
  finally { await session.close(); }
}
