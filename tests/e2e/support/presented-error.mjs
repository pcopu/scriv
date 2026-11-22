import assert from 'node:assert/strict';

export const jsonImportAcknowledgement = 'acknowledge-json-import-error';

// Read-only public UIAlertController presentation state, not pixel visibility,
// accessibility reachability or action invocation. No store error hooks.
export async function observePresentedError(session, message) {
  const deadline = Date.now() + 15000;
  do {
    const alerts = await session.command('presented-alerts', {}, Math.max(1, deadline - Date.now()));
    const nodes = await session.command('snapshot', {}, Math.max(1, deadline - Date.now()));
    const tabs = nodes.filter(node => node.identifier === 'workspace-tabs');
    if (alerts.length === 1 && alerts[0].observation === 'public-controller-presentation-state'
      && alerts[0].title === 'Scriv' && alerts[0].message === message && alerts[0].style === 'alert'
      && alerts[0].beingPresented === false && alerts[0].beingDismissed === false
      && alerts[0].viewAttachedToWindow === true && tabs.length === 1
      && tabs[0].enabled === false && tabs[0].hittable === false) {
      assert.deepEqual(alerts[0].actions, [{ title: 'OK', enabled: true, style: 'default' }]);
      return { nodes, alert: alerts[0], route: 'public-controller-presentation-state' };
    }
    if (Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, Math.min(50, deadline - Date.now())));
  } while (Date.now() < deadline);
  throw new Error('Exact production error did not reach a stable attached public UIAlertController');
}

export async function acknowledgeJSONImportError(session) {
  assert.deepEqual(await session.command(jsonImportAcknowledgement), { dispatched: true });
  await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.enabled && node.hittable));
  assert.deepEqual(await session.command('presented-alerts'), []);
}
