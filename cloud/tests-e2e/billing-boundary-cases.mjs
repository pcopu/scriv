// Public local HTTP continuation. Synthetic fixture state is observed independently through D1/R2.
import assert from 'node:assert/strict';
import { createHmac, randomUUID } from 'node:crypto';

export async function billingBoundaryCases({ mf, db, state, event, actors, teamId, projectId, providerCount }) {
  let checks = 0;
  const sign = (raw, timestamp = Math.floor(Date.now() / 1000)) => `t=${timestamp},v1=${createHmac('sha256', 'whsec_synthetic_only').update(`${timestamp}.${raw}`).digest('hex')}`;
  async function send(path, { raw, signature, role, method = 'POST' } = {}) {
    const base = await mf.ready;
    assert.equal(base.hostname, '127.0.0.1'); assert.equal(base.protocol, 'http:');
    const response = await fetch(new URL(path, base), {
      method, headers: { ...(raw === undefined ? {} : { 'content-type': 'application/json' }),
        ...(signature === undefined ? {} : { 'stripe-signature': signature }),
        ...(role ? { authorization: `Bearer ${actors[role].token}` } : {}) },
      body: raw, redirect: 'error', signal: AbortSignal.timeout(5000),
    });
    checks++;
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
    const text = await response.text(); assert(Buffer.byteLength(text) < 65536);
    return { status: response.status, data: JSON.parse(text) };
  }
  async function unchanged(path, options, status, code) {
    const before = await state(db), calls = providerCount();
    const result = await send(path, options);
    assert.equal(result.status, status, `boundary ${checks} status`); assert.equal(result.data.error.code, code, `boundary ${checks} code`);
    assert.equal(providerCount(), calls); assert.deepEqual(await state(db), before);
  }
  const raw = JSON.stringify(event('evt_sol_signature_boundary'));
  const timestamp = Math.floor(Date.now() / 1000);
  // Each malformed timestamp/digest is refused before a receipt or entitlement can change.
  for (const signature of [
    `t=-1,v1=${'0'.repeat(64)}`, `t=9007199254740992,v1=${'0'.repeat(64)}`,
    `t=1e3,v1=${'0'.repeat(64)}`, `t=${timestamp},v1=abc`,
    `t=${timestamp},v1=${'A'.repeat(64)}`, `t=${timestamp},v1=`,
  ]) await unchanged('/billing/webhook', { raw, signature }, 400, 'invalid_signature');
  const envelope = event('evt_sol_payload_boundary');
  for (const [body, code] of [
    [{ ...envelope, id: 'x'.repeat(129) }, 'invalid_field'],
    [{ ...envelope, type: 17 }, 'invalid_field'],
    [{ ...envelope, data: { object: null } }, 'invalid_event'],
    [{ ...envelope, data: { object: { customer: { id: 1 } } } }, 'invalid_customer'],
    [{ ...envelope, data: { object: { customer: 'x'.repeat(129) } } }, 'invalid_customer'],
    [{ ...envelope, created: -1 }, 'invalid_event'],
    [{ ...envelope, created: 1.5 }, 'invalid_event'],
    [{ ...envelope, created: '1234' }, 'invalid_event'],
  ]) { const payload = JSON.stringify(body); await unchanged('/billing/webhook', { raw: payload, signature: sign(payload) }, 400, code); }
  // The webhook body limit is enforced before signature parsing and JSON decoding.
  const oversized = 'x'.repeat(262145);
  await unchanged('/billing/webhook', { raw: oversized, signature: sign(oversized) }, 413, 'body_too_large');
  // Authorization failures preserve durable application rows and never reach the provider fixture.
  for (const route of ['checkout', 'portal']) {
    await unchanged(`/v1/teams/${teamId}/billing/${route}`, { role: 'viewer' }, 403, 'not_allowed');
    await unchanged(`/v1/teams/${teamId}/billing/${route}`, {}, 401, 'sign_in_required');
  }
  await unchanged(`/v1/teams/${teamId}/billing/checkout`, { role: 'owner', raw: 'x'.repeat(4097) }, 413, 'body_too_large');
  await unchanged(`/v1/projects/${projectId}/commands`, { role: 'viewer', raw: JSON.stringify({ commandId: randomUUID(), sessionId: actors.viewer.sessionId, epoch: 1, label: 'Synthetic viewer boundary', operations: [{ op: 'put', id: projectId, kind: 'scene', expectedVersion: 0, data: { id: projectId, title: 'Denied viewer scene', order: 0 } }] }) }, 403, 'read_only');
  await unchanged(`/v1/projects/${projectId}`, { role: 'outsider', method: 'GET' }, 404, 'not_found');
  const returnBefore = await state(db), returnCalls = providerCount();
  const returnBase = await mf.ready;
  const returnResponse = await fetch(new URL('/billing/return?team=%22%3E%3Cscript%3E%26', returnBase), { redirect: 'error', signal: AbortSignal.timeout(5000) });
  checks++;
  assert.equal(returnResponse.status, 200);
  assert.equal(returnResponse.headers.get('content-type'), 'text/html; charset=utf-8');
  assert.equal(returnResponse.headers.get('cache-control'), 'no-store');
  assert.equal(returnResponse.headers.get('content-security-policy'), "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'");
  const returnHTML = await returnResponse.text();
  assert(returnHTML.includes('href="scriv://billing/%22%3E%3Cscript%3E%26"'));
  assert.equal(returnHTML.includes('<script>'), false);
  assert.equal(providerCount(), returnCalls); assert.deepEqual(await state(db), returnBefore);
  assert.equal(checks, 23);
  return { kind: 'sol-billing-boundary-evidence', httpChecks: checks, signatureRefusals: 6, envelopeRefusals: 8, bodyLimitRefusals: 2, authorizationRefusals: 6, liveProvider: false };
}
