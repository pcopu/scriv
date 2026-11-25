import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readdir, readFile, symlink, unlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { audioProjectFixture, syntheticPCM } from './audio-library-fixtures.mjs';

async function packageFiles(root, prefix = '') {
  const files = [];
  for (const entry of await readdir(join(root, prefix), { withFileTypes: true })) {
    const path = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory()) {
      files.push(...await packageFiles(root, path));
      continue;
    }
    assert.ok(entry.isFile(), `Expected an owned regular package member: ${path}`);
    const bytes = await readFile(join(root, path));
    files.push({ path, byteCount: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') });
  }
  return files.sort((a, b) => a.path < b.path ? -1 : Number(a.path !== b.path));
}

export async function verifyPackageExport(session, step) {
  const originalIDs = new Set((await step.saved()).map(project => project.id));
  const fixture = audioProjectFixture();
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(fixture) }), { dispatched: true, projectChanged: true });
  const imported = await waitForSavedProject(session, project => !originalIDs.has(project.id));
  await step.visible(imported);
  assert.deepEqual(await session.command('import-local-image', { fixture: 'coral' }),
    { dispatched: true, imported: true, cleanupVerified: true });
  assert.deepEqual(await session.command('import-audio', { base64: syntheticPCM().toString('base64'), attachment: 'scene' }),
    { dispatched: true, imported: true, cleanupVerified: true });
  const project = await waitForSavedProject(session, saved => saved.id === imported.id && saved.images.length === 1 && saved.audioAssets.length === 1);
  assert.deepEqual((await session.command('loaded-project')).project, project);
  assert.match(project.id, /^[0-9a-f-]{36}$/i);
  const packageRoot = join(session.root, 'Projects', `${project.id}.scriv`);
  const before = await step.saved();
  const expected = await packageFiles(packageRoot);
  assert.ok(expected.some(file => file.path === 'project.json'));
  assert.ok(expected.filter(file => file.path.startsWith('history/')).length >= 3);
  for (const [directory, asset] of [['assets', project.images[0]], ['audio', project.audioAssets[0]]]) {
    assert.deepEqual(expected.find(file => file.path === `${directory}/${asset.fileName}`), {
      path: `${directory}/${asset.fileName}`, byteCount: asset.byteCount, sha256: asset.sha256,
    });
  }
  const temporaryExports = async () => (await readdir(session.root)).filter(name => name.startsWith('ScrivExport-'));
  const result = { dispatched: true, cleanupVerified: true, files: expected };
  await assert.rejects(session.command('export-project', { path: '/synthetic-not-an-export-destination' }), /Synthetic project export is unavailable or invalid/);
  assert.deepEqual(await temporaryExports(), []);
  assert.deepEqual(await session.command('export-project'), result);

  const alias = join(packageRoot, 'synthetic-export-refusal');
  await symlink('nonexistent-synthetic-member', alias);
  try {
    await assert.rejects(session.command('export-project'), /Synthetic project export is unavailable or invalid/);
    assert.deepEqual(await temporaryExports(), [], 'Copy refusal leaves no staged package');
  } finally { await unlink(alias); }

  assert.deepEqual(await session.command('export-project'), result, 'The same saved package exports after the owned fixture is removed');
  assert.deepEqual(await temporaryExports(), []);
  assert.deepEqual(await packageFiles(packageRoot), expected);
  assert.deepEqual(await step.saved(), before);
  assert.deepEqual((await session.command('loaded-project')).project, project);
  assert.deepEqual(await session.command('presented-alerts'), []);

  // Simulate a different valid snapshot appearing on disk in the owned fixture.
  const metadata = join(packageRoot, 'project.json');
  const original = await readFile(metadata);
  const changed = Buffer.from(JSON.stringify({ ...JSON.parse(original), title: 'Synthetic different saved snapshot' }));
  await writeFile(metadata, changed);
  try {
    await assert.rejects(session.command('export-project'), /Synthetic project export is unavailable or invalid/);
    assert.deepEqual(await readFile(metadata), changed, 'Export refusal preserves the other saved snapshot');
    assert.deepEqual((await session.command('loaded-project')).project, project, 'Export refusal preserves the loaded project');
    assert.deepEqual(await temporaryExports(), []);
  } finally { await writeFile(metadata, original); }
  assert.deepEqual(await session.command('export-project'), result);
  assert.deepEqual(await step.saved(), before);
}

async function nativeExportControl(session) {
  await session.command('key', { input: ',', modifiers: ['command'] });
  const isExport = node => node.type === 'UIButton' && node.title === 'Export project…' && node.enabled && node.hittable;
  const nodes = await session.waitForUnique(isExport);
  return nodes.find(isExport);
}

export async function verifyNativeExportRefusal(session) {
  const original = await session.command('loaded-project');
  const { id } = original.project;
  assert.match(id, /^[0-9a-f-]{36}$/i);
  const metadata = join(session.root, 'Projects', `${id}.scriv`, 'project.json');
  const bytes = await readFile(metadata);
  const replacement = Buffer.from(JSON.stringify({ ...JSON.parse(bytes), title: 'Different owned snapshot' }));

  const control = await nativeExportControl(session);
  await writeFile(metadata, replacement);
  try {
    assert.deepEqual(await session.command('activate', { target: control.path }), { dispatched: true });
    const message = 'Scriv could not confirm the latest project on disk. Finish saving before trying again.';
    let alert;
    for (let i = 0; i < 80 && !alert; i++) {
      alert = (await session.command('presented-alerts')).find(item => item.message === message
        && item.viewAttachedToWindow && !item.beingPresented && !item.beingDismissed);
      if (!alert) await new Promise(resolve => setTimeout(resolve, 50));
    }
    assert.ok(alert, 'The Settings action reports its actual export refusal');
    assert.deepEqual(alert.actions, [{ title: 'OK', enabled: true, style: 'default' }]);
    assert.deepEqual(await readFile(metadata), replacement, 'Export preserves the other saved snapshot');
    assert.deepEqual(await session.command('loaded-project'), original);
  } finally {
    await writeFile(metadata, bytes);
  }
}
