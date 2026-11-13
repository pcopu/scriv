import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { identityReviewInput } from './text-identity-review-fixtures.mjs';
import { scriptAuthoringSteps, byID, readyTabs, focusedEditors, keyIs } from './script-authoring-steps.mjs';

// Direction entries isolate exact annotation identity from dialogue retiming.
const cases = [
  { id: 'review-confirm-unlink-unicode', source: 'Randy waits.', unlink: true,
    edit: { start: 0, end: 0, text: '👩‍💻 e\u0301 ' }, result: '👩‍💻 e\u0301 Randy waits.',
    links: [{ id: 'identity-proposal', location: 9, length: 5, text: 'Randy', isConfirmed: true }] },
  { id: 'delete-first-duplicate-keeps-second', source: 'Randy Randy waits.', duplicate: true,
    edit: { start: 0, end: 6, delete: true }, result: 'Randy waits.',
    links: [{ id: 'identity-second', characterId: 'randy', location: 0, length: 5, text: 'Randy', isConfirmed: true }] },
  { id: 'numeric-boundary-revokes', source: 'Randy waits.',
    edit: { start: 5, end: 5, text: '2' }, result: 'Randy2 waits.', links: [] },
  { id: 'underscore-boundary-revokes', source: 'Randy waits.',
    edit: { start: 0, end: 0, text: '_' }, result: '_Randy waits.', links: [] },
];
for (const test of cases) {
  const { start, end, text = '' } = test.edit;
  assert.equal(test.source.slice(0, start) + text + test.source.slice(end), test.result);
  for (const link of test.links) {
    assert.equal(test.result.slice(link.location, link.location + link.length), link.text);
  }
}
export const identityBoundaryCatalog = cases.map(test => ({ group: 'identity-boundaries', id: test.id,
  journey: 'AUT-J06', nativeVerified: false, retirementAllowed: false,
  oracles: ['exact UTF-16 selection and native callback count', 'complete independently expected saved and loaded model',
    'stable annotation IDs and explicit unlink survive only permitted edits'] }));

export async function runIdentityBoundaries(session) {
  const step = scriptAuthoringSteps(session);
  const capabilities = await session.command('capabilities');
  for (const name of ['script-insert', 'script-delete-selection', 'script-interaction-counts', 'loaded-project', 'persisted-projects']) {
    assert.ok(capabilities.commands.includes(name));
  }
  await session.waitFor(readyTabs);
  await step.selectTab('Script');
  await step.workspaceCommand('s');
  const startup = await step.saved(project => project.title === 'YAM MAN');
  assert.deepEqual(await session.command('persisted-projects'), [startup]);
  const ordered = projects => [...projects].sort((a, b) => a.id.localeCompare(b.id));
  const sourceNodes = nodes => nodes.filter(node => node.label === 'Source line, unchanged');
  async function button(title) {
    const predicate = node => /Button$/.test(node.type) && node.title === title;
    let nodes = await session.waitFor(nodes => nodes.filter(predicate).length === 1);
    await step.reveal(nodes.find(predicate), nodes);
    nodes = await session.waitFor(nodes => nodes.filter(predicate).length === 1
      && nodes.find(predicate).enabled && nodes.find(predicate).hittable);
    assert.deepEqual(await session.command('activate', { target: nodes.find(predicate).path }), { dispatched: true });
  }
  for (const test of cases) {
    const others = await session.command('persisted-projects');
    const input = identityReviewInput({ source: test.source, location: 0 });
    input.title = `Identity boundary ${test.id} ${randomUUID()}`;
    Object.assign(input.entries[0], { kind: 'direction', words: [], coverageDurationMs: 3000 });
    if (test.duplicate) input.entries[0].characterLinks.push({ id: 'identity-second', characterId: 'randy',
      location: 6, length: 5, text: 'Randy', isConfirmed: true });
    const stablePayload = project => {
      const result = structuredClone(project);
      for (const key of ['id', 'createdAt', 'modifiedAt', 'revision']) delete result[key];
      return result;
    };
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
    const before = await step.saved(project => project.title === input.title);
    assert.notEqual(before.id, input.id);
    assert.equal(before.revision, 0);
    assert.deepEqual(stablePayload(before), stablePayload(input));
    const initialWitness = await session.command('loaded-project');
    assert.deepEqual(initialWitness.project, before);
    await step.selectTab('Script');
    await step.displayed('identity-line', test.source, { finished: true });
    await button('Review 1 character suggestion');
    await session.waitFor(nodes => sourceNodes(nodes).length === 1);
    await button('Confirm');
    await session.waitFor(nodes => !nodes.some(node => /Button$/.test(node.type) && node.title === 'Confirm'));
    if (test.unlink) {
      await button('Unlink');
      await session.waitFor(nodes => nodes.some(node => node.text === 'Kept unlinked'));
      // Rescanning must respect the explicitly excluded range in this draft.
      await button('Find more name suggestions');
      await session.waitFor(nodes => nodes.some(node => node.text === 'Kept unlinked')
        && !nodes.some(node => /Button$/.test(node.type) && node.title === 'Confirm'));
    }
    const reviewNodes = await session.command('snapshot');
    assert.equal(sourceNodes(reviewNodes)[0].text, test.source);
    assert.equal(sourceNodes(reviewNodes)[0].editable, false);
    assert.deepEqual(ordered(await session.command('persisted-projects')), ordered([...others, before]));
    await button('Save links');
    await session.waitFor(nodes => sourceNodes(nodes).length === 0 && readyTabs(nodes));
    await step.workspaceCommand('s');
    const reviewed = await step.saved(project => project.id === before.id && project.revision === before.revision + 1);
    const reviewedLinks = structuredClone(input.entries[0].characterLinks);
    reviewedLinks[0].isConfirmed = true;
    if (test.unlink) delete reviewedLinks[0].characterId;
    const reviewedExpected = { ...before, revision: before.revision + 1, modifiedAt: reviewed.modifiedAt,
      entries: before.entries.map(entry => entry.id === 'identity-line' ? { ...entry, characterLinks: reviewedLinks } : entry) };
    assert.ok(Number.isFinite(reviewed.modifiedAt) && reviewed.modifiedAt >= before.modifiedAt);
    assert.deepEqual(reviewed, reviewedExpected);
    assert.deepEqual((await session.command('loaded-project')).project, reviewedExpected);

    assert.ok((await session.command('keys')).some(command => keyIs(command, '\r', ['command'])));
    assert.deepEqual(await step.key('\r', ['command']), { dispatched: true });
    const id = 'script-editor-identity-line';
    let nodes = await session.waitFor(nodes => focusedEditors(nodes).length === 1
      && byID(nodes, id).some(node => node.firstResponder && node.text === test.source));
    await step.reveal(byID(nodes, id)[0], nodes);
    await session.command('selection', { target: id, start: test.edit.start, end: test.edit.end });
    await step.waitEditor(id, test.source, test.edit.start, test.edit.end);
    const countsBefore = await session.command('script-interaction-counts');
    const response = await session.command(test.edit.delete ? 'script-delete-selection' : 'script-insert',
      { target: id, ...(test.edit.delete ? {} : { text: test.edit.text }) });
    assert.deepEqual(response, test.edit.delete
      ? { dispatched: true, delegateAcceptedDeletion: true, coverage: 'public-script-selection-deletion-delegate-contract' }
      : { dispatched: true, delegateAcceptedInsertion: true, coverage: 'public-script-insertion-delegate-contract' });
    const countsAfter = await session.command('script-interaction-counts');
    assert.equal(countsAfter.onTextEditInvocations - countsBefore.onTextEditInvocations, 1);
    assert.equal(countsAfter.mergeAtStartInvocations - countsBefore.mergeAtStartInvocations, 0);
    await step.waitEditor(id, test.result, test.edit.start + (test.edit.text?.length ?? 0));
    await step.finishEditor();
    await step.displayed('identity-line', test.result, { finished: true });
    await step.workspaceCommand('s');
    const after = await step.saved(project => project.id === before.id && project.entries[0].text === test.result);
    assert.equal(after.revision, reviewed.revision + 1);
    assert.ok(Number.isFinite(after.modifiedAt) && after.modifiedAt >= reviewed.modifiedAt);
    const expected = { ...reviewedExpected, revision: reviewed.revision + 1, modifiedAt: after.modifiedAt,
      entries: reviewedExpected.entries.map(entry => entry.id === 'identity-line'
        ? { ...entry, text: test.result, characterLinks: test.links } : entry) };
    assert.deepEqual(after, expected, 'Every field including independent literal annotation IDs/ranges/wording is exact');
    const witness = await session.command('loaded-project');
    assert.deepEqual(witness.project, expected);
    assert.equal(witness.dateReferenceTimeBits.createdAt, initialWitness.dateReferenceTimeBits.createdAt);
    assert.deepEqual(witness.dateReferenceTimeBits.images, initialWitness.dateReferenceTimeBits.images);
    assert.deepEqual(ordered(await session.command('persisted-projects')), ordered([...others, expected]));
    assert.deepEqual(await session.command('presented-alerts'), []);
    assert.equal((await session.command('capabilities')).runID, capabilities.runID);
    console.log(`PASS: AUT-J06/identity-boundaries/${test.id}`);
  }
}
