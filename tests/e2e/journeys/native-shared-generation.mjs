import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { audioLibrarySteps } from './support/audio-library-steps.mjs';
import { stableContent } from './support/audio-library-fixtures.mjs';
import { fixtureImageHash, recoveredImageHash, startCodexFixture } from './support/codex-loopback-fixture.mjs';
import { generationContextInput } from './support/generation-context-cases.mjs';
import { nativeFixtureEmail, startNativeCloudFixture } from './support/native-cloud-fixture.mjs';

assert.ok(process.env.SCRIV_E2E_APP, 'Requires a signed automation-enabled Catalyst build');
const project = generationContextInput('spanning-cue');
project.title = 'Synthetic shared image generation';
project.images = [];
for (const character of project.characters) delete character.portraitImageId;

const fixture = await startNativeCloudFixture();
const byID = id => node => node.identifier === id;
const jobsTab = node => node.type === 'UISegmentedControl' && node.segments?.join('|') === 'This Mac|Shared project';
let session, codex;
let step = 'seed and open the owned paid Team project';
let failed = false;

async function until(read, ready) {
  const deadline = Date.now() + 15_000;
  do {
    const value = await read();
    if (ready(value)) return value;
    await delay(100);
  } while (Date.now() < deadline);
  throw new Error('Expected shared job state did not arrive');
}

function verifyLeaseReceipts(job, { operations }) {
  const receipts = operations.filter(row => row.jobID === job.id);
  assert.ok(job.version >= 3, 'The job was claimed before its terminal update');
  assert.deepEqual(receipts.map(row => row.version), Array.from({ length: job.version - 1 }, (_, index) => index + 2));
  assert.ok(receipts.every(row => row.owner === 1), 'Every job operation was accepted for the owning native session');
  assert.equal(job.leaseExpiresAt, 0);
}

try {
  const { projectID } = await fixture.prepareSharedGeneration(project);
  session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { cloudFixtureOrigin: fixture.origin });
  const { cloudIsolation } = await session.command('capabilities');
  assert.equal(cloudIsolation.network, 'loopback-only');
  assert.equal(cloudIsolation.peerTransport, 'disabled');
  const ui = audioLibrarySteps(session);
  async function click(title) {
    const enabled = nodes => nodes.filter(node => node.enabled && node.hittable && node.type === 'UIButton'
      && (node.title === title || node.label === title));
    let prior, stableSince;
    const nodes = await session.waitFor(nodes => {
      const [target, second] = enabled(nodes);
      const key = target && !second ? JSON.stringify([target.path, target.frame]) : null;
      if (!key || key !== prior) { prior = key; stableSince = Date.now(); return false; }
      return Date.now() - stableSince >= 1000;
    });
    await session.command('activate', { target: enabled(nodes)[0].path });
  }
  await ui.activate(byID('workspace-project'));
  await click('Sign in to Scriv…');
  const isEmail = node => node.type === 'UITextField' && node.label === 'Email address';
  const fields = await session.waitFor(nodes => nodes.some(isEmail));
  await session.command('text', { target: fields.find(isEmail).path, text: nativeFixtureEmail });
  await click('Continue with email');
  await session.waitFor(nodes => nodes.some(node => node.text === 'Check your email'));
  assert.deepEqual(await session.deliverFixtureEmailCode(await fixture.takeCode()), { delivered: true });
  await click('Sign in with code');
  await click('Team projects');
  await session.waitFor(nodes => nodes.some(node => node.text === project.title + ' · Cloud project'));
  await click('Open project');
  const before = await waitForSavedProject(session, candidate => candidate.cloudProjectId === projectID && candidate.revision > 0);
  assert.deepEqual(before.images, []);
  assert.deepEqual(await fixture.sharedGenerationState(), { jobs: [], operations: [], hosted: [] });

  step = 'connect to the owned image runtime';
  codex = await startCodexFixture(session.root, ['success', 'recover', 'failure']);
  await codex.race((async () => {
    await session.command('key', { input: ',', modifiers: ['command'] });
    const setting = node => node.identifier === 'scriv.settings.codex' && node.hittable;
    const settings = await session.waitFor(nodes => nodes.filter(setting).length === 1);
    await session.command('activate', { target: settings.find(setting).path });
    const field = await ui.reveal(node => node.type === 'UITextField' && node.label === 'Saved loopback server address');
    await session.command('text', { target: field.path, text: codex.endpoint });
    await session.command('end-editing');
    await ui.activate(byID('codex-connect'));
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'codex-connection-status' && node.text === 'Connected')
      && nodes.some(node => node.identifier === 'codex-model' && node.label === 'Model: scriv-fixture'));
    codex.assertNoTurns();
    const generateButton = label => node => node.identifier === 'generation-generate-image' && node.label === 'Generate image for ' + label;
    const generateForCue = async (label = '01A') => {
      await ui.tab('Storyboard');
      await ui.activate(byID(label === '01A' ? 'storyboard-word-w2' : 'storyboard-word-w5'));
      await ui.tab('Script');
      await ui.activate(generateButton(label));
    };
    const openJobs = async () => { await ui.activate(byID('codex-jobs')); return ui.reveal(jobsTab); };
    const closeJobs = async () => {
      assert.deepEqual(await session.command('key', { input: 'Escape', modifiers: [] }), { dispatched: true });
      await session.waitFor(nodes => !nodes.some(jobsTab));
    };
    const localJobs = async () => (await session.command('image-evidence')).jobs;
    const savedPackage = async () => (await session.command('persisted-projects')).find(candidate => candidate.id === before.id);

    step = 'complete a shared job only after the generated image is saved and hosted';
    await generateForCue();
    const completed = await until(fixture.sharedGenerationState, state => state.jobs.length === 1
      && state.jobs[0].status === 'completed' && state.hosted.length === 1);
    const [job] = completed.jobs;
    const saved = await waitForSavedProject(session, candidate => candidate.id === before.id
      && candidate.cues.find(cue => cue.id === 'cue')?.imageId === job.imageID);
    const [image, ...extraImages] = saved.images;
    assert.deepEqual(extraImages, []);
    assert.equal(image.id, job.imageID);
    assert.equal(image.sha256, fixtureImageHash);
    assert.equal(job.cueID, 'cue');
    assert.equal(job.sourceRevision, before.revision);
    assert.equal(job.progress, 'Image saved to the shared project');
    assert.equal(job.errorCode, null);
    verifyLeaseReceipts(job, completed);
    assert.ok(job.version >= 4, 'The owning native session renewed the lease before attaching');
    assert.deepEqual(completed.hosted, [{ id: image.id, sha256: fixtureImageHash, bytes: 73 }]);
    assert.deepEqual(saved.entries, before.entries);
    assert.deepEqual(saved.characters, before.characters);
    assert.deepEqual(saved.cues, before.cues.map(cue => cue.id === 'cue' ? { ...cue, imageId: image.id } : cue));
    const local = (await localJobs()).find(record => record.jobID === job.id);
    assert.ok(local?.attachmentVerified && local.journalVerified);
    assert.equal(local.storedArtifactSHA256, fixtureImageHash);

    step = 'review the completed job in Shared project history';
    const tabs = await openJobs();
    await session.command('select', { target: tabs.path, index: 1 });
    await session.waitFor(nodes => nodes.some(node => node.windowPath === tabs.windowPath && node.text === 'Image saved to the shared project'));
    await closeJobs();

    step = 'interrupt an owned shared turn and recover its original image';
    await generateForCue('01B');
    const newLocalJob = (records, status) => records.find(record => record.jobID !== job.id && record.status === status);
    const started = await until(localJobs, records => newLocalJob(records, 'running')?.hasTurnID);
    const id = newLocalJob(started, 'running').jobID;
    const sharedRunning = (await fixture.sharedGenerationState()).jobs.find(record => record.id === id);
    assert.equal(sharedRunning.status, 'running');
    assert.ok(sharedRunning.leaseExpiresAt > Date.now());
    const generating = node => generateButton('01B')(node) && node.title === 'Generating…';
    const active = await session.waitFor(nodes => nodes.filter(generating).length === 1);
    const workspace = active.find(generating).windowPath;
    await ui.activate(node => node.label === 'Cancel the current image generation' && node.windowPath === workspace);
    const waiting = await until(fixture.sharedGenerationState, state => state.jobs.some(record => record.id === id && record.status === 'waiting'));
    const pending = waiting.jobs.find(record => record.id === id);
    assert.equal(pending.imageID, null);
    verifyLeaseReceipts(pending, waiting);
    assert.deepEqual(waiting.hosted, completed.hosted);
    assert.deepEqual(await savedPackage(), saved);

    const recoveryTabs = await openJobs();
    const recoveryControl = title => node => node.title === title && node.windowPath === recoveryTabs.windowPath;
    await ui.activate(recoveryControl('Inspect existing turn'));
    const inspected = await until(localJobs, records => records.some(record => record.jobID === id && record.artifact?.sha256 === recoveredImageHash));
    assert.equal(inspected.find(record => record.jobID === id).attachmentVerified, false);
    assert.deepEqual(await savedPackage(), saved);
    await ui.activate(node => recoveryControl('Use in original project')(node) && node.enabled === true);
    const recovered = await until(fixture.sharedGenerationState, state => state.hosted.length === 2
      && state.jobs.some(record => record.id === id && record.status === 'completed'));
    assert.equal(recovered.jobs.length, 2, 'Recovery kept the original shared job ID');
    const recoveredJob = recovered.jobs.find(record => record.id === id);
    assert.equal(recoveredJob.cueID, 'later');
    assert.equal(recoveredJob.sourceRevision, saved.revision);
    assert.ok(recoveredJob.version >= pending.version + 3, 'An explicit claim, renewal and completion followed the waiting state');
    verifyLeaseReceipts(recoveredJob, recovered);
    assert.deepEqual(recovered.hosted.find(asset => asset.id === recoveredJob.imageID),
      { id: recoveredJob.imageID, sha256: recoveredImageHash, bytes: 73 });
    const recoveredPackage = await waitForSavedProject(session, candidate => candidate.id === before.id
      && candidate.cues.find(cue => cue.id === 'later')?.imageId === recoveredJob.imageID);
    assert.equal(recoveredPackage.images.length, 2);
    assert.deepEqual(recoveredPackage.entries, saved.entries);
    assert.deepEqual(recoveredPackage.characters, saved.characters);
    assert.deepEqual(recoveredPackage.cues, saved.cues.map(cue => cue.id === 'later' ? { ...cue, imageId: recoveredJob.imageID } : cue));
    assert.deepEqual(recovered.jobs.find(row => row.id === job.id), job);
    await session.waitFor(nodes => !nodes.some(recoveryControl('Use in original project')));
    await closeJobs();

    step = 'record a refused turn without changing the completed job or the cue';
    const beforeRefusal = await savedPackage();
    await generateForCue();
    const alerts = await until(() => session.command('presented-alerts'), items => items.length > 0);
    assert.equal(alerts.length, 1);
    assert.equal(alerts[0].message, 'Synthetic image turn refused');
    const refused = await until(fixture.sharedGenerationState, state => state.jobs.some(row => row.status === 'failed'));
    assert.equal(refused.jobs.length, 3);
    const refusal = refused.jobs.find(row => row.status === 'failed');
    assert.equal(refusal.cueID, 'cue');
    // Live reconciliation can advance the package revision after recovery.
    // The app-owned journal records the exact revision captured for this turn.
    const refusedLocal = (await localJobs()).find(record => record.jobID === refusal.id);
    assert.ok(refusedLocal?.hasThreadID && refusedLocal.hasTurnID && !refusedLocal.attachmentVerified);
    assert.match(refusedLocal.jobID, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
    const journal = JSON.parse(await readFile(join(session.root, 'Generation', 'Journal', refusedLocal.jobID + '.json'), 'utf8'));
    assert.equal(journal.id, refusal.id);
    assert.equal(journal.status, 'failed');
    assert.equal(journal.context.projectID, before.id);
    assert.equal(journal.context.cloudProjectID, projectID);
    assert.equal(journal.context.targetCue.id, 'cue');
    assert.equal(refusal.sourceRevision, journal.context.sourceRevision);
    assert.equal(refusal.errorCode, 'local_generation_failed');
    assert.equal(refusal.progress, 'Generation failed on the owning Mac');
    assert.equal(refusal.imageID, null);
    verifyLeaseReceipts(refusal, refused);
    assert.deepEqual(refused.jobs.find(row => row.id === job.id), job);
    assert.deepEqual(refused.jobs.find(row => row.id === id), recoveredJob);
    assert.deepEqual(refused.hosted, recovered.hosted);
    const afterRefusal = await savedPackage();
    assert.ok(refusal.sourceRevision >= beforeRefusal.revision && refusal.sourceRevision <= afterRefusal.revision);
    assert.deepEqual(stableContent(afterRefusal), stableContent(beforeRefusal));
    await fixture.assertNoOutbound();
  })());
  await codex.close();
  codex = undefined;
} catch (error) {
  failed = true;
  throw new Error(`Native shared generation failed during ${step}`, { cause: error });
} finally {
  try { await session?.close(); }
  finally {
    try { await codex?.close().catch(error => { if (!failed) throw error; }); }
    finally { await fixture.close(); }
  }
}
