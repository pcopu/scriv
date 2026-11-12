import assert from 'node:assert/strict';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { audioProjectFixture } from './audio-library-fixtures.mjs';
import { audioLibrarySteps, sortedProjects } from './audio-library-steps.mjs';

// Opt-in synthetic acceptance, not frozen fixture equivalence or retirement.
// Setup writes use import-json, the real finite importer and actual tag buttons.
// After setup every navigation must preserve the complete model and Date bits.
export const sourceNavigationCases = ['source-import-tag-successor', 'source-unplaced-disabled',
  'source-placed-cross-scene', 'source-repeat-different-origin', 'source-browser-reopen'];
const person = { id: 'source-ada', name: 'Synthetic Source Ada', aliases: [],
  biography: 'Synthetic navigation witness', appearance: 'Coral coat', color: 'purple' };
const hashes = ['827d9145314e931860ee40b45f8348ad3527c93e008d1490b687265d947fb577',
  '3fba282698b3df63c76fb40e529943fb6da6d28bafa6ff9e3a75c0c4a0cbb784'];
export function sourceNavigationFixture() {
  const project = audioProjectFixture(); project.title = 'Synthetic image source navigation';
  project.scenes[0].title = 'Scene A'; project.scenes.push({ id: 'scene-b', title: 'Scene B', order: 1 });
  project.entries.push({ id: 'line-b', sceneId: 'scene-b', order: 0, kind: 'dialogue', text: 'Elsewhere',
    ownedDurationMs: 2000, coverageDurationMs: 0, color: 'blue',
    words: [{ id: 'word-b', text: 'Elsewhere', startMs: 0, endMs: 2000 }] });
  project.characters = [structuredClone(person)];
  project.cues[1] = { ...project.cues[1], label: 'Source target',
    startAnchor: { entryId: 'line2', offsetMs: 0 }, authoredDurationMs: 2000 };
  return project;
}
const sourceButton = node => node.title === 'Show in script' && node.enabled !== undefined;
const sceneButton = (node, title) => node.title === title + ' ⌄' && node.enabled === true;
const tagButton = node => node.label === person.name && node.enabled !== undefined;
const selectedTab = (nodes, name) => nodes.some(node => node.identifier === 'workspace-tabs'
  && node.segments[node.selected] === name && node.hittable);

export async function runImageSourceNavigation(app) {
  const session = await ScrivSession.launch(app), ui = audioLibrarySteps(session);
  let current, sample, frozen, step = 'source-setup'; const completed = [];
  async function check(name, body) {
    step = name; await body(); completed.push(name); console.log(`PASS: AUT-J08/local-images/${name}`);
  }
  async function savedExact() {
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), sortedProjects([sample, current]));
    assert.deepEqual(await session.command('presented-alerts'), []);
  }
  async function unchanged() {
    await savedExact(); assert.deepEqual(await session.command('loaded-project'), frozen,
      'Navigation preserves every saved/loaded field, revision, asset lineage, tag and exact Date bit');
  }
  async function workspace() {
    await session.waitFor(nodes => !nodes.some(sourceButton)
      && !nodes.some(node => node.label === 'Image version actions')
      && nodes.some(node => node.identifier === 'workspace-tabs' && node.hittable));
  }
  async function seek(value, maximum) {
    const slider = await ui.reveal(node => node.identifier === 'scene-playback-position');
    assert.equal(slider.slider.maximum, maximum);
    await session.command('slider', { target: slider.path, value });
    await position(value, maximum);
  }
  async function position(value, maximum) {
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'scene-playback-position'
      && node.slider?.value === value && node.slider.maximum === maximum));
  }
  async function origin(from, to, time) {
    await ui.tab('Script');
    const owner = await ui.reveal(node => sceneButton(node, from));
    const menu = await session.command('menu', { target: owner.path });
    assert.deepEqual(menu.primary[0].children.map(action => action.title),
      ['Scene A', 'Scene B', 'New scene', 'Rename scene…', 'Delete scene…']);
    assert.deepEqual(await session.command('menu-action', { target: owner.path, scope: 'script-scenes', action: to }),
      { dispatched: true, coverage: 'semantic-menu-action' });
    await session.waitFor(nodes => nodes.some(node => sceneButton(node, to)));
    await seek(time, to === 'Scene A' ? 5000 : 2000); await ui.tab('Characters');
    await session.waitFor(nodes => selectedTab(nodes, 'Characters')); await unchanged();
  }
  async function inspector(version, enabled) {
    const label = version === 1 ? 'Open Image, version 1' : 'Open Source target, version 2';
    await ui.activate(node => node.label === label && node.enabled !== undefined);
    const nodes = await session.waitFor(nodes => nodes.some(node => node.text === `Version ${version}`)
      && nodes.filter(sourceButton).length === 1);
    assert.equal(nodes.find(sourceButton).enabled, enabled);
    await savedExact();
  }
  async function destination() {
    await workspace();
    const nodes = await session.waitFor(nodes => selectedTab(nodes, 'Script')
      && nodes.some(node => sceneButton(node, 'Scene A'))
      && nodes.some(node => node.text === 'Source target · Version 2')
      && nodes.some(node => node.identifier === 'script-picture-split'));
    await position(3000, 5000);
    const lines = nodes.filter(node => node.identifier === 'script-line-line2');
    assert.equal(lines.length, 1); assert.equal(lines[0].text, 'four');
    const rows = nodes.filter(node => node.type === 'ScriptEntryRow' && lines[0].path.startsWith(node.path + '.'));
    assert.equal(rows.length, 1);
    const splits = nodes.filter(node => node.identifier === 'script-picture-split');
    assert.equal(splits.length, 1, 'Exactly one selected source row exposes its split control');
    assert.ok(splits[0].path.startsWith(rows[0].path + '.'), 'Selected row is line2, not merely visible source text');
    assert.equal(splits[0].enabled, true);
    await unchanged();
  }
  async function showSource() {
    await inspector(2, true); await ui.activate(sourceButton); await destination();
  }
  async function importVersion(index) {
    const before = current;
    assert.deepEqual(await session.command('import-local-image', { fixture: ['coral', 'blue'][index] }, 30000),
      { dispatched: true, imported: true, cleanupVerified: true });
    const after = await waitForSavedProject(session, p => p.id === before.id && p.images.length === index + 1);
    const asset = after.images[index]; assert.match(asset.id, /^[A-Fa-f0-9-]{36}$/); assert.ok(Number.isFinite(asset.createdAt));
    assert.deepEqual(asset, { id: asset.id, version: index + 1, fileName: hashes[index] + '.png', sha256: hashes[index],
      byteCount: 73, mimeType: 'image/png', prompt: 'Imported image', characterIds: index ? [person.id] : [],
      createdAt: asset.createdAt, ...(index ? { previousVersionId: before.images[0].id } : {}) });
    const expected = structuredClone(before); expected.images.push(asset); expected.cues[1].imageId = asset.id;
    expected.revision++; expected.modifiedAt = after.modifiedAt;
    assert.ok(Number.isFinite(after.modifiedAt) && after.modifiedAt >= before.modifiedAt);
    assert.deepEqual(after, expected); current = after; await savedExact();
  }
  try {
    const cap = await session.command('capabilities'); assert.equal(cap.cloudIsolation.network, 'disabled');
    for (const command of ['import-json', 'import-local-image', 'loaded-project', 'persisted-projects', 'menu-action']) assert.ok(cap.commands.includes(command));
    assert.ok(cap.semanticMenuActionScopes.includes('script-scenes'));
    await ui.tab('Script'); await session.command('key', { input: 's', modifiers: ['command'] });
    sample = await waitForSavedProject(session, p => p.title === 'YAM MAN');
    const fixture = sourceNavigationFixture();
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(fixture) }),
      { dispatched: true, projectChanged: true });
    current = await waitForSavedProject(session, p => p.id !== sample.id);
    const expected = structuredClone(fixture); for (const key of ['id', 'createdAt', 'modifiedAt']) expected[key] = current[key];
    assert.deepEqual(current, expected);
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.title === fixture.title));
    await check('source-import-tag-successor', async () => {
      await seek(3500, 5000); await importVersion(0);
      await ui.activate(node => node.label === 'Edit pictured character tags' && node.enabled !== undefined);
      await session.waitFor(nodes => nodes.some(node => tagButton(node) && node.value === 'Not tagged'));
      const before = current; await ui.activate(tagButton);
      const after = await waitForSavedProject(session, p => p.id === before.id && p.revision > before.revision);
      const expected = structuredClone(before); expected.revision++; expected.modifiedAt = after.modifiedAt;
      expected.images[0].characterIds = [person.id];
      assert.ok(Number.isFinite(after.modifiedAt) && after.modifiedAt >= before.modifiedAt); assert.deepEqual(after, expected);
      current = after;
      await session.waitFor(nodes => nodes.some(node => tagButton(node) && node.value === 'Pictured in this image'));
      await ui.activate(node => node.title === 'Done' && node.enabled !== undefined);
      await session.waitFor(nodes => !nodes.some(tagButton) && nodes.some(node => node.identifier === 'preview-inspect' && node.hittable));
      await importVersion(1); frozen = await session.command('loaded-project'); assert.deepEqual(frozen.project, current);
      assert.deepEqual(frozen.dateReferenceTimeBits.images.map(image => image.id), current.images.map(image => image.id));
      for (const bits of [frozen.dateReferenceTimeBits.createdAt, frozen.dateReferenceTimeBits.modifiedAt,
        ...frozen.dateReferenceTimeBits.images.map(image => image.createdAt)]) assert.match(bits, /^\d+$/);
      await unchanged();
    });
    await check('source-unplaced-disabled', async () => {
      await origin('Scene A', 'Scene B', 750); await inspector(1, false);
      const nodes = await session.command('snapshot'), disabled = nodes.find(sourceButton);
      await assert.rejects(session.command('activate', { target: disabled.path }), /Target is disabled/);
      const stillOpen = await session.waitFor(nodes => nodes.some(node => node.text === 'Version 1')
        && nodes.some(node => sourceButton(node) && node.enabled === false));
      assert.equal(stillOpen.filter(sourceButton).length, 1); await savedExact();
      await ui.activate(node => node.title === 'Done' && node.enabled !== undefined); await workspace();
      await session.waitFor(nodes => selectedTab(nodes, 'Characters')); await unchanged();
      await ui.tab('Script'); await session.waitFor(nodes => nodes.some(node => sceneButton(node, 'Scene B')));
      await position(750, 2000); await ui.tab('Characters'); await unchanged();
    });
    await check('source-placed-cross-scene', showSource);
    await check('source-repeat-different-origin', async () => {
      await origin('Scene A', 'Scene A', 1250); await showSource();
    });
    await check('source-browser-reopen', async () => {
      await ui.openProject(sample); assert.deepEqual(await ui.openProject(current), frozen); await unchanged();
      await origin('Scene A', 'Scene B', 750); await showSource();
    });
    assert.deepEqual(completed, sourceNavigationCases);
  } catch (error) { throw new Error(`AUT-J08/local-images/${step} failed`, { cause: error }); }
  finally { await session.close(); }
}
