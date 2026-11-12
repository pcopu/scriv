import assert from 'node:assert/strict';
import { scenarioRestrictions } from '../../cli/scenario-restrictions.mjs';
import { ScrivSession } from '../../cli/scriv.mjs';
import { waitForSavedProject } from './support/saved-projects.mjs';

// Candidate only: actual UIKit controls and the app-owned saved-package export.
// Deferred actions require a real UIControl or UIKit accessibility button.
// The denied AppKit fallback is removed; the entire candidate is blocked below.
// Missing, ambiguous or unhandled actions fail; no private handler or retry.
const restriction = scenarioRestrictions['character-aliases'];
if (restriction) {
  console.error(JSON.stringify({ scenario: 'character-aliases', ...restriction, nativeLaunched: false }));
  process.exit(2);
}
assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const ready = node => node.enabled === true && node.hittable === true;
const accessibleButton = node => node.hittable === true && node.enabled !== false
  && node.accessibility?.isElement === true && node.accessibility?.button === true
  && node.accessibility?.notEnabled === false;
const named = (node, value) => node.label === value || node.title === value;
const aliasPlaceholder = 'Another name for this character';
const chips = nodes => nodes.filter(node => typeof node.title === 'string'
  && node.label?.startsWith('Remove alias ')).map(node => node.label.slice('Remove alias '.length));
const ribbons = nodes => nodes.filter(node => node.identifier?.startsWith('character-ribbon-'));
const same = (actual, expected) => JSON.stringify(actual) === JSON.stringify(expected);

async function control(predicate, description) {
  let nodes;
  try {
    nodes = await session.waitFor(nodes => nodes.filter(node => ready(node) && predicate(node)).length === 1);
  } catch (error) {
    throw new Error(`No unique enabled, hittable UIControl for ${description}. The scenario cannot continue through the current CLI control surface.`, { cause: error });
  }
  return nodes.find(node => ready(node) && predicate(node));
}
async function activate(value) {
  const deadline = Date.now() + 15000;
  let route;
  let blocker = 'No matching actionable button';
  // Poll read-only observations only. Ambiguity at a preferred layer never
  // permits bypassing it through a different interaction surface.
  while (Date.now() < deadline && !route) {
    const nodes = await session.command('snapshot', {}, Math.max(1, deadline - Date.now()));
    const controls = nodes.filter(node => named(node, value) && ready(node));
    if (controls.length === 1) {
      route = { command: 'activate', parameters: { target: controls[0].path } };
    } else if (controls.length > 1) {
      blocker = `${controls.length} enabled, hittable UIControls match`;
    } else {
      const buttons = nodes.filter(node => named(node, value) && accessibleButton(node));
      if (buttons.length === 1) {
        route = { command: 'accessibility-activate', parameters: { target: buttons[0].path } };
      } else if (buttons.length > 1) {
        blocker = `${buttons.length} enabled, hittable UIKit accessibility buttons match`;
      } else {
        blocker = 'No UIKit action button; the Library Validation-denied AppKit fallback is unavailable';
      }
    }
    if (!route && Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, Math.min(50, deadline - Date.now())));
    }
  }
  if (!route) throw new Error(`Cannot activate ${JSON.stringify(value)}: ${blocker}. Native action reachability remains blocked.`);
  // Select one route before dispatch. A failed, false, or uncertain mutation is
  // never retried through the other route. Completion is observed separately.
  const result = await session.command(route.command, route.parameters);
  assert.equal(result.dispatched, true, `${route.command} must confirm handling ${JSON.stringify(value)}`);
}
async function text(placeholder, value) {
  const node = await control(node => node.placeholder === placeholder, `field ${JSON.stringify(placeholder)}`);
  await session.command('text', { target: node.path, text: value });
  await session.waitFor(nodes => nodes.some(node => node.placeholder === placeholder && node.text === value));
}
async function editorAliases(expected) {
  const nodes = await session.waitFor(nodes => !nodes.some(node => node.placeholder === aliasPlaceholder)
    && nodes.some(node => named(node, 'Save character') && ready(node))
    && same(chips(nodes), expected));
  assert.deepEqual(chips(nodes), expected, 'Mounted alias chips preserve exact values and order');
}
async function addAlias(value, expected, action = 'Add') {
  await activate('Add alias');
  await control(node => node.placeholder === aliasPlaceholder && node.text === '', 'new alias field');
  await text(aliasPlaceholder, value);
  // Do not call UIAlertAction handlers, private selectors, or a model helper.
  await activate(action);
  await editorAliases(expected);
}
async function saveEditor() {
  await activate('Save character');
  await session.waitFor(nodes => !nodes.some(node => node.placeholder === 'Name')
    && nodes.some(node => node.placeholder === 'Search characters' && ready(node)));
}
async function findCharacter(query, expectedIDs) {
  await text('Search characters', query);
  const expected = expectedIDs.map(id => `character-ribbon-${id}`).sort();
  const nodes = await session.waitFor(nodes => same(ribbons(nodes).map(node => node.identifier).sort(), expected)
    && (expected.length !== 0 || nodes.some(node => node.text === 'No matching characters')));
  assert.deepEqual(ribbons(nodes).map(node => node.identifier).sort(), expected,
    `Alias search ${JSON.stringify(query)} shows precisely the expected characters`);
}

try {
  const tabs = await control(node => node.identifier === 'workspace-tabs', 'workspace tabs');
  // The synthetic launch starts in memory. Save using the actual workspace key
  // command before observing its package; never seed project.json from Node.
  await session.command('key', { input: 's', modifiers: ['command'] });
  const index = tabs.segments.indexOf('Characters');
  assert.ok(index >= 0, 'Characters tab exists');
  await session.command('select', { target: tabs.path, index });
  await control(node => node.placeholder === 'Search characters', 'character search');
  const baseline = await waitForSavedProject(session, project => project.characters.length > 0);
  const characterName = 'CLI Alias 台詞';
  for (const query of [characterName, 'Papa, Jr.', 'The Farmer', '🙂']) {
    assert.ok(baseline.characters.every(character => [character.name, ...character.aliases]
      .every(value => !value.toLowerCase().includes(query.toLowerCase()))),
    `Synthetic fixture must not already match ${JSON.stringify(query)}`);
  }
  const originalFranklin = baseline.characters.find(character => character.id === 'character-franklin');
  assert.ok(originalFranklin?.aliases.includes('Franklin'), 'The synthetic project retains its original Franklin alias');
  await findCharacter('fRANKlin', [originalFranklin.id]);
  await text('Search characters', '');
  const unchanged = project => project.id === baseline.id && same(project.characters, baseline.characters);

  await activate('Add character');
  await text('Name', characterName);
  await editorAliases([]);
  await addAlias('The Farmer', ['The Farmer']);
  await addAlias('Franklin', ['The Farmer', 'Franklin']);
  // A UITextField is single-line. Space trimming is asserted here; the frozen
  // helper test's literal newline inputs remain a documented assertion gap.
  await addAlias('  Papa, Jr.  ', ['The Farmer', 'Franklin', 'Papa, Jr.']);
  await addAlias(' frankLIN ', ['The Farmer', 'Franklin', 'Papa, Jr.']);
  await addAlias('   ', ['The Farmer', 'Franklin', 'Papa, Jr.']);
  await addAlias('🙂', ['The Farmer', 'Franklin', 'Papa, Jr.', '🙂']);
  await addAlias('CLI Cancelled alias', ['The Farmer', 'Franklin', 'Papa, Jr.', '🙂'], 'Cancel');
  await waitForSavedProject(session, unchanged);
  await saveEditor();
  const initialAliases = ['The Farmer', 'Franklin', 'Papa, Jr.', '🙂'];
  const created = await waitForSavedProject(session, project => project.id === baseline.id
    && project.characters.length === baseline.characters.length + 1
    && project.characters.some(character => character.name === characterName && same(character.aliases, initialAliases)));
  const character = created.characters.find(character => character.name === characterName);
  assert.deepEqual(created.characters.filter(item => item.id !== character.id), baseline.characters,
    'Adding aliases to a new profile preserves every existing character');
  assert.deepEqual(created.entries, baseline.entries, 'Adding aliases never rewrites script text or confirmed links');

  async function persistedAliases(expected) {
    const project = await waitForSavedProject(session, project => project.id === baseline.id
      && same(project.characters.find(item => item.id === character.id)?.aliases, expected));
    assert.deepEqual(project.characters, created.characters.map(item => item.id === character.id
      ? { ...item, aliases: expected } : item), 'Only the edited character aliases change in the saved package');
    assert.deepEqual(project.entries, baseline.entries, 'Alias edits leave script entries and their links unchanged');
    return project;
  }
  async function reopen(expected) {
    await findCharacter(characterName, [character.id]);
    const card = await control(node => node.identifier === `character-ribbon-${character.id}`, 'created character ribbon');
    await session.command('activate', { target: card.path });
    await activate('Edit');
    await control(node => node.placeholder === 'Name' && node.text === characterName, 'saved character name');
    await editorAliases(expected);
  }

  await findCharacter('pAPA, jR.', [character.id]);
  await session.waitFor(nodes => nodes.some(node => node.text === initialAliases.join(', ')));
  await reopen(initialAliases);
  // Removing from the middle, then the start, exercises the freshly rendered
  // chip indices. No model-level remove operation is exposed to the test.
  await activate('Remove alias Franklin');
  await editorAliases(['The Farmer', 'Papa, Jr.', '🙂']);
  await activate('Remove alias The Farmer');
  await editorAliases(['Papa, Jr.', '🙂']);
  await persistedAliases(initialAliases); // Draft-only until the real Save.
  await saveEditor();
  await persistedAliases(['Papa, Jr.', '🙂']);
  await findCharacter('fRANKlin', [originalFranklin.id]);
  await findCharacter('the farmer', []);
  await findCharacter('pAPA, jR.', [character.id]);
  await findCharacter('🙂', [character.id]);

  await reopen(['Papa, Jr.', '🙂']);
  await activate('Remove alias Papa, Jr.');
  await editorAliases(['🙂']);
  await saveEditor();
  await persistedAliases(['🙂']);
  await findCharacter('Papa, Jr.', []);
  await findCharacter('🙂', [character.id]);

  await reopen(['🙂']);
  await addAlias('  Papa, Jr.  ', ['🙂', 'Papa, Jr.']);
  await saveEditor();
  await persistedAliases(['🙂', 'Papa, Jr.']);
  await findCharacter('pAPA, jR.', [character.id]);
  await reopen(['🙂', 'Papa, Jr.']);
  await activate('Cancel'); // Clean editor dismissal must not discard saved aliases.
  await session.waitFor(nodes => !nodes.some(node => node.placeholder === 'Name')
    && nodes.some(node => node.placeholder === 'Search characters' && ready(node)));
  await persistedAliases(['🙂', 'Papa, Jr.']);
  console.log('PASS: actual UIKit alias add/cancel, space trim, duplicate/blank rejection, ordered removal/re-add, saved packages, editor reopen and alias search');
} finally { await session.close(); }
