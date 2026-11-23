import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { fountainSteps } from './support/fountain-steps.mjs';
import { importCases, metadataSource, forcedSource, invalidFilenames, openingLines } from './support/fountain-cases.mjs';
import { verifyPackageExport } from './support/package-export-steps.mjs';

// IJ-02, with independently selectable Fountain and project package cases.
// Installation uses production importScript validation. Exports use Scriv's
// normal staging, handoff and cleanup. The platform picker and final destination
// are outside these semantic routes. JSON validation has its own journey.
const texts = project => project.entries.map(entry => entry.text);
const scenes = project => project.scenes.map(scene => scene.title);
const owned = project => project.entries.map(entry => entry.ownedDurationMs);
const directionCoverage = project => project.entries.filter(entry => entry.kind === 'direction').map(entry => entry.coverageDurationMs);
const fields = project => ({ scenes: scenes(project), text: texts(project),
  kind: project.entries.map(entry => entry.kind), coverage: project.entries.map(entry => entry.coverageDurationMs) });
const invalidImports = [
  {}, { text: null }, { text: 1 }, { text: ['!Wait.'] },
  { text: '!Wait.', path: '/not-an-import-input' },
  { text: '!Wait.', name: 'not-an-import-input.fountain' },
  { text: '!Wait.', url: 'file:///not-an-import-input' },
  { text: 'a'.repeat(64 * 1024 + 1) }, { text: '🎬'.repeat(16 * 1024 + 1) },
];
const invalidExports = sample => [
  { path: '/not-an-export-destination' }, { url: 'file:///not-an-export-destination' },
  { name: 'NotAnExport.fountain' }, { text: 'Title: Not input' }, { projectID: sample.id },
];
const groups = ['roundtrip', 'import', 'filename', 'package'];
const args = process.argv.slice(2);
let selected = groups;
if (args.includes('--group')) {
  const value = args[args.indexOf('--group') + 1];
  assert.ok(groups.includes(value), `--group must be one of: ${groups.join(', ')}`);
  selected = [value];
}
assert.ok(args.every((arg, index) => arg === '--list-cases' || arg === '--group'
  || (args[index - 1] === '--group' && groups.includes(arg))), 'Unknown argument');
const manifest = [
  ...Array.from({ length: 5 }, (_, index) => ({ group: 'roundtrip', id: `reject-export-${index + 1}` })),
  ...['sample', 'metadata', 'multiline-title', 'forced-action'].map(id => ({ group: 'roundtrip', id })),
  ...invalidImports.map((_, index) => ({ group: 'import', id: `reject-import-${index + 1}` })),
  ...importCases.map((fixture, index) => ({ group: 'import', id: `fixture-${index + 1}`, legacy: fixture.id, name: fixture.name })),
  ...invalidFilenames.map((_, index) => ({ group: 'filename', id: `reject-filename-${index + 1}` })),
  { group: 'filename', id: 'metadata-fallback' },
  ...openingLines.map((_, index) => ({ group: 'filename', id: `opening-colon-${index + 1}` })),
  { group: 'package', id: 'saved-media-and-history' },
].filter(test => selected.includes(test.group));
if (args.includes('--list-cases')) {
  // Authorship inventory only: does not launch the app or claim native passes.
  console.log(JSON.stringify({ journey: 'IJ-02', nativeVerified: false, groups, cases: manifest }, null, 2));
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const step = fountainSteps(session);
  let currentCase = 'setup';
  const completed = [];
  async function run(group, id, body) {
    currentCase = `${group}/${id}`;
    await body(); // No automatic mutation retries.
    completed.push(currentCase);
    console.log(`PASS: IJ-02/${currentCase}`);
  }
  try {
    const capabilities = await session.command('capabilities');
    for (const command of ['import-fountain', 'persisted-projects', ...(selected.includes('roundtrip') ? ['export-fountain'] : []),
      ...(selected.includes('package') ? ['export-project'] : [])]) {
      assert.ok(capabilities.commands.includes(command), `Requires compiled ${command} support`);
    }
    const nodes = await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.enabled && node.hittable));
    const tabs = nodes.find(node => node.identifier === 'workspace-tabs');
    const scriptIndex = tabs.segments.indexOf('Script');
    assert.ok(scriptIndex >= 0, 'Actual Script tab exists');
    if (tabs.selected !== scriptIndex) await session.command('select', { target: tabs.identifier, index: scriptIndex });
    await session.command('key', { input: 's', modifiers: ['command'] });
    const sample = await waitForSavedProject(session, project => project.entries.length > 0);
    assert.equal((await step.saved()).length, 1, 'Fresh isolated journey starts with exactly one saved sample');
    assert.equal(sample.title, 'YAM MAN', 'Use the production startup sample');

    if (selected.includes('roundtrip')) {
      for (const [index, request] of invalidExports(sample).entries()) {
        await run('roundtrip', `reject-export-${index + 1}`, () => step.reject('export-fountain', request));
      }
      let exportedSample;
      let sampleRoundTrip;
      await run('roundtrip', 'sample', async () => {
        exportedSample = await step.exportText(sample);
        assert.equal(await step.exportText(sample), exportedSample, 'Independent repeat capture/cleanup is deterministic');
        sampleRoundTrip = await step.importText(exportedSample);
        assert.equal(sampleRoundTrip.title, sample.title);
        assert.deepEqual(texts(sampleRoundTrip), texts(sample));
        assert.deepEqual(owned(sampleRoundTrip), owned(sample));
        assert.deepEqual(directionCoverage(sampleRoundTrip), directionCoverage(sample));
      });
      await run('roundtrip', 'metadata', async () => {
        const metadata = await step.importText(metadataSource);
        assert.equal(metadata.title, 'First line\nSecond line');
        assert.equal(metadata.scenes.length, 1);
        assert.deepEqual(texts(metadata), ['The car arrives.']);
        assert.deepEqual(metadata.characters, []);
        const exported = await step.exportText(metadata);
        assert.equal(await step.exportText(metadata), exported, 'Capture retains neither previous project nor previous export');
        const roundTrip = await step.importText(exported);
        assert.equal(roundTrip.title, metadata.title);
        assert.deepEqual(texts(roundTrip), texts(metadata));
        const saved = await step.saved();
        assert.equal(saved.length, 4, 'Original sample and three accepted imports');
        for (const expected of [sample, sampleRoundTrip, metadata, roundTrip]) {
          assert.deepEqual(saved.find(project => project.id === expected.id), expected);
        }
      });
      await run('roundtrip', 'multiline-title', async () => {
        assert.ok(exportedSample.startsWith('Title: YAM MAN\n'), 'Exact known startup export header');
        // Change only the synthetic file header; never set a model property.
        const input = 'Title:\n    First line\n    \n    Third line' + exportedSample.slice('Title: YAM MAN'.length);
        const source = await step.importText(input);
        assert.equal(source.title, 'First line\n\nThird line');
        assert.deepEqual(texts(source), texts(sample));
        assert.deepEqual(scenes(source), scenes(sample));
        const roundTrip = await step.importText(await step.exportText(source));
        assert.equal(roundTrip.title, source.title);
        assert.deepEqual(texts(roundTrip), texts(source));
        assert.deepEqual(scenes(roundTrip), scenes(source));
      });
      await run('roundtrip', 'forced-action', async () => {
        const source = await step.importText(forcedSource);
        assert.equal(source.title, 'Forced');
        assert.deepEqual(fields(source), { scenes: ['A custom scene name'],
          text: ['RUN\nDo not look back.', 'INT. is a direction here, not a scene.', '@camera stays still'],
          kind: ['direction', 'direction', 'direction'], coverage: [86400000, 1000, 3000] });
        assert.deepEqual(owned(source), [2000, 1000, 0]);
        const roundTrip = await step.importText(await step.exportText(source));
        assert.deepEqual(fields(roundTrip), fields(source), 'Every original scene/text/kind/coverage oracle');
        assert.deepEqual((await step.saved()).find(project => project.id === sample.id), sample);
      });
      assert.equal((await step.saved()).length, 8, 'Sample plus seven round-trip group imports');
    }
    if (selected.includes('import')) {
      const before = await step.saved();
      for (const [index, request] of invalidImports.entries()) {
        await run('import', `reject-import-${index + 1}`, () => step.reject('import-fountain', request));
      }
      for (const [index, fixture] of importCases.entries()) {
        await run('import', `fixture-${index + 1}`, async () => {
          const project = await step.importText(fixture.text);
          fixture.verify(project);
        });
      }
      assert.equal((await step.saved()).length, before.length + 18, 'Exactly 18 actual-app fixture imports');
      // Independent --group import retains the original absolute 19-package oracle.
      if (selected.length === 1) assert.equal((await step.saved()).length, 19);
    }
    if (selected.includes('filename')) {
      for (const [index, filename] of invalidFilenames.entries()) {
        await run('filename', `reject-filename-${index + 1}`, () => step.reject('import-fountain', { text: '!Wait.', filename }));
      }
      await run('filename', 'metadata-fallback', async () => {
        const project = await step.importText('Draft date: 2026-10-30\nAuthor: A Writer\n\nINT. OFFICE - DAY\n\nAuthor: This is an action in the screenplay.\n\n@WRITER\nTitle: These are spoken words.\n', { filename: 'Filename fallback.fountain' });
        assert.equal(project.title, 'Filename fallback');
        assert.equal(project.scenes.length, 1);
        assert.deepEqual(texts(project), ['Author: This is an action in the screenplay.', 'Title: These are spoken words.']);
        assert.deepEqual(project.entries.map(entry => entry.kind), ['direction', 'dialogue']);
      });
      for (const [index, opening] of openingLines.entries()) {
        await run('filename', `opening-colon-${index + 1}`, async () => {
          const project = await step.importText(opening + '\n\nThe door opens.', { filename: 'Plain text.fountain' });
          assert.equal(project.title, 'Plain text');
          assert.deepEqual(texts(project), [opening, 'The door opens.']);
        });
      }
    }
    if (selected.includes('package')) {
      await run('package', 'saved-media-and-history', () => verifyPackageExport(session, step));
    }
    currentCase = 'final-preservation';
    assert.deepEqual((await step.saved()).find(project => project.id === sample.id), sample);
    assert.deepEqual(completed, manifest.map(test => `${test.group}/${test.id}`), 'Every declared selected case executed');
    assert.equal((await step.saved()).length, 1 + (selected.includes('roundtrip') ? 7 : 0)
      + (selected.includes('import') ? 18 : 0) + (selected.includes('filename') ? 5 : 0)
      + (selected.includes('package') ? 1 : 0));
    console.log('PASS: IJ-02 local import and export boundaries');
  } catch (error) {
    console.error(`FAIL: IJ-02/${currentCase}`);
    throw error;
  } finally { await session.close(); }
}
