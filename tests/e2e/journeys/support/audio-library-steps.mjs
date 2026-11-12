import assert from 'node:assert/strict';

const ready = node => node.enabled === true && node.hittable;
export const sortedProjects = projects => [...projects].sort((a, b) => a.id.localeCompare(b.id));
export function audioLibrarySteps(session) {
  async function reveal(predicate) {
    for (let attempt = 0; attempt < 8; attempt++) {
      const nodes = await session.waitFor(nodes => nodes.filter(predicate).length === 1);
      const node = nodes.find(predicate);
      if (ready(node)) return node;
      const scroll = nodes.filter(candidate => candidate.scroll && candidate.hittable
        && node.path.startsWith(candidate.path + '.')).sort((a, b) => b.path.length - a.path.length)[0];
      assert.ok(scroll, 'Offscreen control requires a reachable native scrolling ancestor');
      const y = scroll.scroll.y + node.frame.y - scroll.frame.y - scroll.frame.height / 2 + node.frame.height / 2;
      assert.ok(Math.abs(y - scroll.scroll.y) > 0.5, 'Do not disguise a covered control as an offscreen control');
      await session.command('scroll', { target: scroll.path, y });
    }
    throw new Error('Audio control remained unreachable after bounded native scrolling');
  }
  async function activate(predicate) {
    const control = await reveal(predicate);
    await session.command('activate', { target: control.path });
  }
  async function tab(name) {
    const nodes = await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && ready(node)));
    const tabs = nodes.find(node => node.identifier === 'workspace-tabs');
    const index = tabs.segments.indexOf(name);
    assert.ok(index >= 0, `Actual workspace has a ${name} tab`);
    if (tabs.selected !== index) await session.command('select', { target: tabs.identifier, index });
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.selected === index && ready(node)));
  }
  async function openLibrary() {
    await tab('Script');
    const disclosure = await reveal(node => node.identifier === 'preview-layers-disclosure');
    if (disclosure.label === 'Expand Layers') await activate(node => node.identifier === disclosure.identifier);
    await session.waitFor(nodes => nodes.some(node => node.identifier === disclosure.identifier && node.label === 'Collapse Layers'));
    await activate(node => node.title === 'Audio' && node.enabled !== undefined);
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'local-audio-sheet')
      && nodes.some(node => node.label === 'Close local audio' && ready(node)));
  }
  async function closeLibrary() {
    await activate(node => node.label === 'Close local audio' && node.enabled !== undefined);
    await session.waitFor(nodes => nodes.every(node => node.identifier !== 'local-audio-sheet')
      && nodes.some(node => node.identifier === 'workspace-tabs' && ready(node)));
  }
  async function openTrim(clip, expected) {
    await activate(node => node.identifier === 'audio-clip-trim-' + clip.id);
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'audio-trim-editor'));
    await fields(expected);
  }
  async function fields(expected) {
    const ids = ['audio-source-in', 'audio-duration', 'audio-placement-offset'];
    await session.waitFor(nodes => ids.every((id, index) => nodes.some(node => node.identifier === id && node.text === expected[index])));
  }
  async function input(id, text) {
    const field = await reveal(node => node.identifier === id);
    await session.command('text', { target: field.path, text });
    await session.waitFor(nodes => nodes.some(node => node.identifier === id && node.text === text));
  }
  async function draft(source, duration, offset) {
    await input('audio-source-in', source);
    await input('audio-duration', duration);
    await input('audio-placement-offset', offset);
    await fields([source, duration, offset]);
  }
  async function finishTrim(apply = true) {
    await activate(node => apply ? node.identifier === 'audio-apply'
      : node.title === 'Cancel' && node.enabled !== undefined);
    await session.waitFor(nodes => nodes.every(node => node.identifier !== 'audio-trim-editor')
      && nodes.some(node => node.label === 'Close local audio' && ready(node)));
  }
  async function slider(label, value) {
    const control = await reveal(node => node.label === label && !!node.slider);
    await session.command('slider', { target: control.path, value });
    await session.waitFor(nodes => nodes.some(node => node.label === label && Math.abs(node.slider?.value - value) < 0.000001));
  }
  async function openProject(project) {
    await activate(node => node.identifier === 'workspace-project');
    const search = await reveal(node => node.placeholder === 'Find a project');
    await session.command('text', { target: search.path, text: project.title });
    await session.waitFor(nodes => nodes.some(node => node.text === `${project.title} · ${project.scenes.length} scene${project.scenes.length === 1 ? '' : 's'}`));
    await activate(node => node.title === 'Open project' && node.enabled !== undefined);
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.title === project.title && node.hittable));
    const actual = await session.command('loaded-project');
    assert.equal(actual.project.id, project.id, 'Normal project browser really loaded the requested saved project');
    return actual;
  }
  return { reveal, activate, tab, openLibrary, closeLibrary, openTrim, fields, input, draft,
    finishTrim, slider, openProject };
}
