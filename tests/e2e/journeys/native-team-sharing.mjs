import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { isDeepStrictEqual } from 'node:util';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { audioLibrarySteps, sortedProjects } from './support/audio-library-steps.mjs';
import { audioProjectFixture } from './support/audio-library-fixtures.mjs';
import { nativeFixtureEmail, nativeFixtureTeam, startNativeCloudFixture } from './support/native-cloud-fixture.mjs';
import { keyIs, scriptAuthoringSteps } from './support/script-authoring-steps.mjs';

const groups = ['sharing', 'live-presence'];
const args = process.argv.slice(2);
if (args.length === 1 && args[0] === '--list-cases') {
  console.log(JSON.stringify({ groups, groupActions: {
    'live-presence': [{ id: 'incoming-script-selection', command: 'event', trigger: 'presence-delta',
      condition: 'another-live-session-selects-then-leaves-the-displayed-line', entryPoint: {
        path: 'apps/mac/Sources/ScrivApp/Services/CloudClient.swift', start: 737, end: 744,
        sha256: '6770242f3a2e0738044092b7e1132f37d377c7f17130c8ca0ca76d735888a47e',
      } }],
  } }));
  process.exit(0);
}
assert.ok(args.length === 0 || args.length === 2 && args[0] === '--group' && groups.includes(args[1]), 'Choose a supported native Team group');
const livePresence = args[1] === 'live-presence';

assert.ok(process.env.SCRIV_E2E_APP, 'Requires a signed Catalyst automation build');
const fixture = await startNativeCloudFixture();
const ready = node => node.enabled && node.hittable;
const byID = id => node => node.identifier === id;
const button = title => node => node.type === 'UIButton' && (node.title === title || node.label === title);
const teamHeading = `Share with ${nativeFixtureTeam}?`;
const shareCopy = 'Create a separate team copy. The original project and its history remain unchanged.';
const shareLocal = 'Share the current project with this team. Local files remain on this device.';
const dispatched = { dispatched: true, coverage: 'semantic-menu-action' };
const byTitle = rows => [...rows].sort((a, b) => a.title.localeCompare(b.title));
const byItemID = (a, b) => a.id.localeCompare(b.id);
const documentOf = ({ id, title, cloudProjectId, revision, createdAt, modifiedAt, entries, characters, ...rest }) => ({
  ...rest, entries: [...entries].sort(byItemID), characters: [...characters].sort(byItemID),
});
let session;
let step = 'set up a paid synthetic Team and sign in';

async function run() {
  const team = await fixture.createPaidTeam();
  assert.match(team.id, /^[a-f0-9-]{36}$/i);
  session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { cloudFixtureOrigin: fixture.origin });
  const caps = await session.command('capabilities');
  assert.equal(caps.cloudIsolation.network, 'loopback-only');
  assert.equal(caps.cloudIsolation.peerTransport, 'disabled');
  const ui = audioLibrarySteps(session);
  const packages = async () => sortedProjects(await session.command('persisted-projects'));
  const projectButton = byID('workspace-project');
  async function readyControl(matches, settle = false) {
    const select = nodes => nodes.filter(node => matches(node) && ready(node));
    let last, since;
    const nodes = await session.waitFor(nodes => {
      const [node, other] = select(nodes);
      if (!settle) return !!node && !other;
      const key = node && !other ? JSON.stringify([node.path, node.frame]) : undefined;
      if (!key || key !== last) { last = key; since = Date.now(); return false; }
      return Date.now() - since >= 1000;
    });
    return select(nodes)[0];
  }
  async function click(matches) {
    const target = (await readyControl(matches, true)).path;
    await session.command('activate', { target });
  }
  async function openPanel(scope, action) {
    const menu = await readyControl(node => node.label === 'Workspace actions');
    assert.deepEqual(await session.command('menu-action', { target: menu.path, scope, action }), dispatched);
  }
  async function openTeams() {
    await openPanel('workspace-panels', 'Teams and sharing…');
    await session.waitFor(nodes => nodes.some(node => node.text === 'Members (1)')
      && nodes.some(node => node.text === '● Active'));
  }
  async function openConfirmation(message) {
    await ui.activate(button('Share team copy'));
    const active = await session.waitFor(nodes => nodes.some(node => node.text === teamHeading)
      && nodes.some(node => node.text === message)
      && nodes.some(node => byID('team-share-confirm')(node) && ready(node)), 5000).catch(async error => {
      const alerts = await session.command('presented-alerts');
      const legacy = alerts.find(item => item.title === teamHeading && item.message === message);
      if (legacy) throw new Error(`The native alert presents ${legacy.actions.map(action => action.title).join(' and ')} without the expected public share control`, { cause: error });
      throw error;
    });
    const confirm = active.find(byID('team-share-confirm'));
    assert.equal(confirm.title, 'Share');
    assert.ok(active.some(node => byID('team-share-cancel')(node) && node.windowPath === confirm.windowPath));
  }
  async function shareLocalProject() {
    step = 'share an unsynced local project without making a copy';
    const input = { ...audioProjectFixture(), title: 'Synthetic local Team project' };
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
    const local = await waitForSavedProject(session, project => project.title === input.title);
    assert.equal(local.cloudProjectId, undefined);
    await openTeams();
    await openConfirmation(shareLocal);
    await click(byID('team-share-confirm'));
    await waitForSavedProject(session, project => project.id === local.id && !!project.cloudProjectId);
    await click(button('Open project'));
    await readyControl(projectButton);
    const loadedShared = (await session.command('loaded-project')).project;
    const shared = await waitForSavedProject(session, project => isDeepStrictEqual(project, loadedShared));
    assert.equal(shared.id, local.id);
    assert.equal(shared.title, local.title);
    assert.deepEqual(documentOf(shared), documentOf(local));
    return shared;
  }

  await ui.tab('Script');
  await session.command('key', { input: 's', modifiers: ['command'] });
  const sample = await waitForSavedProject(session, project => project.title === 'YAM MAN');
  await click(projectButton);
  await click(button('Sign in to Scriv…'));
  const email = await ui.reveal(node => node.type === 'UITextField' && node.label === 'Email address');
  await session.command('text', { target: email.path, text: nativeFixtureEmail });
  await click(button('Continue with email'));
  await session.waitFor(nodes => nodes.some(node => node.text === 'Check your email'));
  assert.deepEqual(await session.deliverFixtureEmailCode(await fixture.takeCode()), { delivered: true });
  await click(button('Sign in with code'));
  await click(button('Close Projects'));
  await readyControl(projectButton);
  assert.deepEqual(await fixture.projectTeams(), []);

  if (livePresence) {
    const shared = await shareLocalProject();
    assert.deepEqual(await fixture.projectTeams(), [{ id: shared.cloudProjectId, title: shared.title, teamId: team.id }]);
    step = 'publish native Script selections to another live session';
    await session.waitFor(nodes => nodes.some(node => node.text?.endsWith(' · Live')));
    assert.equal(await fixture.openPresenceObserver(shared.cloudProjectId), true);
    async function waitForPresence(predicate, message, timeoutMs = 5000) {
      const deadline = Date.now() + timeoutMs;
      do {
        const result = predicate(await fixture.observedPresence());
        if (result) return result;
        await delay(75);
      } while (Date.now() < deadline);
      assert.fail(message);
    }
    await waitForPresence(state => state.ready, 'The second session joins the live project');
    const script = scriptAuthoringSteps(session);
    await script.selectTab('Script');
    const [line] = shared.entries;
    await script.displayed(line.id, line.text, { finished: true });
    const editKey = (await session.command('keys')).find(command => keyIs(command, '\r', ['command'])
      && command.action === 'toggleScriptEditingFromKeyboard:');
    assert.ok(editKey, 'The selected script line exposes the edit shortcut');
    await script.key(editKey.input, editKey.modifiers);
    const editorID = `script-editor-${line.id}`;
    await session.waitFor(nodes => nodes.some(node => node.identifier === editorID && node.firstResponder));
    let connectionId;
    const latestSelection = { start: 4, end: 7 };
    for (const selection of [{ start: 1, end: 3 }, latestSelection]) {
      await session.command('selection', { target: editorID, ...selection });
      await script.waitEditor(editorID, line.text, selection.start, selection.end);
      const update = await waitForPresence(state => state.updates.findLast(update => update.itemId === line.id
        && isDeepStrictEqual(update.selection, selection)), 'The second session receives the exact Script selection');
      connectionId ??= update.connectionId;
      assert.equal(update.connectionId, connectionId);
    }
    step = 'restore the unchanged Script selection after an isolated socket closure';
    assert.equal(await fixture.closeObservedPresenceConnection(shared.cloudProjectId, connectionId), true);
    await waitForPresence(state => state.updates.findLast(update => update.connectionId !== connectionId
      && update.itemId === line.id && isDeepStrictEqual(update.selection, latestSelection)),
    'The second session receives the exact selection again over a new app connection', 10_000);
    await script.waitEditor(editorID, line.text, latestSelection.start, latestSelection.end);
    await script.finishEditor();

    step = 'display and clear the second live session’s selection on the unchanged script';
    const display = byID(`script-line-${line.id}`);
    const peerMarker = nodes => {
      const row = nodes.find(node => display(node) && node.hittable && node.text === line.text);
      if (!row) return undefined;
      return nodes.some(node => node.path.startsWith(row.path + '.') && node.label === 'Scriv user is editing here'
        && node.frame.width > 0 && node.frame.height > 0);
    };
    const initial = await script.displayed(line.id, line.text, { finished: true });
    assert.equal(peerMarker(initial), false);
    assert.equal(await fixture.echoObservedPresence(shared.cloudProjectId, line.id), true);
    await session.waitFor(nodes => peerMarker(nodes) === true);
    assert.equal(await fixture.echoObservedPresence(shared.cloudProjectId, null), true);
    await session.waitFor(nodes => peerMarker(nodes) === false);
    assert.deepEqual((await session.command('loaded-project')).project, shared);
    assert.deepEqual(await packages(), sortedProjects([sample, shared]));
    assert.deepEqual(await session.command('presented-alerts'), []);
    await fixture.assertNoOutbound();
    console.log('PASS: native Script selections travel both ways and survive an isolated reconnect');
    return;
  }

  step = 'create a personal cloud project without Team membership';
  await openPanel('workspace-discussion', 'Discussion');
  await click(button('Save script to cloud'));
  await waitForSavedProject(session, project => project.id === sample.id && !!project.cloudProjectId);
  await click(button('Close discussion'));
  await readyControl(projectButton);
  const personalLoaded = await session.command('loaded-project');
  const personal = await waitForSavedProject(session, project => isDeepStrictEqual(project, personalLoaded.project));
  const personalCloud = { id: personal.cloudProjectId, title: personal.title, teamId: null };
  assert.deepEqual(await fixture.projectTeams(), [personalCloud]);

  step = 'cancel the Team copy confirmation without changing either store';
  await openTeams();
  await openConfirmation(shareCopy);
  await click(byID('team-share-cancel'));
  await readyControl(button('Share team copy'));
  assert.deepEqual(await packages(), [personal]);
  assert.deepEqual(await fixture.projectTeams(), [personalCloud]);

  step = 'create an independent Team copy of the personal project';
  await openConfirmation(shareCopy);
  await click(byID('team-share-confirm'));
  await waitForSavedProject(session, project => project.title === `${personal.title} — Team copy` && !!project.cloudProjectId);
  await session.waitFor(nodes => nodes.some(node => node.text === 'Shared with this team'));
  await click(button('Open project'));
  await readyControl(projectButton);
  const loadedCopy = (await session.command('loaded-project')).project;
  const copy = await waitForSavedProject(session, project => isDeepStrictEqual(project, loadedCopy));
  assert.notEqual(copy.id, personal.id);
  assert.notEqual(copy.cloudProjectId, personal.cloudProjectId);
  assert.equal(copy.title, `${personal.title} — Team copy`);
  assert.deepEqual(documentOf(copy), documentOf(personal));
  const teamCopy = { id: copy.cloudProjectId, title: copy.title, teamId: team.id };
  assert.deepEqual(byTitle(await fixture.projectTeams()), byTitle([personalCloud, teamCopy]));
  assert.deepEqual(await packages(), sortedProjects([personal, copy]));
  const shared = await shareLocalProject();
  assert.deepEqual(await packages(), sortedProjects([personal, copy, shared]));
  const sharedCloud = { id: shared.cloudProjectId, title: shared.title, teamId: team.id };
  assert.deepEqual(byTitle(await fixture.projectTeams()), byTitle([personalCloud, teamCopy, sharedCloud]));
  assert.deepEqual(await ui.openProject(personal), personalLoaded);
  assert.deepEqual(await session.command('presented-alerts'), []);
  await fixture.assertNoOutbound();
}
try { await run(); }
catch (error) { throw new Error(`Native Team sharing failed during ${step}`, { cause: error }); }
finally {
  try { await session?.close(); }
  finally { await fixture.close(); }
}
