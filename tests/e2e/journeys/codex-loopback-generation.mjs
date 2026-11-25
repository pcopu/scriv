import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, readdir, realpath, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { reviewSteps } from './support/generation-review-steps.mjs';
import { generationContextInput } from './support/generation-context-cases.mjs';
import { fixtureImageHash, recoveredImageHash, startCodexFixture } from './support/codex-loopback-fixture.mjs';

const groups = ['history-prompt', 'history-retry', 'history-artifact', 'history-retry-portrait', 'cancel-unconfirmed', 'completed-without-image'];
const args = process.argv.slice(2);
if (args.length === 1 && args[0] === '--list-cases') {
  console.log(JSON.stringify({ groups, groupActions: {
    'completed-without-image': [{ id: 'generate-image', command: 'activate', trigger: 'generation-generate-image',
      condition: 'provider-completes-without-an-image', entryPoint: {
        path: 'apps/catalyst/ScrivUIKit/Images/PreviewViewController.swift', start: 175, end: 181,
        sha256: 'eeefc45ca6579f22f405fa2c447d4f157bffd72ae659d12a5083ad0bea7093ff',
      } }],
  } }));
  process.exit(0);
}
assert.ok(args.length === 0 || args.length === 2 && args[0] === '--group' && groups.includes(args[1]), 'Choose a supported local Codex group');
const historyPrompt = args[1] === 'history-prompt';
const retryPortrait = args[1] === 'history-retry-portrait';
const portraitSHA256 = '3fba282698b3df63c76fb40e529943fb6da6d28bafa6ff9e3a75c0c4a0cbb784';
const historyRetry = args[1] === 'history-retry' || retryPortrait;
const historyArtifact = args[1] === 'history-artifact';
const cancelUnconfirmed = args[1] === 'cancel-unconfirmed';
const completedWithoutImage = args[1] === 'completed-without-image';

assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const byID = id => node => node.identifier === id;
const canActivate = node => node.hittable && node.enabled === true;
const fixtureSource = generationContextInput('spanning-cue');
fixtureSource.title = 'Synthetic local Codex fixture';
fixtureSource.images = [];
for (const character of fixtureSource.characters) delete character.portraitImageId;
let fixture;
let step = 'verify the isolated app and save the cue';
let failed = false;

async function waitForControl(matches) {
  const controls = nodes => nodes.filter(node => matches(node) && canActivate(node));
  const nodes = await session.waitFor(nodes => controls(nodes).length === 1);
  return controls(nodes)[0];
}

async function reveal(matches) {
  for (let attempt = 0; attempt < 8; attempt++) {
    const nodes = await session.waitFor(nodes => nodes.filter(matches).length === 1);
    const target = nodes.find(matches);
    if (target.hittable) return target;
    const ancestor = nodes.filter(node => node.scroll && node.hittable && target.path.startsWith(node.path + '.'))
      .sort((a, b) => b.path.length - a.path.length)[0];
    assert.ok(ancestor, 'The target has a reachable scroll ancestor');
    await session.command('scroll', { target: ancestor.path, y: ancestor.scroll.y + target.frame.y - ancestor.frame.y - 12 });
  }
  throw new Error('Control did not become hittable');
}

async function activate(target) {
  assert.ok(canActivate(target), 'Activate only an enabled, hittable control');
  await session.command('activate', { target: target.path });
}

async function selectTab(title) {
  const tabs = await waitForControl(byID('workspace-tabs'));
  const index = tabs.segments.indexOf(title);
  assert.ok(index >= 0);
  await session.command('select', { target: tabs.path, index });
  await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.selected === index));
}

async function poll(observe, predicate) {
  const deadline = Date.now() + 15_000;
  do {
    const value = await observe();
    if (predicate(value)) return value;
    await delay(50);
  } while (Date.now() < deadline);
  throw new Error('Expected observable condition did not arrive');
}

try {
  const capabilities = await session.command('capabilities');
  assert.equal(capabilities.cloudIsolation.network, 'disabled');
  assert.deepEqual((await session.command('image-evidence')).jobs, []);
  await waitForControl(byID('workspace-tabs'));
  await session.command('key', { input: 's', modifiers: ['command'] });
  const sample = await waitForSavedProject(session, project => project.title === 'YAM MAN');
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(fixtureSource) }),
    { dispatched: true, projectChanged: true });
  let before = await waitForSavedProject(session, project => project.title === fixtureSource.title);
  assert.deepEqual(before.images, []);
  assert.deepEqual(before.cues, fixtureSource.cues);
  await selectTab('Storyboard');
  await activate(await reveal(byID('storyboard-word-w2')));
  await selectTab('Script');
  const generate = node => node.identifier === 'generation-generate-image' && node.label === 'Generate image for 01A';
  const jobs = async () => (await session.command('image-evidence')).jobs;

  if (retryPortrait) {
    step = 'import and tag a local picture before choosing it as Anna’s portrait';
    assert.deepEqual(await session.command('import-local-image', { fixture: 'blue' }, 30000),
      { dispatched: true, imported: true, cleanupVerified: true });
    const imported = await waitForSavedProject(session, project => project.id === before.id && project.images.length === 1);
    const [asset] = imported.images;
    assert.equal(asset.sha256, portraitSHA256);
    assert.equal(imported.cues.find(cue => cue.id === 'cue').imageId, asset.id);
    await activate(await reveal(node => node.label === 'Edit pictured character tags' && node.enabled !== undefined));
    await activate(await reveal(node => node.label === 'Anna' && node.enabled !== undefined));
    await session.waitFor(nodes => nodes.some(node => node.label === 'Anna' && node.value === 'Pictured in this image'));
    await activate(await waitForControl(node => node.title === 'Done'));
    await selectTab('Characters');
    await activate(await reveal(byID('character-ribbon-a')));
    await session.command('end-editing');
    const target = 'character-portrait-options';
    await reveal(byID(target));
    const menu = await session.command('menu', { target });
    const choices = menu.primary.flatMap(section => section.children).flatMap(section => section.children);
    assert.deepEqual(choices.map(choice => choice.title), ['Use 01A · v1']);
    assert.deepEqual(await session.command('menu-action', { target, scope: target, action: choices[0].title,
      characterID: 'a', imageID: asset.id }), { dispatched: true, coverage: 'semantic-menu-action' });
    before = await waitForSavedProject(session, project => project.id === imported.id
      && project.characters.find(person => person.id === 'a').portraitImageId === asset.id);
    assert.deepEqual(before.characters, imported.characters.map(person => person.id === 'a'
      ? { ...person, portraitImageId: asset.id } : person));
    assert.deepEqual(before.images, [{ ...asset, characterIds: ['a'] }]);
    assert.deepEqual(before.cues, imported.cues);
    assert.deepEqual(before.entries, imported.entries);
    await selectTab('Script');
    step = 'review the exact reference portrait before submitting';
    const review = reviewSteps(session);
    await review.open();
    const people = await review.section(1);
    assert.ok(people.some(node => node.text === 'Portrait inputs · 1 attached · up to 5'));
    const exact = await review.section(2);
    assert.match(exact.find(byID('generation-exact-request')).text, /^Reference 1 \(reference-0\): "Anna" \["a"\]$/m);
    await review.activate('generation-review-done');
    await review.closed();
    assert.deepEqual(await jobs(), []);
    assert.deepEqual((await session.command('persisted-projects')).sort((a, b) => a.id.localeCompare(b.id)),
      [sample, before].sort((a, b) => a.id.localeCompare(b.id)));
  }

  step = 'connect to the owned loopback fixture in Settings';
  const submittedRequests = [];
  const outcomes = [completedWithoutImage ? 'completed-without-image' : 'success'];
  if (cancelUnconfirmed) outcomes.push('cancel-unconfirmed');
  else if (historyRetry) outcomes.push('cancel', 'retry-success');
  else if (args.length === 0) outcomes.push('cancel', 'recover', 'missing-artifact', 'input-request', 'failure');
  fixture = await startCodexFixture(session.root, outcomes, {
    accountRefresh: true,
    ...((historyPrompt || historyRetry) && { onSubmittedPrompt: request => submittedRequests.push(request) }),
    ...(retryPortrait && { referenceSHA256: portraitSHA256 }),
  });
  await fixture.race((async () => {
    await session.command('key', { input: ',', modifiers: ['command'] });
    // Sidebar cells use the public collection view selection route. The CLI
    // reports their hit-test state but only UIControl nodes have `enabled`.
    const codexCells = nodes => nodes.filter(node => node.identifier === 'scriv.settings.codex'
      && node.hittable && node.enabled !== false);
    const settings = await session.waitFor(nodes => codexCells(nodes).length === 1);
    assert.deepEqual(await session.command('activate', { target: codexCells(settings)[0].path }), { dispatched: true });
    const isEndpoint = node => node.type === 'UITextField' && node.label === 'Saved loopback server address';
    const endpoint = await reveal(isEndpoint);
    assert.ok(canActivate(endpoint), 'The manual endpoint field is enabled and hittable');
    await session.command('text', { target: endpoint.path, text: fixture.endpoint });
    const endpoints = (await session.command('snapshot')).filter(isEndpoint);
    assert.equal(endpoints.length, 1);
    assert.equal(endpoints[0].text, fixture.endpoint);
    await session.command('end-editing');
    const connect = await reveal(byID('codex-connect'));
    assert.equal(connect.label, 'Connect to this address');
    await activate(connect);
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'codex-connection-status' && node.text === 'Connected')
      && nodes.some(node => node.identifier === 'codex-account-status' && node.text === 'Not required by this provider')
      && nodes.some(node => node.identifier === 'codex-model' && node.label === 'Model: scriv-fixture'));

    step = 'decline unsolicited provider approval and input requests';
    const unchangedOnConnect = await session.command('persisted-projects');
    const extraPermissions = 'Codex requested additional permissions. Review this generation in Codex before retrying.';
    const needsInput = 'Codex needs additional input. Add the details to the image direction and retry.';
    for (const [method, result, message] of [
      ['item/commandExecution/requestApproval', { decision: 'decline' }, extraPermissions],
      ['item/fileChange/requestApproval', { decision: 'decline' }, extraPermissions],
      ['item/permissions/requestApproval', { permissions: {}, scope: 'turn' }, 'Codex requested additional permissions. No extra access was granted.'],
      ['mcpServer/elicitation/request', { action: 'decline', content: null }, 'A connected Codex tool requested additional input. Review it in Codex before retrying.'],
      ['item/tool/requestUserInput', { answers: {} }, needsInput],
    ]) {
      assert.deepEqual(await fixture.request(method), { result });
      await session.waitFor(nodes => nodes.some(node => node.text === message)
        && nodes.some(node => node.identifier === 'codex-connection-status' && node.text === 'Connected'));
    }
    assert.deepEqual(await fixture.request('fixture/unsupported'), {
      error: { code: -32601, message: 'This client does not implement fixture/unsupported.' },
    });
    fixture.assertNoTurns();
    assert.deepEqual(await jobs(), []);
    assert.deepEqual(await session.command('persisted-projects'), unchangedOnConnect);

    step = 'surface provider notices and ignore an unrelated login completion';
    for (const [variant, message] of [
      ['warning', 'Synthetic provider warning'],
      ['config-warning', 'Synthetic provider configuration warning'],
      ['error', 'Synthetic provider error'],
    ]) {
      await fixture.notify(variant);
      await session.waitFor(nodes => nodes.some(node => node.text === message)
        && nodes.some(node => node.identifier === 'codex-connection-status' && node.text === 'Connected'));
    }
    await fixture.notify('orphan-login');
    assert.deepEqual(await fixture.request('fixture/unsupported'), {
      error: { code: -32601, message: 'This client does not implement fixture/unsupported.' },
    });
    await session.waitFor(nodes => nodes.some(node => node.text === 'Synthetic provider error')
      && nodes.every(node => node.text !== 'Synthetic unrelated login failure'));

    step = 'refresh the provider account and recover from unsuccessful reads';
    for (const [account, connection, enabled, message] of [
      ['synthetic-account@example.invalid', 'Connected', true],
      ['Checking existing account…', 'Checking local connection…', false, 'This runtime returned an invalid account identity.'],
      ['Checking existing account…', 'Checking local connection…', false, 'Synthetic account check interrupted'],
      ['Not signed in', 'Connected · sign-in needed', true],
      ['Not required by this provider', 'Connected', true],
    ]) {
      await fixture.notify('account-update');
      await session.waitFor(nodes => nodes.some(node => node.identifier === 'codex-account-status' && node.text === account)
        && nodes.some(node => node.identifier === 'codex-connection-status' && node.text === connection)
        && nodes.some(node => node.identifier === 'codex-account' && node.enabled === enabled)
        && (!message || nodes.some(node => node.text === message)));
    }
    fixture.assertNoTurns();
    assert.deepEqual(await jobs(), []);
    assert.deepEqual(await session.command('persisted-projects'), unchangedOnConnect);

    if (completedWithoutImage) {
      step = 'report a completed provider turn that returned no image';
      await activate(await reveal(generate));
      const alerts = await poll(() => session.command('presented-alerts'), alerts => alerts.length > 0);
      assert.equal(alerts.length, 1);
      assert.equal(alerts[0].title, 'Scriv');
      assert.match(alerts[0].message, /^Codex completed without a valid generated image/);
      const [job, ...unexpected] = await jobs();
      assert.deepEqual(unexpected, []);
      assert.equal(job.status, 'failed');
      assert.equal(job.projectID, before.id);
      assert.equal(job.cueID, 'cue');
      assert.equal(job.hasThreadID && job.hasTurnID, true);
      assert.equal(job.journalVerified, false);
      assert.equal(job.attachmentVerified, false);
      assert.equal(job.artifact, undefined);
      assert.match(job.jobID, /^[0-9a-f-]{36}$/i);
      const journal = JSON.parse(await readFile(join(session.root, 'Generation', 'Journal', job.jobID + '.json'), 'utf8'));
      assert.equal(journal.id, job.jobID);
      assert.equal(journal.status, 'failed');
      assert.equal(journal.outputImageID, undefined);
      assert.deepEqual(await session.command('persisted-projects'), unchangedOnConnect);
      return;
    }

    step = 'generate and attach the fixture image';
    await activate(await reveal(generate));
    const previousImageID = before.cues.find(cue => cue.id === 'cue')?.imageId;
    const saved = await waitForSavedProject(session, project => {
      const imageID = project.cues.find(cue => cue.id === 'cue')?.imageId;
      return project.id === before.id && imageID && imageID !== previousImageID;
    });
    const imageID = saved.cues.find(cue => cue.id === 'cue').imageId;
    const [complete] = await poll(jobs, records => records.length === 1 && records[0].attachmentVerified);
    assert.equal(complete.status, 'completed');
    assert.equal(complete.projectID, saved.id);
    assert.equal(complete.cueID, 'cue');
    assert.equal(complete.assetID, imageID);
    assert.equal(complete.journalVerified, true);
    assert.equal(complete.hasThreadID && complete.hasTurnID, true);
    assert.equal(complete.storedArtifactSHA256, fixtureImageHash);
    assert.deepEqual(complete.artifact, { sha256: fixtureImageHash, byteCount: 73, width: 2, height: 2, decodedThumbnailWidth: 2, decodedThumbnailHeight: 2 });
    assert.deepEqual(complete.asset, complete.artifact);
    assert.deepEqual(saved.entries, before.entries);
    assert.deepEqual(saved.characters, before.characters);
    assert.deepEqual(saved.cues.filter(cue => cue.id !== 'cue'), before.cues.filter(cue => cue.id !== 'cue'));
    assert.deepEqual(saved.images.filter(image => image.id !== imageID), before.images);
    assert.equal(saved.images.length, before.images.length + 1);
    let savedProjects = [sample, saved].sort((a, b) => a.id.localeCompare(b.id));
    const unchanged = async () => assert.deepEqual((await session.command('persisted-projects'))
      .sort((a, b) => a.id.localeCompare(b.id)), savedProjects, 'Only the completed fixture job may change saved projects');
    await unchanged();

    const jobsSource = node => node.type === 'UISegmentedControl' && node.segments?.join('|') === 'This Mac|Shared project';
    const openJobs = async () => {
      await activate(await reveal(byID('codex-jobs')));
      return (await waitForControl(jobsSource)).windowPath;
    };
    if (historyPrompt) {
      step = 'read the completed job’s exact submitted prompt';
      const historyWindow = await openJobs();
      await activate(await reveal(node => node.windowPath === historyWindow && node.title === 'View details'));
      await activate(await reveal(node => node.windowPath === historyWindow && node.title === 'View exact submitted prompt'));
      const promptText = node => node.windowPath === historyWindow && node.type === 'UITextView' && node.hittable;
      const promptNodes = await session.waitFor(nodes => nodes.filter(promptText).length === 1);
      const promptView = promptNodes.find(promptText);
      assert.equal(submittedRequests.length, 1);
      assert.equal(submittedRequests[0].jobID, complete.jobID);
      assert.equal(promptView.text, submittedRequests[0].prompt);
      assert.equal(promptView.editable, false);
      await assert.rejects(session.command('text', { target: promptView.path, text: 'Synthetic replacement' }), /Editor cannot be edited/);
      assert.deepEqual(await jobs(), [complete]);
      await unchanged();
      return;
    }
    if (historyArtifact) {
      step = 'refuse a changed job image while keeping the saved project';
      const historyWindow = await openJobs();
      const openImage = node => node.windowPath === historyWindow && node.title === 'Open image';
      const artifactError = node => node.windowPath === historyWindow
        && node.text === 'The saved generation image is missing or has changed.';
      assert.match(complete.jobID, /^[0-9a-f-]{36}$/);
      const file = join(session.root, 'Generation', complete.jobID, 'storyboard.png');
      assert.equal(await realpath(file), file);
      const original = await readFile(file);
      const altered = Buffer.from(original);
      altered[0] ^= 0xff;
      try {
        await writeFile(file, altered);
        await activate(await reveal(openImage));
        await session.waitFor(nodes => nodes.some(artifactError));
        await waitForControl(openImage);
        assert.deepEqual(await readFile(file), altered);
        await unchanged();
      } finally {
        await writeFile(file, original);
      }

      step = 'open the restored original from Generation history';
      const visiblePaths = new Set((await session.command('snapshot')).filter(node => node.windowPath === historyWindow && node.hittable).map(node => node.path));
      await activate(await waitForControl(openImage));
      await session.waitFor(nodes => !nodes.some(artifactError)
        && nodes.some(node => openImage(node) && !node.hittable)
        && nodes.some(node => node.windowPath === historyWindow && node.hittable && !visiblePaths.has(node.path)));
      assert.deepEqual(await session.command('presented-alerts'), []);
      assert.deepEqual(await jobs(), [complete]);
      await unchanged();
      return;
    }

    step = 'interrupt the running turn with the visible Cancel button';
    await activate(await reveal(generate));
    // An early progress notification can race the turn/start reply. Use the
    // app's recorded turn identity before exercising the visible Cancel action.
    const running = await poll(jobs, records => records.length === 2 && records.some(job =>
      job.jobID !== complete.jobID && job.status === 'running' && job.hasThreadID && job.hasTurnID));
    const cancelledID = running.find(job => job.jobID !== complete.jobID).jobID;
    const activeGenerate = node => generate(node) && node.title === 'Generating…';
    const composer = await session.waitFor(nodes => nodes.filter(activeGenerate).length === 1);
    const workspaceWindow = composer.find(activeGenerate).windowPath;
    const cancelButton = node => node.label === 'Cancel the current image generation' && node.windowPath === workspaceWindow;
    await activate(await reveal(cancelButton));
    await poll(jobs, records => records.find(job => job.jobID === cancelledID)?.status === 'waiting');

    const inspectOriginal = async windowPath => activate(await reveal(node =>
      node.title === 'Inspect existing turn' && node.windowPath === windowPath));
    const verifyWaiting = async (windowPath, progress) => {
      await session.waitFor(nodes => nodes.some(node => node.windowPath === windowPath && node.text === progress));
      const records = await jobs();
      assert.equal(records.length, 2);
      const original = records.find(job => job.jobID === cancelledID);
      assert.equal(original.status, 'waiting');
      assert.equal(original.hasThreadID && original.hasTurnID, true);
      assert.equal(original.attachmentVerified, false);
      await unchanged();
    };

    const closeJobs = async () => {
      const escape = (await session.command('keys')).find(command => command.input === 'Escape' && command.modifiers.length === 0);
      assert.equal(escape?.responderType, 'ScrivGenerationJobsController');
      assert.equal(escape.action, 'scrivEscapeSheet');
      assert.deepEqual(await session.command('key', { input: 'Escape', modifiers: [] }), { dispatched: true });
      await session.waitFor(nodes => !nodes.some(jobsSource));
    };

    if (cancelUnconfirmed) {
      step = 'inspect the original turn after the runtime refuses cancellation';
      await session.waitFor(nodes => nodes.some(node => node.identifier === 'codex-setup-error'
        && node.text === 'Codex cancellation could not be confirmed. The turn may still be running in the local runtime. Synthetic runtime refused the interruption'));
      const historyWindow = await openJobs();
      await inspectOriginal(historyWindow);
      await verifyWaiting(historyWindow, 'Original turn is still in progress. Inspect again later; do not submit a duplicate.');
      const previous = (await jobs()).find(job => job.jobID === complete.jobID);
      assert.equal(previous.attachmentVerified, true);
      assert.equal(previous.assetID, imageID);
      assert.equal(previous.storedArtifactSHA256, fixtureImageHash);
      assert.deepEqual(await session.command('presented-alerts'), []);
      return;
    }

    step = 'inspect the saved turn while the owned runtime connection is lost';
    await waitForControl(generate);
    await fixture.dropAfterCancellation();
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'codex-connection-status' && node.text === 'Not connected')
      && nodes.some(node => node.text === 'Codex connection closed.'));
    const disconnectedJobs = await openJobs();
    await inspectOriginal(disconnectedJobs);
    await verifyWaiting(disconnectedJobs, 'Connect the original runtime to inspect its saved turn. Nothing was resubmitted.');
    assert.deepEqual(await session.command('presented-alerts'), []);
    await closeJobs();

    step = 'reconnect through Settings and check both pages of the model catalog';
    await activate(await reveal(byID('codex-connect')));
    const modelButton = await waitForControl(node => node.identifier === 'codex-model' && node.label === 'Model: scriv-fixture');
    const catalog = await session.command('menu', { target: modelButton.path });
    assert.deepEqual(catalog.primary[0].children.map(({ title, state }) => ({ title, state })), [
      { title: 'scriv-fixture', state: 'on' }, { title: 'scriv-fixture-extra', state: 'off' },
    ]);

    step = 'recheck the same turn until the original cancellation is confirmed';
    const reconnectedJobs = await openJobs();
    await inspectOriginal(reconnectedJobs);
    await verifyWaiting(reconnectedJobs, 'The original turn is not visible yet. No new generation was submitted.');
    await inspectOriginal(reconnectedJobs);
    await verifyWaiting(reconnectedJobs, 'Original turn is still in progress. Inspect again later; do not submit a duplicate.');
    await inspectOriginal(reconnectedJobs);
    const inspected = await poll(jobs, records => records.find(job => job.jobID === cancelledID)?.status === 'cancelled');
    const cancelled = inspected.find(job => job.jobID === cancelledID);
    assert.equal(cancelled.hasThreadID && cancelled.hasTurnID, true);
    assert.equal(cancelled.attachmentVerified, false);
    assert.equal(cancelled.outputImageID, undefined);
    assert.equal(inspected.length, 2, 'Inspection did not create a new job');
    await unchanged();

    if (historyRetry) {
      const retryButton = node => node.windowPath === reconnectedJobs && node.title === 'Retry…';
      const readJournal = async id => {
        assert.match(id, /^[0-9a-f-]{36}$/);
        const file = join(session.root, 'Generation', 'Journal', `${id}.json`);
        assert.equal(await realpath(file), file);
        return JSON.parse(await readFile(file, 'utf8'));
      };
      const originalJournals = await Promise.all(inspected.map(job => readJournal(job.jobID)));
      const confirmation = async () => {
        await activate(await reveal(retryButton));
        await waitForControl(byID('generation-retry-cancel'));
        await waitForControl(byID('generation-retry-confirm'));
      };
      step = 'cancel the retry confirmation without starting a request';
      await confirmation();
      await activate(await waitForControl(byID('generation-retry-cancel')));
      await waitForControl(retryButton);
      assert.equal(submittedRequests.length, 2);
      assert.deepEqual(await jobs(), inspected);
      await unchanged();

      step = 'confirm one new request with the cancelled job’s original prompt';
      await confirmation();
      await activate(await waitForControl(byID('generation-retry-confirm')));
      await poll(() => submittedRequests, requests => requests.length === 3);
      const [first, original, retry] = submittedRequests;
      assert.equal(first.jobID, complete.jobID);
      assert.equal(original.jobID, cancelledID);
      assert.ok(!inspected.some(job => job.jobID === retry.jobID));
      assert.equal(retry.prompt, original.prompt);
      const journal = await poll(() => readJournal(retry.jobID), record => record.status === 'completed' && record.outputImageID);
      assert.equal(journal.id, retry.jobID);
      assert.equal(journal.retryOf, cancelledID);
      assert.equal(journal.submittedPrompt, original.prompt);
      assert.equal(journal.context.projectID, cancelled.projectID);
      assert.equal(journal.context.targetCue.id, cancelled.cueID);
      assert.equal(journal.artifactSha256, recoveredImageHash);
      assert.deepEqual(await Promise.all(inspected.map(job => readJournal(job.jobID))), originalJournals);
      const updated = await waitForSavedProject(session, project => project.id === saved.id
        && project.cues.find(cue => cue.id === cancelled.cueID)?.imageId === journal.outputImageID);
      const retake = updated.images.find(image => image.id === journal.outputImageID);
      assert.equal(retake?.sha256, recoveredImageHash);
      assert.equal(retake.fileName, `${recoveredImageHash}.png`);
      const output = join(session.root, 'Projects', `${updated.id}.scriv`, 'assets', retake.fileName);
      assert.equal(await realpath(output), output);
      assert.equal(createHash('sha256').update(await readFile(output)).digest('hex'), recoveredImageHash);
      assert.deepEqual(updated.images.filter(image => image.id !== journal.outputImageID), saved.images);
      assert.deepEqual(updated.entries, saved.entries);
      assert.deepEqual(updated.characters, saved.characters);
      assert.deepEqual(updated.cues.filter(cue => cue.id !== cancelled.cueID), saved.cues.filter(cue => cue.id !== cancelled.cueID));
      savedProjects = [sample, updated].sort((a, b) => a.id.localeCompare(b.id));
      await unchanged();
      if (retryPortrait) {
        const references = [{ fileName: 'reference-0.png', sha256: portraitSHA256 }];
        const originalJournal = originalJournals.find(record => record.id === cancelledID);
        assert.deepEqual(originalJournal.references, references);
        assert.deepEqual(journal.references, references);
        step = 'refuse a modified saved portrait without creating another request';
        const path = join(session.root, 'Generation', cancelledID, references[0].fileName);
        assert.equal(await realpath(path), path);
        const bytes = await readFile(path);
        assert.equal(createHash('sha256').update(bytes).digest('hex'), portraitSHA256);
        const altered = await readFile(output);
        assert.equal(createHash('sha256').update(altered).digest('hex'), recoveredImageHash);
        try {
          await writeFile(path, altered);
          await confirmation();
          await activate(await waitForControl(byID('generation-retry-confirm')));
          const alerts = await poll(() => session.command('presented-alerts'), records => records.length > 0);
          assert.deepEqual(alerts.map(({ title, message }) => ({ title, message })), [{
            title: 'Scriv', message: 'An original reference image is missing or changed. Choose new references instead.',
          }]);
          assert.equal(submittedRequests.length, 3);
          const journalDirectory = join(session.root, 'Generation', 'Journal');
          assert.deepEqual((await readdir(journalDirectory)).filter(name => name.endsWith('.json')).sort(),
            [first.jobID, cancelledID, retry.jobID].map(id => `${id}.json`).sort());
          assert.deepEqual(await Promise.all(inspected.map(job => readJournal(job.jobID))), originalJournals);
          assert.deepEqual(await readJournal(retry.jobID), journal);
          await unchanged();
        } finally {
          await writeFile(path, bytes);
        }
        assert.deepEqual(await readFile(path), bytes);
      }
      return;
    }

    await closeJobs();

    step = 'recover the finished original turn without resubmitting';
    await selectTab('Storyboard');
    await activate(await reveal(byID('storyboard-word-w5')));
    await selectTab('Script');
    const recoveryGenerate = node => node.identifier === 'generation-generate-image' && node.label === 'Generate image for 01B';
    await activate(await reveal(recoveryGenerate));
    const recovering = await poll(jobs, records => records.length === 3 && records.some(job =>
      ![complete.jobID, cancelledID].includes(job.jobID) && job.status === 'running' && job.hasThreadID && job.hasTurnID));
    const recoveryID = recovering.find(job => ![complete.jobID, cancelledID].includes(job.jobID)).jobID;
    await activate(await reveal(cancelButton));
    await poll(jobs, records => records.find(job => job.jobID === recoveryID)?.status === 'waiting');
    await unchanged();
    const inspectLatest = async windowPath => {
      // The newest pending card precedes the earlier cancelled card.
      const inspect = node => node.title === 'Inspect existing turn' && node.windowPath === windowPath;
      const buttons = (await session.waitFor(nodes => nodes.filter(inspect).length === 2)).filter(inspect);
      await activate(await reveal(node => inspect(node) && node.path === buttons[0].path));
    };
    const recoveryWindow = await openJobs();
    await inspectLatest(recoveryWindow);
    const ready = await poll(jobs, records => records.some(job => job.jobID === recoveryID
      && job.status === 'completed' && job.artifact?.sha256 === recoveredImageHash));
    assert.equal(ready.length, 3);
    assert.equal(ready.find(job => job.jobID === recoveryID).attachmentVerified, false);
    await unchanged();
    await activate(await reveal(node => node.title === 'Use in original project' && node.windowPath === recoveryWindow));
    const recovered = await waitForSavedProject(session, project => project.id === saved.id
      && project.images.some(image => image.sha256 === recoveredImageHash)
      && !!project.cues.find(cue => cue.id === 'later')?.imageId);
    const recoveredAsset = recovered.images.find(image => image.sha256 === recoveredImageHash);
    assert.equal(recovered.cues.find(cue => cue.id === 'later').imageId, recoveredAsset.id);
    assert.deepEqual(recovered.entries, saved.entries);
    assert.deepEqual(recovered.characters, saved.characters);
    assert.deepEqual(recovered.cues.filter(cue => cue.id !== 'later'), saved.cues.filter(cue => cue.id !== 'later'));
    const attached = await poll(jobs, records => records.some(job => job.jobID === recoveryID && job.attachmentVerified));
    assert.equal(attached.length, 3, 'Recovery must reuse the original job');
    assert.equal(attached.find(job => job.jobID === recoveryID).assetID, recoveredAsset.id);
    savedProjects = [sample, recovered].sort((a, b) => a.id.localeCompare(b.id));
    await unchanged();
    await closeJobs();

    step = 'inspect a completed turn that has no local image';
    await selectTab('Storyboard');
    await activate(await reveal(byID('storyboard-word-w2')));
    await selectTab('Script');
    await activate(await reveal(generate));
    const existingIDs = attached.map(job => job.jobID);
    const unknown = jobs => jobs.find(job => !existingIDs.includes(job.jobID));
    const pendingMissing = await poll(jobs, records => records.length === 4 && unknown(records)?.hasTurnID
      && unknown(records)?.status === 'running');
    const missingID = unknown(pendingMissing).jobID;
    await activate(await reveal(cancelButton));
    await poll(jobs, records => records.find(job => job.jobID === missingID)?.status === 'waiting');
    const missingWindow = await openJobs();
    await inspectLatest(missingWindow);
    await session.waitFor(nodes => nodes.some(node => node.windowPath === missingWindow
      && node.text === 'The saved turn completed without a valid local image'));
    const missing = await jobs();
    assert.equal(missing.length, 4, 'Checking the missing image did not create another job');
    const originalMissing = missing.find(job => job.jobID === missingID);
    assert.equal(originalMissing.status, 'failed');
    assert.equal(originalMissing.hasThreadID && originalMissing.hasTurnID, true);
    assert.equal(originalMissing.attachmentVerified, false);
    assert.equal(originalMissing.outputImageID, undefined);
    assert.equal(originalMissing.artifact, undefined);
    await unchanged();
    await closeJobs();

    step = 'interrupt only the active generation when the provider asks for more input';
    await activate(await reveal(generate));
    const knownIDs = missing.map(job => job.jobID);
    const needsDetails = records => records.find(job => !knownIDs.includes(job.jobID));
    const withActiveTurn = await poll(jobs, records => records.length === 5 && needsDetails(records)?.hasTurnID
      && needsDetails(records)?.status === 'running');
    const inputJobID = needsDetails(withActiveTurn).jobID;
    assert.deepEqual(await fixture.request('item/tool/requestUserInput', { activeTurn: true }), { result: { answers: {} } });
    const stopped = await poll(jobs, records => records.find(job => job.jobID === inputJobID)?.status === 'waiting');
    const inputJob = stopped.find(job => job.jobID === inputJobID);
    assert.equal(inputJob.attachmentVerified, false);
    assert.equal(inputJob.artifact, undefined);
    assert.deepEqual(stopped.filter(job => job.jobID !== inputJobID), missing);
    await session.waitFor(nodes => nodes.some(node => node.text === needsInput));
    await unchanged();

    step = 'verify a refused turn changes neither the cue nor prior jobs';
    await selectTab('Storyboard');
    await activate(await reveal(byID('storyboard-word-w2')));
    await selectTab('Script');
    await activate(await reveal(generate));
    const alerts = await poll(() => session.command('presented-alerts'), alerts => alerts.length > 0);
    assert.equal(alerts.length, 1);
    assert.equal(alerts[0].title, 'Scriv');
    assert.equal(alerts[0].message, 'Synthetic image turn refused');
    const finished = await jobs();
    assert.equal(finished.length, 6);
    const refused = finished.find(job => ![...knownIDs, inputJobID].includes(job.jobID));
    assert.equal(refused.status, 'failed');
    assert.equal(refused.attachmentVerified, false);
    assert.equal(refused.outputImageID, undefined);
    assert.equal(refused.hasThreadID && refused.hasTurnID, true);
    assert.equal(finished.find(job => job.jobID === cancelledID).status, 'cancelled');
    assert.deepEqual(finished.find(job => job.jobID === missingID), originalMissing);
    assert.deepEqual(finished.find(job => job.jobID === inputJobID), inputJob);
    assert.equal(finished.find(job => job.jobID === recoveryID).assetID, recoveredAsset.id);
    assert.equal(finished.find(job => job.jobID === complete.jobID).assetID, imageID);
    await unchanged();
  })());
  await fixture.close();
  fixture = undefined;
  if (historyPrompt) console.log('PASS: Generation history displays the exact recorded request as read-only text without changing jobs or projects');
  else if (retryPortrait) console.log('PASS: Retry sends the captured portrait bytes once and rejects a modified copy');
  else if (historyRetry) console.log('PASS: Cancel preserves the job and confirmed Retry submits its recorded request once');
  else if (cancelUnconfirmed) console.log('PASS: refused interruption retains the original turn for inspection without a duplicate');
  else if (historyArtifact) console.log('PASS: Generation history rejects modified artifact bytes and opens the restored original');
  else if (completedWithoutImage) console.log('PASS: Scriv reports the missing image and preserves the failed job and saved projects');
  else console.log('PASS: native Codex loopback fixture generation, cancellation, reconnect, recovery inspection and refusal');
} catch (error) {
  failed = true;
  throw new Error(`Codex loopback generation failed while trying to ${step}`, { cause: error });
} finally {
  // Preserve the primary assertion if cleanup also sees incomplete fixture work.
  try { if (fixture && failed) await fixture.close().catch(() => {}); }
  finally { await session.close(); }
}
