import assert from 'node:assert/strict';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { fixture, content } from './picture-coverage-cases.mjs';
import { coverageSteps, sorted } from './picture-coverage-steps.mjs';
import { audioLibrarySteps } from './audio-library-steps.mjs';

export const placementCases = ['fill-gap', 'undo-redo-gap', 'split-interior', 'undo-redo-split', 'browser-reopen'];
export async function runPlacementJourney() {
  assert.ok(process.env.SCRIV_E2E_APP, 'Requires an isolated automation-enabled Catalyst app');
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const ui = coverageSteps(session), browser = audioLibrarySteps(session);
  let stage = 'setup', current, sample;
  const packages = async () => sorted(await session.command('persisted-projects'));
  async function unchanged() {
    assert.deepEqual(await packages(), sorted([sample, current]), 'Complete saved packages remain exact');
    assert.deepEqual(await session.command('presented-alerts'), [], 'No error alert is dismissed or ignored');
    assert.deepEqual((await session.command('loaded-project')).project, current, 'Loaded Swift model equals saved model');
  }
  async function savedAfter(before, expected) {
    const after = await waitForSavedProject(session, project => project.id === before.id && project.revision > before.revision);
    assert.equal(after.id, before.id);
    assert.equal(after.createdAt, before.createdAt);
    assert.ok(Number.isFinite(after.modifiedAt) && after.modifiedAt >= before.modifiedAt, 'Modification time is finite and nondecreasing');
    assert.equal(after.revision, before.revision + 1);
    assert.deepEqual(content(after), expected, 'All authored fields, cue order, words, timing and unrelated data match');
    current = after; await unchanged(); return after;
  }
  async function seek(milliseconds) {
    await ui.tab('Script');
    const slider = await ui.reveal(node => node.identifier === 'scene-playback-position');
    assert.equal(slider.slider.maximum, 4000, 'Placement edits never alter scene runtime');
    await session.command('slider', { target: slider.path, value: milliseconds });
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'scene-playback-position'
      && node.slider.value === milliseconds));
    await ui.tab('Storyboard');
  }
  async function add(milliseconds, expectedCue, editExisting = () => {}) {
    const before = current;
    await seek(milliseconds); await unchanged();
    await ui.button('Add placement');
    const after = await waitForSavedProject(session, project => project.id === before.id && project.revision > before.revision);
    const added = after.cues.filter(cue => !before.cues.some(old => old.id === cue.id));
    assert.equal(added.length, 1, 'Exactly one new placement identity');
    assert.match(added[0].id, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
    // Only the runtime-generated UUID is learned from output. Every other field
    // is a literal authored oracle, not copied from the implementation's result.
    const expected = content(before); editExisting(expected);
    expected.cues.push({ id: added[0].id, ...expectedCue });
    await savedAfter(before, expected);
    await ui.reveal(node => node.identifier === 'storyboard-duration-' + added[0].id);
    return before;
  }
  async function history(before) {
    const edited = current;
    await ui.history(); await savedAfter(edited, content(before));
    const undone = current;
    await ui.history(true); await savedAfter(undone, content(edited));
  }
  async function step(name, body) {
    stage = name; await body(); console.log(`PASS AUT-J09/placements/${name}`);
  }
  try {
    const capabilities = await session.command('capabilities');
    for (const command of ['import-json', 'persisted-projects', 'loaded-project', 'snapshot', 'activate',
      'text', 'select', 'slider', 'scroll', 'keys', 'key', 'presented-alerts']) {
      assert.ok(capabilities.commands.includes(command), `App supports ${command}`);
    }
    await ui.tab('Script'); await session.command('key', { input: 's', modifiers: ['command'] });
    sample = await waitForSavedProject(session, project => project.entries.length > 0);
    assert.equal((await packages()).length, 1);
    const source = fixture(); source.title = 'Placement interaction fixture';
    source.cues[0].prompt = 'Keep the road visible';
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(source) }),
      { dispatched: true, projectChanged: true });
    current = await waitForSavedProject(session, project => project.id !== sample.id);
    assert.notEqual(current.id, source.id);
    assert.match(current.id, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
    assert.ok(Number.isFinite(current.createdAt) && Number.isFinite(current.modifiedAt), 'Import generates finite timestamps');
    assert.equal(current.modifiedAt, current.createdAt, 'Production import initializes both timestamps together');
    const expectedImport = structuredClone(source);
    for (const key of ['id', 'createdAt', 'modifiedAt']) expectedImport[key] = current[key];
    assert.deepEqual(current, expectedImport, 'Production import changes only the local identity/date envelope');
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.title === source.title && node.hittable));
    await unchanged();
    let before;
    await step('fill-gap', async () => {
      before = await add(3000, { sceneId: 's', label: 'Image 2', startMs: 2500, endMs: 4000,
        prompt: '', startAnchor: { entryId: 'c', offsetMs: 500 }, authoredDurationMs: 1500 });
    });
    await step('undo-redo-gap', () => history(before));
    await step('split-interior', async () => {
      before = await add(500, { sceneId: 's', label: 'Parent 2', startMs: 500, endMs: 2500,
        prompt: 'Keep the road visible', startAnchor: { entryId: 'a', offsetMs: 500 }, authoredDurationMs: 2000 }, expected => {
        expected.cues[0].endMs = 500; expected.cues[0].authoredDurationMs = 500;
      });
    });
    await step('undo-redo-split', () => history(before));
    await step('browser-reopen', async () => {
      await ui.tab('Script');
      await session.command('key', { input: 's', modifiers: ['command'] });
      await unchanged();
      const baseline = await session.command('loaded-project');
      assert.deepEqual((await browser.openProject(sample)).project, sample);
      assert.deepEqual(await browser.openProject(current), baseline, 'Browser reopen preserves the entire Swift model and exact Date witnesses');
      await unchanged();
    });
    console.log('PASS AUT-J09 placements: semantic playback slider and actual Add placement UIButton; gap fill, interior split, full-model history and browser reopen. Not picture-menu split/merge or physical input proof.');
  } catch (error) {
    console.error(`FAIL AUT-J09/placements/${stage}`); throw error;
  } finally { await session.close(); }
}
