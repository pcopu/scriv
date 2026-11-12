import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { observePresentedError } from '../../support/presented-error.mjs';
import { lineDurationStatus, invalidDirectionSeconds } from './line-duration-cases.mjs';

export const ready = node => node.enabled === true && node.hittable === true;
export const sorted = projects => [...projects].sort((a, b) => a.id.localeCompare(b.id));
const disclosure = node => node.identifier === 'preview-layers-disclosure';
const field = node => node.label === 'Duration, seconds';
const menuAction = 'Owned duration…';
const invalidMessage = 'Enter a valid duration up to 3,600 seconds.';
const header = (nodes, title) => nodes.some(node => node.identifier === 'workspace-project'
  && node.title === title && ready(node));
const keyIs = (command, input, modifiers) => command.input === input
  && command.modifiers.length === modifiers.length && modifiers.every(value => command.modifiers.includes(value));

// Compatibility export for the original preparation audit. This contract now
// accompanies an executable direction-only runner; none of it is native proof.
export const pendingLineDurationSteps = Object.freeze({
  ...lineDurationStatus,
  requiredExistingCommands: ['snapshot', 'activate', 'text', 'select', 'scroll', 'slider',
    'key', 'keys', 'menu', 'menu-action', 'import-json', 'persisted-projects', 'loaded-project', 'presented-alerts'],
  dispatcher: { command: 'menu-action', action: menuAction,
    response: { dispatched: true, coverage: 'semantic-menu-action' },
    scope: 'Exact current embedded Layers direction UIButton and its single stored secondary UIAction only.' },
  loadedObserver: 'Requires the separately guarded same-store, current-navigation Owned duration sheet scope, with at most one terminal validation UIAlertController.',
  beforeMutation: [
    'Save and retain the actual isolated startup sample, then import a literal synthetic fixture through the production importer.',
    'Verify complete imported authored fields, local app-generated identity, zero revision, and the loaded model/date witnesses.',
    'Expand embedded Layers and use its real zoom/scroll controls. Require exactly one current direction UIButton by complete title and label, enabled and hittable, plus its single stored secondary menu action.',
    'STOP for dialogue, an expanded Layers modal, duplicate/unreachable controls, unsupported dispatcher, unsupported observer or any denied helper.',
  ],
  additionalAcceptance: ['one-time wrong-action/extra-field/dialogue/covered-target guard checks', 'Cancel two distinct drafts', 'eight invalid numeric drafts and correction in the same editor',
    'complete sampled saved/loaded/date invariance', 'exact frozen ordered edits',
    'runtime slider and following-row timestamp', 'post-save editor precision',
    'non-sample literal Undo/Redo after frozen sequence', 'different-document browser reopen'],
  deferred: ['Script UIAlertController Apply/Cancel', 'dialogue duration edits', 'sample Undo/Redo annotation bootstrap',
    'other valid numeric boundaries beyond exact fixture steps', 'physical input', 'native menu presentation/selection',
    'hold/drag/scrub', 'direction coverage rail', 'delayed/denied lease races',
    'stale source/navigation while sheet is open', 'transient state between observations',
    'image/audio bytes or rendering', 'audio playback', 'process restart/crash recovery'],
});

export function auditPendingLineDurationSteps() {
  assert.equal(pendingLineDurationSteps.status, 'prepared-native-unverified');
  assert.equal(pendingLineDurationSteps.nativeVerified, false);
  assert.equal(pendingLineDurationSteps.retirementAllowed, false);
  assert.ok(pendingLineDurationSteps.beforeMutation.some(step => step.startsWith('STOP')));
  return pendingLineDurationSteps;
}

export function lineDurationSteps(session) {
  const packages = async () => sorted(await session.command('persisted-projects'));
  const loaded = () => session.command('loaded-project');
  const saved = predicate => waitForSavedProject(session, predicate);
  async function reveal(predicate) {
    for (let attempt = 0; attempt < 10; attempt++) {
      const nodes = await session.waitFor(nodes => nodes.filter(predicate).length === 1);
      const node = nodes.find(predicate);
      if (node.hittable) return node;
      const ancestors = nodes.filter(candidate => candidate.scroll && candidate.hittable
        && node.path.startsWith(candidate.path + '.')).sort((a, b) => b.path.length - a.path.length);
      assert.ok(ancestors.length, 'Offscreen target needs a reachable real scrolling ancestor');
      const ancestor = ancestors[0];
      const y = ancestor.scroll.y + node.frame.y - ancestor.frame.y
        - ancestor.frame.height / 2 + node.frame.height / 2;
      assert.ok(Math.abs(y - ancestor.scroll.y) > 0.5, 'Covered/horizontally clipped target has no vertical-scroll fallback');
      await session.command('scroll', { target: ancestor.path, y });
    }
    throw new Error('Direction duration target remained unreachable after bounded real scrolling');
  }
  async function activate(predicate) {
    const node = await reveal(predicate);
    assert.ok(ready(node), 'Activate only an enabled, hittable real UIControl');
    assert.deepEqual(await session.command('activate', { target: node.path }), { dispatched: true });
  }
  async function button(title) { await activate(node => node.title === title && ready(node)); }
  async function tab(name) {
    const nodes = await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && ready(node)));
    const tabs = nodes.find(node => node.identifier === 'workspace-tabs');
    const index = tabs.segments.indexOf(name);
    assert.ok(index >= 0);
    if (tabs.selected !== index) await session.command('select', { target: tabs.identifier, index });
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.selected === index && ready(node)));
  }
  async function key(input, modifiers = ['command']) {
    assert.ok((await session.command('keys')).some(command => command.responderType === 'ScrivWorkspaceController'
      && keyIs(command, input, modifiers)), 'The actual enabled workspace key command must be installed');
    assert.deepEqual(await session.command('key', { input, modifiers }), { dispatched: true });
  }
  async function initialize() {
    const capabilities = await session.command('capabilities');
    for (const command of pendingLineDurationSteps.requiredExistingCommands) {
      assert.ok(capabilities.commands.includes(command), `Matching native app supports ${command}`);
    }
    assert.ok(capabilities.semanticMenuActionScopes?.includes('layers-direction-duration'),
      'Matching app advertises the independently audited embedded direction menu scope');
    await tab('Script'); await key('s');
    const startup = await saved(project => project.title === 'YAM MAN' && project.entries.length === 18);
    assert.deepEqual(await packages(), [startup], 'Fresh run owns only its saved synthetic startup project');
    assert.deepEqual((await loaded()).project, startup);
    return startup;
  }
  async function importCase(test, startup) {
    assert.equal(test.entryKind, 'direction', 'Never route dialogue through the direction-only sheet');
    const input = test.makeInput(startup); input.title = `Duration ${test.key} ${randomUUID()}`;
    assert.equal(input.entries.find(entry => entry.id === test.entryID)?.kind, 'direction');
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }),
      { dispatched: true, projectChanged: true });
    await session.waitFor(nodes => header(nodes, input.title));
    await tab('Script');
    const before = await saved(project => project.title === input.title && project.id !== startup.id);
    assert.notEqual(before.id, input.id); assert.equal(before.revision, 0);
    assert.equal(Object.hasOwn(before, 'cloudProjectId'), false);
    const importedPayload = structuredClone(before), inputPayload = structuredClone(input);
    for (const key of ['id', 'createdAt', 'modifiedAt', 'revision']) {
      delete importedPayload[key]; delete inputPayload[key];
    }
    assert.deepEqual(importedPayload, inputPayload, 'Import preserves every authored field and legacy omission');
    const witness = await loaded(); assert.deepEqual(witness.project, before);
    for (const key of ['createdAt', 'modifiedAt']) assert.match(witness.dateReferenceTimeBits[key], /^\d+$/);
    await othersUnchanged(startup, before.id);
    return before;
  }
  async function othersUnchanged(startup, projectID) {
    const all = await packages();
    assert.equal(all.length, 2);
    assert.deepEqual(all.filter(project => project.id !== projectID), [startup]);
  }
  async function unchanged(beforePackages, beforeLoaded, { alert = false } = {}) {
    assert.deepEqual(await packages(), beforePackages, 'Every complete saved package/revision/date is unchanged');
    assert.deepEqual(await loaded(), beforeLoaded, 'Complete actual loaded model and Date bits are unchanged at this observation');
    if (!alert) assert.deepEqual(await session.command('presented-alerts'), []);
  }
  async function expandLayers() {
    const node = await reveal(disclosure);
    if (node.label === 'Expand Layers') await activate(disclosure);
    await session.waitFor(nodes => nodes.some(node => disclosure(node) && node.label === 'Collapse Layers'));
    const zoom = await reveal(node => node.label === 'Timeline zoom');
    assert.ok(ready(zoom));
    assert.ok(Math.abs(zoom.slider.minimum - 0.3) < 0.001);
    // The ordinary zoom control brings the sample's later source into view.
    // No horizontal-scroll support or native menu opening is fabricated.
    if (zoom.slider.value !== zoom.slider.minimum) {
      await session.command('slider', { target: zoom.path, value: zoom.slider.minimum });
      await session.waitFor(nodes => nodes.some(node => node.label === 'Timeline zoom'
        && Math.abs(node.slider.value - node.slider.minimum) < 0.001));
    }
  }
  async function collapseLayers() {
    const node = await reveal(disclosure);
    if (node.label === 'Collapse Layers') await activate(disclosure);
    await session.waitFor(nodes => nodes.some(node => disclosure(node) && node.label === 'Expand Layers'));
  }
  async function directionButton(project, id) {
    const targets = project.entries.filter(entry => entry.id === id);
    assert.equal(targets.length, 1); const target = targets[0];
    assert.equal(target.kind, 'direction');
    assert.equal(project.entries.filter(entry => entry.sceneId === target.sceneId
      && entry.kind === 'direction' && entry.text === target.text
      && entry.ownedDurationMs === target.ownedDurationMs).length, 1, 'Duplicate direction labels are unsupported, never guessed');
    await expandLayers();
    const duration = target.ownedDurationMs === 0 ? '0s' : `${(target.ownedDurationMs / 1000).toFixed(1)}s`;
    const title = `${target.text}\n${duration} owned`;
    const node = await reveal(node => node.title === title && node.label === title);
    assert.ok(ready(node));
    const menu = await session.command('menu', { target: node.path });
    assert.deepEqual(menu.primary, []); assert.deepEqual(menu.context, []);
    assert.equal(menu.secondary.length, 1);
    assert.equal(menu.secondary[0].type, 'menu'); assert.equal(menu.secondary[0].title, '');
    assert.deepEqual(menu.secondary[0].children, [{ type: 'action', title: menuAction,
      disabled: false, hidden: false, state: 'off' }]);
    return node;
  }
  async function open(project, id, expected) {
    // Paths are deliberately re-queried after every rebuild/edit.
    const node = await directionButton(project, id);
    assert.deepEqual(await session.command('menu-action', { target: node.path, action: menuAction }),
      pendingLineDurationSteps.dispatcher.response);
    const nodes = await session.waitFor(nodes => nodes.filter(field).length === 1
      && nodes.some(node => field(node) && ready(node))
      && nodes.some(node => node.title === 'Apply' && ready(node))
      && nodes.some(node => node.title === 'Cancel' && ready(node)));
    assert.equal(nodes.find(field).text, expected, 'Existing sheet loads exact three-decimal owned duration');
    assert.ok(nodes.some(node => node.text === 'Owned duration'));
    assert.ok(!nodes.some(node => node.text === 'Authored image coverage'));
    assert.deepEqual(await session.command('presented-alerts'), []);
    assert.deepEqual((await loaded()).project, project, 'Opening the real sheet does not edit the loaded project');
  }
  async function input(text) {
    const node = await reveal(field); assert.ok(ready(node));
    await session.command('text', { target: node.path, text });
    await session.waitFor(nodes => nodes.some(node => field(node) && node.text === text && ready(node)));
  }
  async function closed() {
    await session.waitFor(nodes => nodes.every(node => !field(node))
      && nodes.some(node => node.identifier === 'workspace-tabs' && ready(node)));
    assert.deepEqual(await session.command('presented-alerts'), []);
  }
  async function verifyMenuGuards(test, project) {
    const beforePackages = await packages(), beforeLoaded = await loaded();
    let target = await directionButton(project, test.entryID);
    for (const request of [
      { target: target.path, action: 'Authored coverage…' },
      { target: target.path, action: menuAction, unexpected: true },
    ]) {
      await assert.rejects(session.command('menu-action', request), /outside the supported (?:isolated )?scope/);
      await unchanged(beforePackages, beforeLoaded);
    }
    const direction = project.entries.find(entry => entry.id === test.entryID);
    const dialogue = project.entries.find(entry => entry.sceneId === direction.sceneId && entry.kind === 'dialogue');
    assert.ok(dialogue, 'Every selected synthetic direction fixture includes a real dialogue control');
    const speaker = project.characters.find(character => character.id === dialogue.characterId)?.name ?? 'Dialogue';
    const title = `${speaker}\n${dialogue.text}`;
    const spoken = await reveal(node => node.title === title && node.label === title);
    assert.ok(ready(spoken));
    await assert.rejects(session.command('menu-action', { target: spoken.path, action: menuAction }),
      /outside the supported isolated scope/);
    await unchanged(beforePackages, beforeLoaded);
    await open(project, test.entryID, test.originalSeconds);
    // Look up the actual covered control again; never dispatch a stale path or
    // use covered Script alert controls as an alternate route.
    const source = project.entries.find(entry => entry.id === test.entryID);
    const duration = source.ownedDurationMs === 0 ? '0s' : `${(source.ownedDurationMs / 1000).toFixed(1)}s`;
    const directionTitle = `${source.text}\n${duration} owned`;
    const nodes = await session.command('snapshot');
    const covered = nodes.filter(node => node.title === directionTitle && node.label === directionTitle);
    assert.equal(covered.length, 1); assert.equal(covered[0].hittable, false);
    await assert.rejects(session.command('menu-action', { target: covered[0].path, action: menuAction }),
      /Target is behind the active presentation/);
    await unchanged(beforePackages, beforeLoaded);
    await button('Cancel'); await closed(); await unchanged(beforePackages, beforeLoaded);
  }
  async function cancelDrafts(test, project) {
    const beforePackages = await packages(), beforeLoaded = await loaded();
    for (const draft of ['2.75', '86400']) {
      await open(project, test.entryID, test.originalSeconds); await input(draft);
      await unchanged(beforePackages, beforeLoaded);
      await button('Cancel'); await closed(); await unchanged(beforePackages, beforeLoaded);
    }
  }
  async function invalidDrafts(test, project) {
    const beforePackages = await packages(), beforeLoaded = await loaded();
    await open(project, test.entryID, test.originalSeconds);
    for (const value of invalidDirectionSeconds) {
      await input(value); await button('Apply');
      await session.waitFor(nodes => nodes.some(node => node.text === invalidMessage)
        && nodes.some(node => field(node) && node.text === value && ready(node)));
      await unchanged(beforePackages, beforeLoaded);
    }
    // Successful cases correct the same editor with their first exact stimulus.
  }
  async function savedAfter(before, expected, startup) {
    const current = await saved(project => project.id === before.id && project.revision > before.revision);
    assert.equal(current.revision, before.revision + 1, 'Exactly one accepted command creates one revision');
    const actual = structuredClone(current); delete actual.modifiedAt; delete actual.revision;
    assert.deepEqual(actual, expected, 'Complete saved content equals the explicit literal oracle');
    assert.deepEqual((await loaded()).project, current);
    await othersUnchanged(startup, current.id);
    return current;
  }
  async function runtimeAndStarts(project, oracle) {
    await collapseLayers();
    const seek = await reveal(node => node.identifier === 'scene-playback-position');
    assert.ok(ready(seek)); assert.equal(seek.slider.maximum, oracle.runtimeMs);
    for (const [id, milliseconds] of Object.entries(oracle.starts ?? {})) {
      await reveal(node => node.identifier === `script-line-${id}`);
      const nodes = await session.command('snapshot');
      const source = nodes.find(node => node.identifier === `script-line-${id}`);
      const rows = nodes.filter(node => node.type === 'ScriptEntryRow' && source.path.startsWith(node.path + '.'));
      assert.equal(rows.length, 1, 'Timestamp is scoped to the exact real source row');
      const timestamp = `${String(Math.floor(milliseconds / 60000)).padStart(2, '0')}:${((milliseconds % 60000) / 1000).toFixed(1).padStart(4, '0')}`;
      assert.ok(nodes.some(node => node.path.startsWith(rows[0].path + '.') && node.text === timestamp),
        'Actual following row displays the frozen expected timestamp');
      const target = project.entries.find(entry => entry.id === id);
      assert.ok(target);
      // The whole saved model was already matched, including exact entry order
      // and owned milliseconds. Rounded label equality is not the timing oracle.
    }
  }
  async function reopen(project, other) {
    await collapseLayers(); await key('s');
    const before = await loaded(); assert.deepEqual(before.project, project);
    async function openDocument(value) {
      await activate(node => node.identifier === 'workspace-project');
      const search = await reveal(node => node.placeholder === 'Find a project');
      await session.command('text', { target: search.path, text: value.title });
      await session.waitFor(nodes => nodes.some(node => node.text === `${value.title} · ${value.scenes.length} scene${value.scenes.length === 1 ? '' : 's'}`));
      await button('Open project'); await session.waitFor(nodes => header(nodes, value.title));
      const result = await loaded(); assert.equal(result.project.id, value.id); return result;
    }
    assert.deepEqual((await openDocument(other)).project, other);
    assert.deepEqual(await openDocument(project), before, 'Real different-document Open/reopen preserves the full model and Date bits');
    await othersUnchanged(other, project.id);
  }
  async function reject(test, project) {
    const beforePackages = await packages(), beforeLoaded = await loaded();
    await open(project, test.entryID, test.originalSeconds);
    await input(test.rejection.seconds); await button('Apply');
    // Production errors are presented above the sheet. Never invoke an alert
    // action, click Cancel behind it, retry the mutation, or load a native helper.
    await observePresentedError(session, test.rejection.error);
    for (let pass = 0; pass < 2; pass++) await unchanged(beforePackages, beforeLoaded, { alert: true });
  }
  return { initialize, importCase, packages, loaded, saved, othersUnchanged, unchanged,
    open, input, button, closed, verifyMenuGuards, cancelDrafts, invalidDrafts, savedAfter,
    runtimeAndStarts, reopen, reject, collapseLayers,
    history: (redo = false) => key('z', redo ? ['command', 'shift'] : ['command']) };
}
