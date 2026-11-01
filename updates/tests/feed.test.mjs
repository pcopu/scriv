import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign, verify } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { Miniflare, convertV4MiniflareOptions } from '../../cloud/node_modules/miniflare/dist/src/index.js';
import { validPointer, validChannel, channelForPath } from '../src/worker.mjs';
const digest = b => createHash('sha256').update(b).digest('hex');
const source = await readFile(new URL('../src/worker.mjs', import.meta.url), 'utf8');
const mf = new Miniflare(convertV4MiniflareOptions({ name: 'scriv-updates-test', modules: true, script: source, compatibilityDate: '2026-10-30', r2Buckets: ['RELEASES'] }));
const bucket = await mf.getR2Bucket('RELEASES');
const request = (path, options) => mf.dispatchFetch('https://scriv-updates.why-not.work' + path, options);
test.after(() => mf.dispose());

test('no release is fail-closed, service health is not a fake release', async () => {
  assert.equal((await request('/health')).status, 200);
  assert.equal((await request('/appcast.xml')).status, 503);
});
test('every write method rejected; no publisher or arbitrary R2 read surface', async () => {
  for (const method of ['POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS']) assert.equal((await request('/appcast.xml', { method })).status, 405);
  for (const path of ['/publish', '/channels/stable.json', '/manifests/1.json', '/releases/../secret', '/releases/1/%2e%2e', '/appcast.xml?url=evil']) assert.equal((await request(path)).status, 404);
});
test('pointer shape rejects traversal, mismatched hash key and invalid versions', () => {
  const base = { schema: 1, channel: 'stable', build: 2, feedSHA256: 'a'.repeat(64), feedKey: `feeds/${'a'.repeat(64)}.xml` };
  assert.ok(validPointer(base));
  for (const replacement of [{ build: -1 }, { build: 1.5 }, { build: '2' }, { feedKey: '../private' }, { schema: 2 }, { feedSHA256: 'b'.repeat(64) }]) assert.ok(!validPointer({ ...base, ...replacement }));
});
test('synthetic signed bytes survive real Workers/R2 check-download-verification unchanged', async () => {
  // Ephemeral key and inert bytes only. This is not a signed/notarized Mac app.
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const artifact = Buffer.from('INERT SYNTHETIC SCRIV UPDATE FIXTURE, NOT AN APP');
  const signature = sign(null, artifact, privateKey);
  const artifactKey = `releases/2/${digest(artifact)}.zip`;
  const content = Buffer.from(`<rss><channel><item><version>2</version><url>${artifactKey}</url></item></channel></rss>\n`);
  const feedSignature = sign(null, content, privateKey);
  const feed = Buffer.concat([content, Buffer.from(`<!-- sparkle-signatures:\nedSignature: ${feedSignature.toString('base64')}\nlength: ${content.length}\n-->\n`)]);
  const hash = digest(feed), feedKey = `feeds/${hash}.xml`;
  await bucket.put(artifactKey, artifact, { customMetadata: { sha256: digest(artifact) } });
  await bucket.put(feedKey, feed);
  await bucket.put('channels/stable.json', JSON.stringify({ schema: 1, channel: 'stable', build: 2, feedSHA256: hash, feedKey }));
  const response = await request('/appcast.xml'); assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), feed);
  assert.ok(verify(null, content, publicKey, feedSignature));
  const download = await request('/' + artifactKey); assert.equal(download.status, 200);
  const bytes = Buffer.from(await download.arrayBuffer()); assert.deepEqual(bytes, artifact);
  assert.ok(verify(null, bytes, publicKey, signature));
  assert.ok(!verify(null, Buffer.concat([bytes, Buffer.from('tamper')]), publicKey, signature));
  assert.equal((await request('/' + artifactKey, { method: 'HEAD' })).headers.get('content-length'), String(artifact.length));
  assert.equal(await (await request('/' + artifactKey, { method: 'HEAD' })).text(), '');
  assert.equal((await request('/' + artifactKey, { headers: { 'if-none-match': `"${digest(artifact)}"` } })).status, 304);
  await bucket.put(feedKey, 'tampered feed');
  assert.equal((await request('/appcast.xml')).status, 503);
});
test('corrupt pointers and artifacts without matching metadata fail closed', async () => {
  await bucket.put('channels/stable.json', 'not JSON'); assert.equal((await request('/appcast.xml')).status, 503);
  const key = `releases/5/${'d'.repeat(64)}.zip`; await bucket.put(key, 'unsigned');
  assert.equal((await request('/' + key)).status, 503);
  assert.equal((await request(`/releases/999/${'e'.repeat(64)}.zip`)).status, 404);
});

test('acceptance feed is isolated; stable never falls through to it', async () => {
  const channel = 'acceptance-20261031', bytes = Buffer.from('inert channel fixture');
  const hash = digest(bytes), feedKey = `feeds/${hash}.xml`;
  await bucket.delete('channels/stable.json');
  await bucket.put(feedKey, bytes);
  await bucket.put(`channels/${channel}.json`, JSON.stringify({ schema: 1, channel, build: 1002, feedSHA256: hash, feedKey }));
  assert.equal((await request('/appcast.xml')).status, 503);
  assert.equal(await (await request(`/channels/${channel}/appcast.xml`)).text(), bytes.toString());
  assert.equal((await request(`/channels/${channel}/appcast.xml`, { method: 'POST' })).status, 405);
  assert.equal((await request('/channels/stable/appcast.xml')).status, 404);
  assert.equal((await request('/channels/beta/appcast.xml')).status, 404);
  await bucket.put(`channels/${channel}.json`, JSON.stringify({ schema: 1, channel: 'stable', build: 1002, feedSHA256: hash, feedKey }));
  assert.equal((await request(`/channels/${channel}/appcast.xml`)).status, 503);
});
test('channel route accepts only explicit stable or bounded acceptance namespaces', () => {
  assert.ok(validChannel('stable')); assert.ok(validChannel('acceptance-20261031'));
  assert.equal(channelForPath('/appcast.xml'), 'stable');
  assert.equal(channelForPath('/channels/acceptance-20261031/appcast.xml'), 'acceptance-20261031');
  for (const bad of ['acceptance-', '../stable', 'beta', 'acceptance-A', 'acceptance-' + 'x'.repeat(49)]) assert.ok(!validChannel(bad));
});
