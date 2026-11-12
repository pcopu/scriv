#!/usr/bin/env node
// Deliberately blocked scaffold. Never imported by standard test discovery.
// No app launch, socket, authentication, provider request, or generated fixture.
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { validateConfiguration as validateConnection } from './codex-connection.mjs';

export const syntheticDirection = 'One blue paper triangle on a plain white tabletop. No people, text, logos, or reference images.';
export const submissionLimit = 1;

/** Local attestations only: this function does not prove account or runtime state. */
export function validateConfiguration(env) {
  const connection = validateConnection(env);
  if (connection.account !== 'authenticated') {
    throw new Error('Image execution requires an approved, already authenticated dedicated test identity. This scenario must not sign in.');
  }
  for (const name of [
    'SCRIV_LIVE_IMAGE_ALLOWED',
    'SCRIV_LIVE_IMAGE_CAPABILITY_VERIFIED',
    'SCRIV_LIVE_IMAGE_USAGE_APPROVED',
    'SCRIV_LIVE_IMAGE_SHARED_ARTIFACT_ACCESS_VERIFIED',
  ]) {
    if (env[name] !== 'yes') throw new Error(`Set ${name}=yes only after verifying the documented prerequisite.`);
  }
  if (env.SCRIV_LIVE_IMAGE_MAX_TURNS !== String(submissionLimit)) {
    throw new Error('SCRIV_LIVE_IMAGE_MAX_TURNS must be exactly 1. No retry or cancellation turn is included.');
  }
  const budget = env.SCRIV_LIVE_IMAGE_BUDGET_LIMIT ?? '';
  const currency = env.SCRIV_LIVE_IMAGE_BUDGET_CURRENCY ?? '';
  // These attestations record an approved ceiling, not provider-side enforcement.
  // Free/included quota may use zero; never infer permission to purchase more.
  if (!/^(0|[1-9][0-9]{0,5})(\.[0-9]{1,2})?$/.test(budget)
      || !/^[A-Z]{3}$/.test(currency)) {
    throw new Error('Provide an explicitly approved finite SCRIV_LIVE_IMAGE_BUDGET_LIMIT and three-letter SCRIV_LIVE_IMAGE_BUDGET_CURRENCY.');
  }
  return { ...connection, maxTurns: submissionLimit, budget, currency };
}

export const implementationBlockers = Object.freeze([
  'The image-evidence observer compiled and its zero-job isolation passed, but completed-artifact, decode, attachment and rendered-preview branches have not been verified.',
  'The one-submit native UI flow and evidence assertions are not implemented. No environment flag can enable generation in this scaffold.',
  'The owned external runtime must demonstrably share legitimate access to the app-created synthetic Generation job directory; WebSocket connectivity is not artifact transfer.',
]);

export async function run(env = process.env) {
  try {
    validateConfiguration(env);
  } catch (error) {
    // Configuration messages name only fixed settings, never values or diagnostics.
    console.error(JSON.stringify({ scenario: 'live-codex-image', status: 'BLOCKED', stage: 'configuration', submittedTurns: 0, reason: error.message }));
    return 1;
  }
  console.error(JSON.stringify({
    scenario: 'live-codex-image', status: 'BLOCKED', stage: 'implementation',
    submittedTurns: 0, blockers: implementationBlockers,
    prerequisiteDocument: 'docs/testing/live-codex-image.md',
  }));
  return 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  run().then(code => { process.exitCode = code; }).catch(() => {
    console.error('BLOCKED: image preflight failed; no live generation is implemented.');
    process.exitCode = 1;
  });
}
