import assert from 'node:assert/strict';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { observePresentedError } from '../../support/presented-error.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { content, fixture } from './picture-coverage-cases.mjs';
import { coverageSteps } from './picture-coverage-steps.mjs';

export const sharedCutListing = {
  journey: 'AUT-J09', portion: 'shared-picture-cuts',
  cases: ['Storyboard preview and cancellation', 'Storyboard release', 'Layers Escape', 'Layers release with and without snapping', 'Undo and Redo', 'reject an empty picture'],
};

export async function runSharedCutJourney() {
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const ui = coverageSteps(session);
  const grip = node => node.label === 'Move cut after Parent';
  let activeWindow;
  let step = 'import adjacent pictures into a saved project';

  async function start() {
    const nodes = await session.waitFor(items => items.filter(node => grip(node) && node.hittable).length === 1);
    const handle = nodes.find(node => grip(node) && node.hittable);
    activeWindow = handle.windowPath;
    assert.deepEqual(await session.command('picture-timing-gesture', { target: handle.path, phase: 'begin' }), { dispatched: true });
    return handle.frame.x;
  }
  const activeGrip = node => grip(node) && node.windowPath === activeWindow;
  async function gesture(phase, fields = {}) {
    const nodes = await session.waitFor(items => items.filter(activeGrip).length === 1);
    const { path } = nodes.find(activeGrip);
    return session.command('picture-timing-gesture', { target: path, phase, ...fields });
  }
  async function preview(origin, translation, saved) {
    assert.deepEqual(await gesture('change', { translation, shift: false }), { dispatched: true });
    await session.waitFor(nodes => nodes.some(node => activeGrip(node) && Math.abs(node.frame.x - origin - translation) < 0.5));
    await unchanged(saved);
  }
  async function unchanged(saved) {
    assert.deepEqual((await session.command('persisted-projects')).find(project => project.id === saved.id), saved);
  }
  async function nextRevision(previous, expected) {
    const saved = await waitForSavedProject(session, project => project.id === previous.id && project.revision > previous.revision);
    assert.equal(saved.revision, previous.revision + 1);
    assert.deepEqual(content(saved), expected);
    return saved;
  }

  try {
    await ui.tab('Script');
    await session.command('key', { input: 's', modifiers: ['command'] });
    await waitForSavedProject(session, project => project.title === 'YAM MAN');
    const input = fixture();
    input.title = 'Synthetic neighboring pictures';
    Object.assign(input.cues[0], { endMs: 1000, authoredDurationMs: 1000 });
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
    const before = await waitForSavedProject(session, project => project.title === input.title);
    await ui.tab('Storyboard');

    step = 'preview and cancel the Storyboard shared cut';
    const storyboardOrigin = await start();
    await preview(storyboardOrigin, 10, before);
    assert.deepEqual(await gesture('cancel'), { dispatched: true });
    await session.waitFor(nodes => nodes.some(node => activeGrip(node) && Math.abs(node.frame.x - storyboardOrigin) < 0.5));
    await unchanged(before);
    await assert.rejects(gesture('end', { translation: 10, shift: false }), /no active picture timing gesture/i);

    step = 'release the Storyboard cut at 1.200 seconds';
    await start();
    assert.deepEqual(await gesture('end', { translation: 10, shift: false }), { dispatched: true });
    const shifted = content(before);
    Object.assign(shifted.cues[0], { endMs: 1200, authoredDurationMs: 1200 });
    Object.assign(shifted.cues[1], { startMs: 1200, authoredDurationMs: 1300, startAnchor: { entryId: 'b', offsetMs: 200 } });
    const storyboardSaved = await nextRevision(before, shifted);

    step = 'cancel a Layers preview and snap the real cut to a word boundary';
    await ui.tab('Script');
    await ui.activate(node => node.identifier === 'preview-layers-disclosure' && node.label === 'Expand Layers');
    await ui.activate(node => node.identifier !== 'preview-layers-disclosure' && node.label === 'Expand Layers');
    await session.waitFor(nodes => nodes.some(node => node.label === 'Snap to words' && node.isOn && node.hittable));
    const layersOrigin = await start();
    await preview(layersOrigin, 14, storyboardSaved);
    await session.command('key', { input: 'Escape', modifiers: [] });
    await session.waitFor(nodes => nodes.some(node => activeGrip(node) && node.hittable && Math.abs(node.frame.x - layersOrigin) < 0.5));
    await unchanged(storyboardSaved);
    await start();
    assert.deepEqual(await gesture('end', { translation: 14, shift: false }), { dispatched: true });
    const snapped = content(storyboardSaved);
    Object.assign(snapped.cues[0], { endMs: 1666, authoredDurationMs: 1666 });
    Object.assign(snapped.cues[1], { startMs: 1666, authoredDurationMs: 834, startAnchor: { entryId: 'b', offsetMs: 666 } });
    const snappedSaved = await nextRevision(storyboardSaved, snapped);

    step = 'turn off snapping and save the exact Layers cut';
    const snapSwitch = node => node.label === 'Snap to words' && node.hittable;
    const controls = await session.waitFor(nodes => nodes.filter(snapSwitch).length === 1);
    await session.command('toggle', { target: controls.find(snapSwitch).path, value: false });
    await session.waitFor(nodes => nodes.some(node => snapSwitch(node) && node.isOn === false));
    await start();
    assert.deepEqual(await gesture('end', { translation: -4, shift: false }), { dispatched: true });
    const exact = content(snappedSaved);
    Object.assign(exact.cues[0], { endMs: 1566, authoredDurationMs: 1566 });
    Object.assign(exact.cues[1], { startMs: 1566, authoredDurationMs: 934, startAnchor: { entryId: 'b', offsetMs: 566 } });
    const layersSaved = await nextRevision(snappedSaved, exact);
    await session.command('key', { input: 'Escape', modifiers: [] });
    await ui.tab('Storyboard');

    step = 'undo and redo both edges, then reject an empty picture';
    await ui.history();
    const undone = await nextRevision(layersSaved, content(snappedSaved));
    await ui.history(true);
    const redone = await nextRevision(undone, content(layersSaved));
    assert.deepEqual((await session.command('loaded-project')).project, redone);
    await start();
    assert.deepEqual(await gesture('end', { translation: -100, shift: false }), { dispatched: true });
    await observePresentedError(session, 'Both images must retain positive duration.');
    await unchanged(redone);
    console.log('PASS: Storyboard and Layers shared cuts preview, cancel, save, snap, undo and reject empty coverage');
  } catch (cause) {
    throw new Error(`Shared cut journey failed while trying to ${step}`, { cause });
  } finally {
    await session.close();
  }
}
