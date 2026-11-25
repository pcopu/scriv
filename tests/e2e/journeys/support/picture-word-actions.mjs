import assert from 'node:assert/strict';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { observePresentedError } from '../../support/presented-error.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { content, fixture } from './picture-coverage-cases.mjs';
import { coverageSteps } from './picture-coverage-steps.mjs';

export const wordMoveListing = { journey: 'AUT-J09', portion: 'storyboard-word-moves',
  cases: ['extend and toggle a word selection', 'move a boundary word to either adjacent picture', 'refuse wrong target and non-boundary word'] };
export const wordDragListing = { journey: 'AUT-J09', portion: 'layers-word-drags',
  cases: ['preview and cancel a word move', 'save a shifted word and drag both edges', 'refuse overlap'] };
export const storyboardDropListing = { journey: 'AUT-J09', portion: 'storyboard-word-drop',
  cases: ['cancel a local word drag', 'drop a boundary word on the neighboring picture', 'refuse a drag captured before Undo'] };

async function importFixture(session, ui, input) {
  await ui.tab('Script');
  await session.command('key', { input: 's', modifiers: ['command'] });
  await waitForSavedProject(session, project => project.title === 'YAM MAN');
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
  return waitForSavedProject(session, project => project.title === input.title);
}

async function nextRevision(session, previous, expected) {
  const saved = await waitForSavedProject(session, project => project.id === previous.id && project.revision > previous.revision);
  assert.equal(saved.revision, previous.revision + 1);
  assert.deepEqual(content(saved), expected);
  return saved;
}

async function assertUnchanged(session, expected) {
  assert.deepEqual((await session.command('persisted-projects')).find(project => project.id === expected.id), expected);
}

export async function runStoryboardWordMoves() {
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const ui = coverageSteps(session);
  let step = 'open adjacent pictures in Storyboard';
  const scope = 'storyboard-word-move';

  async function move(wordID, direction) {
    const action = `Move to ${direction} image`;
    const target = await ui.reveal(node => node.identifier === 'storyboard-word-' + wordID);
    const menu = await session.command('menu', { target: target.path });
    assert.equal(menu.secondary.flatMap(item => item.children).filter(item => item.title === action && !item.disabled).length, 1);
    assert.deepEqual(await session.command('menu-action', { scope, action, target: target.path, wordID }),
      { dispatched: true, coverage: 'semantic-menu-action' });
  }

  try {
    const input = fixture();
    input.title = 'Synthetic word transfers';
    Object.assign(input.cues[0], { endMs: 1000, authoredDurationMs: 1000 });
    const before = await importFixture(session, ui, input);
    await ui.tab('Storyboard');

    step = 'extend and toggle the selected Storyboard words without editing the script';
    const [first, middle, last] = before.entries.flatMap(entry => entry.words);
    assert.ok(first && middle && last);
    async function selectWord(word, modifiers) {
      const target = 'storyboard-word-' + word.id;
      await ui.reveal(node => node.identifier === target);
      assert.deepEqual(await session.command('activate', { target, ...(modifiers && { modifiers }) }), { dispatched: true });
    }
    const selected = count => session.waitFor(nodes => nodes.some(node =>
      node.text === `${count} ${count === 1 ? 'word' : 'words'} selected`));
    await selectWord(first);
    await selected(1);
    const word = await ui.reveal(node => node.identifier === 'storyboard-word-' + last.id);
    assert.deepEqual((await session.command('capabilities')).semanticActivationModifiers['storyboard-word'], ['shift', 'command']);
    await assert.rejects(session.command('activate', { target: word.path, modifiers: ['option'] }),
      /Storyboard word activation is unavailable/);
    await selected(1);
    await selectWord(last, ['shift']);
    await selected(3);
    await selectWord(middle, ['command']);
    await selected(2);
    await selectWord(middle, ['command']);
    await selected(3);
    await ui.activate(node => node.identifier === 'storyboard-deselect');
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'storyboard-deselect' && node.enabled === false));
    await assertUnchanged(session, before);

    step = 'move the first word to the previous picture';
    const firstWord = await ui.reveal(node => node.identifier === 'storyboard-word-b-word-0');
    await assert.rejects(session.command('menu-action', { scope, action: 'Move to previous image', target: firstWord.path, wordID: 'b-word-1' }), /scope/i);
    await assertUnchanged(session, before);
    await move('b-word-0', 'previous');
    const moved = content(before);
    Object.assign(moved.cues[0], { endMs: 1666, authoredDurationMs: 1666 });
    Object.assign(moved.cues[1], { startMs: 1666, authoredDurationMs: 834, startAnchor: { entryId: 'b', offsetMs: 666 } });
    const previousSaved = await nextRevision(session, before, moved);
    assert.ok((await session.command('capabilities')).semanticMenuActionScopes.includes(scope));

    step = 'move the last word of the left picture to the next picture';
    await move('b-word-0', 'next');
    const nextSaved = await nextRevision(session, previousSaved, content(before));
    assert.deepEqual((await session.command('loaded-project')).project, nextSaved);

    step = 'reject a word away from the first edge';
    await move('b-word-1', 'previous');
    await observePresentedError(session, 'Select from the first word in this image to move the phrase backward without moving unselected words.');
    await assertUnchanged(session, nextSaved);
    console.log('PASS: Storyboard word moves preserve word identity and update the adjacent cut or show the original validation error');
  } catch (cause) {
    throw new Error(`Storyboard word journey failed while trying to ${step}`, { cause });
  } finally { await session.close(); }
}

export async function runStoryboardWordDrop() {
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const ui = coverageSteps(session);
  const command = 'storyboard-word-drag';
  const word = 'storyboard-word-b-word-0';
  const parent = 'storyboard-duration-parent';
  const child = 'storyboard-duration-child';
  let step = 'discover the native Storyboard word drag';
  async function sample(phase, identifier) {
    const target = await ui.reveal(node => node.identifier === identifier);
    return session.command(command, { phase, target: target.path });
  }
  async function dispatch(phase, identifier) {
    assert.deepEqual(await sample(phase, identifier), { dispatched: true });
  }
  try {
    const caps = await session.command('capabilities');
    assert.ok(caps.commands.includes(command) && caps.semanticGestureCommands.includes(command),
      'The app must expose the mounted Storyboard word drag');
    const input = fixture();
    input.title = 'Synthetic Storyboard word drops';
    Object.assign(input.cues[0], { endMs: 1000, authoredDurationMs: 1000 });
    const before = await importFixture(session, ui, input);
    await ui.tab('Storyboard');

    step = 'cancel without moving the saved cut';
    await dispatch('begin', word);
    await session.waitFor(nodes => nodes.some(node => node.text === '1 word selected'));
    await assertUnchanged(session, before);
    await dispatch('cancel', word);
    await assert.rejects(sample('end', parent), /no active Storyboard word drag/i);
    await assertUnchanged(session, before);

    step = 'drop on the neighboring picture and persist exactly one cut change';
    await dispatch('begin', word);
    await assert.rejects(sample('end', word), /Storyboard drop destination is unavailable/i);
    await dispatch('end', parent);
    const moved = content(before);
    Object.assign(moved.cues[0], { endMs: 1666, authoredDurationMs: 1666 });
    Object.assign(moved.cues[1], { startMs: 1666, authoredDurationMs: 834, startAnchor: { entryId: 'b', offsetMs: 666 } });
    const saved = await nextRevision(session, before, moved);
    assert.deepEqual((await session.command('loaded-project')).project, saved);
    await assert.rejects(sample('end', parent), /no active Storyboard word drag/i);

    step = 'refuse the captured drop after Undo advances the revision';
    await dispatch('begin', word);
    await ui.history();
    const undone = await nextRevision(session, saved, content(before));
    await dispatch('end', child);
    await observePresentedError(session, 'The scene changed during the drag. Select the words again before moving this cut.');
    await assertUnchanged(session, undone);
    assert.deepEqual((await session.command('loaded-project')).project, undone);
    console.log('PASS: mounted Storyboard word drag cancels, moves one saved cut, and refuses stale capture');
  } catch (cause) {
    throw new Error(`Storyboard word drop journey failed while trying to ${step}`, { cause });
  } finally { await session.close(); }
}

export async function runLayersWordDrags() {
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const ui = coverageSteps(session);
  let step = 'open the word timeline with room between words';
  let layersWindow;
  function target(label) {
    const type = label === 'Move' ? 'UIButton' : 'UIView';
    return node => node.windowPath === layersWindow && node.type === type && node.label === label;
  }
  async function gesture(label, phase, translation) {
    const matches = target(label);
    const nodes = await session.waitFor(items => items.filter(matches).length === 1
      && (phase !== 'begin' || items.find(matches).hittable));
    const { path } = nodes.find(matches);
    const sample = translation === undefined ? {} : { translation, shift: false };
    assert.deepEqual(await session.command('picture-timing-gesture', { target: path, phase, ...sample }), { dispatched: true });
  }
  async function savedWord(previous, times) {
    const expected = content(previous);
    Object.assign(expected.entries.find(entry => entry.id === 'b').words[0], { ...times, timingSource: 'authored' });
    return nextRevision(session, previous, expected);
  }

  try {
    const input = fixture();
    input.title = 'Synthetic word drag timing';
    Object.assign(input.entries[1].words[0], { startMs: 80, endMs: 440 });
    Object.assign(input.entries[1].words[1], { startMs: 750, endMs: 950 });
    const before = await importFixture(session, ui, input);
    await ui.tab('Script');
    await ui.activate(node => node.identifier === 'preview-layers-disclosure' && node.label === 'Expand Layers');
    await ui.activate(node => node.identifier !== 'preview-layers-disclosure' && node.label === 'Expand Layers');
    const visibleMove = node => node.type === 'UIButton' && node.label === 'Move' && node.hittable;
    const shown = await session.waitForUnique(visibleMove);
    const visibleWord = shown.find(visibleMove);
    layersWindow = visibleWord.windowPath;

    step = 'preview and cancel retiming the whole word';
    await gesture('Move', 'begin');
    await gesture('Move', 'change', 2);
    await session.waitFor(nodes => nodes.some(node => target('Move')(node) && Math.abs(node.frame.x - visibleWord.frame.x - 2) < 0.5));
    await assertUnchanged(session, before);
    await session.command('key', { input: 'Escape', modifiers: [] });
    await session.waitFor(nodes => nodes.some(node => target('Move')(node) && node.hittable && Math.abs(node.frame.x - visibleWord.frame.x) < 0.5));
    await assertUnchanged(session, before);

    step = 'save a shifted word';
    await gesture('Move', 'begin');
    await gesture('Move', 'end', 2);
    const shifted = await savedWord(before, { startMs: 130, endMs: 490 });
    step = 'retime through the word end handle';
    await gesture('Retime Move end', 'begin');
    await gesture('Retime Move end', 'end', 2);
    const extended = await savedWord(shifted, { endMs: 540 });
    step = 'retime through the word start handle';
    await gesture('Retime Move start', 'begin');
    await gesture('Retime Move start', 'end', -2);
    const retimed = await savedWord(extended, { startMs: 80 });

    step = 'reject a drag that crosses the neighboring word';
    await gesture('Move', 'begin');
    await gesture('Move', 'end', 12);
    await observePresentedError(session, 'This phrase would cross another word or leave its line. Shorten a word or adjust neighboring timing to make room.');
    await assertUnchanged(session, retimed);
    console.log('PASS: Layers word block and handles keep authored timing and reject overlapping motion');
  } catch (cause) {
    throw new Error(`Layers word journey failed while trying to ${step}`, { cause });
  } finally { await session.close(); }
}
