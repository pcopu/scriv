import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { generationContextInput } from './support/generation-context-cases.mjs';
import { fixtureImageHash, recoveredImageHash, startCodexFixture } from './support/codex-loopback-fixture.mjs';

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
  const before = await waitForSavedProject(session, project => project.title === fixtureSource.title);
  assert.deepEqual(before.images, []);
  assert.deepEqual(before.cues, fixtureSource.cues);
  await selectTab('Storyboard');
  await activate(await reveal(byID('storyboard-word-w2')));
  await selectTab('Script');
  const generate = node => node.identifier === 'generation-generate-image' && node.label === 'Generate image for 01A';
  const jobs = async () => (await session.command('image-evidence')).jobs;

  step = 'connect to the owned loopback fixture in Settings';
  fixture = await startCodexFixture(session.root, ['success', 'cancel', 'recover', 'missing-artifact', 'input-request', 'failure']);
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

    step = 'generate and attach the fixture image';
    await activate(await reveal(generate));
    const saved = await waitForSavedProject(session, project => project.id === before.id && !!project.cues.find(cue => cue.id === 'cue')?.imageId);
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
    assert.equal(saved.images.length, 1);
    let savedProjects = [sample, saved].sort((a, b) => a.id.localeCompare(b.id));
    const unchanged = async () => assert.deepEqual((await session.command('persisted-projects'))
      .sort((a, b) => a.id.localeCompare(b.id)), savedProjects, 'Only the completed fixture job may change saved projects');
    await unchanged();

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

    const jobsSource = node => node.type === 'UISegmentedControl' && node.segments?.join('|') === 'This Mac|Shared project';
    const openJobs = async () => {
      await activate(await reveal(byID('codex-jobs')));
      return (await waitForControl(jobsSource)).windowPath;
    };
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
  console.log('PASS: native Codex loopback fixture generation, cancellation, reconnect, recovery inspection and refusal');
} catch (error) {
  failed = true;
  throw new Error(`Codex loopback generation failed while trying to ${step}`, { cause: error });
} finally {
  // Preserve the primary assertion if cleanup also sees incomplete fixture work.
  try { if (fixture && failed) await fixture.close().catch(() => {}); }
  finally { await session.close(); }
}
