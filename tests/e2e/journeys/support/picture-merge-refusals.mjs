import assert from 'node:assert/strict';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { audioProjectFixture } from './audio-library-fixtures.mjs';
import { coverageSteps, sorted } from './picture-coverage-steps.mjs';

export const mergeRefusalListing = {
  journey: 'AUT-J09', portion: 'storyboard-original-menu-merge-refusals',
  nativeVerified: false, optIn: true,
  cases: ['gap-rejected', 'scene-clipped-authored-extent-rejected', 'spanning-third-cue-rejected'],
  inputRoute: 'Production JSON import > mounted Storyboard ellipsis UIButton original menu',
  additionalAcceptance: ['mounted menu omits Merge', 'original-scope semantic request rejected',
    'entire loaded observation including Date bits unchanged', 'every saved package unchanged'],
  excluded: ['core throwing-branch coverage', 'core failure purity', 'physical menu selection',
    'providers', 'delete', 'fill', 'split', 'legacy retirement'],
};

// Literal serialized inputs, not a second implementation of eligibility.
// Production sources: CueAnchoring.swift canMoveBoundary/validate;
// TimingEngine.swift validate allows overlapping source-owned cues;
// StoryboardViewController.swift actions/cliValidatedMergeCue use that same gate.
// The right cue in case 2 is valid: line2 begins at 3000, its authored end is
// 6000, and its resolved end is clipped to the 5000 ms scene duration.
export function mergeRefusalFixtures() {
  const cases = [
    { name: 'gap-rejected', targetLabel: 'Left', cues: [
      { id: 'left', sceneId: 'scene', label: 'Left', prompt: '', startMs: 0, endMs: 2500,
        startAnchor: { entryId: 'line1', offsetMs: 0 }, authoredDurationMs: 2500 },
      { id: 'right', sceneId: 'scene', label: 'Right', prompt: '', startMs: 3000, endMs: 5000,
        startAnchor: { entryId: 'line2', offsetMs: 0 }, authoredDurationMs: 2000 },
    ] },
    { name: 'scene-clipped-authored-extent-rejected', targetLabel: 'Left', cues: [
      { id: 'left', sceneId: 'scene', label: 'Left', prompt: '', startMs: 0, endMs: 3000,
        startAnchor: { entryId: 'line1', offsetMs: 0 }, authoredDurationMs: 3000 },
      { id: 'right', sceneId: 'scene', label: 'Right', prompt: '', startMs: 3000, endMs: 5000,
        startAnchor: { entryId: 'line2', offsetMs: 0 }, authoredDurationMs: 3000 },
    ] },
    { name: 'spanning-third-cue-rejected', targetLabel: 'Target Left', cues: [
      { id: 'parent', sceneId: 'scene', label: 'Parent', prompt: '', startMs: 0, endMs: 5000,
        startAnchor: { entryId: 'line1', offsetMs: 0 }, authoredDurationMs: 5000 },
      { id: 'left', sceneId: 'scene', label: 'Target Left', prompt: '', startMs: 500, endMs: 2500,
        startAnchor: { entryId: 'line1', offsetMs: 500 }, authoredDurationMs: 2000 },
      { id: 'right', sceneId: 'scene', label: 'Next Right', prompt: '', startMs: 2500, endMs: 4000,
        startAnchor: { entryId: 'line1', offsetMs: 2500 }, authoredDurationMs: 1500 },
    ] },
  ];
  return cases.map(({ cues, ...test }) => {
    const project = audioProjectFixture();
    project.id = `merge-refusal-${test.name}`;
    project.title = `Synthetic merge refusal ${test.name}`;
    for (const entry of project.entries) entry.characterLinks = [];
    project.cues = cues;
    return { ...test, project };
  });
}

// Portable literal checks do not claim to run Swift validation or UIKit.
export function validateMergeRefusalFixtures() {
  const fixtures = mergeRefusalFixtures();
  assert.deepEqual(fixtures.map(f => f.name), mergeRefusalListing.cases);
  assert.deepEqual(fixtures.map(f => f.project.cues.map(c =>
    [c.id, c.startMs, c.endMs, c.startAnchor.entryId, c.startAnchor.offsetMs, c.authoredDurationMs])), [
    [['left', 0, 2500, 'line1', 0, 2500], ['right', 3000, 5000, 'line2', 0, 2000]],
    [['left', 0, 3000, 'line1', 0, 3000], ['right', 3000, 5000, 'line2', 0, 3000]],
    [['parent', 0, 5000, 'line1', 0, 5000], ['left', 500, 2500, 'line1', 500, 2000],
      ['right', 2500, 4000, 'line1', 2500, 1500]],
  ]);
  for (const { project, targetLabel } of fixtures) {
    assert.deepEqual(JSON.parse(JSON.stringify(project)), project);
    assert.equal(project.cues.filter(c => c.label === targetLabel).length, 1);
    assert.deepEqual(project.entries.map(e => [e.id, e.ownedDurationMs, e.characterLinks]),
      [['line1', 3000, []], ['line2', 2000, []]]);
    assert.equal(project.entries.flatMap(e => e.words).length, 4);
    assert.deepEqual([project.images, project.audioAssets, project.audioClips], [[], [], []]);
  }
  const fresh = mergeRefusalFixtures();
  fixtures[0].project.cues[0].label = 'mutated only in portable check';
  assert.equal(fresh[0].project.cues[0].label, 'Left');
  assert.equal(fixtures[1].project.cues[0].label, 'Left');
}

const mergeTitle = 'Merge with next placement';
const expectedTitles = ['Picture source…', 'Choose existing image…', 'Import image…',
  'Generate image', 'Preview picture split…', 'Discuss image', 'Remove placement…'];
export async function runMergeRefusalJourney() {
  validateMergeRefusalFixtures();
  assert.ok(process.env.SCRIV_E2E_APP, 'Requires an isolated automation-enabled Catalyst app');
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const ui = coverageSteps(session);
  let stage = 'setup';
  try {
    const capabilities = await session.command('capabilities');
    assert.equal(capabilities.cloudIsolation.network, 'disabled');
    for (const command of ['menu', 'menu-action', 'import-json', 'loaded-project',
      'persisted-projects', 'presented-alerts', 'end-editing', 'key']) {
      assert.ok(capabilities.commands.includes(command));
    }
    await ui.tab('Script');
    await session.command('key', { input: 's', modifiers: ['command'] });
    const sample = await waitForSavedProject(session, p => p.entries.length > 0);
    const packages = [sample];
    assert.deepEqual(sorted(await session.command('persisted-projects')), sorted(packages));
    for (const { name, project: source, targetLabel } of mergeRefusalFixtures()) {
      stage = name;
      await ui.tab('Script');
      assert.deepEqual(await session.command('import-json', { text: JSON.stringify(source) }),
        { dispatched: true, projectChanged: true });
      const current = await waitForSavedProject(session, p => !packages.some(saved => saved.id === p.id));
      const expected = structuredClone(source);
      for (const key of ['id', 'createdAt', 'modifiedAt']) expected[key] = current[key];
      assert.notEqual(current.id, source.id);
      assert.match(current.id, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
      assert.ok(Number.isFinite(current.createdAt) && Number.isFinite(current.modifiedAt));
      assert.equal(current.createdAt, current.modifiedAt);
      assert.deepEqual(current, expected, 'Production import preserves the entire literal fixture');
      packages.push(current);
      await session.command('end-editing');
      await ui.tab('Storyboard');
      const button = await ui.reveal(node => node.label === `Picture actions for ${targetLabel}`);
      const beforeLoaded = await session.command('loaded-project');
      const beforePackages = sorted(await session.command('persisted-projects'));
      assert.deepEqual(beforeLoaded.project, current);
      assert.deepEqual(beforePackages, sorted(packages));
      async function unchanged() {
        assert.deepEqual(await session.command('loaded-project'), beforeLoaded,
          'Full loaded observation, revision and exact Date bits remain unchanged');
        assert.deepEqual(sorted(await session.command('persisted-projects')), beforePackages,
          'Every saved package, including startup and earlier fixtures, remains unchanged');
        assert.deepEqual(await session.command('presented-alerts'), []);
      }
      // Reads the already mounted UIButton.menu, not a provider or rebuilt menu.
      const menu = await session.command('menu', { target: button.path });
      assert.deepEqual(menu.secondary, []); assert.deepEqual(menu.context, []);
      assert.equal(menu.primary.length, 1);
      assert.equal(menu.primary[0].type, 'menu'); assert.equal(menu.primary[0].title, '');
      const actions = menu.primary[0].children;
      assert.deepEqual(actions.map(a => a.title), expectedTitles);
      assert.ok(actions.every(a => a.type === 'action' && !a.disabled && !a.hidden && a.state === 'off'));
      assert.ok(!actions.some(a => a.title === mergeTitle), 'Mounted original menu lacks Merge');
      await unchanged();
      await assert.rejects(session.command('menu-action', {
        target: button.path, scope: 'storyboard-merge', action: mergeTitle,
      }), /Storyboard merge is outside the supported isolated scope/);
      await unchanged();
      console.log(`PASS AUT-J09/merge-refusals/${name}`);
    }
    console.log('PASS AUT-J09 merge refusals: mounted UI/helper rejection only; no core throwing-branch or failure-purity claim.');
  } catch (error) {
    console.error(`FAIL AUT-J09/merge-refusals/${stage}`); throw error;
  } finally { await session.close(); }
}
