import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { ScrivSession } from '../../cli/scriv.mjs';

// Only the rejected literals in frozen baseline CodexConnectionCheckTests::0004.
// The userinfo/query values are synthetic test strings, never credentials.
const invalidEndpoints = Object.freeze([
  'ws://example.com:4500', 'ws://0.0.0.0:4500', 'ws://127.0.0.1:80',
  'https://127.0.0.1:4500', 'ws://a:b@127.0.0.1:4500',
  'ws://127.0.0.1:4500?token=secret', 'ws://127.0.0.1:4500#fragment',
  'ws://127.0.0.1:65536',
]);
const errorText = 'Use an unprivileged loopback Codex app-server address on this Mac, without credentials or query parameters.';
const source = async path => readFile(new URL(`../../${path}`, import.meta.url), 'utf8');
// Fail closed on source drift. This is source evidence, NOT binary attestation
// or a network trace; run only a separately verified build of this checkout.
const controller = await source('apps/mac/Sources/ScrivApp/Services/CodexController.swift');
const connect = controller.split('    func connect(timeout:')[1]?.split('    private func initialize(')[0];
assert.ok(connect, 'Expected manual connect implementation');
const validation = connect.indexOf('let url = try CodexLocalSetup.endpointURL(endpoint)');
assert.ok(validation >= 0);
for (const marker of ['disconnect(cancelCheck: false)', 'isConnecting = true', 'URLSessionConfiguration.ephemeral', 'URLSession(configuration:', 'session.webSocketTask(with: url)', 'ws.resume()']) {
  assert.ok(connect.indexOf(marker) > validation, `Endpoint validation must precede ${marker}`);
}
assert.doesNotMatch(connect.slice(0, validation), /URLSession|webSocketTask|\.resume\(/);
const settings = await source('apps/catalyst/ScrivUIKit/Account/ScrivSettingsController.swift');
assert.ok(settings.includes('setup.onConnect = { [weak self] in self?.run { [weak self] in guard let self else { return }; self.saveRuntimeFields(); try await self.store.codex.connect() } }'), 'Re-review manual action routing before running');
const policy = await source('apps/mac/Sources/ScrivCore/CodexConnectionCheck.swift');
for (const guard of ['["ws", "wss"].contains(parts.scheme ?? "")', '["localhost", "127.0.0.1", "::1", "[::1]"].contains(parts.host ?? "")', 'parts.user == nil, parts.password == nil, parts.fragment == nil', 'parts.query == nil, parts.port.map({ (1024...65535).contains($0) }) ?? false', `throw ScrivError.permission("${errorText}")`]) {
  assert.ok(policy.includes(guard), 'Re-review endpoint rejection policy before running');
}
if (process.argv.includes('--check-source-only')) {
  console.log('PASS: source ordering/policy guard only; actual UIKit scenario NOT run');
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to a verified automation-enabled build of this checkout');
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const byID = (nodes, id) => nodes.filter(node => node.identifier === id);
  const paneNodes = nodes => {
    const panes = byID(nodes, 'codex-settings');
    if (panes.length !== 1) return [];
    return nodes.filter(node => node.path === panes[0].path || node.path.startsWith(`${panes[0].path}.`));
  };
  const field = node => node.label === 'Saved loopback server address' && node.type === 'UITextField';
  const textOf = node => node?.text ?? node?.title ?? node?.label ?? '';
  const disconnected = nodes => {
    const pane = paneNodes(nodes);
    return byID(pane, 'codex-connection-status').length === 1
      && textOf(byID(pane, 'codex-connection-status')[0]) === 'Not connected'
      && ['codex-account-status', 'codex-model', 'codex-stop', 'codex-cancel-check'].every(id => byID(pane, id).length === 0)
      && byID(pane, 'codex-connect').some(node => node.enabled === true);
  };
  async function reveal(predicate) {
    let nodes = paneNodes(await session.command('snapshot'));
    const scrolls = byID(nodes, 'codex-setup-scroll');
    assert.equal(scrolls.length, 1);
    const height = scrolls[0].scroll?.contentHeight;
    assert.ok(Number.isFinite(height) && height >= 0 && height <= 20000);
    for (let y = 0; y <= height + 240; y += 240) {
      const scroll = byID(paneNodes(await session.command('snapshot')), 'codex-setup-scroll');
      assert.equal(scroll.length, 1);
      await session.command('scroll', { target: scroll[0].path, y });
      nodes = paneNodes(await session.command('snapshot'));
      const targets = nodes.filter(predicate);
      assert.ok(targets.length <= 1, 'Ambiguous settings target');
      if (targets.length === 1 && targets[0].hittable && targets[0].enabled !== false) return targets[0];
    }
    throw new Error('Settings target did not become actionable');
  }
  async function enter(value) {
    const endpoint = await reveal(field);
    await session.command('text', { target: endpoint.path, text: value });
    await session.waitFor(nodes => paneNodes(nodes).some(node => field(node) && node.text === value && node.firstResponder));
  }
  try {
    await session.waitFor(nodes => byID(nodes, 'workspace-tabs').some(node => node.hittable && node.enabled));
    await session.command('key', { input: ',', modifiers: ['command'] });
    const nodes = await session.waitFor(nodes => byID(nodes, 'scriv.settings.codex').filter(node => node.hittable).length === 1);
    await session.command('activate', { target: byID(nodes, 'scriv.settings.codex').find(node => node.hittable).path });
    await session.waitFor(disconnected);
    for (let cycle = 1; cycle <= 2; cycle++) {
      for (const address of invalidEndpoints) {
        await enter(''); // Clearing is observed, but never submitted as a connection.
        await session.waitFor(disconnected);
        await enter(address);
        const button = await reveal(node => node.identifier === 'codex-connect');
        assert.equal(button.label, 'Connect to this address');
        const before = await session.command('snapshot');
        assert.ok(disconnected(before), 'Refuse activation unless still disconnected');
        const fields = paneNodes(before).filter(field);
        assert.equal(fields.length, 1);
        assert.equal(fields[0].text, address, 'Never submit a default or normalized endpoint');
        assert.equal(fields[0].firstResponder, true, 'Keep edit alive until manual action saves it');
        assert.ok(invalidEndpoints.includes(fields[0].text));
        // No end-editing: manual onConnect saves the field itself. Never invoke
        // codex-check (primary Connect), start, sign-in, logout or any provider.
        await session.command('activate', { target: button.path });
        await session.waitFor(nodes => disconnected(nodes)
          && byID(paneNodes(nodes), 'codex-setup-error').length === 1
          && textOf(byID(paneNodes(nodes), 'codex-setup-error')[0]) === errorText
          && paneNodes(nodes).some(node => field(node) && node.text === address));
      }
      console.log(`Observed invalid-endpoint cycle ${cycle}: eight local rejections; disconnected`);
    }
    await enter('');
    await session.waitFor(disconnected);
    console.log('PASS: actual UIKit manual endpoint rejection, repeated edits/clears and disconnected state; no valid endpoint submitted');
  } finally { await session.close(); }
  if (process.env.SCRIV_LIVE_CODEX_ALLOWED === 'yes') {
    const { run } = await import('../live-e2e/codex-connection.mjs');
    await run(process.env);
  }
}
