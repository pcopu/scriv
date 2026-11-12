import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { audit, fixtureKey, expected, wordTimingSteps } from './support/word-timing.mjs';

import { multiwordKey, multiwordAudit, multiwordExpected, multiwordSteps } from './support/word-timing-multiword.mjs';

const args = process.argv.slice(2);
assert.ok(args.length === 0 || (args.length === 1 && args[0] === '--list-cases')
  || (args.length === 2 && args[0] === '--case' && [fixtureKey, multiwordKey].includes(args[1])), 'Use --list-cases or --case interior-word|adjacent-words');
const manifest = { journey: 'AUT-J15', freshSessionPerCase: true, portions: [audit(), multiwordAudit()] };
const selected = args[0] === '--case' ? [args[1]] : [fixtureKey, multiwordKey];
if (args[0] === '--list-cases') console.log(JSON.stringify(manifest, null, 2));
else for (const selectedKey of selected) {
  const multiword = selectedKey === multiwordKey;
  assert.ok(process.env.SCRIV_E2E_APP, 'Requires a matching automation-enabled isolated Catalyst app; no fallback');
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  try {
    assert.ok((await session.command('capabilities')).semanticMenuActionScopes?.includes('layers-word-timing'));
    const ui = (multiword ? multiwordSteps : wordTimingSteps)(session), startup = await ui.initialize();
    const before = await ui.importFixture(startup);
    await ui.guardChecks(); await ui.pendingCases();
    await ui.button('Save timing'); await ui.closed();
    const after = await ui.savedAfter(before, (multiword ? multiwordExpected : expected)(before), startup);
    const oldEntry = before.entries[0], entry = after.entries[0];
    assert.deepEqual(entry.words[1], { id: 'w2', text: 'two', startMs: multiword ? 1200 : 1700, endMs: multiword ? 1600 : 2100, timingSource: 'authored' });
    if (multiword) assert.deepEqual(entry.words[0], { id: 'w1', text: 'one', startMs: 0, endMs: 1200, timingSource: 'authored' });
    else assert.deepEqual(entry.words[0], oldEntry.words[0]);
    assert.deepEqual(entry.words[2], oldEntry.words[2]);
    assert.equal(entry.text, oldEntry.text); assert.deepEqual(after.cues, before.cues);
    assert.deepEqual(after.audioAssets, before.audioAssets); assert.deepEqual(after.audioClips, before.audioClips);
    assert.equal(entry.ownedDurationMs, 3000); assert.equal(oldEntry.ownedDurationMs, 3000);
    await ui.collapseLayers();
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'scene-playback-position'
      && node.slider?.maximum === 3000 && node.enabled));
    const packages = await ui.packages(), loaded = await ui.loaded();
    await ui.open(multiword ? '1.200' : '1.700', multiword ? '1.600' : '2.100'); await ui.button('Cancel'); await ui.closed(); await ui.unchanged(packages, loaded);
    await ui.reopen(after, startup);
    if (multiword) await ui.verifyReopened();
    console.log(`PASS supported observable AUT-J15/${selectedKey} assertions. Semantic stored UIAction + real editor controls only; no automatic method retirement, singular-core branch proof, native-menu or hardware-input claim.`);
  } catch (error) {
    throw new Error(`AUT-J15/${selectedKey} actual-app journey failed; no mutation retry or fallback`, { cause: error });
  } finally { await session.close(); }
}
