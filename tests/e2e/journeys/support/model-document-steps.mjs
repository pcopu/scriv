import assert from 'node:assert/strict';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { acknowledgeJSONImportError, jsonImportAcknowledgement, observePresentedError } from '../../support/presented-error.mjs';
import { payload } from './model-document-cases.mjs';

const sorted = items => [...items].sort((a, b) => a.id.localeCompare(b.id));
const header = (nodes, title) => nodes.some(n => n.identifier === 'workspace-project' && n.title === title && n.hittable);
export async function openModelDocument(session, project) {
  // STEP browser begin
  let nodes = await session.waitFor(nodes => nodes.some(n => n.identifier === 'workspace-project' && n.hittable));
  await session.command('activate', { target: nodes.find(n => n.identifier === 'workspace-project' && n.hittable).path });
  nodes = await session.waitFor(nodes => nodes.some(n => n.placeholder === 'Find a project' && n.hittable));
  await session.command('text', { target: nodes.find(n => n.placeholder === 'Find a project' && n.hittable).path, text: project.title });
  await session.waitFor(nodes => nodes.some(n => n.text === `${project.title} · ${project.scenes.length} scene${project.scenes.length === 1 ? '' : 's'}`));
  nodes = await session.waitFor(nodes => nodes.some(n => n.title === 'Open project' && n.hittable && n.enabled !== false));
  await session.command('activate', { target: nodes.find(n => n.title === 'Open project' && n.hittable && n.enabled !== false).path });
  await session.waitFor(nodes => header(nodes, project.title));
  const loaded = await session.command('loaded-project');
  assert.deepEqual(loaded.project, project, 'Browser opened the complete expected saved model');
  assert.deepEqual(await session.command('presented-alerts'), []);
  return loaded;
  // STEP browser end
}
async function presentedMessage(session) {
  // Decoder LocalizedError text varies with Foundation locale/version. Discover
  // only the public alert, then require its exact stable structure and repeats.
  const deadline = Date.now() + 15000;
  do {
    const alerts = await session.command('presented-alerts', {}, Math.max(1, deadline - Date.now()));
    if (alerts.length === 1 && typeof alerts[0].message === 'string' && alerts[0].message.length) return alerts[0].message;
    if (Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, Math.min(50, deadline - Date.now())));
  } while (Date.now() < deadline);
  throw new Error('Decoder failure did not present a nonempty public error');
}
export async function runModelDocuments(app, tests, { fresh }) {
  const roots = new Set();
  let next = 0;
  while (next < tests.length) {
    // STEP launch begin
    const session = await ScrivSession.launch(app);
    try {
      assert.equal(typeof session.root, 'string'); assert.ok(!roots.has(session.root)); roots.add(session.root);
      // STEP launch end
      // STEP setup begin
      const capabilities = await session.command('capabilities');
      for (const name of ['import-json', 'loaded-project', 'persisted-projects', 'presented-alerts', 'key', 'snapshot', 'text', 'activate']) {
        assert.ok(capabilities.commands.includes(name), `Requires ${name}`);
      }
      assert.equal(capabilities.cloudIsolation.network, 'disabled');
      await session.waitFor(nodes => header(nodes, 'YAM MAN'));
      await session.command('key', { input: 's', modifiers: ['command'] });
      const sample = await waitForSavedProject(session, p => p.title === 'YAM MAN');
      assert.deepEqual(await session.command('persisted-projects'), [sample]);
      assert.deepEqual(await session.command('presented-alerts'), []);
      // STEP setup end

      const reuse = !fresh && capabilities.commands.includes(jsonImportAcknowledgement)
        && capabilities.jsonImportAcknowledgementScope === 'owned-presentations';
      const end = reuse ? tests.length : next + 1;
      let saved = [sample];
      for (; next < end; next++) saved = await runModelDocument(session, tests[next], sample, saved, reuse);
    } finally { await session.close(); }
  }
  return roots.size;
}

async function runModelDocument(session, test, sample, priorPackages, reuse) {
  try {
    assert.deepEqual(sorted(await session.command('persisted-projects')), priorPackages);
    assert.deepEqual(await session.command('presented-alerts'), []);
    // STEP import begin
    const input = test.make(); input.title = `Model ${test.key}`;
    const start = Date.now();
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
    const finish = Date.now();
    await session.waitFor(nodes => header(nodes, input.title));
    const before = await session.command('loaded-project');
    const actual = before.project;
    assert.notEqual(actual.id, input.id); assert.match(actual.id, /^[0-9a-f-]{36}$/i);
    assert.equal(actual.revision, 0); assert.equal(Object.hasOwn(actual, 'cloudProjectId'), false);
    assert.equal(actual.createdAt, actual.modifiedAt);
    assert.ok(actual.createdAt >= start - 1 && actual.createdAt <= finish + 1, 'Import reset date lies inside the actual call window');
    assert.deepEqual(payload(actual), test.expected ? test.expected(input) : payload(input), 'Every authored field and only declared legacy defaults survive');
    assert.match(before.dateReferenceTimeBits.createdAt, /^\d+$/);
    assert.equal(before.dateReferenceTimeBits.modifiedAt, before.dateReferenceTimeBits.createdAt);
    assert.deepEqual(before.dateReferenceTimeBits.images.map(x => x.id), actual.images.map(x => x.id));
    for (const image of before.dateReferenceTimeBits.images) assert.match(image.createdAt, /^\d+$/);
    const saved = await waitForSavedProject(session, p => p.id === actual.id);
    assert.deepEqual(saved, actual);
    const packages = sorted(await session.command('persisted-projects'));
    assert.deepEqual(packages, sorted([...priorPackages, actual]), 'Only the accepted model was added and all prior project metadata is unchanged');
    assert.deepEqual(await session.command('loaded-project'), before);
    assert.deepEqual(await session.command('presented-alerts'), []);
    // STEP import end
    if (!test.mutate) {
      // STEP reopen begin
      await session.command('key', { input: 's', modifiers: ['command'] });
      assert.deepEqual(await waitForSavedProject(session, p => p.id === actual.id), actual);
      await openModelDocument(session, sample);
      assert.deepEqual(await openModelDocument(session, actual), before, 'All fields and exact Date storage bits survive real save, switch away and reopen');
      assert.deepEqual(sorted(await session.command('persisted-projects')), packages);
      assert.deepEqual(await session.command('loaded-project'), before);
      // STEP reopen end
    } else {
      // STEP reject begin
      const invalid = structuredClone(input); test.mutate(invalid);
      assert.notDeepEqual(invalid, input);
      assert.deepEqual(await session.command('import-json', { text: JSON.stringify(invalid) }), { dispatched: true, projectChanged: false });
      const message = test.error ?? await presentedMessage(session);
      assert.equal(typeof message, 'string'); assert.ok(message.length > 0);
      const observation = await observePresentedError(session, message);
      const mounted = observation.nodes.filter(n => n.identifier === 'workspace-project');
      assert.equal(mounted.length, 1); assert.equal(mounted[0].title, actual.title); assert.equal(mounted[0].hittable, false);
      assert.deepEqual(await session.command('loaded-project'), before);
      assert.deepEqual(sorted(await session.command('persisted-projects')), packages);
      await observePresentedError(session, message);
      assert.deepEqual(await session.command('loaded-project'), before, 'Rejected document leaves every loaded field and Date bit unchanged');
      assert.deepEqual(sorted(await session.command('persisted-projects')), packages, 'Repeated public reads prove no persisted project metadata mutation');
      // STEP reject end
      if (reuse) {
        await acknowledgeJSONImportError(session);
        assert.deepEqual(await session.command('loaded-project'), before, 'Acknowledgement preserves the complete loaded model and date bits');
        assert.deepEqual(sorted(await session.command('persisted-projects')), packages, 'Acknowledgement preserves every saved project');
      }
    }
    console.log(`PASS: model-document/${test.key}; public semantic import and complete model observation`);
    return packages;
  } catch (error) {
    throw new Error(`model-document/${test.key} failed`, { cause: error });
  }
}
