import assert from 'node:assert/strict';
import { ScrivSession } from '../../cli/scriv.mjs';

assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const parentPath = path => path.slice(0, path.lastIndexOf('.'));
const inside = (node, parent) => node.path.startsWith(parent.path + '.');
const near = (actual, expected, tolerance) => Number.isFinite(actual) && Math.abs(actual - expected) <= tolerance;
const displays = nodes => nodes.filter(node => node.identifier?.startsWith('script-line-'));

function presentation(nodes) {
  const lines = displays(nodes);
  assert.ok(lines.length > 0, 'Native script display rows are mounted');
  assert.equal(new Set(lines.map(node => node.identifier)).size, lines.length, 'Script line identifiers are unique');
  // Use containment of every identified script display, not the first generic
  // scroll view (Characters adds several unrelated scroll containers).
  const ancestors = nodes.filter(node => node.type === 'UIScrollView'
    && lines.every(line => inside(line, node)));
  assert.equal(ancestors.length, 1, 'One native script scroll view contains every displayed script line');
  const scroll = ancestors[0];
  const stack = nodes.find(node => node.path === parentPath(scroll.path));
  assert.equal(stack?.type, 'UIStackView', 'Script scroll belongs to its root stack');
  const pane = nodes.find(node => node.path === parentPath(stack.path));
  assert.ok(pane, 'Script controller root view is mounted');
  assert.ok(nodes.some(node => inside(node, pane) && /^Shared script zoom, \d+ percent$/.test(node.label)),
    'The scoped pane contains the real script zoom control');
  assert.ok(near(stack.frame.width, pane.frame.width, 1), 'Script root stack fills the controller pane');
  assert.ok(near(scroll.frame.width, pane.frame.width, 1), 'Script scroll fills the controller pane width');
  return { pane, scroll, lines };
}

function compare(actual, baseline) {
  assert.ok(near(actual.pane.frame.width, baseline.width, 1), 'Script and Characters give the script the same width (±1 pt)');
  assert.ok(near(actual.scroll.scroll.y, baseline.offset, 1), 'Both tabs preserve the same script scroll offset (±1 pt)');
  assert.deepEqual(actual.lines.map(node => [node.identifier, node.text]).sort(), baseline.text,
    'Tab switching preserves every mounted script entry and exact text');
  for (const line of actual.lines) {
    assert.ok(near(line.font?.pointSize, baseline.fonts.get(line.identifier), 0.01),
      `Both tabs retain the native font for ${line.identifier} (±0.01 pt)`);
  }
}

try {
  let nodes = await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.enabled && node.hittable)
    && displays(nodes).length > 0);
  const tabs = nodes.filter(node => node.identifier === 'workspace-tabs');
  assert.equal(tabs.length, 1, 'One workspace tab control');
  const scriptIndex = tabs[0].segments.indexOf('Script');
  const charactersIndex = tabs[0].segments.indexOf('Characters');
  assert.ok(scriptIndex >= 0 && charactersIndex >= 0);
  async function select(index) {
    await session.command('select', { target: 'workspace-tabs', index });
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.selected === index)
      && displays(nodes).length > 0);
    // Observe settled layout as well as initial selection, including asynchronous
    // tab updates. Assertions after this delay must still hold on a second read.
    await new Promise(resolve => setTimeout(resolve, 200));
    return session.command('snapshot');
  }
  nodes = await select(scriptIndex);
  let current = presentation(nodes);
  assert.ok(current.scroll.hittable, 'Script scrolling is reachable through its real UI');
  assert.ok(current.scroll.scroll.contentHeight - current.scroll.frame.height >= 300,
    'Synthetic scene has enough real scroll extent for the baseline 300-point offset');
  await session.command('scroll', { target: current.scroll.path, y: 300 });
  nodes = await session.waitFor(nodes => near(presentation(nodes).scroll.scroll.y, 300, 1));
  current = presentation(nodes);
  const baseline = {
    width: current.pane.frame.width,
    offset: current.scroll.scroll.y,
    text: current.lines.map(node => [node.identifier, node.text]).sort(),
    fonts: new Map(current.lines.map(node => [node.identifier, node.font?.pointSize])),
  };
  assert.ok(baseline.width > 0);
  assert.ok([...baseline.fonts.values()].every(size => Number.isFinite(size) && size > 0), 'All native script fonts are observable');
  for (let cycle = 0; cycle < 2; cycle++) {
    for (const index of [charactersIndex, scriptIndex]) {
      nodes = await select(index);
      if (index === charactersIndex) assert.equal(nodes.filter(node => node.placeholder === 'Search characters').length, 1,
        'Characters panel is actually mounted alongside the script');
      compare(presentation(nodes), baseline);
      await new Promise(resolve => setTimeout(resolve, 150));
      compare(presentation(await session.command('snapshot')), baseline);
    }
  }
  console.log('PASS: actual UIKit Script/Characters pane width, font and 300-point scroll parity over repeated tab switches');
} finally { await session.close(); }
