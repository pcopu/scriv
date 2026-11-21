import assert from 'node:assert/strict';
import { ScrivSession } from '../../cli/scriv.mjs';
import { waitForSavedProject } from './support/saved-projects.mjs';
assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const buttons = (nodes, title) => nodes.filter(node => node.enabled && node.hittable && (node.title === title || node.label === title));
async function click(title) {
  const nodes = await session.waitFor(nodes => buttons(nodes, title).length === 1);
  await session.command('activate', { target: buttons(nodes, title)[0].path });
}
try {
  await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.enabled && node.hittable));
  for (let repeat = 0; repeat < 2; repeat++) {
    await session.command('activate', { target: 'workspace-project' });
    let nodes = await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project'));
    const search = nodes.find(node => node.placeholder === 'Find a project');
    await session.command('text', { target: search.path, text: 'no-such-synthetic-project-7c891' });
    await session.waitFor(nodes => nodes.some(node => node.text === 'No matching projects'));
    // The CLI must respect modal routing rather than activating covered controls.
    await assert.rejects(session.command('select', { target: 'workspace-tabs', index: 1 }), /active presentation|disabled|exactly one/);
    await click('Clear search');
    await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project' && node.text === ''));
    await click('Close Projects');
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.enabled && node.hittable) && !nodes.some(node => node.placeholder === 'Find a project'));
  }
  // Save only the session-owned sample, then create a distinct local project.
  await session.command('key', { input: 's', modifiers: ['command'] });
  const original = await waitForSavedProject(session, project => project.title === 'YAM MAN');
  const originalLoaded = await session.command('loaded-project');
  assert.equal(originalLoaded.project.id, original.id);
  await session.command('activate', { target: 'workspace-project' });
  await click('New project');
  const created = await waitForSavedProject(session, project => project.id !== original.id);
  assert.equal(created.title, 'Untitled');
  assert.deepEqual(created.entries.map(entry => entry.text), ['Describe the opening moment.', 'Your first line.']);
  let nodes = await session.command('snapshot');
  if (nodes.some(node => node.placeholder === 'Find a project')) await click('Close Projects');
  await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.title === 'Untitled' && node.hittable));
  const createdLoaded = await session.command('loaded-project');
  assert.equal(createdLoaded.project.id, created.id);

  await session.command('activate', { target: 'workspace-project' });
  for (const [source, emptyTitle] of [['Scriv Cloud', 'Your scriv cloud'], ['Team projects', 'Your team projects']]) {
    await click(source);
    nodes = await session.waitFor(nodes => nodes.some(node => node.text === emptyTitle));
    assert.ok(nodes.some(node => node.text === 'Sign in for free script storage and team access. Your local projects stay available without an account.'));
    assert.ok(nodes.some(node => node.title === 'Open project' && node.enabled === false), 'Signed-out source cannot open a local project');
    assert.ok(nodes.some(node => node.title === 'Sign in to Scriv' && node.hittable), 'Empty cloud source offers sign-in');
  }
  await click('On this Mac');
  // Leading/trailing whitespace and case folding operate on real local metadata.
  for (const [query, expected, baseline] of [['  yAm mAn  ', original, originalLoaded], ['  uNtItLeD  ', created, createdLoaded]]) {
    nodes = await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project' && node.hittable));
    await session.command('text', { target: nodes.find(node => node.placeholder === 'Find a project' && node.hittable).path, text: query });
    await session.waitFor(nodes => nodes.some(node => node.text === `${expected.title} · ${expected.scenes.length} scene${expected.scenes.length === 1 ? '' : 's'}`));
    await click('Open project');
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.title === expected.title && node.hittable) && !nodes.some(node => node.placeholder === 'Find a project'));
    assert.deepEqual(await session.command('loaded-project'), baseline, 'Filtered Open restores the complete saved model and exact dates');
    assert.deepEqual(await session.command('presented-alerts'), [], 'Opening owned packages presents no recovery error');
    if (expected.id === original.id) {
      await session.command('activate', { target: 'workspace-project' });
      await click('Recent');
    }
  }
  const retained = await session.command('persisted-projects');
  assert.equal(retained.length, 2, 'Filtering and opening never duplicate or delete a package');
  assert.deepEqual(retained.find(project => project.id === original.id), original, 'Original sample remains byte-model equivalent');
  assert.deepEqual(retained.find(project => project.id === created.id), created, 'Created project remains byte-model equivalent');
  const expectedPackages = [...retained].sort((left, right) => left.id.localeCompare(right.id));
  for (const test of [
    { query: 'no-such-synthetic-project-7c891', input: 'Escape', modifiers: [], action: 'closeCommand', expected: created, baseline: createdLoaded },
    { query: '  yAm mAn  ', input: '\r', modifiers: ['command'], action: 'openCommand', expected: original, baseline: originalLoaded }
  ]) {
    await session.command('activate', { target: 'workspace-project' });
    nodes = await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project' && node.hittable));
    await session.command('text', { target: nodes.find(node => node.placeholder === 'Find a project' && node.hittable).path, text: test.query });
    await session.waitFor(nodes => nodes.some(node => node.text === (test.input === 'Escape'
      ? 'No matching projects'
      : `${original.title} · ${original.scenes.length} scene${original.scenes.length === 1 ? '' : 's'}`)));
    const commands = await session.command('keys');
    const handler = commands.find(command => command.input === test.input
      && command.modifiers.length === test.modifiers.length
      && test.modifiers.every(modifier => command.modifiers.includes(modifier)));
    assert.ok(handler, 'The active responder chain offers the exact browser shortcut');
    assert.equal(handler.responderType, 'ProjectBrowserController', 'Public key dispatch reaches the presented browser first');
    assert.equal(handler.action, test.action);
    assert.deepEqual(await session.command('key', { input: test.input, modifiers: test.modifiers }), { dispatched: true });
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.title === test.expected.title && node.enabled && node.hittable)
      && !nodes.some(node => node.placeholder === 'Find a project'));
    assert.deepEqual(await session.command('loaded-project'), test.baseline, 'Browser keyboard cancellation/open preserves the complete expected model and exact dates');
    assert.deepEqual(await session.command('presented-alerts'), [], 'Browser shortcuts present no error or recovery alert');
    const packages = await session.command('persisted-projects');
    assert.deepEqual(packages.sort((left, right) => left.id.localeCompare(right.id)), expectedPackages,
      'Browser keyboard cancellation/open preserves exactly both complete saved packages');
  }
  async function waitForSettledControl(predicate) {
    // Snapshot hit-testing becomes available before UIKit clears isBeingPresented.
    // The CLI exposes no transition-completion bit. Require one second of stable
    // mounted control geometry (within waitFor's 15-second bound) before the
    // next presentation/dismissal action. Mutations are dispatched only once.
    let previous = '';
    let stableSince = 0;
    return session.waitFor(nodes => {
      const matches = nodes.filter(node => node.hittable && node.enabled && predicate(node));
      const current = matches.length === 1 ? JSON.stringify([matches[0].path, matches[0].frame]) : '';
      if (!current || current !== previous) {
        previous = current;
        stableSince = Date.now();
        return false;
      }
      return Date.now() - stableSince >= 1000;
    });
  }
  const emailField = nodes => nodes.filter(node => node.type === 'UITextField' && node.label === 'Email address' && node.hittable);
  const emailActions = nodes => nodes.filter(node => node.type === 'UIButton' && node.title === 'Continue with email');
  const cloudIsolation = (await session.command('capabilities')).cloudIsolation;
  assert.equal(cloudIsolation.network, 'disabled');
  assert.equal(cloudIsolation.oauth, 'disabled');
  const isolatedError = 'Isolated CLI cloud access is unavailable.';
  const codeView = node => node.text === 'Check your email' || node.type === 'UITextField' && node.label === 'Verification code';
  for (let repeat = 0; repeat < 2; repeat++) {
    await session.command('activate', { target: 'workspace-project' });
    await waitForSettledControl(node => node.title === 'Sign in to Scriv…' || node.label === 'Sign in to Scriv…');
    await click('Sign in to Scriv…');
    nodes = await session.waitFor(nodes => emailField(nodes).length === 1 && emailActions(nodes).length === 1);
    await waitForSettledControl(node => node.type === 'UITextField' && node.label === 'Email address');
    assert.equal(emailField(nodes)[0].text, '', 'Reopened sign-in starts with an empty transient email draft');
    assert.equal(emailField(nodes)[0].enabled, true);
    assert.equal(emailActions(nodes)[0].enabled, false, 'Empty email cannot request a code');
    assert.ok(nodes.some(node => node.text === 'Save scripts to the cloud and join your team.'));
    assert.equal(nodes.some(node => node.label === 'Verification code' && node.hittable), false);
    assert.equal(nodes.some(node => node.title === 'Continue with GitHub…' && node.hittable), false, 'Reopened sign-in collapses the provider disclosure');
    for (const [value, enabled] of [
      ['   ', false], ['not-an-email', false], ['writer@localhost', false],
      ['a..b@example.invalid', false], [' Writer@Example.invalid ', true], ['', false]
    ]) {
      await session.command('text', { target: emailField(nodes)[0].path, text: value });
      nodes = await session.waitFor(nodes => emailField(nodes).length === 1 && emailField(nodes)[0].text === value
        && emailActions(nodes).length === 1 && emailActions(nodes)[0].enabled === enabled);
      assert.equal(emailActions(nodes)[0].enabled, enabled, 'Email syntax controls the real request button without sending a request');
    }
    await click('Already used GitHub?');
    nodes = await session.waitFor(nodes => nodes.some(node => node.title === 'Continue with GitHub…' && node.enabled && node.hittable));
    assert.ok(nodes.some(node => node.text === 'Use your existing GitHub-linked Scriv account.'));
    await click('Already used GitHub?');
    await session.waitFor(nodes => !nodes.some(node => node.title === 'Continue with GitHub…' && node.hittable));
    // Leave the disclosure expanded before dismissal to check fresh state on reopen.
    await click('Already used GitHub?');
    await session.waitFor(nodes => nodes.some(node => node.title === 'Continue with GitHub…' && node.enabled && node.hittable));
    assert.ok(!nodes.some(node => node.text === isolatedError));
    if (repeat === 0) {
      await click('Continue with GitHub…');
    } else {
      const address = 'fixture@example.invalid';
      const fields = await waitForSettledControl(node => node.type === 'UITextField' && node.label === 'Email address');
      await session.command('text', { target: emailField(fields)[0].path, text: address });
      await click('Continue with email');
    }
    await session.waitFor(nodes => nodes.some(node => node.text === isolatedError)
      && nodes.some(node => node.title === 'Continue with email')
      && !nodes.some(codeView));
    assert.deepEqual(await session.command('presented-alerts'), []);
    await click('Keep writing locally');
    await session.waitFor(nodes => nodes.some(node => node.placeholder === 'Find a project' && node.hittable) && emailField(nodes).length === 0);
    await waitForSettledControl(node => node.title === 'Close Projects' || node.label === 'Close Projects');
    await click('Close Projects');
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.title === original.title && node.enabled && node.hittable)
      && !nodes.some(node => node.placeholder === 'Find a project'));
    await waitForSettledControl(node => node.identifier === 'workspace-project');
    assert.deepEqual(await session.command('loaded-project'), originalLoaded, 'Cancelling signed-out sign-in preserves the complete loaded project');
    assert.deepEqual(await session.command('presented-alerts'), []);
    const packages = await session.command('persisted-projects');
    assert.deepEqual(packages.sort((left, right) => left.id.localeCompare(right.id)), expectedPackages,
      'Sign-in drafts and disclosure changes preserve both complete saved packages');
  }
  for (let repeat = 0; repeat < 2; repeat++) {
    await waitForSettledControl(node => node.label === 'Teams and sharing');
    await click('Teams and sharing');
    nodes = await session.waitFor(nodes => nodes.some(node => node.text === 'Your entire team. One subscription.'));
    assert.ok(nodes.some(node => node.text === 'Teams & sharing'));
    assert.ok(nodes.some(node => node.text === '$9.99/month per team, with no per-seat charge. Personal editing and hosted script, timing and image-prompt metadata remain free; Team adds collaboration and private image-file hosting.'));
    assert.equal(buttons(nodes, 'Sign in to Scriv').length, 1, 'Signed-out Teams offers sign-in');
    for (const title of ['New team', 'Join', 'Invite people']) {
      assert.equal(buttons(nodes, title).length, 0, 'Signed-out Teams hides account-only actions');
    }
    assert.equal(nodes.some(node => node.type === 'UISegmentedControl' && node.hittable
      && node.segments?.includes('Members') && node.segments?.includes('Invitations')), false);
    await waitForSettledControl(node => node.title === 'Done' || node.label === 'Done');
    await click('Done');
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.enabled && node.hittable)
      && !nodes.some(node => node.text === 'Teams & sharing'));
    await waitForSettledControl(node => node.identifier === 'workspace-project');
    assert.deepEqual(await session.command('loaded-project'), originalLoaded, 'Opening signed-out Teams preserves the complete loaded project');
    assert.deepEqual(await session.command('presented-alerts'), []);
    const packages = await session.command('persisted-projects');
    assert.deepEqual(packages.sort((left, right) => left.id.localeCompare(right.id)), expectedPackages,
      'Opening and dismissing signed-out Teams preserves both complete saved packages');
  }
  console.log('PASS: actual project browser search, sources, local open/reopen, keyboard cancellation/open, signed-out sign-in and Teams, model preservation, and modal routing');
} finally { await session.close(); }
