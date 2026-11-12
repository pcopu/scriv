import assert from 'node:assert/strict';
import { waitForSavedProject } from '../../support/saved-projects.mjs';

const byID = projects => [...projects].sort((a, b) => a.id.localeCompare(b.id));

// Shared observations only. All mutations use the actual app's semantic
// production importer/exporter; no model setter, parser or validator lives here.
export function fountainSteps(session) {
  const saved = () => session.command('persisted-projects');
  const visible = project => session.waitFor(nodes => nodes.some(node =>
    node.identifier === 'workspace-project' && node.title === project.title
    && node.label === project.title + ', Projects' && node.hittable));
  async function unchanged(before) {
    assert.deepEqual(byID(await saved()), byID(before), 'All saved projects remain unchanged');
  }
  async function importText(text, options = {}) {
    const before = await saved();
    const known = new Set(before.map(project => project.id));
    assert.deepEqual(await session.command('import-fountain', { text, ...options }),
      { dispatched: true, projectChanged: true });
    const project = await waitForSavedProject(session, candidate => !known.has(candidate.id));
    assert.ok(!known.has(project.id), 'Accepted import has a distinct identity');
    const after = await saved();
    assert.equal(after.length, before.length + 1, 'Exactly one package per accepted import');
    assert.deepEqual(byID(after.filter(candidate => known.has(candidate.id))), byID(before),
      'Every previous saved project survives the import unchanged');
    await visible(project);
    return project;
  }
  async function exportText(project) {
    const before = await saved();
    const result = await session.command('export-fountain');
    assert.deepEqual(Object.keys(result).sort(), ['byteCount', 'cleanupVerified', 'dispatched', 'text']);
    assert.equal(result.dispatched, true);
    assert.equal(typeof result.text, 'string');
    assert.equal(result.byteCount, Buffer.byteLength(result.text, 'utf8'));
    assert.ok(result.byteCount > 0 && result.byteCount <= 64 * 1024, 'Captured UTF-8 output is bounded');
    assert.equal(result.cleanupVerified, true, 'Production cleanup removed its own temporary export directory');
    await unchanged(before);
    await visible(project);
    return result.text;
  }
  async function reject(command, request) {
    const before = await saved();
    await assert.rejects(session.command(command, request), new RegExp(`${command}:`));
    // Preserve the original rejection oracle's ordering as well as contents.
    assert.deepEqual(await saved(), before, 'Rejected request does not create or alter a saved project');
  }
  return { saved, visible, unchanged, importText, exportText, reject };
}
