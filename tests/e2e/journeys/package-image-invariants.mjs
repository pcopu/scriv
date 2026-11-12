import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { audioLibrarySteps, sortedProjects } from './support/audio-library-steps.mjs';
import { stableContent, editedContent } from './support/audio-library-fixtures.mjs';
import { packageFixtureToken, packageImageFixture, validatePackageImageFixture, inspectorBaseline } from './support/package-image-fixture.mjs';

import { discloseInspectorPrompts, inspectorPrompts } from './support/package-image-prompts.mjs';

validatePackageImageFixture();
const withPrompts = process.argv.includes('--with-prompts');
const withSemanticPrompts = process.argv.includes('--with-semantic-prompts');
assert.ok(!(withPrompts && withSemanticPrompts), 'Prompt disclosure modes are mutually exclusive');
const inspectPromptCases = withPrompts || withSemanticPrompts;
const cases = ['reject-inputs', 'stage-without-opening', 'open-exact-package', 'gallery-cancel',
  'choose-foreground-history', 'restore-foreground', 'choose-background-successor', 'overlap-seek', 'browser-reopen'];
assert.ok(process.argv.slice(2).every(arg => ['--list-cases', '--with-prompts', '--with-semantic-prompts'].includes(arg)));
const promptCases = ['inspect-historical-prompts', 'inspect-restored-prompts'];
const selectedCases = inspectPromptCases ? cases.flatMap(name => [name,
  ...(name === 'choose-foreground-history' ? [promptCases[0]] : name === 'restore-foreground' ? [promptCases[1]] : [])]) : cases;
if (process.argv.includes('--list-cases')) {
  console.log(JSON.stringify({ journey: 'AUT-J08', portion: 'literal-package-image-invariants', nativeVerified: false,
    cases: selectedCases, ...(withPrompts ? { promptDisclosure: {
      status: 'exploratory-public-accessibility-reachability-only', nativeVerified: false,
      baselineID: `${inspectorBaseline}::0002`,
      uncertainty: 'Native menu presentation and UIKit item exposure are unverified; fail closed with no alternate dispatch or native helper.',
      coverageIfReachable: 'Separate exact manual and captured-or-explicit-missing text, native Show/Hide disclosure, Done, saved-state equality throughout and full loaded-state/date-bit equality after dismissal.',
      excludes: ['decoded inspector image', 'physical input', 'acceptance or retirement credit'],
    } } : withSemanticPrompts ? { promptDisclosure: {
      status: 'source-only-explicit-semantic-disclosure', nativeVerified: false,
      baselineID: `${inspectorBaseline}::0002`,
      scope: 'image-inspector-prompt-disclosure',
      coverageIfVerified: 'Exact separate manual/captured-or-explicit-missing text, semantic Show/Hide/Show, rejected clipboard/share/wrong requests, Done, complete persisted equality and full loaded/date-bit equality after dismissal.',
      excludes: ['native menu presentation', 'physical input', 'acceptance or retirement credit'],
    } } : {}), candidateBaselineIDs: [`${inspectorBaseline}::0001`, `${inspectorBaseline}::0003`],
    partialBaselineIDs: [`${inspectorBaseline}::0002`],
    excluded: ['exact captured/manual prompt rendering', 'physical input', 'external package picker',
      'restart/crash recovery', 'legacy retirement'],
  }, null, 2));
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'Requires the isolated automation-enabled Catalyst app');
  await run();
}
async function run() {
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const ui = audioLibrarySteps(session), completed = [];
  let current, sample, fixture, step = 'setup';
  const saved = async () => sortedProjects(await session.command('persisted-projects'));
  async function check(name, body) { step = name; await body(); completed.push(name); console.log(`PASS AUT-J08/package-image-invariants/${name}`); }
  async function invariant() {
    assert.deepEqual(await saved(), sortedProjects([sample, current]));
    assert.deepEqual((await session.command('loaded-project')).project, current);
    assert.deepEqual(await session.command('presented-alerts'), []);
    assert.ok(current.entries.every(e => !Object.hasOwn(e, 'characterLinks')), 'Nil links must not become an empty array');
  }
  async function inspectPrompts(version) {
    const before = structuredClone(current);
    const beforeSaved = await saved();
    const beforeLoaded = await session.command('loaded-project');
    assert.deepEqual(beforeLoaded.project, before);
    assert.equal(before.cues.find(c => c.id === 'foreground').imageId, `v${version}`);
    const persistedUnchanged = async () => assert.deepEqual(await saved(), beforeSaved,
      'Inspector disclosure never edits any saved project, revision, dates, prompts or lineage');
    // Only persisted observations while the inspector is presented. The loaded
    // observer deliberately excludes it. The semantic dispatcher uses the full
    // existing local-image evidence gate, without widening loaded observation.
    await discloseInspectorPrompts(session, ui, inspectorPrompts.find(p => p.version === version), persistedUnchanged, { semantic: withSemanticPrompts });
    await persistedUnchanged();
    assert.deepEqual(await session.command('loaded-project'), beforeLoaded,
      'Done preserves the complete loaded project and every Date reference-time bit, including modifiedAt');
    assert.deepEqual(current, before); await invariant();
  }
  async function seek(ms, label, version) {
    const slider = await ui.reveal(n => n.identifier === 'scene-playback-position');
    assert.equal(slider.slider.maximum, 3000);
    await session.command('slider', { target: slider.path, value: ms });
    await session.waitFor(nodes => nodes.some(n => n.identifier === 'scene-playback-position' && n.slider.value === ms)
      && nodes.some(n => n.text === `${label} · Version ${version}`));
  }
  async function gallery() {
    await ui.activate(n => n.identifier === 'preview-version');
    const nodes = await session.waitFor(nodes => nodes.some(n => n.identifier === 'image-picker-use-selection')
      && nodes.filter(n => n.label?.includes('\nVersion ') && n.hittable).length === 2);
    const cells = nodes.filter(n => n.label?.includes('\nVersion ') && n.hittable);
    assert.deepEqual(cells.map(n => Number(n.label.match(/\nVersion (\d+)/)[1])), [2, 1], 'Native gallery displays latest-first lineage');
    assert.ok(cells.every(n => !n.label.includes('Not on this Mac')));
    return cells;
  }
  async function selectVersion(cue, version) {
    const before = current;
    const beforeLoaded = await session.command('loaded-project');
    assert.deepEqual(beforeLoaded.project, before);
    assert.match(beforeLoaded.dateReferenceTimeBits.createdAt, /^[0-9]+$/);
    assert.deepEqual(beforeLoaded.dateReferenceTimeBits.images.map(image => image.id), before.images.map(image => image.id));
    assert.ok(beforeLoaded.dateReferenceTimeBits.images.every(image => /^[0-9]+$/.test(image.createdAt)));
    const cells = await gallery();
    await session.command('activate', { target: cells.find(n => n.label.includes(`\nVersion ${version}`)).path });
    await ui.activate(n => n.identifier === 'image-picker-use-selection');
    await session.waitFor(nodes => nodes.every(n => n.identifier !== 'image-picker-use-selection')
      && nodes.some(n => n.identifier === 'preview-version' && n.hittable));
    current = await waitForSavedProject(session, p => p.id === before.id && p.revision > before.revision);
    assert.equal(current.revision, before.revision + 1);
    assert.ok(Number.isFinite(current.modifiedAt) && current.modifiedAt >= before.modifiedAt);
    assert.deepEqual(stableContent(current), editedContent(before, p => { p.cues.find(c => c.id === cue).imageId = `v${version}`; }),
      'Only targeted imageId changes; all anchors, timings, prompts, entries, lineage, dates and empty collections remain exact');
    await invariant();
    const afterLoaded = await session.command('loaded-project');
    assert.deepEqual(afterLoaded.project, current);
    assert.equal(afterLoaded.dateReferenceTimeBits.createdAt, beforeLoaded.dateReferenceTimeBits.createdAt,
      'Selection preserves the exact project creation Date bits, not only its millisecond JSON value');
    assert.deepEqual(afterLoaded.dateReferenceTimeBits.images, beforeLoaded.dateReferenceTimeBits.images,
      'Every immutable image creation Date keeps its exact storage bits and order');
    // modifiedAt legitimately changes on this one production edit; its encoded
    // value remains covered by full loaded/saved equality above.
    // Real bytes and decoded preview, not inferred from the saved metadata.
    for (let i = 0; i < 60; i++) {
      const evidence = await session.command('local-image-evidence');
      assert.equal(evidence.projectID, current.id);
      assert.equal(evidence.generationJobCount, 0); assert.equal(evidence.analysisScanning, false);
      for (const asset of current.images) {
        const record = evidence.assets.find(a => a.assetID === asset.id);
        assert.ok(record); assert.equal(record.sha256, asset.sha256); assert.equal(record.byteCount, 73);
        assert.equal(record.decoded, true); assert.equal(record.width, 2); assert.equal(record.height, 2);
      }
      if (evidence.assets.find(a => a.assetID === `v${version}`).visiblePreviewCount > 0) return;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert.fail('Selected version never visibly decoded');
  }
  try {
    const cap = await session.command('capabilities');
    for (const c of ['stage-package-fixture', 'local-image-evidence', 'loaded-project']) assert.ok(cap.commands.includes(c));
    assert.equal(cap.cloudIsolation.network, 'disabled');
    if (withSemanticPrompts) {
      assert.ok(cap.commands.includes('menu-action'));
      assert.ok(cap.semanticMenuActionScopes?.includes('image-inspector-prompt-disclosure'),
        'Explicit semantic mode requires matching compiled inspector disclosure scope');
    }
    await ui.tab('Script'); await session.command('key', { input: 's', modifiers: ['command'] });
    sample = await waitForSavedProject(session, p => p.title === 'YAM MAN');
    const initial = await session.command('loaded-project');
    await check('reject-inputs', async () => {
      for (const request of [{}, { fixture: null }, { fixture: '../image-inspector-invariants-v1' },
        { fixture: packageFixtureToken, path: '/tmp/other.scriv' }, { fixture: packageFixtureToken, text: '{}' },
        { fixture: packageFixtureToken, projectID: sample.id }]) {
        await assert.rejects(session.command('stage-package-fixture', request), /Synthetic package fixture is unavailable or invalid\.?$/);
        assert.deepEqual(await saved(), [sample]); assert.deepEqual(await session.command('loaded-project'), initial);
      }
    });
    await check('stage-without-opening', async () => {
      const staged = await session.command('stage-package-fixture', { fixture: packageFixtureToken });
      assert.deepEqual(Object.keys(staged).sort(), ['fixture', 'projectID', 'title']);
      assert.equal(staged.fixture, packageFixtureToken); assert.match(staged.projectID, /^[A-Fa-f0-9-]{36}$/);
      fixture = packageImageFixture(); fixture.id = staged.projectID;
      assert.equal(staged.title, fixture.title); assert.notEqual(staged.projectID, sample.id);
      assert.deepEqual(await session.command('loaded-project'), initial, 'Staging never opens or modifies the loaded project');
      assert.deepEqual(await saved(), sortedProjects([sample, fixture]));
      await assert.rejects(session.command('stage-package-fixture', { fixture: packageFixtureToken }), /Synthetic package fixture is unavailable or invalid\.?$/);
      assert.deepEqual(await saved(), sortedProjects([sample, fixture]));
    });
    await check('open-exact-package', async () => {
      const opened = await ui.openProject(fixture);
      assert.deepEqual(opened.project, fixture, 'Production package open retains exact literal nil links and anchored overlapping cues');
      current = fixture; await ui.tab('Script'); await invariant();
    });
    await check('gallery-cancel', async () => {
      await seek(1500, 'Foreground', 2); await gallery();
      await ui.activate(n => n.title === 'Cancel' && n.enabled !== undefined);
      await session.waitFor(nodes => nodes.every(n => n.identifier !== 'image-picker-use-selection'));
      await invariant();
    });
    await check('choose-foreground-history', () => selectVersion('foreground', 1));
    if (inspectPromptCases) await check(promptCases[0], () => inspectPrompts(1));
    await check('restore-foreground', () => selectVersion('foreground', 2));
    if (inspectPromptCases) await check(promptCases[1], () => inspectPrompts(2));
    await check('choose-background-successor', async () => { await seek(500, 'Background', 1); await selectVersion('background', 2); });
    await check('overlap-seek', async () => {
      for (const [ms, label] of [[500, 'Background'], [1500, 'Foreground'], [2500, 'Background']]) {
        await seek(ms, label, 2); await invariant();
      }
      assert.equal(current.cues.length, 2); assert.deepEqual(current.cues.map(c => c.authoredDurationMs), [3000, 1000]);
    });
    await check('browser-reopen', async () => {
      const before = await session.command('loaded-project');
      await ui.openProject(sample); assert.deepEqual(await ui.openProject(current), before); await invariant();
    });
    assert.deepEqual(completed, selectedCases);
  } catch (error) { throw new Error(`AUT-J08/package-image-invariants/${step} failed`, { cause: error }); }
  finally { await session.close(); }
}
