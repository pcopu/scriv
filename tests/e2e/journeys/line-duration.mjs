import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { lineDurationCases, directionDurationCases, unsupportedDialogueCases,
  auditLineDurationFixtures, content, expectedContent, expectedRestoredContent,
  verifyLineDurationSaved } from './support/line-duration-cases.mjs';
import { lineDurationSteps, auditPendingLineDurationSteps } from './support/line-duration-steps.mjs';

// AUT-J04 direction-owned-duration portion only. Public semantic dispatch from
// the actual stored Layers UIAction plus real sheet controls, not native menu
// presentation, Script alert handling, physical input, or complete AUT-J04 parity.
let list = false, requested;
const args = process.argv.slice(2);
for (let index = 0; index < args.length; index++) {
  if (args[index] === '--list-cases') { list = true; continue; }
  assert.equal(args[index], '--case', `Unknown argument: ${args[index]}`);
  assert.equal(requested, undefined, 'Use --case only once');
  requested = args[++index];
  assert.ok(lineDurationCases.some(test => test.key === requested), '--case requires one exact fixture key');
}
const manifest = { ...auditLineDurationFixtures(), interactionContract: auditPendingLineDurationSteps(),
  wholeMethodCandidateCount: 4, acceptedMethodCount: 0,
  warning: 'Prepared runner, not native evidence. Dialogue fixtures are unsupported, never passing/skipped coverage. Retirement requires separate exact assertion reconciliation and native proof.' };
if (list) {
  console.log(JSON.stringify(manifest, null, 2));
} else {
  const selected = requested ? lineDurationCases.filter(test => test.key === requested) : directionDurationCases;
  for (const test of unsupportedDialogueCases) {
    console.log(`UNSUPPORTED AUT-J04/${test.key}: ${test.baselineID}; ${test.blocker}`);
  }
  assert.ok(selected.every(test => test.entryKind === 'direction'),
    'Requested dialogue fixture is unsupported: normal Script UIAlertController Apply/Cancel has no permitted verified route');
  assert.ok(process.env.SCRIV_E2E_APP, 'Requires a matching isolated automation-enabled Catalyst app; no fallback route exists');
  const roots = new Set();
  let checkedGuards = false;
  for (const test of selected) {
    const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
    try {
      assert.ok(!roots.has(session.root), 'Every fixture, including rejection, owns fresh synthetic app storage');
      roots.add(session.root);
      const ui = lineDurationSteps(session);
      const startup = await ui.initialize();
      let current = await ui.importCase(test, startup);
      if (!checkedGuards) { await ui.verifyMenuGuards(test, current); checkedGuards = true; }
      await ui.cancelDrafts(test, current);
      if (test.rejection) {
        await ui.reject(test, current);
        console.log(`PASS supported partial observations AUT-J04/${test.key}: exact error and sampled complete saved/loaded/date equality; staged prerequisite and whole-method retirement remain excluded.`);
        continue;
      }
      await ui.invalidDrafts(test, current);
      const states = [current];
      for (let index = 0; index < test.steps.length; index++) {
        const stimulus = test.steps[index];
        if (index > 0) await ui.open(current, test.entryID, test.steps[index - 1].display);
        await ui.input(stimulus.seconds); await ui.button('Apply'); await ui.closed();
        const previous = current;
        current = await ui.savedAfter(previous, expectedContent(previous, stimulus), startup);
        verifyLineDurationSaved(previous, current, stimulus);
        states.push(current);
        await ui.runtimeAndStarts(current, stimulus);
        const beforePackages = await ui.packages(), beforeLoaded = await ui.loaded();
        await ui.open(current, test.entryID, stimulus.display);
        await ui.button('Cancel'); await ui.closed();
        await ui.unchanged(beforePackages, beforeLoaded);
      }
      // Preserve all original frozen operations and assertions BEFORE history.
      // Only non-sample fixtures have an explicit complete bootstrap oracle.
      if (!test.needsStartupSample) {
        await ui.collapseLayers(); await ui.history();
        const previous = states.at(-2), authored = states.at(-1);
        const undone = await ui.savedAfter(current, expectedRestoredContent(test, previous), startup);
        await ui.history(true);
        current = await ui.savedAfter(undone, expectedRestoredContent(test, authored), startup);
        assert.deepEqual(current.entries.map(entry => entry.characterLinks), current.entries.map(() => []),
          'Real history explicitly restores empty annotations; no optional metadata is stripped');
      } else {
        console.log(`DEFERRED supplemental history AUT-J04/${test.key}: ${test.historyDeferred}`);
      }
      await ui.reopen(current, startup);
      assert.deepEqual(content((await ui.loaded()).project), content(current));
      console.log(`PASS supported direction observations AUT-J04/${test.key}: ${test.baselineID ?? 'additional acceptance only'}; frozen scope=${test.scope}; no automatic retirement or physical-menu parity.`);
    } catch (error) {
      throw new Error(`AUT-J04/${test.key}: actual-app direction journey failed; mutation is not retried`, { cause: error });
    } finally { await session.close(); }
  }
  console.log(`AUT-J04 direction portion completed: ${selected.length} selected direction fixtures. Four dialogue fixtures remain UNSUPPORTED; no full-suite parity or method-retirement claim.`);
}
