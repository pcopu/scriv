import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { characterCatalogSteps, inspectCreationEntries, named, same, ribbons, search, ribbonIDs } from './support/character-catalog-steps.mjs';
import { catalogCases, fixtures } from './support/character-catalog-cases.mjs';
import { mentionCatalogCases } from './support/character-mention-cases.mjs';
import { runMentionDetection } from './support/character-mention-steps.mjs';
import { observePresentedAlert } from '../support/presented-error.mjs';

// AUT-J05 catalog portion: actual UIKit create → validate → save → find →
// reopen/edit → clear/restore → cancel. Independent workflows launch fresh apps;
// they share controls and case data, never invoke old scenario scripts.
// Alias alerts, dirty-discard resolution, deletion, conflicts/leases, relaunch,
// keyboard Return and physical gestures remain outside this candidate.
// Prior native slice evidence does not certify this consolidated runner.
// The mention-detection group is the AUT-J06 initial-proposal companion; it
// imports exact catalogs and authors source through the actual Script editor.

async function createFindReopen(session) {
  const { saved, control, activate, text, saveEnabled, editorClosed, openCatalog } = characterCatalogSteps(session);
  await openCatalog();
  const baseline = await saved(project => project.characters.length > 0);
  const originalCharacters = structuredClone(baseline.characters);
  const unchanged = project => project.id === baseline.id
    && JSON.stringify(project.characters) === JSON.stringify(originalCharacters);

  // Opening and cancelling creation must never persist a placeholder character.
  await activate('Add character');
  await control(node => node.placeholder === 'Name' && node.text === '');
  await saveEnabled(false);
  await activate('Cancel');
  await editorClosed();
  await saved(unchanged);
  await activate('Add character');
  await control(node => node.placeholder === 'Name' && node.text === '');
  await text('Name', '   ');
  await saveEnabled(false);
  const overlong = fixtures.invalidASCIIName;
  await text('Name', overlong);
  await saveEnabled(true);
  await activate('Save character');
  await session.waitFor(nodes => nodes.some(node => node.text === 'Enter a character name of 1–200 characters.')
    && nodes.some(node => node.placeholder === 'Name' && node.text === overlong));
  await saved(unchanged);

  // Restore the original blank draft before Cancel. Dirty-draft alert actions
  // are deliberately not claimed by this candidate.
  await text('Name', '');
  await saveEnabled(false);
  await activate('Cancel');
  await editorClosed();
  await saved(unchanged);
  await activate('Add character');
  await control(node => node.placeholder === 'Name' && node.text === '');
  const characterName = fixtures.createdName;
  await text('Name', characterName);
  await saveEnabled(true);
  await activate('Save character');
  await editorClosed();
  const created = await saved(project => project.id === baseline.id
    && project.characters.length === originalCharacters.length + 1
    && project.characters.some(character => character.name === characterName));
  const character = created.characters.find(character => character.name === characterName);

  // Search routes through UISearchBar's actual text callback. Verify both the
  // empty state and restoration, then case-insensitive matching and Edit reopen.
  await text('Search characters', fixtures.missingSearch);
  await session.waitFor(nodes => nodes.some(node => node.text === 'No matching characters') && ribbons(nodes).length === 0);
  await activate('Clear search');
  await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Search characters' && node.text === '')
    && ribbons(nodes).length === created.characters.length);
  await text('Search characters', characterName.toLowerCase());
  await session.waitFor(nodes => ribbons(nodes).length === 1 && ribbons(nodes)[0].label === characterName);
  const card = await control(node => node.identifier === `character-ribbon-${character.id}`);
  await session.command('activate', { target: card.path });
  await activate('Edit');
  await control(node => node.placeholder === 'Name' && node.text === characterName);
  await saveEnabled(true);
  await activate('Cancel');
  await editorClosed();
  await activate('Edit');
  await control(node => node.placeholder === 'Name' && node.text === characterName);
  await activate('Cancel');
  await editorClosed();
  const after = await saved(project => project.id === baseline.id && project.characters.some(item => item.id === character.id));
  assert.deepEqual(after.characters, created.characters, 'Clean cancel/reopen does not mutate saved character profiles');

  const packages = await session.command('persisted-projects');
  await activate('Edit');
  await control(node => node.placeholder === 'Name' && node.text === characterName);
  await text('Name', fixtures.unsavedName);
  await activate('Cancel');
  await observePresentedAlert(session, {
    title: 'Discard character changes?',
    message: 'Your changes have not been saved.',
    actions: [
      { title: 'Keep editing', enabled: true, style: 'cancel' },
      { title: 'Discard changes', enabled: true, style: 'destructive' },
    ],
  });
  assert.deepEqual(await session.command('persisted-projects'), packages, 'Presenting dirty Cancel preserves saved packages');
}

async function editProfile(session) {
  const { saved, locate, activate, text, openCatalog, rememberOpeningPalette, inspectEditor,
    saveEditor, cancelCleanEditor, nameField, searchField, biographyField, appearanceField } = characterCatalogSteps(session);
  await openCatalog();
  const baseline = await saved(project => project.characters.length > 0);
  const initial = fixtures.initialProfile;
  assert.ok(baseline.characters.every(character => [character.name, ...character.aliases]
    .every(value => !value.includes(initial.name))), 'The synthetic fixture does not already match the new character');
  assert.notEqual(initial.biography, initial.biography.normalize('NFC'), 'Fixture uses a decomposed combining accent');

  await activate('Add character');
  await rememberOpeningPalette();
  for (const predicate of [nameField, biographyField, appearanceField]) {
    assert.equal((await locate(predicate, 'new empty profile field')).text, '', 'New profile fields start empty');
  }
  const initialDraft = { ...initial, name: `  ${initial.name}  ` };
  await text(nameField, initialDraft.name, 'new character name with outer spaces');
  await text(biographyField, initial.biography, 'new Biography');
  await text(appearanceField, initial.appearance, 'new Appearance');
  await activate('Purple character colour');
  await activate('Pink character colour'); // Re-rendered palette controls remain usable.
  await inspectEditor(initialDraft);
  await saved(project => project.id === baseline.id && same(project.characters, baseline.characters)
    && same(project.entries, baseline.entries));
  await saveEditor();
  const created = await saved(project => project.id === baseline.id
    && project.characters.length === baseline.characters.length + 1
    && project.characters.some(character => character.name === initial.name
      && Object.entries(initial).every(([key, value]) => character[key] === value)));
  const character = created.characters.find(character => character.name === initial.name);
  assert.deepEqual(character.aliases, [], 'No alias is invented by profile creation');
  assert.deepEqual(created.characters.filter(item => item.id !== character.id), baseline.characters,
    'Creating the profile preserves every existing character');
  inspectCreationEntries(baseline.entries, created.entries, baseline.characters);

  async function persisted(expected) {
    const project = await saved(project => project.id === baseline.id
      && Object.entries(expected).every(([key, value]) => project.characters.find(item => item.id === character.id)?.[key] === value));
    assert.deepEqual(project.characters, created.characters.map(item => item.id === character.id
      ? { ...item, ...expected } : item), 'Only this character’s intended profile fields change');
    assert.deepEqual(project.entries, created.entries,
      'Later profile changes preserve every entry field and all explicit or materialized link metadata');
    return project;
  }
  async function reopen(expected) {
    await text(searchField, initial.name, 'character search');
    const expectedRibbon = `character-ribbon-${character.id}`;
    await session.waitFor(nodes => same(nodes.filter(node => node.identifier?.startsWith('character-ribbon-'))
      .map(node => node.identifier), [expectedRibbon]));
    const ribbon = await locate(node => node.identifier === expectedRibbon && node.enabled === true, 'saved character ribbon');
    await session.command('activate', { target: ribbon.path });
    await activate('Edit');
    await rememberOpeningPalette();
    await inspectEditor(expected);
  }
  async function rejectSave(issue, predicate, value, expected) {
    await activate('Save character');
    await session.waitFor(nodes => nodes.some(node => node.text === issue)
      && nodes.filter(predicate).length === 1 && nodes.find(predicate).text === value
      && nodes.some(node => named(node, 'Save character') && node.enabled === true));
    await persisted(expected);
  }

  await persisted(initial);
  await reopen(initial);
  // Errors appear in the real form rather than an alert. Invalid edits stay in
  // the mounted draft, and the app-owned saved package must remain unchanged.
  const overlongName = fixtures.invalidUnicodeName;
  assert.equal(overlongName.length, 202, 'Name limit fixture uses 202 UTF-16 units, not 101 code points');
  await text(nameField, overlongName, 'overlong Unicode name');
  await rejectSave('Enter a character name of 1–200 characters.', nameField, overlongName, initial);
  await text(nameField, initial.name, 'restored name');
  const overlongAppearance = fixtures.invalidAppearance;
  await text(appearanceField, overlongAppearance, 'overlong Appearance');
  await rejectSave('Biography and image direction can each contain up to 20,000 characters. Your draft has not been truncated.',
    appearanceField, overlongAppearance, initial);
  await text(appearanceField, initial.appearance, 'restored Appearance');

  // The frozen validator fixture is below the field limit, but JSON must escape
  // every U+0001 unit. This local size check characterizes the input only; the
  // actual form's distinct encoded-size error is the acceptance observation.
  const oversizedEncodedBiography = fixtures.encodedBiography;
  assert.equal(oversizedEncodedBiography.length, 12_000, 'Encoded-size fixture stays below the 20,000 UTF-16 field limit');
  assert.ok(Buffer.byteLength(JSON.stringify(oversizedEncodedBiography), 'utf8') > 65_536,
    'The fixture’s JSON string alone exceeds 64 KiB through required control-character escapes');
  await text(biographyField, oversizedEncodedBiography, 'encoded-size Biography containing exact U+0001 units');
  assert.equal((await locate(biographyField, 'untruncated control-character Biography')).text, oversizedEncodedBiography,
    'Native UITextView retains all 12,000 original U+0001 code units before Save');
  await persisted(initial);
  await rejectSave("This character's complete profile exceeds 64 KiB. Shorten its notes before saving; the draft remains here.",
    biographyField, oversizedEncodedBiography, initial);
  await text(biographyField, initial.biography, 'restored Biography after encoded-size rejection');
  await inspectEditor(initial);
  await cancelCleanEditor(); // All edits restored: never enter dirty-discard UI.
  await persisted(initial);

  const edited = { ...initial,
    biography: '  Keeps the cafe\u0301 ledger.\n\n台詞 and 👩🏽‍🚀 stay exact.  \n',
    appearance: 'Warm light\nBlue jacket; caf\u00e9 buttons.\n  Soft shadows.  ', color: 'FF7E21' };
  await reopen(initial);
  await text(biographyField, edited.biography, 'edited Biography');
  await text(appearanceField, edited.appearance, 'edited Appearance');
  await activate('Orange character colour');
  await inspectEditor(edited);
  await persisted(initial); // Neither text view nor palette publishes a draft.
  await saveEditor();
  await persisted(edited);
  await reopen(edited);
  await saveEditor(); // Re-saving an unchanged profile does not truncate notes.
  await persisted(edited);

  const cleared = { ...edited, biography: '', appearance: '', color: '69C581' };
  await reopen(edited);
  await text(biographyField, '', 'cleared Biography');
  await text(appearanceField, '', 'cleared Appearance');
  await activate('Green character colour');
  await inspectEditor(cleared);
  await persisted(edited);
  await saveEditor();
  await persisted(cleared);
  await reopen(cleared);
  await cancelCleanEditor();
  await persisted(cleared);

  // Re-entering the original exact notes after a clear must not resurrect any
  // discarded draft or lose the decomposed accent, spaces or trailing newline.
  await reopen(cleared);
  await text(biographyField, initial.biography, 'restored exact Biography');
  await text(appearanceField, initial.appearance, 'restored exact Appearance');
  await activate('Pink character colour');
  await inspectEditor(initial);
  await persisted(cleared);
  await saveEditor();
  await persisted(initial);
  for (let attempt = 0; attempt < 2; attempt++) {
    await reopen(initial);
    await cancelCleanEditor();
    await persisted(initial);
  }

  // A spelling-only normalization change is authored text too. Establish both
  // fields with decomposed accents, then change just one field at a time. An
  // unrelated colour/name edit must not hide an equality-based no-op save.
  const canonicalSource = { ...initial, appearance: 'Warm light; cafe\u0301 buttons.\n' };
  await reopen(initial);
  await text(appearanceField, canonicalSource.appearance, 'decomposed Appearance setup');
  await saveEditor();
  await persisted(canonicalSource);
  let prior = canonicalSource;
  for (const [field, predicate] of [['biography', biographyField], ['appearance', appearanceField]]) {
    const canonical = { ...prior, [field]: prior[field].normalize('NFC') };
    assert.notEqual(canonical[field], prior[field], `${field}: composed edit changes exact UTF-16 content`);
    assert.equal(canonical[field].normalize('NFD'), prior[field].normalize('NFD'),
      `${field}: the only change is Unicode normalization`);
    await reopen(prior);
    await text(predicate, canonical[field], `canonical-only ${field} edit`);
    await inspectEditor(canonical);
    await persisted(prior);
    await saveEditor();
    try {
      await persisted(canonical);
    } catch (error) {
      throw new Error(`Canonical-only ${field} replacement did not persist exact UTF-16 content after native Save; canonical equality is not sufficient`, { cause: error });
    }
    await reopen(canonical);
    await cancelCleanEditor();
    await persisted(canonical);
    prior = canonical;
  }
}

async function searchFocus(session) {
  const { openCatalog, escapeState } = characterCatalogSteps(session);
  await openCatalog({ persist: false });
  let nodes = await session.waitFor(nodes => search(nodes).length === 1 && search(nodes)[0].enabled && search(nodes)[0].hittable
    && ribbons(nodes).some(node => node.label === 'Randy') && ribbons(nodes).some(node => node.label === 'Miyazaki'));
  const baseline = ribbonIDs(nodes);
  assert.equal(search(nodes)[0].text, '', 'Fresh Characters search is empty');

  // Repeat the whole flow to catch focus and stale-filter regressions on reuse.
  for (let pass = 0; pass < 2; pass++) {
    const field = search(await session.command('snapshot'))[0];
    await session.command('text', { target: field.path, text: 'Miya' });
    nodes = await session.waitFor(nodes => search(nodes).some(node => node.text === 'Miya' && node.firstResponder)
      && ribbons(nodes).some(node => node.label === 'Miyazaki')
      && !ribbons(nodes).some(node => node.label === 'Randy'));
    assert.ok(ribbonIDs(nodes).length < baseline.length, 'Search removes nonmatching characters');
    await escapeState(true);
    await session.command('key', { input: 'Escape', modifiers: [] });
    nodes = await session.waitFor(nodes => search(nodes).some(node => node.text === '' && !node.firstResponder)
      && ribbons(nodes).some(node => node.label === 'Randy')
      && JSON.stringify(ribbonIDs(nodes)) === JSON.stringify(baseline));
    assert.deepEqual(ribbonIDs(nodes), baseline, 'Escape restores every character, not merely the field text');
    await escapeState(false); // Observe canPerformAction directly, not chain absence.
  }
}

const workflows = { 'create-find-reopen': createFindReopen, 'edit-profile': editProfile, 'search-focus': searchFocus,
  'mention-detection': runMentionDetection };
let selected = Object.keys(workflows);
let listCases = false;
let groupSeen = false;
const args = process.argv.slice(2);
for (let index = 0; index < args.length; index++) {
  if (args[index] === '--list-cases') { listCases = true; continue; }
  assert.equal(args[index], '--group', `Unknown argument: ${args[index]}`);
  assert.equal(groupSeen, false, 'Use --group only once');
  groupSeen = true;
  const group = args[++index];
  assert.ok(Object.hasOwn(workflows, group), `--group must be one of: ${Object.keys(workflows).join(', ')}`);
  selected = [group];
}
if (listCases) {
  const characterEditorSource = 'apps/catalyst/ScrivUIKit/Characters/CharacterEditorController.swift';
  console.log(JSON.stringify({ journey: selected.length === 1 && selected[0] === 'mention-detection' ? 'AUT-J06' : 'AUT-J05',
    ...(selected.includes('mention-detection') && selected.length > 1 ? { companions: ['AUT-J06'] } : {}), nativeVerified: false,
    groups: selected,
    cases: [...catalogCases, ...mentionCatalogCases].filter(test => selected.includes(test.group)),
    ...(selected.includes('create-find-reopen') ? { groupActions: {
      'create-find-reopen': [{
        id: 'character-editor-cancel', command: 'activate', condition: 'dirty-existing-character-name',
        entryPoint: { path: characterEditorSource, start: 53, end: 53,
          sha256: 'cdd6f12c9d6b229cd82dab400a60dd7cf4f582a36010d4c224a6de863a5adb7a' },
        branch: { path: characterEditorSource, start: 174, end: 182,
          sha256: '6fa43f9591c36a89c3f6b14cd61f96b42de0662b1d53d667afa649f7f3b948f0' },
      }],
    } } : {}) }, null, 2));
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
  for (const group of selected) {
    const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
    const journey = group === 'mention-detection' ? 'AUT-J06' : 'AUT-J05';
    try {
      await workflows[group](session);
      console.log(`PASS: ${journey}/${group}`);
    } catch (error) {
      throw new Error(`${journey}/${group} failed; later workflows were not run`, { cause: error });
    } finally { await session.close(); }
  }
}
