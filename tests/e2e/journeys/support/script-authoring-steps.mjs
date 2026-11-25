import assert from 'node:assert/strict';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';

// Shared real-control steps, not domain operations or old-scenario wrappers.
export const byID = (nodes, id) => nodes.filter(node => node.identifier === id);
export const readyTabs = nodes => byID(nodes, 'workspace-tabs').find(node => node.enabled && node.hittable);
export const named = (nodes, name) => nodes.filter(node => node.enabled === true
  && (node.label === name || node.title === name));
export const focusedEditors = nodes => nodes.filter(node => node.identifier.startsWith('script-editor-') && node.firstResponder);
export const lines = nodes => nodes.filter(node => node.identifier.startsWith('script-line-'));
export const lineIDs = nodes => lines(nodes).map(node => node.identifier).sort();
export const rangeIs = (node, start, end = start) => node?.selection?.start === start && node.selection.end === end;
export const keyIs = (command, input, modifiers) => command.input === input
  && command.modifiers.length === modifiers.length && modifiers.every(value => command.modifiers.includes(value));
// The placeholder is a display-only oracle, never accepted in editor/package text.
export const dialogueDisplayText = text => text === '' ? 'Write dialogue…' : text;
// Production history may bootstrap missing character annotations on sample rows.
// Preserve the original narrow exception; every other entry/word field is exact.
export const historyEntries = project => project.entries.map(({ characterLinks, ...entry }) => entry)
  .sort((a, b) => a.id.localeCompare(b.id));

export function scriptAuthoringSteps(session) {
  const saved = predicate => waitForSavedProject(session, predicate);
  const key = (input, modifiers = []) => session.command('key', { input, modifiers });
  async function reveal(node, nodes, bottom = false) {
    if (node.hittable) return;
    const scroll = nodes.filter(candidate => /ScrollView/.test(candidate.type) && candidate.hittable
      && node.path.startsWith(candidate.path + '.')).sort((a, b) => b.path.length - a.path.length)[0];
    assert.ok(scroll, 'Offscreen control has a reachable native scroll ancestor');
    await session.command('scroll', { target: scroll.path,
      y: bottom ? Number.MAX_SAFE_INTEGER : scroll.scroll.y + node.frame.y - scroll.frame.y - 24 });
  }
  async function activate(name) {
    const nodes = await session.waitFor(nodes => named(nodes, name).filter(node => node.hittable).length === 1);
    await session.command('activate', { target: named(nodes, name).find(node => node.hittable).path });
  }
  async function selectTab(title, { force = false } = {}) {
    const tabs = readyTabs(await session.waitFor(readyTabs));
    const index = tabs.segments.indexOf(title);
    assert.ok(index >= 0, `The actual workspace exposes ${title}`);
    if (force || tabs.selected !== index) await session.command('select', { target: tabs.identifier, index });
    await session.waitFor(nodes => readyTabs(nodes)?.selected === index);
    return tabs;
  }
  async function workspaceCommand(input, modifiers = ['command']) {
    assert.ok((await session.command('keys')).some(command => command.responderType === 'ScrivWorkspaceController'
      && keyIs(command, input, modifiers)), `The actual workspace exposes its enabled ${modifiers.join('-')}-${input} action`);
    assert.deepEqual(await key(input, modifiers), { dispatched: true });
  }
  const workspaceHistory = (redo = false) => workspaceCommand('z', redo ? ['command', 'shift'] : ['command']);
  async function openScript() {
    await selectTab('Script');
    await key('s', ['command']);
    return saved(project => project.entries.length > 0);
  }
  async function addDialogue(before, { allowEmptyStateName = false, revealEditor = true } = {}) {
    const buttonName = nodes => named(nodes, 'Dialogue').length === 1 ? 'Dialogue'
      : allowEmptyStateName && named(nodes, 'Add dialogue').length === 1 ? 'Add dialogue' : null;
    let nodes = await session.waitFor(nodes => !!buttonName(nodes));
    const name = buttonName(nodes);
    await reveal(named(nodes, name)[0], nodes, true);
    await activate(name);
    nodes = await session.waitFor(nodes => focusedEditors(nodes).length === 1);
    const editor = focusedEditors(nodes)[0];
    const entryID = editor.identifier.slice('script-editor-'.length);
    assert.ok(!before.entries.some(entry => entry.id === entryID), 'Dialogue focuses one newly created entry');
    const added = await saved(project => project.id === before.id && project.entries.some(entry => entry.id === entryID));
    assert.equal(added.entries.length, before.entries.length + 1, 'Dialogue control adds exactly one entry');
    assert.equal(added.entries.find(entry => entry.id === entryID).kind, 'dialogue');
    if (revealEditor) {
      await reveal(editor, nodes);
      await session.waitFor(nodes => byID(nodes, editor.identifier).some(node => node.firstResponder && node.hittable));
    }
    return { before, added, editor, entryID, lineID: `script-line-${entryID}` };
  }
  async function waitEditor(id, text, start, end = start, { hittable = true, stage = 'Native editor text and UTF-16 selection' } = {}) {
    try {
      return await session.waitFor(nodes => focusedEditors(nodes).length === 1 && byID(nodes, id).length === 1
        && byID(nodes, id).some(node => node.firstResponder && (!hittable || node.hittable)
          && node.text === text && rangeIs(node, start, end)));
    } catch (error) { throw new Error(`${stage} did not reach its exact expected state`, { cause: error }); }
  }
  async function finishEditor() {
    assert.ok((await session.command('keys')).some(command => keyIs(command, 'Escape', [])),
      'Native script editor exposes its enabled finish command');
    await key('Escape');
    await session.waitFor(nodes => focusedEditors(nodes).length === 0);
  }
  const displayed = (entryID, text, { finished = false } = {}) => session.waitFor(nodes => byID(nodes, `script-line-${entryID}`)
    .some(node => node.text === dialogueDisplayText(text)) && (!finished || focusedEditors(nodes).length === 0));
  async function savedExactText(context, text, stage) {
    const { before, added, entryID } = context;
    try {
      const project = await saved(project => project.id === before.id
        && project.entries.find(entry => entry.id === entryID)?.text === text);
      assert.equal(project.entries.length, before.entries.length + 1, `${stage}: entry count is unchanged`);
      const entry = project.entries.find(entry => entry.id === entryID);
      assert.equal(entry.kind, 'dialogue', `${stage}: the same entry remains dialogue`);
      assert.deepEqual(entry.words.map(word => word.text), text.match(/\S+/gu) ?? [],
        `${stage}: saved word text preserves the exact spelling of every source token`);
      assert.equal(entry.sceneId, added.entries.find(entry => entry.id === entryID).sceneId,
        `${stage}: editing does not move the entry to another scene`);
      for (const original of before.entries) assert.equal(project.entries.find(entry => entry.id === original.id)?.text,
        original.text, `${stage}: other entry text remains exact`);
      return project;
    } catch (error) { throw new Error(`${stage}: exact text did not persist in the same project`, { cause: error }); }
  }
  async function returnFailureEvidence(projectID, editorID, entryID, priorIDs) {
    // Read this synthetic session only. Never retry Return, repair focus or
    // call the delegate/controller while observing an uncertain outcome.
    const evidence = {};
    try {
      const nodes = await session.command('snapshot', {}, 3000);
      const summarize = ({ identifier, text, selection, firstResponder }) => ({ identifier, text, selection, firstResponder });
      evidence.originalEditor = byID(nodes, editorID).map(summarize);
      evidence.focusedEditors = focusedEditors(nodes).map(summarize);
    } catch (error) { evidence.snapshotError = error.message; }
    try {
      const project = (await session.command('persisted-projects', {}, 3000)).find(project => project.id === projectID);
      evidence.savedEntryCount = project?.entries.length ?? null;
      evidence.originalSavedEntry = project?.entries.filter(entry => entry.id === entryID).map(({ id, text }) => ({ id, text })) ?? [];
      evidence.newSavedEntries = project?.entries.filter(entry => !priorIDs.has(entry.id)).map(({ id, text }) => ({ id, text })) ?? [];
    } catch (error) { evidence.savedReadError = error.message; }
    return evidence;
  }
  return { saved, key, reveal, activate, selectTab, workspaceCommand, workspaceHistory, openScript,
    addDialogue, waitEditor, finishEditor, displayed, savedExactText, returnFailureEvidence };
}

export async function runScriptJourney({ journey, workflows, cases, companions = [], excluded = [], groupWitnessPaths, groupActions }, args = process.argv.slice(2)) {
  let selected = Object.keys(workflows);
  let list = false;
  let groupSeen = false;
  for (let index = 0; index < args.length; index++) {
    if (args[index] === '--list-cases') { list = true; continue; }
    assert.equal(args[index], '--group', `Unknown argument: ${args[index]}`);
    assert.equal(groupSeen, false, 'Use --group only once');
    groupSeen = true;
    const group = args[++index];
    assert.ok(Object.hasOwn(workflows, group), `--group must be one of: ${Object.keys(workflows).join(', ')}`);
    selected = [group];
  }
  if (list) {
    console.log(JSON.stringify({ journey, nativeVerified: false, companions, groups: selected,
      cases: cases.filter(test => selected.includes(test.group)), excluded,
      ...(groupWitnessPaths && { groupWitnessPaths: Object.fromEntries(Object.entries(groupWitnessPaths)
        .filter(([group]) => selected.includes(group))) }),
      ...(groupActions && { groupActions: Object.fromEntries(Object.entries(groupActions)
        .filter(([group]) => selected.includes(group))) }) }, null, 2));
    return;
  }
  assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
  const roots = new Set();
  for (const group of selected) {
    const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
    try {
      assert.ok(!roots.has(session.root), 'Each journey group receives fresh synthetic app storage');
      roots.add(session.root);
      await workflows[group](session);
      console.log(`PASS: ${journey}/${group}`);
    } catch (error) {
      throw new Error(`${journey}/${group} failed; later groups were not run`, { cause: error });
    } finally { await session.close(); }
  }
}
