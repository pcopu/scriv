import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';

// AUT-J11 presentation portion. Real UIKit disclosure/slider/switch and public
// Escape command only. No drag, snapping-result, pixel or full legacy coverage.
assert.ok(process.env.SCRIV_E2E_APP, 'Requires an isolated automation Catalyst app');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const ready = node => node.enabled && node.hittable;
const disclosure = node => node.identifier === 'preview-layers-disclosure';
const near = (a, b) => Number.isFinite(a) && Math.abs(a - b) < 0.001;
const byID = projects => [...projects].sort((a, b) => a.id.localeCompare(b.id));
async function reveal(predicate) {
  for (let attempt = 0; attempt < 8; attempt++) {
    const nodes = await session.waitFor(nodes => nodes.filter(predicate).length === 1);
    const node = nodes.find(predicate);
    if (ready(node)) return node;
    const ancestors = nodes.filter(candidate => candidate.scroll && candidate.hittable
      && node.path.startsWith(candidate.path + '.')).sort((a, b) => b.path.length - a.path.length);
    assert.ok(ancestors.length, 'Offscreen target needs an actual hittable scrolling ancestor');
    const scroll = ancestors[0];
    const y = scroll.scroll.y + node.frame.y - scroll.frame.y - scroll.frame.height / 2 + node.frame.height / 2;
    assert.ok(Math.abs(y - scroll.scroll.y) > 0.5, 'A covered control cannot be made reachable by a no-op scroll');
    await session.command('scroll', { target: scroll.path, y });
  }
  throw new Error('Target did not become hittable after bounded real scrolling');
}
async function activate(predicate) {
  const node = await reveal(predicate);
  await session.command('activate', { target: node.path });
}
async function control(label) {
  const nodes = await session.waitFor(nodes => nodes.filter(node => node.label === label && ready(node)).length === 1);
  return nodes.find(node => node.label === label && ready(node));
}
async function exerciseControls() {
  const zoom = await control('Timeline zoom');
  assert.ok(near(zoom.slider.minimum, 0.3));
  assert.ok(near(zoom.slider.maximum, 2.5));
  const initial = zoom.slider.value;
  for (const value of [zoom.slider.minimum, zoom.slider.maximum, initial]) {
    const current = await control('Timeline zoom');
    await session.command('slider', { target: current.path, value });
    await session.waitFor(nodes => nodes.some(node => node.label === 'Timeline zoom' && ready(node) && near(node.slider?.value, value)));
  }
  const snap = await control('Snap to words');
  const before = snap.isOn;
  assert.equal(typeof before, 'boolean');
  for (const value of [!before, before]) {
    const current = await control('Snap to words');
    await session.command('toggle', { target: current.path, value });
    await session.waitFor(nodes => nodes.some(node => node.label === 'Snap to words' && ready(node) && node.isOn === value));
  }
}
try {
  let nodes = await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && ready(node)));
  const tabs = nodes.find(node => node.identifier === 'workspace-tabs');
  const script = tabs.segments.indexOf('Script');
  assert.ok(script >= 0);
  if (tabs.selected !== script) await session.command('select', { target: tabs.identifier, index: script });
  await session.command('key', { input: 's', modifiers: ['command'] });
  await waitForSavedProject(session, project => project.entries.length > 0);
  const baseline = byID(await session.command('persisted-projects'));
  const initial = await reveal(disclosure);
  assert.equal(initial.label, 'Expand Layers');
  assert.equal((await session.command('snapshot')).filter(node => node.label === 'Timeline zoom').length, 0, 'Collapsed Layers is not mounted');
  for (let cycle = 0; cycle < 2; cycle++) {
    await activate(disclosure);
    await session.waitFor(nodes => nodes.some(node => disclosure(node) && node.label === 'Collapse Layers'));
    await reveal(node => node.label === 'Timeline zoom');
    await exerciseControls();
    await activate(node => node.label === 'Expand Layers' && !disclosure(node));
    await control('Timeline zoom');
    nodes = await session.waitFor(nodes => nodes.some(node => node.text === 'Drag a picture to offset within its source. Lower right edge: coverage. Upper cut grip: shared cut. Shift: no snap. Change source: picture menu.'));
    assert.ok(nodes.some(node => disclosure(node) && !node.hittable), 'Sheet covers embedded disclosure');
    await exerciseControls();
    await session.command('key', { input: 'Escape', modifiers: [] });
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && ready(node)));
    await reveal(disclosure);
    await activate(disclosure);
    await session.waitFor(nodes => nodes.some(node => disclosure(node) && node.label === 'Expand Layers')
      && nodes.every(node => node.label !== 'Timeline zoom'));
    assert.deepEqual(byID(await session.command('persisted-projects')), baseline, 'Layers inspection does not author any saved project field');
  }
  console.log('PASS AUT-J11 Layers presentation: two expand/zoom/snap/sheet/Escape/collapse cycles; saved packages unchanged. No drag/snapping-result/pixel claims.');
} finally { await session.close(); }
