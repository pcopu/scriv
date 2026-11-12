#!/usr/bin/env node
// Opt-in real-runtime UI scenario. Never imported by standard test discovery.
import assert from 'node:assert/strict';
import { createConnection } from 'node:net';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { ScrivSession } from '../../cli/scriv.mjs';

/** Validate without launching, probing a socket, reading credentials, or logging inputs. */
export function validateConfiguration(env) {
  for (const name of [
    'SCRIV_LIVE_CODEX_ALLOWED',
    'SCRIV_LIVE_CODEX_ISOLATED_RUNTIME',
    'SCRIV_LIVE_CODEX_VERIFIED_CREDENTIAL_BACKEND',
    'SCRIV_LIVE_CODEX_TELEMETRY_DISABLED',
    'SCRIV_LIVE_CODEX_STANDARD_SERVICE',
  ]) {
    if (env[name] !== 'yes') throw new Error(`Set ${name}=yes only after verifying the documented prerequisite.`);
  }
  if (!env.SCRIV_E2E_APP) throw new Error('Set SCRIV_E2E_APP to the automation-enabled Catalyst bundle.');
  // Match the original string, not URL-normalized hostnames (which accept integer,
  // hex, shortened IPv4, userinfo, and other unexpected aliases).
  const address = env.SCRIV_LIVE_CODEX_ENDPOINT ?? '';
  const parts = /^ws:\/\/(127\.0\.0\.1|\[::1\]):([1-9][0-9]{3,4})\/?$/.exec(address);
  if (!parts || parts[0] !== address || Number(parts[2]) < 1024 || Number(parts[2]) > 65535) {
    throw new Error('SCRIV_LIVE_CODEX_ENDPOINT must be ws://127.0.0.1:PORT or ws://[::1]:PORT, with an explicit port 1024–65535 and no credentials, path, query, or fragment.');
  }
  const account = env.SCRIV_LIVE_CODEX_EXPECT_ACCOUNT;
  if (!['signed-out', 'authenticated'].includes(account)) {
    throw new Error('Set SCRIV_LIVE_CODEX_EXPECT_ACCOUNT to signed-out or authenticated; authentication must be completed separately.');
  }
  if (account === 'authenticated' && env.SCRIV_LIVE_CODEX_DEDICATED_TEST_IDENTITY !== 'yes') {
    throw new Error('Authenticated mode requires SCRIV_LIVE_CODEX_DEDICATED_TEST_IDENTITY=yes after verifying an approved dedicated test identity.');
  }
  return { app: env.SCRIV_E2E_APP, address, host: parts[1] === '[::1]' ? '::1' : parts[1], port: Number(parts[2]), account };
}

// Read-only transport reachability, not an authentication check or an ownership
// proof. No WebSocket request, auth material, or arbitrary response is recorded.
function listenerReachable({ host, port }) {
  return new Promise((resolve, reject) => {
    const socket = createConnection({ host, port });
    const finish = error => { socket.destroy(); error ? reject(new Error('Dedicated loopback listener is not reachable.')) : resolve(); };
    socket.setTimeout(3000, () => finish(true));
    socket.once('error', () => finish(true));
    socket.once('connect', () => finish(false));
  });
}
const byID = (nodes, id) => nodes.filter(node => node.identifier === id);
function paneNodes(nodes) {
  const panes = byID(nodes, 'codex-settings');
  if (panes.length !== 1) return [];
  return nodes.filter(node => node.path === panes[0].path || node.path.startsWith(`${panes[0].path}.`));
}
const textOf = node => node?.text ?? node?.title ?? node?.label ?? '';
const hasText = (nodes, id, value) => byID(nodes, id).length === 1 && textOf(byID(nodes, id)[0]) === value;
function disconnected(nodes) {
  const pane = paneNodes(nodes);
  return hasText(pane, 'codex-connection-status', 'Not connected')
    && byID(pane, 'codex-account-status').length === 0
    && byID(pane, 'codex-model').length === 0
    && byID(pane, 'codex-stop').length === 0
    && byID(pane, 'codex-connect').some(node => node.enabled === true);
}
function connected(nodes, account) {
  const pane = paneNodes(nodes);
  const stop = byID(pane, 'codex-stop');
  if (stop.length !== 1 || stop[0].label !== 'Disconnect' || !stop[0].enabled) return false;
  if (byID(pane, 'codex-setup-error').length) return false;
  if (account === 'signed-out') {
    return hasText(pane, 'codex-connection-status', 'Connected · sign-in needed')
      && hasText(pane, 'codex-account-status', 'Not signed in')
      && byID(pane, 'codex-model').length === 0;
  }
  const accounts = byID(pane, 'codex-account-status');
  const models = byID(pane, 'codex-model');
  return hasText(pane, 'codex-connection-status', 'Connected')
    && accounts.length === 1 && textOf(accounts[0]).length > 0
    && !['Not signed in', 'Not checked yet', 'Checking existing account…', 'Complete sign-in in your browser', 'Not required by this provider'].includes(textOf(accounts[0]))
    && models.length === 1 && models[0].enabled === true
    && models[0].label.startsWith('Model: ') && models[0].label.length > 7
    && !['Model: Choose available model', 'Model: No available models reported'].includes(models[0].label);
}

/** Only scroll UIKit's visible settings pane, then return a fresh target path. */
async function reveal(session, predicate) {
  let nodes = paneNodes(await session.command('snapshot'));
  const scrolls = byID(nodes, 'codex-setup-scroll');
  assert.equal(scrolls.length, 1, 'Expected exactly one owned settings scroll view.');
  const height = scrolls[0].scroll?.contentHeight;
  assert.ok(Number.isFinite(height) && height >= 0 && height <= 20000, 'Unexpected settings scroll extent.');
  for (let y = 0; y <= height + 240; y += 240) {
    await session.command('scroll', { target: 'codex-setup-scroll', y });
    nodes = paneNodes(await session.command('snapshot'));
    const targets = nodes.filter(predicate);
    assert.ok(targets.length <= 1, 'Ambiguous settings target.');
    if (targets.length === 1 && targets[0].hittable && targets[0].enabled !== false) return targets[0];
  }
  throw new Error('Expected settings control never became actionable.');
}
async function activate(session, id, label) {
  const node = await reveal(session, node => node.identifier === id);
  assert.equal(node.label, label, 'Unexpected action label; refusing a different operation.');
  await session.command('activate', { target: node.path });
}

export async function run(env = process.env) {
  let session;
  let stage = 'configuration';
  try {
    const config = validateConfiguration(env);
    stage = 'macOS host preflight';
    if (process.platform !== 'darwin') throw new Error('Requires macOS.');
    stage = 'dedicated listener preflight';
    await listenerReachable(config);
    stage = 'isolated Catalyst launch';
    session = await ScrivSession.launch(config.app);
    stage = 'open native Settings with Command-comma';
    await session.waitFor(nodes => byID(nodes, 'workspace-tabs').some(node => node.hittable));
    await session.command('key', { input: ',', modifiers: ['command'] });
    let nodes = await session.waitFor(nodes => byID(nodes, 'scriv.settings.codex').some(node => node.hittable));
    const cells = byID(nodes, 'scriv.settings.codex').filter(node => node.hittable);
    assert.equal(cells.length, 1, 'Expected one native Codex settings item.');
    await session.command('activate', { target: cells[0].path });
    stage = 'initial disconnected state';
    await session.waitFor(disconnected);
    for (let cycle = 1; cycle <= 3; cycle++) {
      stage = `cycle ${cycle}: enter supplied manual endpoint`;
      const endpoint = await reveal(session, node => node.label === 'Saved loopback server address');
      await session.command('text', { target: endpoint.path, text: config.address });
      nodes = paneNodes(await session.command('snapshot'));
      const fields = nodes.filter(node => node.label === 'Saved loopback server address');
      assert.equal(fields.length, 1);
      assert.equal(fields[0].text, config.address, 'Endpoint edit was not accepted.');
      await session.command('end-editing');
      stage = `cycle ${cycle}: connect to supplied address and observe ${config.account} state`;
      await activate(session, 'codex-connect', 'Connect to this address');
      await session.waitFor(nodes => connected(nodes, config.account), 30000);
      stage = `cycle ${cycle}: disconnect through UI and clear account/model readiness`;
      await activate(session, 'codex-stop', 'Disconnect');
      await session.waitFor(disconnected);
      stage = `cycle ${cycle}: external listener survives disconnect`;
      await listenerReachable(config);
      console.log(JSON.stringify({ scenario: 'live-codex-connection', cycle, status: 'observed', account: config.account, disconnected: true, listenerReachable: true, submittedTurns: 0 }));
    }
    stage = 'close isolated app';
    await session.close();
    session = undefined;
    console.log('PASS: three real UIKit manual connect/disconnect cycles; external listener reachable after each disconnect; no sign-in or generation requested.');
  } catch (error) {
    // Do not stringify app/RPC errors or snapshots: they can contain account
    // identity, login URLs, or provider diagnostics. Stage names are fixed text.
    const detail = stage === 'configuration' ? ` ${error.message}` : ' Inspect the prerequisite checklist and the isolated test UI without exporting authentication diagnostics. No automatic retry was attempted.';
    throw new Error(`BLOCKED/FAILED at ${stage}.${detail}`);
  } finally {
    if (session) await session.close().catch(() => { console.error('Cleanup could not confirm isolated app exit; inspect the test app locally. External runtime was not stopped.'); });
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  run().catch(error => { console.error(error.message); process.exitCode = 1; });
}
