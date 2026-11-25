import assert from 'node:assert/strict';
export const ready = node => node.enabled && node.hittable;
export const sorted = projects => [...projects].sort((a, b) => a.id.localeCompare(b.id));
export function coverageSteps(session) {
  async function reveal(predicate) {
    for (let attempt = 0; attempt < 8; attempt++) {
      const nodes = await session.waitForUnique(predicate);
      const node = nodes.find(predicate);
      if (ready(node)) return node;
      const ancestor = nodes.filter(candidate => candidate.scroll && candidate.hittable
        && node.path.startsWith(candidate.path + '.')).sort((a, b) => b.path.length - a.path.length)[0];
      assert.ok(ancestor, 'Offscreen control requires a reachable scrolling ancestor');
      await session.command('scroll', { target: ancestor.path,
        y: ancestor.scroll.y + node.frame.y - ancestor.frame.y - 12 });
    }
    throw new Error('Coverage control remained unreachable after bounded real scrolling');
  }
  async function activate(predicate) {
    const node = await reveal(predicate);
    await session.command('activate', { target: node.path });
  }
  const field = node => node.label === 'Duration, seconds';
  async function button(label) { await activate(node => node.label === label && ready(node)); }
  async function open(expected) {
    await activate(node => node.identifier === 'storyboard-duration-child');
    const nodes = await session.waitFor(nodes => nodes.some(node => field(node) && ready(node))
      && nodes.some(node => node.label === 'Apply' && ready(node)));
    assert.equal(nodes.find(field).text, expected, 'Editor loads authored extent, including scene-clipped values');
    assert.ok(nodes.some(node => node.text === 'Authored image coverage'));
  }
  async function input(text) {
    const node = await reveal(field);
    await session.command('text', { target: node.path, text });
    await session.waitFor(nodes => nodes.some(node => field(node) && node.text === text));
  }
  async function closed() {
    await session.waitFor(nodes => nodes.every(node => !field(node))
      && nodes.some(node => node.identifier === 'workspace-tabs' && ready(node)));
  }
  async function tab(name) {
    const nodes = await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && ready(node)));
    const tabs = nodes.find(node => node.identifier === 'workspace-tabs');
    const index = tabs.segments.indexOf(name);
    assert.ok(index >= 0, `Actual ${name} segment exists`);
    if (tabs.selected !== index) await session.command('select', { target: tabs.identifier, index });
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.selected === index));
  }
  async function history(redo = false) {
    const modifiers = redo ? ['command', 'shift'] : ['command'];
    assert.ok((await session.command('keys')).some(key => key.input === 'z'
      && key.modifiers.length === modifiers.length && modifiers.every(value => key.modifiers.includes(value))),
    `Real ${redo ? 'Redo' : 'Undo'} command is available`);
    await session.command('key', { input: 'z', modifiers });
  }
  return { reveal, activate, button, open, input, closed, tab, history };
}
