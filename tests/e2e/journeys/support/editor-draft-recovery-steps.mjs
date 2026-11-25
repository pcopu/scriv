import assert from 'node:assert/strict';
import { join } from 'node:path';
import { scriptAuthoringSteps } from './script-authoring-steps.mjs';

// All draft bytes are read-only observations of this run's owned native workspace.
// A real accepted text edit plus canonical history refusal retains the journal.
export async function editorDraftRecoverySteps({ getSession, root, baseline, tree,
  activate, cold, normalOpen, refuseHistory, restore, saveFailureAlert }) {
  const entry = baseline.entries.find(value => value.id === 'mara-line');
  assert.ok(entry); const text = entry.text + '  ';
  const target = `script-editor-${entry.id}`;
  async function journal() {
    const files = await tree(join(root, 'EditorDrafts'));
    return Object.entries(files).filter(([name]) => name.endsWith('.json')).map(([name, bytes]) => {
      assert.match(name, /^[0-9a-f]{64}\.json$/);
      return { name, bytes, record: JSON.parse(Buffer.from(bytes, 'base64').toString('utf8')) };
    });
  }
  async function edit() {
    const session = getSession(), step = scriptAuthoringSteps(session);
    await step.selectTab('Script');
    const nodes = await session.waitFor(nodes => nodes.some(n => n.identifier === `script-line-${entry.id}`));
    const line = nodes.find(n => n.identifier === `script-line-${entry.id}`);
    await step.reveal(line, nodes);
    await session.command('key', { input: '\r', modifiers: ['command'] });
    await session.waitFor(nodes => nodes.some(n => n.identifier === target && n.firstResponder) || nodes.some(n => n.title === 'Apply reviewed draft') && nodes.some(n => n.title === 'Keep for later' && n.hittable && n.enabled === true));
  }
  await edit();
  assert.deepEqual(await journal(), [], 'Beginning an unchanged line creates no draft JSON');
  const packagesBefore = await tree(join(root, 'Projects'));
  await refuseHistory();
  await getSession().command('text', { target, text });
  const alert = await saveFailureAlert(baseline.title);
  const loaded = (await getSession().command('loaded-project')).project;
  const expected = structuredClone(baseline);
  expected.entries.find(value => value.id === entry.id).text = text;
  expected.entries.find(value => value.id === entry.id).characterLinks = [];
  expected.revision += 1; expected.modifiedAt = loaded.modifiedAt;
  assert.ok(Number.isFinite(loaded.modifiedAt) && loaded.modifiedAt >= baseline.modifiedAt);
  assert.deepEqual(loaded, expected, 'Whitespace preserves every word identity, time and unrelated model field');
  assert.deepEqual(await tree(join(root, 'Projects')), packagesBefore);
  const retained = await journal(); assert.equal(retained.length, 1);
  const draft = retained[0].record;
  assert.match(draft.revisionID, /^[0-9a-f-]{36}$/i);
  assert.ok(Number.isFinite(draft.updatedAt));
  assert.deepEqual(draft, {
    schemaVersion: 1, revisionID: draft.revisionID,
    scope: { packagePath: join(root, 'Projects', baseline.id + '.scriv'), projectID: baseline.id,
      server: 'http://127.0.0.1:1', entryID: entry.id },
    sourceRevision: baseline.revision, sourceEntry: entry, text,
    edits: [{ location: 0, length: entry.text.length, replacement: text }], updatedAt: draft.updatedAt,
  }, 'Full journal schema, original source, exact UTF-16 replacement and scope');
  assert.equal(typeof draft.scope.server, 'string'); assert.ok(draft.scope.server.length > 0);
  await restore();
  assert.deepEqual(await getSession().command('presented-alerts'), [alert]);
  await cold();
  assert.deepEqual(await journal(), retained, 'Cold restart retains exact native-produced journal bytes');
  assert.deepEqual(await tree(join(root, 'Projects')), packagesBefore);
  await normalOpen(expected);
  assert.deepEqual(await journal(), retained, 'Canonical accepted-save replay does not clear editor recovery');
  await edit();
  await getSession().waitFor(nodes => nodes.some(n => n.title === 'Apply reviewed draft') && nodes.some(n => n.title === 'Keep for later' && n.hittable && n.enabled === true));
  let nodes = await getSession().command('snapshot');
  assert.equal(nodes.find(n => n.title === 'Apply reviewed draft').enabled, false, 'Original recovery base must be reviewed before apply');
  const recoveredText = label => nodes.find(n => n.type === 'ScriptTextView' && n.label === label)?.text;
  assert.equal(recoveredText('Current saved line'), text);
  assert.equal(recoveredText('Your local draft'), text);
  await activate(n => n.title === 'Keep for later');
  await getSession().waitFor(nodes => !nodes.some(n => n.title === 'Apply reviewed draft')
    && nodes.some(n => n.identifier === 'workspace-tabs' && n.hittable));
  assert.deepEqual((await getSession().command('loaded-project')).project, expected);
  assert.deepEqual(await journal(), retained, 'Keeping recovery preserves its exact record');
  await edit();
  await getSession().waitFor(nodes => nodes.some(n => n.title === 'Apply reviewed draft') && nodes.some(n => n.title === 'Keep for later' && n.hittable && n.enabled === true));
  await activate(n => n.title === 'Use current saved line as base');
  await getSession().waitFor(nodes => nodes.some(n => n.title === 'Apply reviewed draft' && n.enabled === true && n.hittable));
  const rebased = await journal(); assert.equal(rebased.length, 1);
  const rebasedDraft = rebased[0].record;
  assert.notEqual(rebasedDraft.revisionID, draft.revisionID);
  assert.ok(Number.isFinite(rebasedDraft.updatedAt) && rebasedDraft.updatedAt >= draft.updatedAt);
  assert.deepEqual(rebasedDraft, { ...draft, revisionID: rebasedDraft.revisionID,
    updatedAt: rebasedDraft.updatedAt, sourceRevision: expected.revision,
    sourceEntry: expected.entries.find(value => value.id === entry.id),
    edits: [{ location: 0, length: text.length, replacement: text }] });
  const packagesApplied = await tree(join(root, 'Projects'));
  await activate(n => n.title === 'Apply reviewed draft');
  const deadline = Date.now() + 15000;
  while ((await journal()).length && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 50));
  assert.deepEqual(await journal(), [], 'Successful reviewed canonical save acknowledges exact journal revision');
  await getSession().waitFor(nodes => !nodes.some(n => n.title === 'Apply reviewed draft')
    && nodes.some(n => n.identifier === 'workspace-tabs' && n.hittable));
  assert.deepEqual((await getSession().command('loaded-project')).project, expected);
  assert.deepEqual(await tree(join(root, 'Projects')), packagesApplied, 'Matching recovered text adds no revision or history');
  await cold(); await normalOpen(expected);
  assert.deepEqual(await journal(), []);
  await edit();
  nodes = await getSession().command('snapshot');
  assert.ok(!nodes.some(n => n.title === 'Apply reviewed draft'));
  assert.deepEqual((await getSession().command('loaded-project')).project, expected);
}
