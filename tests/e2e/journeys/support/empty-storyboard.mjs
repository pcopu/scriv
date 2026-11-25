import assert from 'node:assert/strict';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { fixture } from './picture-coverage-cases.mjs';
import { coverageSteps, ready, sorted } from './picture-coverage-steps.mjs';

export async function runEmptyStoryboard() {
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  try {
    const ui = coverageSteps(session);
    await ui.tab('Script');
    await session.command('key', { input: 's', modifiers: ['command'] });
    const sentinel = await waitForSavedProject(session, project => project.title === 'YAM MAN');
    const input = { ...fixture(), title: 'Synthetic storyboard before adding pictures', cues: [] };
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
    const project = await waitForSavedProject(session, value => value.title === input.title);
    assert.deepEqual(project, { ...input, id: project.id, createdAt: project.createdAt, modifiedAt: project.modifiedAt });
    const loaded = await session.command('loaded-project');
    assert.deepEqual(loaded.project, project);

    await ui.tab('Storyboard');
    const shared = nodes => nodes.find(node => node.identifier === 'storyboard-shared-script');
    const nodes = await session.waitFor(nodes => !!shared(nodes) && nodes.some(node => node.text === 'Build the scene, one image at a time'));
    const words = nodes.filter(node => node.path.startsWith(shared(nodes).path + '.') && node.identifier.startsWith('storyboard-word-'));
    assert.deepEqual(words.map(node => node.identifier).sort(), input.entries.flatMap(entry => entry.words.map(word => 'storyboard-word-' + word.id)).sort());
    assert.ok(nodes.every(node => !node.identifier.startsWith('storyboard-picture-row-')));
    assert.equal(nodes.find(node => node.identifier === 'storyboard-deselect')?.enabled, false);
    const word = node => node.identifier === 'storyboard-word-b-word-0';
    const target = await ui.reveal(word);
    const menu = await session.command('menu', { target: target.path });
    assert.deepEqual(menu.secondary[0].children.map(node => node.title), ['Play word', 'Edit word timing…']);
    await ui.activate(word);
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'storyboard-deselect' && ready(node))
      && nodes.some(node => node.text === '1 word selected'));
    await ui.activate(node => node.identifier === 'storyboard-deselect');
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'storyboard-deselect' && node.enabled === false));
    await ui.button('Write in Script');
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && ready(node)
      && node.segments[node.selected] === 'Script'));
    assert.deepEqual(await session.command('loaded-project'), loaded);
    assert.deepEqual(sorted(await session.command('persisted-projects')), sorted([sentinel, project]));
  } finally { await session.close(); }
}
