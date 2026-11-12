import assert from 'node:assert/strict';
import { scriptAuthoringSteps, runScriptJourney, named, lineIDs } from './support/script-authoring-steps.mjs';
import { searchFixtures as fixture, searchCases } from './support/script-authoring-cases.mjs';

// AUT-J01 Find portion, not source mutation or scene-restructure coverage.
async function findReadClose(session) {
  const step = scriptAuthoringSteps(session);
  const fields = nodes => nodes.filter(node => node.placeholder === 'Find in script');
  let before = await step.openScript();
  const addedIDs = [];
  for (const text of [fixture.first, fixture.second]) {
    const { editor, entryID, lineID } = await step.addDialogue(before, { allowEmptyStateName: true });
    await session.command('text', { target: editor.identifier, text });
    await session.waitFor(nodes => nodes.some(node => node.identifier === editor.identifier && node.text === text));
    await step.finishEditor();
    await step.displayed(entryID, text);
    before = await step.saved(project => project.id === before.id && project.entries.some(entry => entry.text === text));
    addedIDs.push(lineID);
  }
  before = await step.saved(project => [fixture.first, fixture.second].every(text => project.entries.some(entry => entry.text === text)));
  const baseline = lineIDs(await session.command('snapshot'));
  assert.ok(addedIDs.every(id => baseline.includes(id)));
  async function openFind() {
    const scoped = nodes => {
      const headers = nodes.filter(node => /ScrivWorkspaceHeader$/.test(node.type));
      return named(nodes, 'Find in script').filter(node => node.hittable && headers.some(header => node.path.startsWith(header.path + '.')));
    };
    const nodes = await session.waitFor(nodes => scoped(nodes).length === 1);
    await session.command('activate', { target: scoped(nodes)[0].path });
  }
  async function findField() {
    const nodes = await session.waitFor(nodes => fields(nodes).length === 1 && fields(nodes)[0].hittable && fields(nodes)[0].firstResponder);
    return fields(nodes)[0];
  }
  async function query(text) {
    await session.command('text', { target: (await findField()).path, text });
    await session.waitFor(nodes => fields(nodes).some(node => node.text === text && node.firstResponder));
  }
  async function count(text) {
    const nodes = await session.waitFor(nodes => {
      const field = fields(nodes)[0];
      if (!field) return false;
      const row = field.path.slice(0, field.path.lastIndexOf('.'));
      return nodes.some(node => node.path.startsWith(row + '.') && /Label/.test(node.type) && node.text === text);
    });
    assert.deepEqual(lineIDs(nodes), baseline, 'Find preserves all mounted scene lines');
  }
  async function closed() {
    await session.waitFor(nodes => fields(nodes).length === 0 && named(nodes, 'Next match').length === 0 && named(nodes, 'Previous match').length === 0);
  }

  await openFind();
  assert.equal((await findField()).text, '');
  await query(fixture.mixedQuery);
  await count('1 / 2'); // Two source entries, never three substring occurrences.
  for (const [action, expected] of [['Next match', '2 / 2'], ['Next match', '1 / 2'],
    ['Previous match', '2 / 2'], ['Previous match', '1 / 2']]) {
    await step.activate(action);
    await count(expected);
  }
  await step.key('g', ['command']);
  await count('2 / 2');
  await step.key('g', ['command', 'shift']);
  await count('1 / 2');
  await step.key('f', ['command']);
  assert.equal((await findField()).text, fixture.mixedQuery);
  await count('1 / 2');
  console.log('PASS: AUT-J01/find-read-close/count-wrap-and-refocus');

  await query(fixture.missing);
  await count('0 results');
  await step.activate('Next match');
  await step.activate('Previous match');
  await count('0 results');
  await query(fixture.unicodeQuery);
  await count('1 / 1');
  await step.activate('Next match');
  await count('1 / 1');
  await query(fixture.query);
  await count('1 / 2');
  await step.activate('Next match');
  await count('2 / 2');
  console.log('PASS: AUT-J01/find-read-close/zero-unicode-recovery');

  await step.key('Escape');
  await closed();
  for (const [priorDismissal, nextDismissal] of [['Escape', 'Close'], ['Close', 'Escape']]) {
    await openFind();
    assert.equal((await findField()).text, '', `${priorDismissal} clears query on reopen`);
    await query(fixture.query);
    await count('1 / 2');
    if (nextDismissal === 'Escape') await step.key('Escape'); else await step.activate('Close');
    await closed();
  }
  const after = (await session.command('persisted-projects')).find(project => project.id === before.id);
  assert.ok(after, 'Same isolated saved project remains present');
  assert.deepEqual(after.entries, before.entries, 'Searching does not change persisted script entries');
  console.log('PASS: AUT-J01/find-read-close/escape-close-reopen');
}
await runScriptJourney({ journey: 'AUT-J01', workflows: { 'find-read-close': findReadClose }, cases: searchCases,
  excluded: ['physical keyboard/IME events', 'Find-field Return', 'name/alias fixture variants', 'relaunch/reopen', 'full navigation/zoom family'] });
