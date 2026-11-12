import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';

const header = (nodes, title) => nodes.find(node => node.identifier === 'workspace-project'
  && node.title === title && node.hittable);
async function activate(session, predicate) {
  const nodes = await session.waitFor(nodes => nodes.some(node => predicate(node) && node.hittable && node.enabled !== false));
  const target = nodes.find(node => predicate(node) && node.hittable && node.enabled !== false);
  await session.command('activate', { target: target.path });
}
async function openThroughBrowser(session, project) {
  await activate(session, node => node.identifier === 'workspace-project');
  const nodes = await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project' && node.hittable));
  await session.command('text', { target: nodes.find(node => node.placeholder === 'Find a project' && node.hittable).path, text: project.title });
  // Search filters the actual browser and its production reload selects the
  // first result. Require the unique title in the selected-project footer.
  await session.waitFor(nodes => nodes.some(node => node.text === `${project.title} · ${project.scenes.length} scene${project.scenes.length === 1 ? '' : 's'}`));
  await activate(session, node => node.title === 'Open project');
  await session.waitFor(nodes => !!header(nodes, project.title));
  const loaded = await session.command('loaded-project');
  assert.equal(loaded.project.id, project.id, 'Normal Open project actually changed the loaded Swift project');
  assert.deepEqual(await session.command('presented-alerts'), []);
  return loaded;
}
export async function runProjectRoundtripCase(app, test, roots) {
  const session = await ScrivSession.launch(app);
  try {
    assert.ok(!roots.has(session.root)); roots.add(session.root);
    const capabilities = await session.command('capabilities');
    for (const command of ['loaded-project', 'import-json', 'snapshot', 'text', 'activate', 'key', 'persisted-projects']) {
      assert.ok(capabilities.commands.includes(command), `Matching app supports ${command}`);
    }
    await session.waitFor(nodes => !!header(nodes, 'YAM MAN'));
    await session.command('key', { input: 's', modifiers: ['command'] });
    const other = await waitForSavedProject(session, project => project.title === 'YAM MAN');
    const input = test.makePositive();
    input.title = `Roundtrip ${randomUUID()}`;
    assert.deepEqual(await session.command('import-json', { text: test.serializePositive(input) }),
      { dispatched: true, projectChanged: true });
    await session.waitFor(nodes => !!header(nodes, input.title));
    const baseline = await session.command('loaded-project');
    const before = baseline.project;
    assert.match(baseline.dateReferenceTimeBits.createdAt, /^\d+$/);
    assert.match(baseline.dateReferenceTimeBits.modifiedAt, /^\d+$/);
    assert.deepEqual(baseline.dateReferenceTimeBits.images, [], 'Chosen frozen fixtures have no nested image dates');
    assert.ok(Object.hasOwn(before, 'createdAt') && Object.hasOwn(before, 'modifiedAt') && Object.hasOwn(before, 'revision'));
    assert.equal(Object.hasOwn(before, 'cloudProjectId'), false, 'Actual nil cloud identity is part of the full baseline');
    assert.notEqual(before.id, input.id, 'Import identity reset precedes, never weakens, the full-model baseline');
    test.verifyPositive(before, input);
    await assert.rejects(session.command('loaded-project', { path: 'not-an-accepted-parameter' }),
      /Synthetic loaded-project observation is unavailable or invalid/);
    assert.deepEqual(await session.command('loaded-project'), baseline, 'Observer is read-only');
    // Real Save, followed by actual UI navigation. No direct load/decoder/test
    // save route is invoked. Switching projects flushes production pending saves.
    await session.command('key', { input: 's', modifiers: ['command'] });
    const saved = await waitForSavedProject(session, project => project.id === before.id);
    assert.deepEqual(saved, before, 'Every encoded Swift field reaches the saved package');
    assert.deepEqual((await openThroughBrowser(session, other)).project, other, 'Different project really loaded');
    const after = await openThroughBrowser(session, before);
    assert.deepEqual(after, baseline, 'Complete loaded model survives real save/reopen: no field filtering, envelope reset or normalization');
    assert.deepEqual(await session.command('loaded-project'), baseline);
    assert.equal((await session.command('persisted-projects')).length, 2);
    console.log(`PASS: IJ-02/${test.key}: ${test.id}; complete loaded-project save/browser-reopen equality`);
  } catch (error) {
    throw new Error(`IJ-02/${test.key}: ${test.id}: actual loaded-project roundtrip failed`, { cause: error });
  } finally { await session.close(); }
}
