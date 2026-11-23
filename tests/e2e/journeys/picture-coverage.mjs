import assert from 'node:assert/strict';
import { mergeRefusalListing, runMergeRefusalJourney } from './support/picture-merge-refusals.mjs';
import { mergeListing, runMergeJourney } from './support/picture-merge-steps.mjs';
import { followListing, runFollowJourney } from './support/picture-follow-steps.mjs';
import { placementCases, runPlacementJourney } from './support/picture-placement-steps.mjs';
import { timingGestureListing, runPictureTimingGestureJourney } from './support/picture-timing-gestures.mjs';
import { sharedCutListing, runSharedCutJourney } from './support/picture-shared-cut.mjs';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { fixture, content, expectedContent, validCases, invalidSeconds, foregroundCases,
  foregroundID, clippedID } from './support/picture-coverage-cases.mjs';
import { coverageSteps, ready, sorted } from './support/picture-coverage-steps.mjs';

// AUT-J09 runs numeric coverage, placement, follow, merge and timing gestures.
// Each portion uses a fresh isolated UIKit session.
const args = process.argv.slice(2);
const groups = ['numeric', 'placements', 'follow', 'merge', 'merge-refusals', 'timing-gestures', 'shared-cuts'];
assert.ok(args.every((arg, index) => arg === '--list-cases' || arg === '--group'
  || args[index - 1] === '--group' && groups.includes(arg)), 'Unknown argument');
assert.ok(args.filter(arg => arg === '--group').length <= 1, 'Choose one group');
const group = args.includes('--group') ? args[args.indexOf('--group') + 1] : 'numeric';
assert.ok(groups.includes(group), `Choose --group ${groups.join(', ')}`);
assert.equal(new Set(invalidSeconds).size, invalidSeconds.length);
assert.deepEqual(fixture().cues.map(cue => cue.id), ['parent', 'child']);
assert.equal(fixture().entries.reduce((sum, entry) => sum + entry.ownedDurationMs, 0), 4000);
const placementListing = { journey: 'AUT-J09', portion: 'storyboard-add-placement', nativeVerified: true,
    cases: placementCases,
    inputRoute: 'Production JSON import > Script playback UISlider > Storyboard Add placement UIButton',
    additionalAcceptance: ['complete model/cues/words/timing preservation', 'Undo/Redo each edit', 'save and browser reopen', 'startup package unchanged'],
    excluded: ['picture-menu split/merge', 'drag/scrub', 'physical input', 'picker', 'restart recovery', 'legacy retirement'],
  };
const numericListing = { journey: 'AUT-J09', portion: 'numeric-picture-coverage', nativeVerified: false,
    candidateBaselineIDs: [foregroundID], partialBaselineIDs: [clippedID],
    inputRoute: 'Storyboard duration UIButton > Duration, seconds UITextField > Apply/Cancel',
    validCases, invalidSeconds, foregroundCases,
    additionalAcceptance: ['Cancel twice', 'invalid input preserves every package', 'Undo/Redo every valid edit',
      'reopen authored extent', 'only target cue extent changes', 'startup package unchanged'],
    excluded: ['drag/scrub', 'physical input', 'picker', 'scene-growth restoration', 'pixels', 'restart recovery'],
  };
if (args.includes('--list-cases')) {
  const portions = [numericListing, placementListing, followListing, mergeListing, mergeRefusalListing, timingGestureListing, sharedCutListing];
  const listing = args.includes('--group') ? portions[groups.indexOf(group)]
    : { journey: 'AUT-J09', groups, freshSessionPerGroup: true, nativeCompositionVerified: false,
      defaultGroups: groups, portions };
  console.log(JSON.stringify(listing, null, 2));
} else if (group === 'timing-gestures') {
  await runPictureTimingGestureJourney();
} else if (group === 'shared-cuts') {
  await runSharedCutJourney();
} else if (group === 'merge-refusals') {
  await runMergeRefusalJourney();
} else if (group === 'merge') {
  await runMergeJourney();
} else if (group === 'follow') {
  await runFollowJourney();
} else if (group === 'placements') {
  await runPlacementJourney();
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'Requires an isolated automation-enabled Catalyst app');
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const ui = coverageSteps(session);
  try {
    const capabilities = await session.command('capabilities');
    for (const command of ['import-json', 'persisted-projects', 'snapshot', 'activate', 'text', 'select', 'slider', 'keys', 'key', 'presented-alerts']) {
      assert.ok(capabilities.commands.includes(command), `App supports ${command}`);
    }
    await ui.tab('Script');
    await session.command('key', { input: 's', modifiers: ['command'] });
    await waitForSavedProject(session, project => project.entries.length > 0);
    const retained = sorted(await session.command('persisted-projects'));
    assert.equal(retained.length, 1);
    const source = fixture();
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(source) }),
      { dispatched: true, projectChanged: true });
    let current = await waitForSavedProject(session, project => project.id !== retained[0].id);
    assert.notEqual(current.id, source.id, 'Production import creates a distinct local project');
    assert.equal(current.revision, 0);
    assert.ok(!current.cloudProjectId);
    // Import resets only project identity/timestamps. All authored fields must match.
    const imported = content(current), input = content(source);
    delete imported.id; delete imported.createdAt; delete input.id; delete input.createdAt;
    assert.deepEqual(imported, input);
    const initial = current;
    await ui.tab('Storyboard');

    async function packagesUnchanged(before) {
      assert.deepEqual(sorted(await session.command('persisted-projects')), before);
      assert.deepEqual(await session.command('presented-alerts'), [], 'No native error alert to dismiss');
    }
    async function savedAfter(before, expected) {
      const saved = await waitForSavedProject(session, project => project.id === before.id
        && project.revision > before.revision);
      assert.equal(saved.revision, before.revision + 1, 'One user commit advances one revision');
      assert.deepEqual(content(saved), expected, 'Every field except revision/modifiedAt matches expected content');
      const packages = sorted(await session.command('persisted-projects'));
      assert.equal(packages.length, 2);
      assert.deepEqual(packages.find(project => project.id === retained[0].id), retained[0]);
      return saved;
    }

    // Close/reopen is a repeated real presentation; drafts never reach storage.
    for (const draft of ['2.75', '86400']) {
      const before = sorted(await session.command('persisted-projects'));
      await ui.open('1.500'); await ui.input(draft); await ui.button('Cancel'); await ui.closed();
      await packagesUnchanged(before);
    }
    const beforeInvalid = sorted(await session.command('persisted-projects'));
    await ui.open('1.500');
    for (const text of invalidSeconds) {
      await ui.input(text); await ui.button('Apply');
      await session.waitFor(nodes => nodes.some(node => node.text === 'Enter positive image coverage up to 86,400 seconds (24 hours).')
        && nodes.some(node => node.label === 'Duration, seconds' && node.text === text && ready(node)));
      await packagesUnchanged(beforeInvalid);
    }
    // A valid correction on the same editor must recover from inline errors.
    let display = '1.500';
    for (let index = 0; index < validCases.length; index++) {
      const test = validCases[index];
      if (index !== 0) await ui.open(display);
      await ui.input(test.text); await ui.button('Apply'); await ui.closed();
      const previous = current;
      current = await savedAfter(previous, expectedContent(previous, test));
      await ui.open(test.display); await ui.button('Cancel'); await ui.closed();
      await packagesUnchanged(sorted([retained[0], current]));
      await ui.history();
      const undone = await savedAfter(current, content(previous));
      await ui.history(true);
      current = await savedAfter(undone, content(current));
      display = test.display;
    }

    // Exact frozen ::0003 boundary oracle via the real scene seek control and
    // Preview subtitle, not a JS reimplementation of activeCue selection.
    await ui.tab('Script');
    for (const test of foregroundCases) {
      const seek = await ui.reveal(node => node.identifier === 'scene-playback-position');
      assert.equal(seek.slider.maximum, 4000, 'Coverage never extends scene runtime');
      await session.command('slider', { target: seek.path, value: test.milliseconds });
      await session.waitFor(nodes => nodes.some(node => node.identifier === 'scene-playback-position'
        && node.slider.value === test.milliseconds)
        && nodes.some(node => node.text === `${test.label} · No image chosen`));
    }
    assert.equal(current.cues.length, 2);
    assert.deepEqual(current.entries, initial.entries);
    assert.deepEqual(current.cues[0], initial.cues[0], 'Underlying parent placement survives every coverage edit');
    await packagesUnchanged(sorted([retained[0], current]));
    console.log(`PASS AUT-J09 numeric coverage: ${foregroundID}; ${clippedID} initial clipped state ONLY. Bounds, invalid text, Cancel, saved invariance and Undo/Redo. No drag/picker/physical-input parity.`);
  } finally { await session.close(); }
  // Fail fast; each subsequent portion launches its own fresh isolated session.
  if (!args.includes('--group')) {
    await runPlacementJourney();
    await runFollowJourney();
    await runMergeJourney();
    await runMergeRefusalJourney();
    await runPictureTimingGestureJourney();
    await runSharedCutJourney();
  }
}
