import assert from 'node:assert/strict';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
export const ready = node => node.enabled === true && node.hittable === true;
export const named = (node, value) => node.label === value || node.title === value;
export const same = (actual, expected) => JSON.stringify(actual) === JSON.stringify(expected);
export const ribbons = nodes => nodes.filter(node => node.identifier?.startsWith('character-ribbon-'));
export const search = nodes => nodes.filter(node => node.placeholder === 'Search characters');
export const ribbonIDs = nodes => ribbons(nodes).map(node => node.identifier).sort();
const notes = label => node => /TextView/.test(node.type) && node.label === label;
const paletteNames = ['Orange', 'Yellow', 'Green', 'Teal', 'Blue', 'Purple', 'Pink', 'Slate'].map(name => `${name} character colour`);
const paletteLabels = nodes => nodes.filter(node => node.enabled === true && / character colour$/.test(node.label)).map(node => node.label).sort();
export function characterCatalogSteps(session) {
  const saved = predicate => waitForSavedProject(session, predicate);
  let openingPalette;
  async function locate(predicate, description, reveal = true) {
    try {
      let nodes = await session.waitFor(nodes => nodes.filter(predicate).length === 1);
      let node = nodes.find(predicate);
      if (reveal && !node.hittable) {
        const scroll = nodes.filter(candidate => /ScrollView/.test(candidate.type) && candidate.hittable
          && node.path.startsWith(candidate.path + '.')).sort((a, b) => b.path.length - a.path.length)[0];
        assert.ok(scroll, `${description}: offscreen input has a reachable native scroll ancestor`);
        await session.command('scroll', { target: scroll.path,
          y: scroll.scroll.y + node.frame.y - scroll.frame.y - 20 });
        nodes = await session.waitFor(nodes => nodes.filter(predicate).length === 1 && nodes.find(predicate).hittable);
        node = nodes.find(predicate);
      }
      return node;
    } catch (error) { throw new Error(`Could not locate ${description} through the actual UIKit view tree`, { cause: error }); }
  }
  async function activate(value) {
    const node = await locate(node => node.enabled === true && named(node, value), `button ${JSON.stringify(value)}`);
    const result = await session.command('activate', { target: node.path });
    assert.equal(result.dispatched, true, `${value}: native control action is dispatched exactly once`);
  }
  async function text(predicate, value, description = 'character text input') {
    if (typeof predicate === 'string') {
      const placeholder = predicate;
      predicate = node => node.placeholder === placeholder && ready(node);
    }
    const node = await locate(predicate, description);
    await session.command('text', { target: node.path, text: value });
    try {
      await session.waitFor(nodes => nodes.filter(predicate).length === 1 && nodes.find(predicate).text === value);
    } catch (error) { throw new Error(`${description}: native input did not retain the exact UTF-16 text`, { cause: error }); }
  }
  const nameField = node => node.placeholder === 'Name' && node.enabled === true;
  const searchField = node => node.placeholder === 'Search characters' && node.enabled === true;
  const biographyField = notes('Biography');
  const appearanceField = notes('Appearance & image direction');

  async function rememberOpeningPalette() {
    await locate(nameField, 'editable character name');
    openingPalette = paletteLabels(await session.command('snapshot'));
    for (const label of paletteNames) {
      assert.ok(openingPalette.includes(label), `The opened palette includes ${label}`);
    }
  }
  async function inspectEditor(expected) {
    // Wait for the actual edit lease to enable Save before inspecting the fields.
    await locate(node => node.enabled === true && named(node, 'Save character'), 'enabled Save character');
    for (const [predicate, value, description] of [
      [nameField, expected.name, 'saved character name'],
      [biographyField, expected.biography, 'saved Biography text view'],
      [appearanceField, expected.appearance, 'saved Appearance text view'],
    ]) {
      const node = await locate(predicate, description);
      assert.equal(node.text, value, `${description}: exact UTF-16 content, whitespace and line breaks`);
    }
    const nodes = await session.command('snapshot');
    // A retained custom colour can share a label with a standard swatch. For
    // example literal "blue" and hex 4E87EE are distinct values both named Blue.
    // Preserve this editor's observed multiplicities, not global label uniqueness.
    assert.deepEqual(paletteLabels(nodes), openingPalette,
      'Palette retains the exact opening label multiset after field or colour edits');
  }
  async function editorClosed() {
    await session.waitFor(nodes => !nodes.some(node => node.placeholder === 'Name')
      && nodes.some(node => searchField(node) && node.hittable));
  }
  async function saveEditor() { await activate('Save character'); await editorClosed(); }
  async function cancelCleanEditor() { await activate('Cancel'); await editorClosed(); }


  async function control(predicate) {
    const nodes = await session.waitFor(nodes => nodes.filter(node => ready(node) && predicate(node)).length === 1);
    return nodes.find(node => ready(node) && predicate(node));
  }
  async function saveEnabled(enabled) {
    await session.waitFor(nodes => nodes.filter(node => named(node, 'Save character') && typeof node.enabled === 'boolean').length === 1
      && nodes.some(node => named(node, 'Save character') && node.enabled === enabled));
  }
  async function openCatalog({ persist = true } = {}) {
    const tabs = await control(node => node.identifier === 'workspace-tabs');
    // Verification mode only publishes the isolated package after actual Save.
    if (persist) await session.command('key', { input: 's', modifiers: ['command'] });
    const index = tabs.segments.indexOf('Characters');
    assert.ok(index >= 0, 'Characters tab exists');
    await session.command('select', { target: tabs.path, index });
    await control(searchField);
  }
  async function escapeState(enabled) {
    const commands = (await session.command('controller-keys')).filter(command => command.controllerType === 'CharactersController'
      && command.input === 'Escape' && command.modifiers.length === 0 && command.action === 'clearSearchCommand');
    assert.equal(commands.length, 1, 'Characters registers exactly one search Escape command');
    assert.equal(commands[0].wantsPriorityOverSystemBehavior, true, 'Search Escape takes priority over native field handling');
    assert.equal(commands[0].enabled, enabled, 'Character Escape eligibility tracks search focus');
  }
  return { saved, locate, control, activate, text, saveEnabled, editorClosed, openCatalog,
    rememberOpeningPalette, inspectEditor, saveEditor, cancelCleanEditor, escapeState,
    nameField, searchField, biographyField, appearanceField };
}

export function inspectCreationEntries(before, after, existingCharacters) {
  assert.equal(after.length, before.length, 'Profile creation preserves the complete script entry count');
  const characterIDs = new Set(existingCharacters.map(character => character.id));
  for (let index = 0; index < before.length; index++) {
    const original = before[index];
    const persisted = after[index];
    if (original.characterLinks != null) {
      assert.deepEqual(persisted, original,
        'Profile creation preserves entries with explicit links, including explicit empty arrays');
      continue;
    }
    // Creating a character intentionally freezes missing legacy suggestions
    // before changing the catalog. Exempt only that absent -> array transition,
    // never existing links or any source, timing, identity or ordering field.
    const { characterLinks: originalLinks, ...originalFields } = original;
    const { characterLinks: newLinks, ...persistedFields } = persisted;
    assert.deepEqual(persistedFields, originalFields,
      'Profile creation preserves every entry field except previously missing characterLinks');
    assert.ok(Array.isArray(newLinks), 'Missing legacy annotations materialize as a saved array');
    const linkIDs = new Set();
    let end = 0;
    for (const link of newLinks) {
      assert.equal(typeof link.id, 'string', 'Materialized suggestion has a string identity');
      assert.ok(link.id.length > 0 && !linkIDs.has(link.id), 'Materialized suggestion IDs are nonempty and unique within their entry');
      linkIDs.add(link.id);
      assert.equal(link.isConfirmed, false, 'Bootstrapping never confirms an inferred identity');
      assert.ok(characterIDs.has(link.characterId), 'Materialized suggestions refer only to the pre-existing character catalog');
      assert.ok(Number.isSafeInteger(link.location) && Number.isSafeInteger(link.length)
        && link.location >= end && link.length > 0 && link.location + link.length <= original.text.length,
      'Materialized suggestions have ordered, non-overlapping, in-bounds UTF-16 ranges');
      assert.equal(link.text, original.text.slice(link.location, link.location + link.length),
        'Materialized suggestion text matches the exact original UTF-16 source span');
      end = link.location + link.length;
    }
  }
}
