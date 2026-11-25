import assert from 'node:assert/strict';
import { scriptAuthoringSteps, byID } from './script-authoring-steps.mjs';
import { structureFixture } from './script-structure-cases.mjs';
import { observePresentedAlert } from '../../support/presented-error.mjs';

const sorted = projects => [...projects].sort((a, b) => a.id.localeCompare(b.id));

export async function observeOwnedDurationDialog(session) {
  const { commands } = await session.command('capabilities');
  for (const command of ['activate', 'import-json', 'snapshot', 'text', 'presented-alerts', 'loaded-project', 'persisted-projects']) {
    assert.ok(commands.includes(command), `Matching app provides ${command}`);
  }
  const step = scriptAuthoringSteps(session);
  const startup = await step.openScript(), fixture = structureFixture();
  assert.deepEqual(await session.command('import-json', { text: JSON.stringify(fixture) }),
    { dispatched: true, projectChanged: true });
  await step.selectTab('Script');
  const saved = await step.saved(project => project.title === fixture.title && project.id !== startup.id);
  assert.deepEqual(saved, { ...fixture, id: saved.id, createdAt: saved.createdAt, modifiedAt: saved.modifiedAt });
  const loaded = await session.command('loaded-project');
  const packages = sorted([startup, saved]);
  assert.deepEqual(loaded.project, saved);
  assert.deepEqual(sorted(await session.command('persisted-projects')), packages);
  assert.deepEqual(await session.command('presented-alerts'), []);

  const entryID = fixture.entries[0].id;
  const durationButtons = nodes => {
    const matches = byID(nodes, `script-line-${entryID}`);
    if (matches.length !== 1) return [];
    const [line] = matches;
    const row = nodes.find(node => /ScriptEntryRow$/.test(node.type) && line.path.startsWith(node.path + '.'));
    return row ? nodes.filter(node => node.path.startsWith(row.path + '.') && node.label === 'Edit owned duration'
      && /UIButton$/.test(node.type) && node.enabled && node.hittable) : [];
  };
  const nodes = await session.waitFor(nodes => durationButtons(nodes).length === 1);
  const [button] = durationButtons(nodes);
  assert.deepEqual(await session.command('activate', { target: button.path }), { dispatched: true });
  const dialog = {
    title: 'Owned duration',
    message: 'Adds time to this direction’s action slot. Coverage remains a separate source-owned extent.',
    actions: [{ title: 'Cancel', enabled: true, style: 'cancel' }, { title: 'Apply', enabled: true, style: 'default' }],
  };
  function secondsField(nodes) {
    const fields = nodes.filter(node => node.placeholder === 'Seconds'
      && /TextField$/.test(node.type) && node.enabled && node.hittable);
    assert.equal(fields.length, 1, 'The attached dialog exposes one editable Seconds field');
    return fields[0];
  }
  const initial = secondsField((await observePresentedAlert(session, dialog)).nodes);
  assert.equal(initial.text, '0.000', 'The dialog shows the selected direction’s saved owned duration');
  assert.deepEqual(await session.command('text', { target: initial.path, text: '1.25' }), { dispatched: true });
  const draft = secondsField((await observePresentedAlert(session, dialog)).nodes);
  assert.equal(draft.text, '1.25');
  assert.deepEqual(await session.command('loaded-project'), loaded, 'The pending duration draft preserves the exact loaded model');
  assert.deepEqual(sorted(await session.command('persisted-projects')), packages, 'The pending draft preserves both packages');
}
