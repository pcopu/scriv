import assert from 'node:assert/strict';
import { fixture } from './generation-review-fixture.mjs';
import { nodeWithID as byID, reviewSteps, sortedProjects } from './generation-review-steps.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';

export const generationRecoveryCases = ['missing-profile-fallbacks', 'no-resolved-people', 'refuse-review-edits'];
export async function runGenerationRecovery(session) {
  const step = reviewSteps(session);
  const tabs = byID(await session.waitFor(nodes => byID(nodes, 'workspace-tabs')?.hittable), 'workspace-tabs');
  const script = tabs.segments.indexOf('Script'); assert.ok(script >= 0);
  await session.command('select', { target: tabs.path, index: script });
  await session.command('key', { input: 's', modifiers: ['command'] });
  await waitForSavedProject(session, project => project.title === 'YAM MAN');
  const jobs = await session.command('image-evidence'); assert.deepEqual(jobs.jobs, []);
  for (const kind of ['missing-profile-fallbacks', 'no-resolved-people']) {
    const input = structuredClone(fixture);
    input.title = 'Synthetic review ' + kind;
    if (kind === 'missing-profile-fallbacks') {
      input.characters = input.characters.map(person => ({ ...person, aliases: [], appearance: '', biography: '' }));
    } else {
      input.characters = [];
      for (const entry of input.entries) delete entry.characterId;
    }
    const previous = await session.command('persisted-projects');
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }),
      { dispatched: true, projectChanged: true });
    const imported = await waitForSavedProject(session, project => !previous.some(other => other.id === project.id));
    assert.deepEqual(imported.entries, input.entries);
    assert.deepEqual(imported.characters, input.characters);
    const saved = sortedProjects([...previous, imported]);
    await step.open();
    if (kind === 'no-resolved-people') {
      const source = await session.command('snapshot');
      assert.ok(source.some(node => node.text === 'No character identities are resolved for this picture.'));
      assert.equal(source.filter(node => node.identifier.startsWith('generation-source-person-')).length, 0);
    }
    const people = await step.section(1);
    if (kind === 'missing-profile-fallbacks') {
      assert.equal(byID(people, 'generation-person-mara')?.value, 'Expanded');
      const profile = byID(people, 'generation-profile-grid-mara');
      assert.ok(profile, 'Expanded Mara has its own profile grid');
      const scoped = people.filter(node => node.path.startsWith(profile.path + '.'));
      for (const text of ['No aliases saved.', 'No appearance saved.', 'No background saved.']) {
        assert.ok(scoped.some(node => node.text === text), `Expanded Mara profile displays ${text}`);
      }
      await step.activate('generation-person-mara');
      assert.equal(byID(await session.command('snapshot'), 'generation-person-mara')?.value, 'Collapsed');
    } else {
      assert.ok(people.some(node => node.text === 'No character identities are resolved for this picture. Unrelated profiles are not included.'));
      assert.equal(people.filter(node => node.identifier.startsWith('generation-person-')).length, 0);
    }
    await step.section(2);
    const exact = byID(await session.command('snapshot'), 'generation-exact-request');
    assert.equal(exact.editable, false);
    assert.ok(exact.text.includes(JSON.stringify(input.entries[0].text)));
    await assert.rejects(session.command('text', { target: exact.path, text: 'Unauthorized replacement' }), /Editor cannot be edited/);
    for (const index of [-1, 3]) {
      await assert.rejects(session.command('select', { target: 'generation-review-tabs', index }), /Invalid segment/);
      const unchanged = await session.command('snapshot');
      assert.equal(byID(unchanged, 'generation-review-tabs').selected, 2);
      assert.equal(byID(unchanged, 'generation-exact-request').text, exact.text);
    }
    await step.activate('generation-review-done'); await step.closed();
    await step.open(); await step.section(2);
    assert.equal(byID(await session.command('snapshot'), 'generation-exact-request').text, exact.text);
    await step.activate('generation-review-done'); await step.closed();
    assert.deepEqual(sortedProjects(await session.command('persisted-projects')), saved);
    assert.deepEqual(await session.command('image-evidence'), jobs);
    console.log(`PASS: AUT-J12/recovery/${kind}; read-only and invalid-tab refusal preserved`);
  }
}
