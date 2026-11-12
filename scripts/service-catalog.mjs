/** Fixed local service routes and public help only. No I/O or application imports. */
export const serviceJourneys = Object.freeze([
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
].map(row => Object.freeze(row)));

export const serviceUsage = 'tracer app -- test services [' + serviceJourneys.map(row => row.id).join('|') + ']';
export const serviceHelp = serviceUsage + '\ntracer app -- test services --list\n\nRuns isolated real Worker HTTP journeys with synthetic state and denied unexpected outbound access.\nNo selection runs all thirteen in stable order. These are local service checks, not native app acceptance.';
