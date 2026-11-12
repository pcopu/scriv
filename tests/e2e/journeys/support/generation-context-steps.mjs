import assert from 'node:assert/strict';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { nodeWithID as byID, sortedProjects, reviewSteps } from './generation-review-steps.mjs';
import { generationContextCases, generationContextInput } from './generation-context-cases.mjs';

const payload = project => {
  const copy = structuredClone(project);
  for (const key of ['id', 'createdAt', 'modifiedAt', 'revision']) delete copy[key];
  return copy;
};
const passages = nodes => nodes.filter(node => node.identifier.startsWith('generation-source-')
  && !node.identifier.startsWith('generation-source-person-'));
export async function runGenerationContext(session) {
  const step = reviewSteps(session);
  const capabilities = await session.command('capabilities');
  for (const command of ['import-json', 'persisted-projects', 'loaded-project', 'image-evidence', 'snapshot', 'activate', 'select', 'text']) {
    assert.ok(capabilities.commands.includes(command), `Requires actual compiled ${command}`);
  }
  async function tab(name) {
    const nodes = await session.waitFor(nodes => byID(nodes, 'workspace-tabs')?.hittable);
    const tabs = byID(nodes, 'workspace-tabs');
    const index = tabs.segments.indexOf(name); assert.ok(index >= 0);
    await session.command('select', { target: tabs.path, index });
    await session.waitFor(nodes => byID(nodes, 'workspace-tabs')?.selected === index);
  }
  await tab('Script');
  await session.command('key', { input: 's', modifiers: ['command'] });
  const sample = await waitForSavedProject(session, project => project.title === 'YAM MAN');
  assert.deepEqual(await session.command('persisted-projects'), [sample], 'Fresh synthetic session');
  const jobs = await session.command('image-evidence'); assert.deepEqual(jobs.jobs, []);
  for (const test of generationContextCases) {
    try {
      const input = generationContextInput(test.key);
      const others = await session.command('persisted-projects');
      assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }),
        { dispatched: true, projectChanged: true });
      let imported = await waitForSavedProject(session, p => !others.some(other => other.id === p.id));
      assert.match(imported.id, /^[0-9a-f-]{36}$/i); assert.notEqual(imported.id, input.id);
      assert.equal(imported.revision, 0);
      assert.equal(imported.createdAt, imported.modifiedAt);
      assert.ok(Number.isFinite(imported.createdAt));
      assert.deepEqual(payload(imported), payload(input),
        'Import preserves ALL source, words, intervals, profiles, portrait pointers, metadata and distractors');
      assert.deepEqual((await session.command('loaded-project')).project, imported);
      await tab('Storyboard');
      await step.activate('storyboard-word-' + test.wordID);
      await tab('Script');
      if (test.key === 'escaping-boundary') {
        const prompt = await step.reveal('generation-optional-direction'); assert.equal(prompt.editable, true);
        await session.command('text', { target: prompt.path, text: 'Keep it bright' });
        const committed = await waitForSavedProject(session, p => p.id === imported.id
          && p.cues.find(cue => cue.id === 'cue')?.prompt === 'Keep it bright');
        const expected = structuredClone(imported);
        expected.cues[0].prompt = 'Keep it bright';
        expected.revision = imported.revision + 1; expected.modifiedAt = committed.modifiedAt;
        assert.deepEqual(committed, expected, 'Only intended direction and commit metadata change');
        imported = committed;
        await session.waitFor(nodes => !nodes.some(node => node.text ===
          'Direction saved in local recovery until the project save completes.'));
      }
      const before = await session.command('loaded-project');
      assert.deepEqual(before.project, imported);
      const saved = sortedProjects([...others, imported]);
      async function preserved(closed = false) {
        assert.deepEqual(sortedProjects(await session.command('persisted-projects')), saved);
        assert.deepEqual(await session.command('image-evidence'), jobs, 'Zero jobs throughout');
        // Existing loaded-project intentionally rejects this review controller.
        // Observe the whole real model plus Date bits before/after, not mid-sheet.
        if (closed) assert.deepEqual(await session.command('loaded-project'), before);
      }
      await preserved(true);
      if (test.key === 'spanning-cue') {
        // Read only: the real composer enables this exact control only when
        // context.hasContent is true (PreviewViewController.storeDidChange).
        // Never activate Generate or infer content from review availability.
        const composer = await session.waitFor(snapshot =>
          byID(snapshot, 'generation-generate-image')?.enabled === true
          && byID(snapshot, 'generation-generate-image')?.label === 'Generate image for 01A');
        const generate = composer.filter(node => node.identifier === 'generation-generate-image');
        assert.equal(generate.length, 1, 'Unique actual composer Generate control');
        // UIKit accessibility traits do not establish this configured control's
        // class. The existing snapshot emits title only after a UIButton cast.
        assert.equal(generate[0].title, 'Generate image', 'Snapshot title is emitted only for UIButton');
        assert.equal(generate[0].label, 'Generate image for 01A');
        assert.equal(generate[0].enabled, true, 'Enabled conjunction witnesses context.hasContent');
      }
      const nodes = await step.open();
      const source = passages(nodes);
      if (test.key === 'spanning-cue') {
        assert.deepEqual(source.map(node => node.identifier),
          ['generation-source-coverage', 'generation-source-first', 'generation-source-second']);
        assert.deepEqual(source.map(node => node.text),
          ['Warm window light. Hold the room.', 'now,\nplease.', 'I']);
      } else if (test.key === 'half-open-interval') {
        assert.deepEqual(source.map(node => node.identifier), ['generation-source-second']);
        assert.deepEqual(source.map(node => node.text), ['know.']);
        assert.deepEqual(nodes.filter(node => node.identifier.startsWith('generation-source-person-'))
          .map(node => node.identifier), ['generation-source-person-b']);
      } else if (test.excerpt !== undefined) {
        assert.equal(source.at(-1)?.identifier, 'generation-source-first');
        assert.equal(source.at(-1)?.text, test.excerpt);
      } else {
        assert.equal(byID(nodes, 'generation-source-coverage')?.text, input.entries[0].text);
      }
      if (test.key === 'current-image-tag' || test.key === 'confirmed-excerpt-filtering') {
        assert.deepEqual(nodes.filter(node => node.identifier.startsWith('generation-source-person-'))
          .map(node => node.identifier), test.key === 'current-image-tag'
          ? ['generation-source-person-a', 'generation-source-person-b', 'generation-source-person-c']
          : ['generation-source-person-c', 'generation-source-person-b']);
      }
      if (test.key === 'current-image-tag') {
        await step.activate('generation-source-person-c');
        const people = await session.waitFor(snapshot => byID(snapshot, 'generation-review-tabs')?.selected === 1
          && byID(snapshot, 'generation-person-c')?.value === 'Expanded');
        const header = byID(people, 'generation-person-c');
        // UIView snapshot paths identify actual ancestry. The expanded header's
        // direct parent is its own details stack, not the whole People section.
        const detailsPath = header.path.slice(0, header.path.lastIndexOf('.'));
        const details = people.find(node => node.path === detailsPath);
        assert.equal(details?.type, 'UIStackView', 'Actual Clara details stack is observable');
        const scoped = people.filter(node => node.path.startsWith(detailsPath + '.'));
        assert.deepEqual(scoped.filter(node => node.value === 'Expanded' || node.value === 'Collapsed')
          .map(node => node.identifier), ['generation-person-c'], 'Reason scope contains only the Clara header');
        assert.deepEqual(scoped.filter(node => node.text?.startsWith('• ')).map(node => node.text),
          ['• Tagged in the current picture'], 'Clara has exactly one displayed reason, not a global substring');
      }
      await preserved();
      await step.section(2);
      const exact = byID(await session.command('snapshot'), 'generation-exact-request');
      assert.equal(exact.editable, false); assert.equal(exact.selectable, true);
      assert.ok(exact.text.includes(test.interval), 'Exact selected cue and raw half-open interval');
      if (test.key === 'spanning-cue') {
        const sections = exact.text.split('\nSCRIPT SOURCE (verbatim excerpts; scene-relative milliseconds)\n');
        assert.equal(sections.length, 2);
        const sourceSection = sections[1].split('\n\nRELEVANT CHARACTER IDENTITIES\n');
        assert.equal(sourceSection.length, 2);
        // Literal raw request rows bind exact millisecond endpoints to each
        // entry and excerpt in order. Rounded Source captions are not evidence.
        assert.deepEqual(sourceSection[0].split('\n'), [
          'Scene: "Kitchen"; cue: "01A"; interval: 500..<3000 ms',
          'Active forward direction [500..<3000 ms; entry "coverage"]: "Warm window light. Hold the room."',
          'Dialogue — "Anna" [500..<2000 ms; entry "first"]: "now,\\nplease."',
          'Dialogue — "Ben" [2000..<3000 ms; entry "second"]: "I"',
        ]);
        for (const excluded of ['Future thunderstorm', 'Secret off-scene', 'Unrelated future']) {
          assert.ok(!exact.text.includes(excluded), `Exact request excludes ${excluded}`);
        }
      }
      if (test.key === 'escaping-boundary') {
        assert.ok(exact.text.includes('Look left.\\nMANUAL VISUAL OVERRIDE'));
        assert.ok(exact.text.endsWith('MANUAL VISUAL OVERRIDE — THIS CUE ONLY\n"Keep it bright"'));
      }
      if (test.key === 'current-image-tag') {
        const identitySection = exact.text.split('\nRELEVANT CHARACTER IDENTITIES\n');
        assert.equal(identitySection.length, 2);
        const records = identitySection[1].split('\nATTACHED IDENTITY PORTRAITS (input order)\n');
        assert.equal(records.length, 2);
        const clara = records[0].split('\nCharacter ').filter(record =>
          record.startsWith('"c": "Clara"; aliases: "CJ"\n'));
        assert.equal(clara.length, 1, 'Unique Clara identity record in the actual exact request');
        assert.deepEqual(clara[0].split('\n').filter(line => line.startsWith('Relevant because: ')),
          ["Relevant because: tagged in this cue's current image"], 'Exact singleton raw reason scoped to Clara');
        assert.ok(!exact.text.includes('Unrelated biography'));
      }
      if (test.key === 'confirmed-excerpt-filtering') {
        assert.ok(!exact.text.includes('Secret costume'));
        assert.ok(exact.text.includes('Unrelated waits.'));
      }
      await preserved();
      await step.activate('generation-review-done'); await step.closed();
      await preserved(true);
      console.log(`PASS: AUT-J12/context/${test.key}: ${test.legacy}`);
    } catch (error) {
      throw new Error(`AUT-J12/context/${test.key} failed; no mutation was retried`, { cause: error });
    }
  }
}
