import assert from 'node:assert/strict';
export const nodeWithID = (nodes, id) => nodes.find(node => node.identifier === id);
export const sortedProjects = projects => [...projects].sort((a, b) => a.id.localeCompare(b.id));
export function reviewSteps(session) {
  // Scroll public UIKit ancestors, re-resolving every path after layout. Never
  // invoke an offscreen action or a private handler. Bounded navigation only.
  async function reveal(id) {
    for (let attempt = 0; attempt < 8; attempt++) {
      const nodes = await session.command('snapshot');
      const target = nodeWithID(nodes, id);
      assert.ok(target, `Mounted control ${id}`);
      if (target.hittable) return target;
      const ancestor = nodes.filter(node => node.scroll && node.hittable
        && target.path.startsWith(node.path + '.')).sort((a, b) => b.path.length - a.path.length)[0];
      assert.ok(ancestor, `Reachable scrolling ancestor for ${id}`);
      await session.command('scroll', { target: ancestor.path,
        y: ancestor.scroll.y + target.frame.y - ancestor.frame.y - 12 });
    }
    throw new Error(`Control did not become hittable: ${id}`);
  }
  async function activate(id) {
    const node = await reveal(id);
    assert.equal(node.enabled, true, `${id} is enabled`);
    await session.command('activate', { target: node.path });
  }
  async function section(index) {
    await session.command('select', { target: 'generation-review-tabs', index });
    return session.waitFor(nodes => nodeWithID(nodes, 'generation-review-tabs')?.selected === index);
  }
  async function open() {
    await session.waitFor(nodes => nodeWithID(nodes, 'generation-review-brief')?.enabled);
    await activate('generation-review-brief');
    return session.waitFor(nodes => nodeWithID(nodes, 'generation-review-tabs')?.selected === 0
      && nodeWithID(nodes, 'generation-review-done')?.hittable);
  }
  async function closed() {
    await session.waitFor(nodes => !nodeWithID(nodes, 'generation-brief-review')
      && nodeWithID(nodes, 'generation-review-brief')?.enabled);
  }
  function chrome(nodes) {
    return Object.fromEntries(['generation-brief-review', 'generation-review-header',
      'generation-review-footer', 'generation-review-done'].map(id => {
      const node = nodeWithID(nodes, id); assert.ok(node, id); return [id, node.frame];
    }));
  }
  function sameChrome(nodes, before) {
    const after = chrome(nodes);
    for (const [id, frame] of Object.entries(before)) for (const key of ['x', 'y', 'width', 'height']) {
      assert.ok(Math.abs(after[id][key] - frame[key]) <= 0.5, `${id}.${key} remains fixed`);
    }
    assert.equal(nodeWithID(nodes, 'generation-review-done').hittable, true);
    assert.equal(nodeWithID(nodes, 'generation-review-done').enabled, true);
  }
  return { reveal, activate, section, open, closed, chrome, sameChrome };
}
