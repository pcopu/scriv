import assert from 'node:assert/strict';

// Two explicit source-only modes: the frozen native accessibility experiment
// and semantic disclosure. Neither retries or falls back to the other mode.
export const missingGenerationPrompt = 'No exact generation prompt was captured for this imported or older version. Its origin is not inferred from the current script.';
export const capturedPromptExplanation = 'Exact submitted text, separate from the manual image direction above.';
export const inspectorPrompts = [
  { version: 1, manual: 'Manual direction one', captured: 'Exact submitted prompt one\nSource at generation time.' },
  { version: 2, manual: 'Manual direction two', captured: null },
];
const named = (node, title) => node.title === title || node.label === title;
const accessible = node => node.hittable === true && node.enabled !== false
  && node.accessibility?.isElement === true && node.accessibility?.button === true
  && node.accessibility?.notEnabled === false;

export async function discloseInspectorPrompts(session, ui, expected, persistedUnchanged, { semantic = false } = {}) {
  const generation = expected.captured ?? missingGenerationPrompt;
  const other = inspectorPrompts.find(prompt => prompt.version !== expected.version);
  const generationTexts = [inspectorPrompts[0].captured, missingGenerationPrompt, capturedPromptExplanation];
  const isText = (node, value) => node.text === value && node.editable === false;
  async function textVisible(value) {
    // UITextView is not a UIControl: ui.reveal's enabled requirement cannot
    // apply. Use the same bounded ancestor scrolling and covered-control guard.
    for (let attempt = 0; attempt < 8; attempt++) {
      const nodes = await session.waitFor(nodes => nodes.filter(n => isText(n, value)).length === 1);
      const node = nodes.find(n => isText(n, value));
      if (node.hittable) return node;
      const scroll = nodes.filter(n => n.scroll && n.hittable && node.path.startsWith(n.path + '.'))
        .sort((a, b) => b.path.length - a.path.length)[0];
      assert.ok(scroll, 'Inspector text requires a reachable native scrolling ancestor');
      const y = scroll.scroll.y + node.frame.y - scroll.frame.y - scroll.frame.height / 2 + node.frame.height / 2;
      assert.ok(Math.abs(y - scroll.scroll.y) > 0.5, 'Do not disguise covered inspector text as offscreen');
      await session.command('scroll', { target: scroll.path, y });
    }
    assert.fail('Inspector text remained unreachable after bounded native scrolling');
  }
  async function rejectRequest(request) {
    const beforeUI = await session.command('snapshot');
    await assert.rejects(session.command('menu-action', request), /outside the supported (?:isolated )?scope/);
    assert.deepEqual(await session.command('snapshot'), beforeUI,
      'Rejected semantic request must leave the real inspector UI unchanged');
    await persistedUnchanged();
  }
  async function semanticNegatives(owner, currentTitle) {
    const beforeMenu = await session.command('menu', { target: owner.path });
    for (const action of ['Copy image direction', 'Copy captured generation prompt', 'Share original image',
      'Not a disclosure', currentTitle === 'Show captured generation prompt'
        ? 'Hide captured generation prompt' : 'Show captured generation prompt']) {
      await rejectRequest({ target: owner.path, action });
      assert.deepEqual(await session.command('menu', { target: owner.path }), beforeMenu);
    }
    await rejectRequest({ target: owner.path, action: currentTitle, unexpected: true });
    await rejectRequest({ target: owner.path });
    const wrongOwner = await ui.reveal(n => n.title === 'Show in script' && n.enabled !== undefined);
    await rejectRequest({ target: wrongOwner.path, action: currentTitle });
  }
  async function disclosure(title) {
    const owner = await ui.reveal(n => n.label === 'Image version actions' && n.enabled !== undefined);
    if (!semantic) assert.ok(accessible(owner), 'The real inspector menu owner must be an accessible, hittable button');
    const menu = await session.command('menu', { target: owner.path });
    assert.deepEqual(menu.secondary, []); assert.deepEqual(menu.context, []);
    assert.equal(menu.primary.length, 1);
    const actions = menu.primary[0].children;
    assert.equal(actions.filter(action => action.type === 'action' && action.title === title).length, 1);
    assert.equal(actions.filter(action => action.title === 'Copy captured generation prompt').length, expected.captured === null ? 0 : 1);
    if (semantic) {
      await semanticNegatives(owner, title);
      // Re-resolve after bounded scrolling, then dispatch exactly once. Never
      // present a native menu or retry an uncertain semantic outcome.
      const current = await ui.reveal(n => n.label === 'Image version actions' && n.enabled !== undefined);
      assert.deepEqual(await session.command('menu-action', { target: current.path, action: title }),
        { dispatched: true, coverage: 'semantic-menu-action' });
      const nextTitle = title === 'Show captured generation prompt'
        ? 'Hide captured generation prompt' : 'Show captured generation prompt';
      await session.waitFor(nodes => nodes.some(n => n.label === 'Image version actions'));
      const next = await ui.reveal(n => n.label === 'Image version actions' && n.enabled !== undefined);
      const nextMenu = await session.command('menu', { target: next.path });
      assert.equal(nextMenu.primary[0].children[0].title, nextTitle);
      await persistedUnchanged();
      return;
    }
    // Request real menu presentation with the public accessibility action.
    // Never replace a failed/uncertain dispatch with menu-action or another route.
    assert.equal((await session.command('accessibility-activate', { target: owner.path })).dispatched, true);
    const nodes = await session.waitFor(nodes => nodes.filter(n => named(n, title)
      && (n.enabled === true && n.hittable === true || accessible(n))).length === 1);
    const action = nodes.find(n => named(n, title) && (n.enabled === true && n.hittable === true || accessible(n)));
    const command = action.enabled === true ? 'activate' : 'accessibility-activate';
    assert.equal((await session.command(command, { target: action.path })).dispatched, true);
    await session.waitFor(nodes => !nodes.some(n => named(n, title)));
    await persistedUnchanged();
  }
  async function collapsed() {
    const nodes = await session.waitFor(nodes => nodes.some(n => isText(n, expected.manual))
      && generationTexts.every(text => !nodes.some(n => n.text === text)));
    assert.ok(!nodes.some(n => isText(n, other.manual)), 'Never display the other version manual direction');
    await textVisible(expected.manual); await persistedUnchanged();
  }
  if (semantic) {
    const outside = await ui.reveal(n => n.identifier === 'preview-inspect');
    await rejectRequest({ target: outside.path, action: 'Show captured generation prompt' });
  }
  await ui.activate(n => n.identifier === 'preview-inspect');
  await session.waitFor(nodes => nodes.some(n => n.text === `Version ${expected.version}`)
    && nodes.some(n => n.title === 'Show in script'));
  await collapsed();
  await disclosure('Show captured generation prompt');
  async function expanded() {
    const nodes = await session.waitFor(nodes => nodes.some(n => isText(n, expected.manual))
      && nodes.some(n => isText(n, generation)));
    assert.equal(nodes.filter(n => n.text === capturedPromptExplanation).length, expected.captured === null ? 0 : 1);
    assert.ok(!nodes.some(n => isText(n, other.manual)));
    assert.ok(!nodes.some(n => isText(n, expected.captured === null ? inspectorPrompts[0].captured : missingGenerationPrompt)));
    assert.notEqual(nodes.find(n => isText(n, expected.manual)).path, nodes.find(n => isText(n, generation)).path,
      'Manual direction and exact captured text (or explicit absence) are separate production text views');
    await textVisible(expected.manual); await textVisible(generation); await persistedUnchanged();
  }
  await expanded();
  await disclosure('Hide captured generation prompt');
  await collapsed();
  if (semantic) { await disclosure('Show captured generation prompt'); await expanded(); }
  await ui.activate(n => n.title === 'Done' && n.enabled !== undefined);
  await session.waitFor(nodes => !nodes.some(n => n.label === 'Image version actions')
    && nodes.some(n => n.identifier === 'preview-inspect' && n.hittable));
}
