/** Service-specific public CLI assertions; expected routes stay independent of implementation. */
import assert from 'node:assert/strict';

export function assertServiceDiscovery(run) {
  const catalog = JSON.parse(run(['app', '--', 'test', 'services', '--list']).stdout);
  assert.equal(catalog.kind, 'local-service-cli-scenario-catalog');
  assert.deepEqual(catalog.scenarios, [
    { id: 'cloud', path: 'cloud/tests-e2e/service-journey.mjs' },
    { id: 'updates', path: 'updates/tests-e2e/update-journey.mjs' },
    { id: 'collaboration', path: 'cloud/tests-e2e/collaboration-journey.mjs' },
    { id: 'discussions-assets', path: 'cloud/tests-e2e/discussions-assets-journey.mjs' },
    { id: 'atomic-batch', path: 'cloud/tests-e2e/atomic-batch-journey.mjs' },
    { id: 'billing', path: 'cloud/tests-e2e/billing-journey.mjs' },
    { id: 'generation', path: 'cloud/tests-e2e/generation-journey.mjs' },
    { id: 'peer-signaling', path: 'cloud/tests-e2e/peer-signaling-journey.mjs' },
    { id: 'email-auth', path: 'cloud/tests-e2e/email-auth-journey.mjs' },
    { id: 'team-lifecycle', path: 'cloud/tests-e2e/team-lifecycle-journey.mjs' },
    { id: 'oauth', path: 'cloud/tests-e2e/oauth-journey.mjs' },
    { id: 'document-integrity', path: 'cloud/tests-e2e/document-integrity-journey.mjs' },
    { id: 'revision-safety', path: 'cloud/tests-e2e/revision-safety-journey.mjs' },
  ]);
  assert.match(run(['app', '--', 'test', 'services', '--help']).stdout, /not native app acceptance/);
  assert.match(run(['actions']).stdout, /test services/);
  for (const args of [['../outside'], ['unknown'], ['cloud', 'updates'], ['--list', 'cloud'], ['--help', '--unknown']]) {
    const result = run(['app', '--', 'test', 'services', ...args], 2);
    assert.equal(result.stdout, '');
    assert.match(result.stderr, /invalid-service-scenario/);
  }
}
