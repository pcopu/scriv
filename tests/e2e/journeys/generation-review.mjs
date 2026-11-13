import assert from 'node:assert/strict';
import { generationRecoveryCases, runGenerationRecovery } from './support/generation-recovery-steps.mjs';
import { generationContextCases } from './support/generation-context-cases.mjs';
import { runGenerationContext } from './support/generation-context-steps.mjs';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { fixture, people } from './support/generation-review-fixture.mjs';
import { nodeWithID as byID, sortedProjects, reviewSteps } from './support/generation-review-steps.mjs';

// AUT-J12 review and local optional-direction portion. No provider, copy, direct model mutation, private
// handler or native AppKit helper. Native verification is required separately.
const cases = ['source-identity', 'people-link-disclosure', 'exact-request', 'close-reopen', 'optional-direction-edit-clear'];
const args = process.argv.slice(2);
const groups = ['review', 'context', 'recovery'];
let selected = groups;
if (args.includes('--group')) {
  const value = args[args.indexOf('--group') + 1];
  assert.ok(groups.includes(value), '--group must be review, context or recovery'); selected = [value];
}
assert.ok(args.every((arg, index) => arg === '--list-cases' || arg === '--group'
  || (args[index - 1] === '--group' && groups.includes(arg))), 'Unknown argument');
if (args.includes('--list-cases')) {
  console.log(JSON.stringify({ journey: 'AUT-J12', nativeVerified: false,
    interactions: ['IMG-049', 'IMG-056', 'IMG-057', 'IMG-058', 'IMG-059', 'IMG-061'],
    cases: selected.includes('review') ? cases : [],
    excluded: ['IMG-060 clipboard', 'IMG-062 generation',
      'stale invalidation', 'portrait attachments', 'physical input', 'viewport size matrix'], groups: selected,
    recoveryCases: selected.includes('recovery') ? generationRecoveryCases : [],
    contextCases: selected.includes('context') ? generationContextCases : [] }, null, 2));
} else if (selected.includes('review')) {
  assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const step = reviewSteps(session);
  let currentCase = 'setup';
  try {
    const capabilities = await session.command('capabilities');
    for (const command of ['import-json', 'persisted-projects', 'image-evidence', 'controller-keys']) {
      assert.ok(capabilities.commands.includes(command), `Requires compiled ${command} support`);
    }
    await session.waitFor(nodes => byID(nodes, 'workspace-tabs')?.hittable);
    await session.command('key', { input: 's', modifiers: ['command'] });
    const sample = await waitForSavedProject(session, project => project.title === 'YAM MAN');
    assert.equal((await session.command('persisted-projects')).length, 1);
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(fixture) }),
      { dispatched: true, projectChanged: true });
    const imported = await waitForSavedProject(session, project => project.id !== sample.id);
    assert.notEqual(imported.id, fixture.id, 'Production import supplies new project identity');
    assert.deepEqual(imported.entries, fixture.entries);
    assert.deepEqual(imported.characters, fixture.characters);
    assert.deepEqual(imported.cues, fixture.cues);
    const saved = sortedProjects(await session.command('persisted-projects'));
    assert.equal(saved.length, 2);
    assert.deepEqual(saved.find(project => project.id === sample.id), sample);
    const jobs = await session.command('image-evidence');
    assert.deepEqual(jobs.jobs, []);
    async function unchanged() {
      assert.deepEqual(sortedProjects(await session.command('persisted-projects')), saved,
        'Review changes no saved source, identity, cue, image, revision or package');
      assert.deepEqual(await session.command('image-evidence'), jobs, 'Review starts zero image jobs');
    }
    const tabs = byID(await session.command('snapshot'), 'workspace-tabs');
    const script = tabs.segments.indexOf('Script'); assert.ok(script >= 0);
    await session.command('select', { target: tabs.path, index: script });
    let nodes = await step.open();
    const chrome = step.chrome(nodes);
    const sourceScroll = byID(nodes, 'generation-review-scroll');
    assert.ok(sourceScroll.frame.height > 0);
    assert.ok(sourceScroll.frame.y >= chrome['generation-review-header'].y
      + chrome['generation-review-header'].height - 0.5, 'Source body stays below fixed header');
    assert.ok(sourceScroll.frame.y + sourceScroll.frame.height <= chrome['generation-review-footer'].y + 0.5,
      'Source body stays above fixed footer');
    currentCase = cases[0];
    assert.deepEqual(byID(nodes, 'generation-review-tabs').segments, ['Source', 'People', 'Exact request']);
    function sourceAssertions(snapshot) {
      assert.deepEqual(snapshot.filter(node => node.identifier.startsWith('generation-source-')
        && !node.identifier.startsWith('generation-source-person-')).map(node => [node.identifier, node.text]),
      fixture.entries.map(entry => ['generation-source-' + entry.id, entry.text]));
      assert.deepEqual(snapshot.filter(node => node.identifier.startsWith('generation-source-person-'))
        .map(node => node.identifier), people.map(person => 'generation-source-person-' + person.id));
      assert.ok(snapshot.some(node => node.text === '01A · Current picture'));
      assert.ok(snapshot.some(node => node.text === 'Follow the script.'));
      assert.ok(snapshot.some(node => node.text === 'No visual override. Your script is unchanged.'));
      assert.ok(!snapshot.some(node => node.text?.includes('Unrelated sentinel')));
    }
    sourceAssertions(nodes);
    await unchanged();
    console.log(`PASS: AUT-J12/${currentCase}`);

    currentCase = cases[1];
    for (const person of [people[1], people[0], people[1]]) {
      await step.section(0);
      await step.activate('generation-source-person-' + person.id);
      nodes = await session.waitFor(snapshot => byID(snapshot, 'generation-review-tabs')?.selected === 1
        && byID(snapshot, 'generation-person-' + person.id)?.value === 'Expanded'
        && byID(snapshot, 'generation-person-' + person.id)?.hittable);
      const header = byID(nodes, 'generation-person-' + person.id);
      const scroll = byID(nodes, 'generation-review-scroll');
      assert.ok(header.frame.y >= scroll.frame.y - 0.5);
      assert.ok(header.frame.y + header.frame.height <= scroll.frame.y + scroll.frame.height + 0.5,
        'Source link reveals the requested header, not just a lower profile fragment');
      for (const field of [person.aliases.join(', '), person.appearance, person.biography]) {
        assert.ok(nodes.some(node => node.text === field), 'Complete captured Unicode profile field');
      }
      assert.ok(byID(nodes, 'generation-profile-grid-' + person.id));
      step.sameChrome(nodes, chrome);
      await step.activate('generation-person-' + person.id);
      nodes = await session.waitFor(snapshot => byID(snapshot, 'generation-person-' + person.id)?.value === 'Collapsed');
      assert.ok(!byID(nodes, 'generation-profile-grid-' + person.id));
      step.sameChrome(nodes, chrome);
      await step.activate('generation-person-' + person.id);
      nodes = await session.waitFor(snapshot => byID(snapshot, 'generation-person-' + person.id)?.value === 'Expanded');
      assert.ok(byID(nodes, 'generation-profile-grid-' + person.id));
      step.sameChrome(nodes, chrome);
    }
    await unchanged();
    console.log(`PASS: AUT-J12/${currentCase}`);

    currentCase = cases[2];
    await step.activate('generation-review-exact-link');
    nodes = await session.waitFor(snapshot => byID(snapshot, 'generation-review-tabs')?.selected === 2);
    const exact = byID(nodes, 'generation-exact-request');
    assert.ok(exact.frame.height > 0 && exact.scroll, 'Exact text has a real scroll viewport');
    assert.equal(exact.editable, false, 'Exact request is a read-only native text view');
    assert.equal(exact.selectable, true, 'Exact request remains selectable');
    assert.ok(exact.text.startsWith('Generate one cinematic storyboard image using the available image generation tool.'));
    for (const value of [...fixture.entries.map(entry => entry.text), ...people.flatMap(person =>
      [person.name, person.appearance, person.biography, ...person.aliases])]) {
      assert.ok(exact.text.includes(JSON.stringify(value)), 'Exact request retains complete quoted input');
    }
    assert.ok(exact.text.includes('No local portrait images are attached.'));
    assert.ok(exact.text.endsWith('None. Follow the script source and identity references above.'));
    assert.ok(!exact.text.includes('Unrelated sentinel'));
    // Presence only: do not disturb the user's system clipboard.
    assert.equal(byID(nodes, 'generation-copy-full-request').enabled, true);
    step.sameChrome(nodes, chrome);
    await session.command('scroll', { target: exact.path, y: exact.scroll.contentHeight });
    step.sameChrome(await session.command('snapshot'), chrome);
    await step.section(0); sourceAssertions(await session.command('snapshot'));
    await step.section(1);
    await step.section(2);
    assert.equal(byID(await session.command('snapshot'), 'generation-exact-request').text, exact.text);
    await unchanged();
    console.log(`PASS: AUT-J12/${currentCase}`);

    currentCase = cases[3];
    for (const route of ['done', 'close', 'escape']) {
      if (route === 'escape') {
        const keys = await session.command('keys');
        assert.ok(keys.some(key => key.responderType === 'GenerationBriefReviewController'
          && key.input === 'Escape' && key.wantsPriorityOverSystemBehavior), 'Review owns priority Escape in responder chain');
        await session.command('key', { input: 'Escape', modifiers: [] });
      } else await step.activate('generation-review-' + route);
      await step.closed(); await unchanged();
      nodes = await step.open(); sourceAssertions(nodes);
      await step.section(2);
      assert.equal(byID(await session.command('snapshot'), 'generation-exact-request').text, exact.text,
        `Exact captured request survives ${route} close and fresh reopen`);
    }
    await step.activate('generation-review-done'); await step.closed(); await unchanged();
    console.log(`PASS: AUT-J12/${currentCase}`);

    currentCase = cases[4];
    // Actual optional-direction editor and delegate, never a Store setter.
    // Draft changes are local; no Generate/clipboard/account action is taken.
    const directions = ['Café 🎬\nKeep the frame still.', 'Cafe\u0301 🎬\nKeep the frame still.', ''];
    assert.notEqual(directions[0], directions[1]);
    assert.equal(directions[0].normalize('NFC'), directions[1].normalize('NFC'));
    let directionProject = imported;
    for (const direction of directions) {
      const prompt = await step.reveal('generation-optional-direction');
      assert.equal(prompt.editable, true);
      await session.command('text', { target: prompt.path, text: direction });
      await session.waitFor(snapshot => byID(snapshot, 'generation-optional-direction')?.text === direction);
      // Ordinary editing journals first, then commits this cue's prompt. Wait
      // for the actual commit before capture; a review crossing that source
      // change correctly invalidates rather than silently changing its request.
      const committed = await waitForSavedProject(session, project => project.id === directionProject.id
        && project.cues.find(cue => cue.id === 'review-cue')?.prompt === direction);
      assert.equal(committed.revision, directionProject.revision + 1);
      const expected = structuredClone(directionProject);
      expected.cues.find(cue => cue.id === 'review-cue').prompt = direction;
      expected.revision = committed.revision; expected.modifiedAt = committed.modifiedAt;
      assert.deepEqual(committed, expected, 'Only the intended cue direction and commit metadata change');
      directionProject = committed;
      await session.waitFor(snapshot => !snapshot.some(node => node.text ===
        'Direction saved in local recovery until the project save completes.'));
      await step.open();
      await step.section(2);
      const request = byID(await session.command('snapshot'), 'generation-exact-request').text;
      const boundary = '\nMANUAL VISUAL OVERRIDE — THIS CUE ONLY\n';
      const at = exact.text.lastIndexOf(boundary); assert.ok(at >= 0);
      assert.equal(request, exact.text.slice(0, at) + boundary +
        (direction === '' ? 'None. Follow the script source and identity references above.' : JSON.stringify(direction)),
        'Only the exact optional visual direction changes the captured request');
      await step.activate('generation-review-done'); await step.closed();
      await session.waitFor(snapshot => byID(snapshot, 'generation-optional-direction')?.text === direction);
      assert.deepEqual(sortedProjects(await session.command('persisted-projects')),
        sortedProjects([sample, directionProject]), 'Review preserves both complete saved projects');
      assert.deepEqual(await session.command('image-evidence'), jobs, 'Direction editing/review starts zero jobs');
    }
    console.log(`PASS: AUT-J12/${currentCase}`);
  } catch (error) {
    throw new Error(`AUT-J12/${currentCase} failed; no mutation was retried`, { cause: error });
  } finally { await session.close(); }
}

if (!args.includes('--list-cases') && selected.includes('context')) {
  assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  try { await runGenerationContext(session); } finally { await session.close(); }
}

if (!args.includes('--list-cases') && selected.includes('recovery')) {
  assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  try { await runGenerationRecovery(session); } finally { await session.close(); }
}
