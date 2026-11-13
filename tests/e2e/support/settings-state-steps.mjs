import assert from 'node:assert/strict';

const byID = (nodes, id) => nodes.filter(node => node.identifier === id);
const one = (nodes, predicate, description) => {
  const matches = nodes.filter(predicate);
  assert.equal(matches.length, 1, `Exactly one ${description}`);
  return matches[0];
};
const codexPane = nodes => {
  const pane = one(nodes, node => node.identifier === 'codex-settings', 'Codex settings pane');
  return nodes.filter(node => node.path === pane.path || node.path.startsWith(`${pane.path}.`));
};

export async function assertIdleSettings(session) {
  const nodes = await session.waitFor(nodes => byID(nodes, 'codex-settings').length === 1
    && byID(nodes, 'codex-connection-status').some(node => node.text === 'Not connected'));
  const pane = codexPane(nodes);
  assert.equal(one(pane, node => node.identifier === 'codex-connection-status', 'connection label').text, 'Not connected');
  for (const id of ['codex-account-status', 'codex-account', 'codex-refresh-account', 'codex-model',
    'codex-stop', 'codex-cancel-check', 'codex-setup-error']) {
    assert.equal(byID(pane, id).length, 0, `${id} stays hidden in idle settings`);
  }
  for (const [id, label] of [['codex-check', 'Connect'], ['codex-connect', 'Connect to this address']]) {
    const button = one(pane, node => node.identifier === id, label);
    assert.equal(button.label, label);
    assert.equal(button.enabled, true);
  }
  assert.ok(pane.some(node => node.text === 'Scriv starts Codex on this Mac when you connect.'));
  assert.ok(pane.some(node => node.text === 'Your Codex account stays on this Mac. Scriv sign-in is separate. Opening Settings does not connect or sign in.'));
  const endpoint = one(pane, node => node.type === 'UITextField' && node.label === 'Saved loopback server address', 'saved endpoint field');
  assert.equal(endpoint.text, 'ws://127.0.0.1:4500');
  assert.equal(endpoint.enabled, true);
  assert.equal(endpoint.firstResponder, false);
  const executable = one(pane, node => node.type === 'UITextField' && node.label === 'Installed Codex executable', 'executable field');
  assert.equal(executable.enabled, true);
  assert.equal(executable.firstResponder, false);
  // A fresh Catalyst session uses automatic discovery through its companion.
  // The local client never probes the host installation when this pane opens.
  assert.equal(executable.text, 'automatic');
}

export async function exerciseAccountDraft(session) {
  const initial = await session.waitFor(nodes => nodes.some(node => node.text === 'Write locally, or sign in'));
  const account = one(initial, node => node.identifier === 'scriv.settings.account' && node.hittable, 'Account sidebar cell');
  const inWindow = nodes => nodes.filter(node => node.windowPath === account.windowPath);
  const button = (nodes, label) => one(inWindow(nodes), node => node.type === 'UIButton' && node.label === label && node.hittable && node.enabled, label);
  assert.ok(inWindow(initial).some(node => node.text === 'Free script storage and team access'));
  assert.ok(inWindow(initial).some(node => node.text === 'Sign out before changing servers.'));
  button(initial, 'Sign in');
  assert.equal(inWindow(initial).filter(node => node.placeholder === 'https://your-scriv-service').length, 0);
  await session.command('activate', { target: button(initial, 'Server settings').path });
  const expanded = await session.waitFor(nodes => inWindow(nodes).some(node => node.placeholder === 'https://your-scriv-service' && node.hittable));
  const field = nodes => one(inWindow(nodes), node => node.type === 'UITextField' && node.placeholder === 'https://your-scriv-service', 'server field');
  const original = field(expanded).text;
  assert.equal(field(expanded).enabled, true);
  button(expanded, 'Save address');
  assert.ok(inWindow(expanded).some(node => node.text === "Use your Scriv service's HTTPS address. Changing servers cancels any pending sign-in."));
  const draft = 'https://settings-draft.invalid';
  await session.command('text', { target: field(expanded).path, text: draft });
  const edited = await session.waitFor(nodes => inWindow(nodes).some(node => node.placeholder === 'https://your-scriv-service' && node.text === draft));
  await session.command('activate', { target: button(edited, 'Server settings').path });
  const collapsed = await session.waitFor(nodes => inWindow(nodes).every(node => node.placeholder !== 'https://your-scriv-service'));
  assert.equal(inWindow(collapsed).filter(node => node.label === 'Save address').length, 0);
  assert.ok(inWindow(collapsed).some(node => node.text === 'Write locally, or sign in'));
  await session.command('activate', { target: button(collapsed, 'Server settings').path });
  const reopened = await session.waitFor(nodes => inWindow(nodes).some(node => node.placeholder === 'https://your-scriv-service' && node.text === draft));
  assert.equal(field(reopened).text, draft, 'Unsaved server draft survives disclosure close and reopen');
  assert.equal(field(reopened).firstResponder, false, 'Collapsing server settings ends editing');
  // Restore only the draft. Save address is never activated.
  await session.command('text', { target: field(reopened).path, text: original });
  const restored = await session.waitFor(nodes => inWindow(nodes).some(node => node.placeholder === 'https://your-scriv-service' && node.text === original));
  await session.command('activate', { target: button(restored, 'Server settings').path });
  const final = await session.waitFor(nodes => inWindow(nodes).every(node => node.placeholder !== 'https://your-scriv-service'));
  button(final, 'Sign in');
  assert.ok(inWindow(final).some(node => node.text === 'Write locally, or sign in'));
}
