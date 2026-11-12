import assert from 'node:assert/strict';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { documentSource, expectedDocument, expectedExport, boundaryDocuments, searchCases } from './script-document-roundtrip-cases.mjs';

// Catalog actions describe these public session calls, not a fabricated fixed
// wire transcript. waitFor repeatedly reads snapshot (50 ms); saved polls only
// persisted-projects (75 ms, retrying only publication-pending). Both use 15 s
// deadlines. No writes are polled/retried and no hidden setup helper is used.
const command = (name, parameters = '{}') => `session.command(${JSON.stringify(name)}, ${parameters})`;
const wait = predicate => `session.waitFor(${predicate}, 15000) [snapshot repeats at 50 ms until true; no mutation]`;
const saved = predicate => `waitForSavedProject(session, ${predicate}, 15000) [persisted-projects repeats at 75 ms; only publication-pending is retryable]`;
const C = command, W = wait, S = saved;
const sorted = projects => [...projects].sort((a, b) => a.id.localeCompare(b.id));
const tabsOf = nodes => nodes.filter(node => node.identifier === 'workspace-tabs' && node.hittable && node.enabled);
const fields = nodes => nodes.filter(node => node.placeholder === 'Find in script');
const uniqueField = nodes => fields(nodes).length === 1 && fields(nodes)[0].hittable && fields(nodes)[0].firstResponder;
const headerIs = (nodes, project) => nodes.some(node => node.identifier === 'workspace-project'
  && node.title === project.title && node.label === project.title + ', Projects' && node.hittable);
const lines = nodes => nodes.filter(node => node.identifier.startsWith('script-line-')).map(node => [node.identifier, node.text]).sort();
const queryButtons = ['Next match', 'Next match', 'Previous match', 'Previous match'];
const definitions = [];
const define = (id, title, actions, marker, description) => {
  const definition = { id: `script-document-${id}`, title, actions, marker, description };
  definitions.push(definition); return definition;
};
const setup = define('setup', 'Save isolated startup', [C('capabilities'), W('one enabled hittable workspace-tabs'),
  C('select', '{target: tabs.path, index: tabs.segments.indexOf("Script")}'), C('key', '{input:"s",modifiers:["command"]}'),
  S('project.title === "YAM MAN" && project.entries.length === 18'), C('persisted-projects'), C('loaded-project')],
  'setup', 'One saved unillustrated synthetic startup project is loaded; matching public import, export and readback routes exist.');
const importDefinition = (id, input, format = 'fountain') => define(`import-${id}`, `Import ${id}`, [C('persisted-projects'),
  C(`import-${format}`, input), S('project.id is absent from beforePackages IDs'), W('headerIs(nodes, imported)'),
  C('persisted-projects'), C('loaded-project')], 'import',
  'Exactly one fresh saved project appears, all earlier packages are unchanged, loaded content equals saved content, and the independently specified document oracle matches.');
const mainImport = importDefinition('document', JSON.stringify({ text: documentSource, filename: 'Document.fountain' }));
const roundImport = importDefinition('roundtrip', '{text: exported.text, filename:"Roundtrip.fountain"}');
const aliasImport = importDefinition('alias-json', '{text: JSON.stringify(aliasInput)}', 'json');
const boundaryImports = boundaryDocuments.map(test => importDefinition(test.key, JSON.stringify({ text: test.text, filename: test.filename })));
const exportDefinition = id => define(`export-${id}`, `Export ${id} twice`, [C('persisted-projects'), C('loaded-project'),
  C('export-fountain'), C('export-fountain'), C('persisted-projects'), C('loaded-project')], 'export',
  'Both actual UTF-8 captures equal the literal expected Fountain bytes, report the exact byte count and successful temporary cleanup, and preserve complete saved/loaded state.');
const mainExport = exportDefinition('document');
const roundExport = exportDefinition('roundtrip');
const boundaryExports = boundaryDocuments.map(test => exportDefinition(test.key));
const searchOpen = define('search-open', 'Open imported script Find', [W('one enabled hittable workspace-tabs'),
  C('select', '{target: tabs.path, index: tabs.segments.indexOf("Script")}'), W('all imported first-scene script lines mounted'),
  C('key', '{input:"f",modifiers:["command"]}'), W('uniqueField(nodes) && searchField.text === ""')],
  'search-open', 'Find opens empty with keyboard focus and all exact imported first-scene display lines still mounted.');
const queryDefinitions = searchCases.map(test => define(`search-${test.key}`, `Find ${test.key}`, [W('uniqueField(nodes)'),
  C('text', `{target: queryField.path, text:${JSON.stringify(test.query)}}`),
  W(`query === ${JSON.stringify(test.query)} && count === ${JSON.stringify(test.counts[0])}`),
  ...queryButtons.flatMap((title, index) => [W(`one hittable enabled ${JSON.stringify(title)} button`),
    C('activate', `{target: ${JSON.stringify(title)} button.path}`),
    W(`query === ${JSON.stringify(test.query)} && count === ${JSON.stringify(test.counts[index + 1])}`)]),
  C('persisted-projects'), C('loaded-project')], 'search-query',
  `The ${test.key} query has exact counts ${test.counts.join(', ')} for initial, Next, Next, Previous, Previous; mounted source lines and complete saved/loaded state are unchanged.`));
const closeDefinitions = ['Close', 'Escape'].map(method => define(`search-cancel-${method.toLowerCase()}`, `Cancel Find with ${method}`,
  [W('uniqueField(nodes)'), C('text', '{target: queryField.path,text:"Nightwatch"}'), W('query === "Nightwatch" && count === "1 / 2"'),
    ...(method === 'Close' ? [W('one hittable enabled "Close" button'), C('activate', '{target: "Close" button.path}')] : [C('key', '{input:"Escape",modifiers:[]}')]),
    W('no Find field or Previous/Next controls'), C('key', '{input:"f",modifiers:["command"]}'),
    W('uniqueField(nodes) && searchField.text === ""'), C('persisted-projects'), C('loaded-project')],
  'search-cancel', 'Closing a nonempty Find through the selected public control removes its controls; reopening resets to empty and preserves all imported content and Date witnesses.'));
const closeFinal = define('search-finish', 'Close Find before imports', [C('key', '{input:"Escape",modifiers:[]}'),
  W('no Find field or Previous/Next controls')], 'search-finish', 'Find is closed before further document imports.');
const rejectedImport = define('reject-filename', 'Reject import traversal component', [C('persisted-projects'), C('loaded-project'),
  C('import-fountain', '{text:"!Do not install.",filename:"../outside.fountain"}'), C('presented-alerts'),
  C('persisted-projects'), C('loaded-project')], 'reject',
  'The bounded import route rejects a path-like filename before presentation or installation and preserves complete saved/loaded state. This is not a production parser rejection or picker cancellation.');
const final = define('final', 'Verify complete document set', [C('persisted-projects'), C('loaded-project')], 'final',
  'Exactly six packages remain: startup, original, roundtrip, alias-JSON, metadata-only and plain text; their complete contents match their saved snapshots.');
export const documentStepDefinitions = definitions;
export const documentStepOrder = [setup, mainImport, mainExport, roundImport, roundExport, aliasImport, searchOpen,
  ...queryDefinitions, ...closeDefinitions, closeFinal, rejectedImport,
  ...boundaryDocuments.flatMap((_, index) => [boundaryImports[index], boundaryExports[index]]), final].map(step => step.id);

// This reads the actual returned document. The expected side is authored above,
// not another invocation of Fountain.parse/export or a copy of its algorithm.
export function assertDocument(project, expected) {
  // WITNESS document begin
  const scenes = [...project.scenes].sort((a, b) => a.order - b.order);
  assert.deepEqual(scenes.map(scene => scene.order), scenes.map((_, index) => index));
  const entries = scenes.flatMap(scene => project.entries.filter(entry => entry.sceneId === scene.id).sort((a, b) => a.order - b.order));
  assert.deepEqual({ title: project.title, scenes: scenes.map(scene => scene.title), entries: entries.map(entry => ({
    scene: scenes.findIndex(scene => scene.id === entry.sceneId), order: entry.order, kind: entry.kind, text: entry.text,
    speaker: project.characters.find(character => character.id === entry.characterId)?.name ?? null,
    duration: entry.ownedDurationMs, coverage: entry.coverageDurationMs,
    words: entry.words.map(({ text, startMs, endMs }) => ({ text, startMs, endMs })),
  })), characters: project.characters.map(({ name, aliases }) => ({ name, aliases })),
  cues: project.cues.map(cue => ({ scene: scenes.findIndex(scene => scene.id === cue.sceneId), label: cue.label,
    startMs: cue.startMs, endMs: cue.endMs })) }, expected, 'Complete supported Fountain payload equals the literal oracle');
  const itemIDs = [...project.scenes, ...project.entries, ...project.characters, ...project.cues].map(item => item.id);
  assert.equal(new Set(itemIDs).size, itemIDs.length, 'Imported scene/entry/character/cue identities are globally distinct');
  const wordIDs = project.entries.flatMap(entry => entry.words.map(word => word.id));
  assert.equal(new Set(wordIDs).size, wordIDs.length);
  for (const id of [...itemIDs, ...wordIDs]) assert.match(id, /^[0-9a-f-]{36}$/i);
  assert.deepEqual(project.images, []); assert.deepEqual(project.audioAssets, []); assert.deepEqual(project.audioClips, []);
  assert.equal(project.audioVolume, 1); assert.equal(project.revision, 0); assert.equal(project.cloudProjectId, undefined);
  // WITNESS document end
}

export async function runDocumentRoundtrip(session) {
  const seen = []; const savedDocuments = []; let aliasLoaded, aliasPackages, sourceLines;
  async function phase(definition, body) {
    const calls = [];
    const action = async (description, callback) => { calls.push(description); return callback(); };
    await body(action);
    assert.deepEqual(calls, definition.actions, `${definition.id}: all public method calls match the catalog order, including repeated calls`);
    seen.push(definition.id);
  }
  let startup;
  await phase(setup, async A => {
    const capabilities = await A(C('capabilities'), () => session.command('capabilities'));
    const nodes = await A(W('one enabled hittable workspace-tabs'), () => session.waitFor(nodes => tabsOf(nodes).length === 1));
    const tabs = tabsOf(nodes)[0]; assert.ok(tabs.segments.includes('Script'));
    await A(setup.actions[2], () => session.command('select', { target: tabs.path, index: tabs.segments.indexOf('Script') }));
    await A(setup.actions[3], () => session.command('key', { input: 's', modifiers: ['command'] }));
    startup = await A(setup.actions[4], () => waitForSavedProject(session, project => project.title === 'YAM MAN' && project.entries.length === 18));
    const packages = await A(C('persisted-projects'), () => session.command('persisted-projects'));
    const loaded = await A(C('loaded-project'), () => session.command('loaded-project'));
    // WITNESS setup begin
    for (const name of ['snapshot', 'key', 'select', 'text', 'activate', 'import-json', 'import-fountain', 'export-fountain', 'persisted-projects', 'loaded-project', 'presented-alerts']) assert.ok(capabilities.commands.includes(name));
    assert.deepEqual(packages, [startup]); assert.deepEqual(loaded.project, startup);
    assert.deepEqual(startup.images, []); assert.ok(startup.cues.every(cue => cue.imageId == null));
    // WITNESS setup end
    savedDocuments.push(startup);
  });
  async function imported(definition, request, expected, format = 'fountain', input) {
    let project;
    await phase(definition, async A => {
      const before = await A(C('persisted-projects'), () => session.command('persisted-projects'));
      const importStartedAt = Date.now();
      const accepted = await A(definition.actions[1], () => session.command(`import-${format}`, request));
      const importReturnedAt = Date.now();
      project = await A(definition.actions[2], () => waitForSavedProject(session, value => !before.some(old => old.id === value.id)));
      await A(definition.actions[3], () => session.waitFor(nodes => headerIs(nodes, project)));
      const after = await A(C('persisted-projects'), () => session.command('persisted-projects'));
      const loaded = await A(C('loaded-project'), () => session.command('loaded-project'));
      // WITNESS import begin
      assert.deepEqual(accepted, { dispatched: true, projectChanged: true });
      assert.equal(after.length, before.length + 1);
      assert.deepEqual(sorted(after.filter(value => value.id !== project.id)), sorted(before));
      assert.deepEqual(loaded.project, project); assertDocument(project, expected);
      if (format === 'json') aliasLoaded = structuredClone(loaded);
      if (input) {
        assert.notEqual(project.id, input.id, 'JSON import creates its own document identity');
        assert.equal(input.revision, 17); assert.equal(project.revision, 0, 'Nonzero input revision resets to zero');
        assert.equal(input.createdAt, 1600000000000); assert.equal(input.modifiedAt, 1600000001000);
        assert.notEqual(project.createdAt, input.createdAt); assert.notEqual(project.modifiedAt, input.modifiedAt);
        assert.equal(project.createdAt, project.modifiedAt, 'Both imported dates reset to the same new millisecond');
        assert.ok(Number.isFinite(project.createdAt) && project.createdAt >= importStartedAt - 1
          && project.createdAt <= importReturnedAt + 1, 'Import dates are within the actual synchronous import window, allowing millisecond rounding');
        assert.deepEqual(project, { ...input, id: project.id, revision: 0, createdAt: project.createdAt, modifiedAt: project.modifiedAt }, 'Only documented identity/date/revision fields change on JSON import');
      }
      // WITNESS import end
      savedDocuments.push(project);
    });
    return project;
  }
  async function exported(definition, expected) {
    let captured;
    await phase(definition, async A => {
      const before = await A(C('persisted-projects'), () => session.command('persisted-projects'));
      const loaded = await A(C('loaded-project'), () => session.command('loaded-project'));
      captured = await A(C('export-fountain'), () => session.command('export-fountain'));
      const repeated = await A(C('export-fountain'), () => session.command('export-fountain'));
      const after = await A(C('persisted-projects'), () => session.command('persisted-projects'));
      const loadedAfter = await A(C('loaded-project'), () => session.command('loaded-project'));
      // WITNESS export begin
      assert.deepEqual(captured, { dispatched: true, text: expected, byteCount: Buffer.byteLength(expected, 'utf8'), cleanupVerified: true });
      assert.deepEqual(repeated, captured, 'Independent repeated export is deterministic and cleans up each time');
      assert.deepEqual(sorted(after), sorted(before)); assert.deepEqual(loadedAfter, loaded, 'Export preserves complete model and Date storage witnesses');
      // WITNESS export end
    });
    return captured;
  }
  const original = await imported(mainImport, { text: documentSource, filename: 'Document.fountain' }, expectedDocument);
  const exportedText = await exported(mainExport, expectedExport);
  const roundtrip = await imported(roundImport, { text: exportedText.text, filename: 'Roundtrip.fountain' }, expectedDocument);
  // Generated identities deliberately change between Fountain documents.
  assert.notEqual(roundtrip.id, original.id);
  await exported(roundExport, expectedExport);
  const aliasInput = structuredClone(original);
  aliasInput.title = 'Midnight aliases'; aliasInput.characters[0].aliases = ['Nightwatch'];
  aliasInput.revision = 17; aliasInput.createdAt = 1600000000000; aliasInput.modifiedAt = 1600000001000;
  const aliasExpected = { ...expectedDocument, title: aliasInput.title, characters: [{ name: 'Mara', aliases: ['Nightwatch'] }] };
  const aliasProject = await imported(aliasImport, { text: JSON.stringify(aliasInput) }, aliasExpected, 'json', aliasInput);
  // Capture saved/loaded baselines from already required import calls without
  // unlisted readback calls; use the complete saved content oracle thereafter.
  aliasPackages = savedDocuments.map(value => structuredClone(value));
  // WITNESS search-observe begin
  async function unchanged(A) {
    const packages = await A(C('persisted-projects'), () => session.command('persisted-projects'));
    const loaded = await A(C('loaded-project'), () => session.command('loaded-project'));
    assert.deepEqual(sorted(packages), sorted(aliasPackages));
    assert.deepEqual(loaded, aliasLoaded, 'Find preserves exact loaded model and Date storage witnesses');
  }
  async function counted(A, query, count, description) {
    const nodes = await A(description, () => session.waitFor(nodes => {
      if (!uniqueField(nodes) || fields(nodes)[0].text !== query) return false;
      const row = fields(nodes)[0].path.slice(0, fields(nodes)[0].path.lastIndexOf('.'));
      const labels = nodes.filter(node => node.path.slice(0, node.path.lastIndexOf('.')) === row && /Label/.test(node.type));
      return labels.length === 1 && labels[0].text === count;
    }));
    assert.deepEqual(lines(nodes), sourceLines, 'Search preserves every mounted first-scene source line');
    return nodes;
  }
  // WITNESS search-observe end
  async function activate(A, title, observeDescription, dispatchDescription) {
    const candidates = nodes => nodes.filter(node => (node.label === title || node.title === title) && node.hittable && node.enabled);
    const nodes = await A(observeDescription, () => session.waitFor(nodes => candidates(nodes).length === 1));
    await A(dispatchDescription, () => session.command('activate', { target: candidates(nodes)[0].path }));
  }
  await phase(searchOpen, async A => {
    const nodes = await A(searchOpen.actions[0], () => session.waitFor(nodes => tabsOf(nodes).length === 1));
    const tabs = tabsOf(nodes)[0];
    await A(searchOpen.actions[1], () => session.command('select', { target: tabs.path, index: tabs.segments.indexOf('Script') }));
    const entries = aliasProject.entries.filter(entry => entry.sceneId === aliasProject.scenes[0].id);
    const mounted = await A(searchOpen.actions[2], () => session.waitFor(nodes => lines(nodes).length === entries.length && entries.every(entry => nodes.some(node => node.identifier === `script-line-${entry.id}` && node.text === entry.text))));
    sourceLines = lines(mounted);
    await A(searchOpen.actions[3], () => session.command('key', { input: 'f', modifiers: ['command'] }));
    const opened = await A(searchOpen.actions[4], () => session.waitFor(nodes => uniqueField(nodes) && fields(nodes)[0].text === ''));
    // WITNESS search-open begin
    assert.equal(fields(opened)[0].text, ''); assert.equal(fields(opened)[0].firstResponder, true);
    assert.deepEqual(lines(opened), sourceLines);
    assert.ok(aliasProject.entries.every(entry => !entry.text.toLowerCase().includes('mara') && !entry.text.toLowerCase().includes('nightwatch')), 'Name/alias queries cannot pass via source text');
    // WITNESS search-open end
  });
  // WITNESS search-query begin
  for (const [index, test] of searchCases.entries()) {
    const definition = queryDefinitions[index];
    await phase(definition, async A => {
      const nodes = await A(definition.actions[0], () => session.waitFor(uniqueField));
      await A(definition.actions[1], () => session.command('text', { target: fields(nodes)[0].path, text: test.query }));
      await counted(A, test.query, test.counts[0], definition.actions[2]);
      for (let position = 0; position < queryButtons.length; position++) {
        await activate(A, queryButtons[position], definition.actions[3 + position * 3], definition.actions[4 + position * 3]);
        await counted(A, test.query, test.counts[position + 1], definition.actions[5 + position * 3]);
      }
      await unchanged(A);
    });
  }
  // WITNESS search-query end
  // WITNESS search-cancel begin
  for (const [index, method] of ['Close', 'Escape'].entries()) {
    const definition = closeDefinitions[index];
    await phase(definition, async A => {
      const nodes = await A(definition.actions[0], () => session.waitFor(uniqueField));
      await A(definition.actions[1], () => session.command('text', { target: fields(nodes)[0].path, text: 'Nightwatch' }));
      await counted(A, 'Nightwatch', '1 / 2', definition.actions[2]);
      let next = 3;
      if (method === 'Close') { await activate(A, 'Close', definition.actions[next++], definition.actions[next++]); }
      else await A(definition.actions[next++], () => session.command('key', { input: 'Escape', modifiers: [] }));
      await A(definition.actions[next++], () => session.waitFor(closed));
      await A(definition.actions[next++], () => session.command('key', { input: 'f', modifiers: ['command'] }));
      const reopened = await A(definition.actions[next++], () => session.waitFor(nodes => uniqueField(nodes) && fields(nodes)[0].text === ''));
      assert.equal(fields(reopened)[0].text, '', `${method} clears the query instead of preserving stale results`);
      assert.deepEqual(lines(reopened), sourceLines); await unchanged(A);
    });
  }
  // WITNESS search-cancel end
  function closed(nodes) { return fields(nodes).length === 0 && !nodes.some(node => ['Next match', 'Previous match'].includes(node.label)); }
  await phase(closeFinal, async A => {
    await A(closeFinal.actions[0], () => session.command('key', { input: 'Escape', modifiers: [] }));
    // WITNESS search-finish begin
    const nodes = await A(closeFinal.actions[1], () => session.waitFor(closed)); assert.ok(closed(nodes));
    // WITNESS search-finish end
  });
  await phase(rejectedImport, async A => {
    const before = await A(C('persisted-projects'), () => session.command('persisted-projects'));
    const loaded = await A(C('loaded-project'), () => session.command('loaded-project'));
    // WITNESS reject begin
    await A(rejectedImport.actions[2], () => assert.rejects(session.command('import-fountain', { text: '!Do not install.', filename: '../outside.fountain' }), /^Error: import-fountain: Synthetic script import is unavailable or invalid\.$/));
    const alerts = await A(C('presented-alerts'), () => session.command('presented-alerts'));
    const after = await A(C('persisted-projects'), () => session.command('persisted-projects'));
    const loadedAfter = await A(C('loaded-project'), () => session.command('loaded-project'));
    assert.deepEqual(alerts, []); assert.deepEqual(sorted(after), sorted(before)); assert.deepEqual(loadedAfter, loaded);
    // WITNESS reject end
  });
  for (const [index, test] of boundaryDocuments.entries()) {
    await imported(boundaryImports[index], { text: test.text, filename: test.filename }, test.expected);
    await exported(boundaryExports[index], test.exported);
  }
  await phase(final, async A => {
    const packages = await A(C('persisted-projects'), () => session.command('persisted-projects'));
    const loaded = await A(C('loaded-project'), () => session.command('loaded-project'));
    // WITNESS final begin
    assert.equal(packages.length, 6); assert.deepEqual(sorted(packages), sorted(savedDocuments));
    assert.deepEqual(loaded.project, savedDocuments.at(-1));
    // WITNESS final end
  });
  assert.deepEqual(seen, documentStepOrder, 'Every complete named phase ran once in its declared order');
  return { status: 'passed', phases: seen };
}
