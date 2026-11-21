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
  fixture = await startCodexFixture(session.root, ['success', 'cancel', 'recover', 'failure']);
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

    step = 'inspect the prior turn in Generation Jobs';
    await activate(await reveal(byID('codex-jobs')));
    const jobsSource = node => node.type === 'UISegmentedControl' && node.segments?.join('|') === 'This Mac|Shared project';
    const jobsWindow = (await waitForControl(jobsSource)).windowPath;
    await activate(await reveal(node => node.title === 'Inspect existing turn' && node.windowPath === jobsWindow));
    const inspected = await poll(jobs, records => records.find(job => job.jobID === cancelledID)?.status === 'cancelled');
    const cancelled = inspected.find(job => job.jobID === cancelledID);
    assert.equal(cancelled.hasThreadID && cancelled.hasTurnID, true);
    assert.equal(cancelled.attachmentVerified, false);
    assert.equal(cancelled.outputImageID, undefined);
    assert.equal(inspected.length, 2, 'Inspection did not create a new job');
    await unchanged();
    const closeJobs = async () => {
      const escape = (await session.command('keys')).find(command => command.input === 'Escape' && command.modifiers.length === 0);
      assert.equal(escape?.responderType, 'ScrivGenerationJobsController');
      assert.equal(escape.action, 'scrivEscapeSheet');
      assert.deepEqual(await session.command('key', { input: 'Escape', modifiers: [] }), { dispatched: true });
      await session.waitFor(nodes => !nodes.some(jobsSource));
    };
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
    await activate(await reveal(byID('codex-jobs')));
    const recoveryWindow = (await waitForControl(jobsSource)).windowPath;
    // Jobs are newest first. Inspect the first waiting card, while the earlier
    // cancelled card remains in the list for its separate outcome assertion.
    const inspect = node => node.title === 'Inspect existing turn' && node.windowPath === recoveryWindow;
    const inspectButtons = (await session.waitFor(nodes => nodes.filter(inspect).length === 2)).filter(inspect);
    await activate(await reveal(node => inspect(node) && node.path === inspectButtons[0].path));
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
    assert.equal(finished.length, 4);
    const refused = finished.find(job => ![cancelledID, complete.jobID, recoveryID].includes(job.jobID));
    assert.equal(refused.status, 'failed');
    assert.equal(refused.attachmentVerified, false);
    assert.equal(refused.outputImageID, undefined);
    assert.equal(refused.hasThreadID && refused.hasTurnID, true);
    assert.equal(finished.find(job => job.jobID === cancelledID).status, 'cancelled');
    assert.equal(finished.find(job => job.jobID === recoveryID).assetID, recoveredAsset.id);
    assert.equal(finished.find(job => job.jobID === complete.jobID).assetID, imageID);
    await unchanged();
  })());
  await fixture.close();
  fixture = undefined;
  console.log('PASS: native Codex loopback fixture generation, cancellation, recovery inspection and refusal');
} catch (error) {
  failed = true;
  throw new Error(`Codex loopback generation failed while trying to ${step}`, { cause: error });
} finally {
  // Preserve the primary assertion if cleanup also sees incomplete fixture work.
  try { if (fixture && failed) await fixture.close().catch(() => {}); }
  finally { await session.close(); }
}
