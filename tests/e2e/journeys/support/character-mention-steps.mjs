import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { scriptAuthoringSteps, byID, readyTabs, focusedEditors, keyIs } from './script-authoring-steps.mjs';
import { mentionCases, mentionInput, auditMentionFixtures } from './character-mention-cases.mjs';

const header = (nodes, title) => byID(nodes, 'workspace-project').some(node => node.title === title && node.hittable);
const ordered = projects => [...projects].sort((a, b) => a.id.localeCompare(b.id));
const targetEntry = project => {
  const matches = project.entries.filter(entry => entry.id === 'mention-line');
  assert.equal(matches.length, 1, 'Exactly one imported source row is the edit target');
  return matches[0];
};
const importPayload = project => {
  const value = structuredClone(project);
  for (const key of ['id', 'createdAt', 'modifiedAt', 'revision']) delete value[key];
  return value;
};

// Full loaded and saved annotations are already available. Nothing here calls
// CharacterMentions, writes the store/package, or synthesizes an app result.
export async function runMentionDetection(session) {
  auditMentionFixtures();
  const step = scriptAuthoringSteps(session);
  const capabilities = await session.command('capabilities');
  for (const command of ['snapshot', 'activate', 'select', 'scroll', 'selection', 'type', 'text',
    'keys', 'key', 'import-json', 'loaded-project', 'persisted-projects', 'presented-alerts']) {
    assert.ok(capabilities.commands.includes(command), `Matching actual app advertises ${command}`);
  }
  await session.waitFor(readyTabs);
  await step.selectTab('Script');
  await step.workspaceCommand('s');
  const startup = await step.saved(project => project.title === 'YAM MAN');
  assert.deepEqual(await session.command('persisted-projects'), [startup], 'This fresh run owns only its synthetic startup package');
  assert.deepEqual((await session.command('loaded-project')).project, startup);

  async function activateMatching(predicate) {
    let nodes = await session.waitFor(nodes => nodes.filter(predicate).length === 1);
    await step.reveal(nodes.find(predicate), nodes);
    nodes = await session.waitFor(nodes => nodes.filter(predicate).length === 1
      && nodes.find(predicate).hittable && nodes.find(predicate).enabled === true);
    assert.deepEqual(await session.command('activate', { target: nodes.find(predicate).path }), { dispatched: true });
  }
  async function openSaved(project) {
    await activateMatching(node => node.identifier === 'workspace-project');
    const nodes = await session.waitFor(nodes => nodes.filter(node => node.placeholder === 'Find a project'
      && node.enabled && node.hittable).length === 1);
    const search = nodes.find(node => node.placeholder === 'Find a project' && node.enabled && node.hittable);
    await session.command('text', { target: search.path, text: project.title });
    const subtitle = `${project.title} · ${project.scenes.length} scene${project.scenes.length === 1 ? '' : 's'}`;
    await session.waitFor(nodes => nodes.some(node => node.text === subtitle));
    await activateMatching(node => node.title === 'Open project');
    await session.waitFor(nodes => header(nodes, project.title));
    const loaded = await session.command('loaded-project');
    assert.equal(loaded.project.id, project.id, 'Real browser Open loads the requested project identity');
    assert.deepEqual(await session.command('presented-alerts'), []);
    return loaded;
  }
  async function unchangedOthers(others, currentID) {
    const saved = await session.command('persisted-projects');
    assert.equal(saved.length, others.length + 1, 'Exactly one synthetic package is added by this import');
    assert.deepEqual(ordered(saved.filter(project => project.id !== currentID)), ordered(others),
      'Every other complete saved project is unchanged');
  }

  for (const test of mentionCases) {
    try {
      const others = await session.command('persisted-projects');
      const input = mentionInput(test);
      input.title = `Mentions ${test.key} ${randomUUID()}`;
      assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }),
        { dispatched: true, projectChanged: true });
      await session.waitFor(nodes => header(nodes, input.title));
      await step.selectTab('Script');
      const before = await step.saved(project => project.title === input.title && !others.some(value => value.id === project.id));
      assert.notEqual(before.id, input.id, 'Production import assigns local document identity');
      assert.equal(before.revision, 0);
      assert.equal(Object.hasOwn(before, 'cloudProjectId'), false);
      assert.deepEqual(importPayload(before), importPayload(input),
        'Import preserves all literal profile values/order, source rows and explicit empty annotation arrays');
      const beforeWitness = await session.command('loaded-project');
      assert.deepEqual(beforeWitness.project, before);
      for (const key of ['createdAt', 'modifiedAt']) assert.match(beforeWitness.dateReferenceTimeBits[key], /^\d+$/);
      assert.deepEqual(beforeWitness.dateReferenceTimeBits.images, []);
      await unchangedOthers(others, before.id);

      // Import selects its first source row. Use the installed edit-toggle key,
      // then the mounted UITextView's selection and public insertText route.
      await step.displayed('mention-line', 'Draft.');
      assert.ok((await session.command('keys')).some(command => keyIs(command, '\r', ['command'])),
        'The actual selected row has its enabled Command-Return edit toggle');
      assert.deepEqual(await step.key('\r', ['command']), { dispatched: true });
      const editorID = 'script-editor-mention-line';
      let nodes = await session.waitFor(nodes => focusedEditors(nodes).length === 1
        && focusedEditors(nodes)[0].identifier === editorID && focusedEditors(nodes)[0].text === 'Draft.');
      await step.reveal(focusedEditors(nodes)[0], nodes);
      nodes = await session.waitFor(nodes => byID(nodes, editorID).some(node => node.firstResponder && node.hittable && node.editable));
      assert.equal(byID(nodes, editorID)[0].smartInsertDeleteDisabled, true,
        'The actual editor disables smart text insertion before exact source replacement');
      await session.command('selection', { target: editorID, start: 0, end: 'Draft.'.length });
      await step.waitEditor(editorID, 'Draft.', 0, 'Draft.'.length);
      assert.deepEqual(await session.command('loaded-project'), beforeWitness,
        'Opening/focusing/selecting the native editor does not mutate the complete model or Date bits');
      assert.deepEqual(ordered(await session.command('persisted-projects')), ordered([...others, before]),
        'Opening/focusing/selecting leaves every saved project unchanged');
      // One dispatch only. A timeout or uncertain outcome fails; never retry it.
      // insertText does not establish shouldChangeText callback multiplicity.
      // Observe accepted source/model results, not an invented delegate count.
      assert.deepEqual(await session.command('type', { target: editorID, text: test.text }), { dispatched: true });
      await step.waitEditor(editorID, test.text, test.text.length);
      await step.finishEditor();
      await step.displayed('mention-line', test.text, { finished: true });
      await step.workspaceCommand('s');
      const after = await step.saved(project => project.id === before.id && targetEntry(project).text === test.text);
      const afterWitness = await session.command('loaded-project');
      assert.deepEqual(afterWitness.project, after, 'Every saved field equals the actual accepted Swift model');
      assert.equal(afterWitness.dateReferenceTimeBits.createdAt, beforeWitness.dateReferenceTimeBits.createdAt);
      assert.match(afterWitness.dateReferenceTimeBits.modifiedAt, /^\d+$/);
      assert.deepEqual(afterWitness.dateReferenceTimeBits.images, []);

      const links = targetEntry(after).characterLinks;
      assert.ok(Array.isArray(links), 'Accepted editing materializes the complete suggestion array, including no-match []');
      assert.equal(links.length, test.expectedLinks.length, 'There are no extra or missing suggestions');
      const ids = new Set();
      for (let index = 0; index < links.length; index++) {
        const link = links[index];
        assert.match(link.id, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
          'New suggested annotation has an actual generated UUID identity');
        assert.equal(ids.has(link.id), false, 'Every proposed occurrence has a distinct identity');
        ids.add(link.id);
        assert.deepEqual(link, { id: link.id, ...test.expectedLinks[index] },
          'Complete ordered annotation has the exact literal identity/range/text/unconfirmed metadata and no hidden fields');
        assert.equal(test.text.slice(link.location, link.location + link.length), link.text,
          'Each literal UTF-16 range extracts the exact unmodified authored source');
      }
      const expected = { ...before, revision: before.revision + 1, modifiedAt: after.modifiedAt,
        entries: before.entries.map(entry => entry.id === 'mention-line'
          ? { ...entry, text: test.text, characterLinks: links } : entry) };
      assert.equal(typeof after.modifiedAt, 'number');
      assert.ok(Number.isFinite(after.modifiedAt) && after.modifiedAt >= before.modifiedAt);
      assert.deepEqual(after, expected,
        'Exactly one source-text edit changes only target text/annotations and its revision/save date; all other fields remain exact');
      assert.deepEqual(await session.command('presented-alerts'), []);

      // Leave the document and use ordinary browser Open. This must preserve
      // complete links, including app-generated IDs, not re-run the matcher.
      assert.deepEqual((await openSaved(startup)).project, startup);
      assert.deepEqual(await openSaved(after), afterWitness,
        'Save and real browser reopen preserve the entire model and exact Date storage witnesses');
      assert.deepEqual((await step.saved(project => project.id === after.id)), after);
      await unchangedOthers(others, after.id);
      console.log(`PASS: AUT-J06/mention-detection/${test.key}`);
    } catch (error) {
      throw new Error(`AUT-J06/mention-detection/${test.key} failed without retrying the mutation`, { cause: error });
    }
  }
}
