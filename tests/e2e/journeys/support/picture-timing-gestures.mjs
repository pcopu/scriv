import assert from 'node:assert/strict';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { content, fixture, expectedContent } from './picture-coverage-cases.mjs';
import { coverageSteps } from './picture-coverage-steps.mjs';

const command = 'picture-timing-gesture';
export const timingGestureListing = {
  journey: 'AUT-J09', portion: 'picture-timing-gestures',
  cases: ['cancel snapped offset', 'commit offset with Shift', 'extend Layers coverage past scene', 'cancel and apply Storyboard duration'],
};

export async function runPictureTimingGestureJourney() {
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const ui = coverageSteps(session);
  const childTile = node => node.type === 'UIButton' && node.label.startsWith('Child, ');
  let layersWindow;
  const tile = node => node.windowPath === layersWindow && childTile(node);
  const edge = node => node.windowPath === layersWindow && node.label === 'Authored coverage edge for Child';
  const card = node => node.identifier === 'storyboard-duration-child';
  let step = 'discover the picture timing action';

  async function gesture(matching, phase, payload = {}) {
    const nodes = await session.waitFor(list => list.filter(matching).length === 1);
    const { path } = nodes.find(matching);
    return session.command(command, { target: path, phase, ...payload });
  }
  async function sample(matching, phase, translation, shift = false) {
    assert.deepEqual(await gesture(matching, phase, { translation, shift }), { dispatched: true });
  }
  async function exactRevision(before, expected) {
    const saved = await waitForSavedProject(session, project => project.id === before.id && project.revision > before.revision);
    assert.equal(saved.revision, before.revision + 1);
    assert.deepEqual(content(saved), expected);
    return saved;
  }
  async function assertDraftOnly(before) {
    assert.deepEqual((await session.command('persisted-projects')).find(project => project.id === before.id), before);
  }

  try {
    assert.ok((await session.command('capabilities')).commands.includes(command), 'The native picture timing gesture action is discoverable');
    step = 'load an isolated project and open Layers';
    await ui.tab('Script');
    await session.command('key', { input: 's', modifiers: ['command'] });
    await waitForSavedProject(session, project => project.title === 'YAM MAN');
    const input = fixture();
    input.title = 'Synthetic picture timing gestures';
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
    const before = await waitForSavedProject(session, project => project.title === input.title);
    await ui.tab('Script');
    await ui.activate(node => node.identifier === 'preview-layers-disclosure' && node.label === 'Expand Layers');
    await ui.activate(node => node.label === 'Expand Layers' && node.identifier !== 'preview-layers-disclosure');
    const layers = await session.waitFor(nodes => nodes.some(node => node.label === 'Snap to words' && node.isOn && node.hittable)
      && nodes.some(node => childTile(node) && node.hittable));
    layersWindow = layers.find(node => childTile(node) && node.hittable).windowPath;
    const coveredTile = layers.find(node => childTile(node) && !tile(node));
    assert.ok(coveredTile && !coveredTile.hittable);
    await assert.rejects(session.command(command, { target: coveredTile.path, phase: 'begin' }), /behind the active presentation/i);

    step = 'preview a snap, reject a competing or malformed action, and cancel with Escape';
    await assert.rejects(gesture(tile, 'end', { translation: 24, shift: false }), /active picture timing gesture/i);
    assert.deepEqual(await gesture(tile, 'begin'), { dispatched: true });
    await assert.rejects(gesture(edge, 'begin'), /active picture timing gesture/i);
    await assert.rejects(gesture(tile, 'change', { translation: true, shift: false }), /invalid picture timing sample/i);
    await sample(tile, 'change', 24);
    await session.waitFor(nodes => nodes.some(node => tile(node) && node.value.includes('+0.666 s')));
    await sample(tile, 'change', 48);
    await session.waitFor(nodes => nodes.some(node => tile(node) && node.value.includes('+0.999 s') && node.value.includes('source limit')));
    await assertDraftOnly(before);
    assert.ok((await session.command('keys')).some(key => key.input === 'Escape' && key.responderType === 'LayerTimelineViewController'));
    await session.command('key', { input: 'Escape', modifiers: [] });
    await session.waitFor(nodes => nodes.some(node => tile(node) && node.hittable && !node.value));
    await assertDraftOnly(before);

    step = 'release a Shift drag and preserve the original script owner';
    assert.deepEqual(await gesture(tile, 'begin'), { dispatched: true });
    await sample(tile, 'change', 24, true);
    await session.waitFor(nodes => nodes.some(node => tile(node) && node.value.includes('+0.600 s')));
    await assertDraftOnly(before);
    await sample(tile, 'end', 24, true);
    const moved = content(before);
    Object.assign(moved.cues.find(cue => cue.id === 'child'), { startMs: 1600, endMs: 3100, startAnchor: { entryId: 'b', offsetMs: 600 } });
    const offsetSaved = await exactRevision(before, moved);

    step = 'drag the coverage edge beyond the scene and save the authored tail';
    await session.waitFor(nodes => nodes.some(node => edge(node) && node.hittable));
    assert.deepEqual(await gesture(edge, 'begin'), { dispatched: true });
    await sample(edge, 'change', 60, true);
    await session.waitFor(nodes => nodes.some(node => edge(node) && node.value.includes('tail preserved beyond scene')));
    await assertDraftOnly(offsetSaved);
    await sample(edge, 'end', 60, true);
    const covered = await exactRevision(offsetSaved, expectedContent(offsetSaved, { authored: 3000, end: 4000 }));

    step = 'cancel a Storyboard hold and save a fresh duration scrub';
    await session.command('key', { input: 'Escape', modifiers: [] });
    await ui.tab('Storyboard');
    assert.deepEqual((await session.command('loaded-project')).project, covered);
    await ui.reveal(card);
    assert.deepEqual(await gesture(card, 'begin'), { dispatched: true });
    await sample(card, 'change', -10);
    await session.waitFor(nodes => nodes.some(node => card(node) && node.value === '3.2s, preview; release to apply'));
    assert.deepEqual(await gesture(card, 'cancel'), { dispatched: true });
    await assertDraftOnly(covered);
    await session.waitFor(nodes => nodes.some(node => card(node) && node.title === '3.0s' && !node.value));
    assert.deepEqual(await gesture(card, 'begin'), { dispatched: true });
    await sample(card, 'end', 40);
    const shortened = await exactRevision(covered, expectedContent(covered, { authored: 2200, end: 3800 }));
    await ui.history();
    const undone = await exactRevision(shortened, content(covered));
    await ui.history(true);
    const redone = await exactRevision(undone, content(shortened));
    assert.deepEqual((await session.command('loaded-project')).project, redone);
    console.log('PASS: native picture timing previews, cancellation, snapped and Shift input, clipped coverage and Undo/Redo');
  } catch (cause) {
    throw new Error(`Picture timing journey failed while trying to ${step}`, { cause });
  } finally {
    await session.close();
  }
}
