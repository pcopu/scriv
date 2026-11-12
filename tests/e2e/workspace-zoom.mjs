import assert from 'node:assert/strict';
import { ScrivSession } from '../../cli/scriv.mjs';
import { waitForSavedProject } from './support/saved-projects.mjs';

// Actual-app coverage. Programmatic attached-menu action dispatch is separate
// from physical menu interaction; preference relaunch remains unverified.
assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const ready = node => node.enabled === true && node.hittable === true;
const zoomControls = nodes => nodes.filter(node => node.enabled === true
  && /^Shared script zoom, \d+ percent$/.test(node.label));
const scriptText = nodes => nodes.filter(node => /^script-(line|editor)-/.test(node.identifier));
const pointSize = node => node?.font?.pointSize;
const near = (actual, expected) => Number.isFinite(actual) && Math.abs(actual - expected) < 0.01;
const key = (input, modifiers = ['command']) => session.command('key', { input, modifiers });
const hasChord = (command, input, modifiers) => command.input === input
  && JSON.stringify([...command.modifiers].sort()) === JSON.stringify([...modifiers].sort());
let baseFontSize;
let originalText;
let editing = null;

function percent(nodes) {
  const controls = zoomControls(nodes);
  assert.equal(controls.length, 1, 'One shared script zoom control is mounted');
  return Number(controls[0].label.match(/(\d+) percent$/)[1]);
}

function textMap(nodes) {
  const result = new Map();
  for (const node of scriptText(nodes)) {
    const id = node.identifier.replace(/^script-(line|editor)-/, '');
    assert.ok(!result.has(id), 'Each mounted entry has one visible display or editor');
    result.set(id, node.text);
  }
  return [...result].sort(([a], [b]) => a.localeCompare(b));
}

function assertPresentation(nodes, expectedPercent) {
  assert.equal(percent(nodes), expectedPercent);
  const text = scriptText(nodes);
  assert.ok(text.length > 0, 'Script text remains mounted');
  for (const node of text) {
    assert.ok(near(pointSize(node), baseFontSize * expectedPercent / 100),
      `Actual native script font follows ${expectedPercent}% zoom`);
  }
  assert.deepEqual(textMap(nodes), originalText, 'Zoom preserves mounted entry IDs and exact text');
  if (editing) {
    const editor = nodes.find(node => node.identifier === editing.identifier);
    assert.ok(editor?.firstResponder, 'Zoom does not replace the active text responder');
    assert.equal(editor.text, editing.text);
    assert.deepEqual(editor.selection, editing.selection, 'Zoom preserves the exact native UTF-16 selection');
  }
}

async function waitForZoom(expectedPercent) {
  const nodes = await session.waitFor(nodes => zoomControls(nodes).length === 1
    && Number(zoomControls(nodes)[0].label.match(/(\d+) percent$/)[1]) === expectedPercent
    && scriptText(nodes).length > 0
    && scriptText(nodes).every(node => near(pointSize(node), baseFontSize * expectedPercent / 100)));
  assertPresentation(nodes, expectedPercent);
  return nodes;
}

async function step(input, modifiers = ['command']) {
  const before = percent(await session.command('snapshot'));
  const expected = Math.max(70, Math.min(200, before + (input === '-' ? -10 : 10)));
  await key(input, modifiers);
  return waitForZoom(expected);
}

async function returnToDefault() {
  // There is no default-zoom key command. Use real minus strokes to reach the
  // supported lower bound, then three real plus strokes to return to 100%.
  for (let attempt = 0; attempt < 16; attempt++) {
    if (percent(await session.command('snapshot')) === 70) break;
    await step('-');
  }
  await waitForZoom(70);
  for (let count = 0; count < 3; count++) await step('=');
  return waitForZoom(100);
}

async function assertChordsAvailable() {
  const commands = await session.command('keys');
  for (const [input, modifiers] of [
    ['=', ['command']], ['+', ['command']],
    ['=', ['command', 'shift']], ['+', ['command', 'shift']], ['-', ['command']],
  ]) {
    assert.ok(commands.some(command => command.responderType === 'ScrivUIKitApplication'
      && command.wantsPriorityOverSystemBehavior && hasChord(command, input, modifiers)),
    'The application exposes each supported priority zoom shortcut');
  }
}

async function chordCycle() {
  await assertChordsAvailable();
  await step('=');
  await step('+');
  await step('=', ['command', 'shift']);
  await step('+', ['command', 'shift']);
  await step('-');
}

async function reveal(node, nodes) {
  if (node.hittable) return;
  const scroll = nodes.filter(parent => /ScrollView/.test(parent.type) && parent.hittable
    && node.path.startsWith(parent.path + '.')).sort((a, b) => b.path.length - a.path.length)[0];
  assert.ok(scroll, 'The selected native editor has a reachable scroll ancestor');
  await session.command('scroll', { target: scroll.path,
    y: scroll.scroll.y + node.frame.y - scroll.frame.y - 24 });
}

async function unchangedSavedProject(before) {
  const saved = (await session.command('persisted-projects')).find(project => project.id === before.id);
  assert.ok(saved, 'The same isolated project package is present');
  assert.deepEqual(saved, before, 'Observed saved project content, IDs, timing and revision are unchanged');
}

try {
  const capabilities = await session.command('capabilities');
  assert.equal(capabilities.driver, 'UIKit controls');
  for (const command of ['snapshot', 'select', 'keys', 'key', 'selection', 'persisted-projects']) {
    assert.ok(capabilities.commands.includes(command), `Native adapter supports ${command}`);
  }
  let nodes = await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && ready(node)));
  const tabs = nodes.find(node => node.identifier === 'workspace-tabs');
  const scriptIndex = tabs.segments.indexOf('Script');
  const charactersIndex = tabs.segments.indexOf('Characters');
  assert.ok(scriptIndex >= 0 && charactersIndex >= 0, 'Both shared-script tabs exist');
  if (tabs.selected !== scriptIndex) await session.command('select', { target: tabs.identifier, index: scriptIndex });
  nodes = await session.waitFor(nodes => zoomControls(nodes).length === 1 && scriptText(nodes).length > 0);
  for (const node of scriptText(nodes)) {
    assert.ok(Number.isFinite(pointSize(node)) && pointSize(node) > 0,
      'Requires a rebuilt automation app with read-only snapshot font.pointSize evidence');
  }
  const initialPercent = percent(nodes);
  assert.ok(initialPercent >= 70 && initialPercent <= 200, 'Initial zoom is within supported bounds');
  baseFontSize = pointSize(scriptText(nodes)[0]) * 100 / initialPercent;
  originalText = textMap(nodes);
  assertPresentation(nodes, initialPercent);

  // Verification launch does not eagerly save the sample. Save through the real
  // workspace command, then use only the app-owned, bounded package observer.
  await key('s');
  const before = await waitForSavedProject(session, project => originalText.every(([id, text]) =>
    project.entries.some(entry => entry.id === id && entry.text === text)));
  await returnToDefault();
  const defaultNodes = await waitForZoom(100);
  const defaultFrames = new Map(scriptText(defaultNodes).map(node => [node.identifier, node.frame]));

  // All four increase aliases and decrease work with no active text input.
  assert.equal(defaultNodes.some(node => node.firstResponder && /Text(Field|View)/.test(node.type)), false);
  await chordCycle();
  await unchangedSavedProject(before);

  // These are responder availability/rejection checks, not delivery of literal
  // typing or arbitrary hardware modifier bits to the physical keyboard policy.
  const currentPercent = percent(await session.command('snapshot'));
  const commands = await session.command('keys');
  for (const input of ['+', '=', '-']) {
    for (const modifiers of [[], ['shift'], ['option'], ['control'], ['command', 'option'], ['command', 'control']]) {
      assert.equal(commands.some(command => hasChord(command, input, modifiers)), false);
      await assert.rejects(key(input, modifiers), /No enabled key command/);
      await waitForZoom(currentPercent);
    }
  }
  await assert.rejects(key('-', ['command', 'shift']), /No enabled key command/);
  await waitForZoom(currentPercent);

  await returnToDefault();
  await key('\r');
  nodes = await session.waitFor(nodes => nodes.some(node => node.identifier.startsWith('script-editor-') && node.firstResponder));
  let editor = nodes.find(node => node.identifier.startsWith('script-editor-') && node.firstResponder);
  await reveal(editor, nodes);
  nodes = await session.waitFor(nodes => nodes.some(node => node.identifier === editor.identifier && node.hittable && node.firstResponder));
  editor = nodes.find(node => node.identifier === editor.identifier);
  const characters = Array.from(editor.text);
  assert.ok(characters.length >= 4, 'Selected synthetic entry supports a nonempty interior selection');
  const selection = { start: characters[0].length, end: characters.slice(0, 4).join('').length };
  await session.command('selection', { target: editor.identifier, ...selection });
  editing = { identifier: editor.identifier, text: editor.text, selection };
  await waitForZoom(100);
  await chordCycle();
  await waitForZoom(130);
  await key('Escape', []);
  const finishedID = editing.identifier;
  editing = null;
  await session.waitFor(nodes => !nodes.some(node => node.identifier === finishedID && node.firstResponder)
    && nodes.some(node => node.identifier === finishedID.replace('script-editor-', 'script-line-')));
  await waitForZoom(130);
  await unchangedSavedProject(before);

  // The same script surface and shared zoom survive Characters/Script switches.
  for (let repeat = 0; repeat < 2; repeat++) {
    await session.command('select', { target: tabs.identifier, index: charactersIndex });
    await session.waitFor(nodes => nodes.some(node => node.identifier === tabs.identifier && node.selected === charactersIndex));
    await waitForZoom(130);
    await step('=');
    await session.command('select', { target: tabs.identifier, index: scriptIndex });
    await session.waitFor(nodes => nodes.some(node => node.identifier === tabs.identifier && node.selected === scriptIndex));
    await waitForZoom(140);
    await step('-');
  }

  // Exercise repeated upper/lower attempts and return to 100% twice. Observe
  // actual native font sizes and a laid-out text frame, not just button titles.
  for (let repeat = 0; repeat < 2; repeat++) {
    for (let attempt = 0; attempt < 16; attempt++) {
      if (percent(await session.command('snapshot')) === 200) break;
      await step('=');
    }
    await waitForZoom(200);
    for (let attempt = 0; attempt < 3; attempt++) await step('+');
    const enlarged = await session.waitFor(nodes => scriptText(nodes).some(node => {
      const frame = defaultFrames.get(node.identifier);
      return frame?.height > 0 && node.frame.height > frame.height + 1;
    }));
    assertPresentation(enlarged, 200);
    await returnToDefault();
    for (let attempt = 0; attempt < 3; attempt++) await step('-');
    await waitForZoom(70);
    for (let attempt = 0; attempt < 3; attempt++) await step('-');
    for (let attempt = 0; attempt < 3; attempt++) await step('=');
    await waitForZoom(100);
    await unchangedSavedProject(before);
  }

  // Dispatch only the actual owning zoom control's existing seven-choice menu.
  // This never opens a native menu or claims physical selection/accessibility.
  assert.ok(capabilities.semanticMenuActionScopes.includes('script-zoom'));
  const choices = [[70, '70%'], [85, '85%'], [100, '100% · Default'], [115, '115%'],
    [130, '130%'], [150, '150%'], [200, '200%'], [100, '100% · Default']];
  const menu = await session.command('menu', { target: 'script-zoom' });
  assert.deepEqual(menu.primary[0].children.map(action => action.title), choices.slice(0, 7).map(([, title]) => title));
  for (const invalid of [{ action: 'Generate image' }, { action: '70%', origin: 'context' }]) {
    await assert.rejects(session.command('menu-action', { target: 'script-zoom', ...invalid }), /outside the supported scope/);
    await waitForZoom(100); await unchangedSavedProject(before);
  }
  await assert.rejects(session.command('menu-action', { target: 'workspace-tabs', action: '70%' }), /outside the supported scope/);
  for (const [value, title] of choices) {
    assert.deepEqual(await session.command('menu-action', { target: 'script-zoom', action: title }),
      { dispatched: true, coverage: 'semantic-menu-action' });
    await waitForZoom(value);
    const state = await session.command('menu', { target: 'script-zoom' });
    assert.deepEqual(state.primary[0].children.filter(action => action.state === 'on').map(action => action.title), [title]);
    await unchangedSavedProject(before);
  }

  await key('s');
  // Repeated saved observations catch a late write in the sampled interval.
  // They are not a save-generation acknowledgement or a relaunch durability test.
  for (let sample = 0; sample < 4; sample++) {
    await new Promise(resolve => setTimeout(resolve, 100));
    await session.waitFor(nodes => nodes.some(node => node.label === 'Saved on this Mac'));
    await unchangedSavedProject(before);
  }
  await waitForZoom(100);
  console.log('PASS: actual UIKit zoom shortcuts, native font/layout effects, editing selection, shared tabs, repeated bounds/default return and unchanged saved observations');
} finally { await session.close(); }
