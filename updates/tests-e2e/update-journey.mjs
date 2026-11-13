// Real HTTP update-distribution journey; not native Sparkle or application E2E.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { createHash, generateKeyPairSync, sign, verify } from 'node:crypto';

const here = await realpath(dirname(fileURLToPath(import.meta.url)));
const updates = await realpath(join(here, '..'));
const self = join(here, 'update-journey.mjs');
if (process.argv[2] !== '--owned-child') {
  let root, capture, child, timer, interrupted = false;
  const killOwned = signal => {
    if (child?.pid) {
      try { process.kill(-child.pid, signal); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    }
  };
  const interrupt = () => { interrupted = true; killOwned('SIGTERM'); };
  process.on('SIGINT', interrupt); process.on('SIGTERM', interrupt);
  try {
    try {
      root = await realpath(await mkdtemp(join(tmpdir(), 'scriv-updates-')));
      for (const name of ['home', 'tmp', 'state']) await mkdir(join(root, name), { mode: 0o700 });
      capture = process.env.SCRIV_UPDATES_COVERAGE_DIR
        ? await (await import('./capture-coverage.mjs')).prepareUpdateCapture(process.env.SCRIV_UPDATES_COVERAGE_DIR, process.env.SCRIV_TRACER_CLI) : null;
      assert.equal(interrupted, false, 'Cancelled during preparation; no Worker launched');
      child = spawn(process.execPath, [self, '--owned-child', root, ...(capture ? [capture.path] : [])], {
        cwd: root, detached: true, stdio: 'inherit',
        // Deliberately no inherited credentials, proxy settings, config, or NODE_OPTIONS.
        env: { PATH: dirname(process.execPath), HOME: join(root, 'home'), TMPDIR: join(root, 'tmp'),
          XDG_CONFIG_HOME: join(root, 'home'), XDG_CACHE_HOME: join(root, 'home'),
          WRANGLER_SEND_METRICS: 'false', CI: '1' },
      });
      timer = setTimeout(() => killOwned('SIGKILL'), 90_000);
      const result = await new Promise((resolve, reject) => {
        child.once('error', reject);
        child.once('exit', (code, signal) => resolve({ code, signal }));
      });
      assert.equal(result.code, 0, `Owned update journey failed: exit=${result.code}, signal=${result.signal}`);
    } finally {
      clearTimeout(timer); killOwned('SIGKILL');
      if (root) await rm(root, { recursive: true, force: true });
      console.log('Owned update process group and temporary state cleaned.');
    }
    assert.equal(interrupted, false, 'Cancelled before measurement import');
    if (capture) await capture.finish(() => interrupted);
    assert.equal(interrupted, false, 'Cancelled during measurement import; inspect preserved evidence');
  } finally {
    process.off('SIGINT', interrupt); process.off('SIGTERM', interrupt);
  }
} else {
  const root = await realpath(process.argv[3]);
  assert.equal(await realpath(process.cwd()), root);
  assert.equal(process.env.HOME, join(root, 'home'));
  const { Miniflare, Log, LogLevel, convertV4MiniflareOptions } = await import('../../cloud/node_modules/miniflare/dist/src/index.js');
  const sourcePath = join(updates, 'src/worker.mjs');
  const source = await readFile(sourcePath);
  const capture = process.argv[4]
    ? await (await import('./capture-coverage.mjs')).loadUpdateCapture(process.argv[4], source, root) : null;
  const digest = bytes => createHash('sha256').update(bytes).digest('hex');
  let outboundAttempts = 0;
  const mf = new Miniflare(convertV4MiniflareOptions({
    name: 'scriv-updates-journey', host: '127.0.0.1', port: 0,
    ...(capture ? capture.options : { modules: true, script: source.toString() }), compatibilityDate: '2026-10-30',
    r2Buckets: ['RELEASES'], cf: false, telemetry: { enabled: false },
    unsafeInspectorProxy: false, unsafeLocalExplorer: false, unsafeObservability: false,
    unsafeEnableSharedStorage: false, logRequests: false, log: new Log(LogLevel.ERROR),
    resourcePersistencePath: join(root, 'state'), resourceTmpPath: join(root, 'tmp'),
    outboundService: () => { outboundAttempts++; throw new Error('Outbound request forbidden'); },
  }));
  let requests = 0;
  try {
    const base = await mf.ready;
    assert.equal(base.hostname, '127.0.0.1'); assert.equal(base.protocol, 'http:');
    assert(Number(base.port) > 0);
    const bucket = await mf.getR2Bucket('RELEASES');
    async function request(path, status, options = {}) {
      const url = new URL(path, base); assert.equal(url.origin, base.origin);
      assert(requests++ < 48, 'HTTP request budget');
      assert(Buffer.byteLength(options.body ?? '') < 8192, 'Request body budget');
      const response = await fetch(url, { ...options, redirect: 'error', signal: AbortSignal.timeout(5000) });
      assert.equal(response.status, status, `${options.method ?? 'GET'} ${path}`);
      const chunks = []; let size = 0;
      if (response.body) for await (const chunk of response.body) {
        size += chunk.length; assert(size <= 16384, 'Response body budget'); chunks.push(chunk);
      }
      assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
      assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
      assert.equal(response.headers.get('content-security-policy'), "default-src 'none'; frame-ancestors 'none'");
      return { headers: response.headers, bytes: Buffer.concat(chunks) };
    }

    async function metadataUnavailable() {
      const rejected = await request('/appcast.xml', 503);
      assert.equal(rejected.bytes.toString(), 'Release metadata unavailable.');
      assert.equal(rejected.headers.get('retry-after'), null);
      assert.equal(rejected.headers.get('cache-control'), 'no-store');
    }
    function assertFeedHeaders(response, bytes) {
      assert.equal(response.headers.get('content-type'), 'application/xml; charset=utf-8');
      assert.equal(response.headers.get('etag'), `"${digest(bytes)}"`);
      assert.equal(response.headers.get('cache-control'), 'no-store');
      assert.equal(response.headers.get('retry-after'), null);
    }

    if (capture) await capture.begin(base);

    // Start with an empty private bucket: health must not pretend a release exists.
    const health = await request('/health', 200);
    assert.deepEqual(JSON.parse(health.bytes), { service: 'scriv-updates', status: 'ok' });
    await request('/appcast.xml', 503);
    for (const method of ['POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS']) {
      const rejected = await request('/appcast.xml', 405, { method });
      assert.equal(rejected.headers.get('allow'), 'GET, HEAD');
    }
    for (const path of ['/publish', '/channels/stable.json', '/manifests/1.json', '/releases/../secret', '/releases/1/%2e%2e', '/appcast.xml?url=evil']) {
      await request(path, 404);
    }

    // Synthetic local publication is fixture setup, not a provider/publisher call.
    // Keys exist only in memory. Inert bytes are neither an application nor notarized.
    const { privateKey, publicKey } = generateKeyPairSync('ed25519');
    const artifact = Buffer.from('INERT SYNTHETIC SCRIV UPDATE FIXTURE, NOT AN APP');
    const signature = sign(null, artifact, privateKey);
    const artifactKey = `releases/2/${digest(artifact)}.zip`;
    const content = Buffer.from(`<rss><channel><item><version>2</version><url>${artifactKey}</url></item></channel></rss>\n`);
    const feedSignature = sign(null, content, privateKey);
    const feed = Buffer.concat([content, Buffer.from(`<!-- sparkle-signatures:\nedSignature: ${feedSignature.toString('base64')}\nlength: ${content.length}\n-->\n`)]);
    const feedHash = digest(feed), feedKey = `feeds/${feedHash}.xml`;
    const pointer = { schema: 1, channel: 'stable', build: 2, feedSHA256: feedHash, feedKey };
    await bucket.put(artifactKey, artifact, { customMetadata: { sha256: digest(artifact) } });
    await bucket.put(feedKey, feed);
    await bucket.put('channels/stable.json', JSON.stringify(pointer));
    const checked = await request('/appcast.xml', 200);
    assert.equal(checked.headers.get('cache-control'), 'no-store');
    assert.deepEqual(checked.bytes, feed);
    // Verify the downloaded signed payload, not only the locally prepared buffer.
    assert.ok(verify(null, checked.bytes.subarray(0, content.length), publicKey, feedSignature));
    assert.ok(!verify(null, Buffer.concat([content, Buffer.from('tamper')]), publicKey, feedSignature));
    const downloaded = await request('/' + artifactKey, 200);
    assert.deepEqual(downloaded.bytes, artifact);
    assert.ok(verify(null, downloaded.bytes, publicKey, signature));
    assert.ok(!verify(null, Buffer.concat([downloaded.bytes, Buffer.from('tamper')]), publicKey, signature));
    const head = await request('/' + artifactKey, 200, { method: 'HEAD' });
    assert.equal(head.headers.get('content-length'), String(artifact.length));
    assert.equal(head.bytes.length, 0);
    const cached = await request('/' + artifactKey, 304, { headers: { 'if-none-match': `"${digest(artifact)}"` } });
    assert.equal(cached.bytes.length, 0);
    await bucket.put(feedKey, 'tampered feed');
    await request('/appcast.xml', 503);

    // A later broken publication cannot expose an unsigned or wrong-hash release.
    await bucket.put('channels/stable.json', 'not JSON');
    await request('/appcast.xml', 503);
    // Restore valid downstream bytes so pointer rejection cannot be masked by
    // the preceding corruption. Each malformed publication changes one field.
    await bucket.put(feedKey, feed);
    for (const build of [-1, 1.5, '2', 0, 1000000000000000]) {
      await bucket.put('channels/stable.json', JSON.stringify({ ...pointer, build }));
      await metadataUnavailable();
    }
    await bucket.put('channels/stable.json', JSON.stringify({ ...pointer, schema: 2 }));
    await metadataUnavailable();

    // Seed the literal key and read it back: a missing object must not be the
    // reason the traversal-shaped pointer is refused.
    await bucket.put('../private', feed);
    assert.deepEqual(Buffer.from(await (await bucket.get('../private')).arrayBuffer()), feed);
    await bucket.put('channels/stable.json', JSON.stringify({ ...pointer, feedKey: '../private' }));
    await metadataUnavailable();

    // If key/digest coupling is lost, these downstream bytes WOULD match the
    // advertised digest. This isolates that coupling from content-hash failure.
    const alternateFeed = Buffer.from('<rss><channel>alternate inert fixture</channel></rss>\n');
    const alternateHash = digest(alternateFeed);
    assert.notEqual(alternateHash, feedHash);
    await bucket.put(feedKey, alternateFeed);
    assert.deepEqual(Buffer.from(await (await bucket.get(feedKey)).arrayBuffer()), alternateFeed);
    await bucket.put('channels/stable.json', JSON.stringify({ ...pointer, feedSHA256: alternateHash }));
    await metadataUnavailable();
    await bucket.put(feedKey, feed);

    // JSON whitespace makes the exact pointer-size boundary independently
    // observable with otherwise valid metadata, including the maximum build.
    const maximumPointer = JSON.stringify({ ...pointer, build: 999999999999999 });
    const paddedPointer = maximumPointer.padEnd(2048, ' ');
    assert.equal(Buffer.byteLength(paddedPointer), 2048);
    await bucket.put('channels/stable.json', paddedPointer);
    const maximumPublication = await request('/appcast.xml', 200);
    assert.deepEqual(maximumPublication.bytes, feed);
    assertFeedHeaders(maximumPublication, feed);
    const oversizedPointer = paddedPointer + ' ';
    assert.equal(Buffer.byteLength(oversizedPointer), 2049);
    await bucket.put('channels/stable.json', oversizedPointer);
    const pointerTooLarge = await request('/appcast.xml', 503);
    assert.equal(pointerTooLarge.bytes.toString(), 'No signed release has been published.');
    assert.equal(pointerTooLarge.headers.get('retry-after'), '3600');
    assert.equal(pointerTooLarge.headers.get('cache-control'), 'no-store');

    // HEAD verifies the accepted feed boundary without raising the 16 KiB
    // response budget. The oversized feed also has a genuine matching hash.
    const boundaryFeed = Buffer.from('<rss>' + ' '.repeat(262144 - 11) + '</rss>');
    assert.equal(boundaryFeed.length, 262144);
    for (const bytes of [boundaryFeed, Buffer.concat([boundaryFeed, Buffer.from(' ')])]) {
      const hash = digest(bytes), key = `feeds/${hash}.xml`;
      await bucket.put(key, bytes);
      await bucket.put('channels/stable.json', JSON.stringify({ ...pointer, feedSHA256: hash, feedKey: key }));
      if (bytes.length === 262144) {
        const boundaryHead = await request('/appcast.xml', 200, { method: 'HEAD' });
        assertFeedHeaders(boundaryHead, bytes);
        assert.equal(boundaryHead.headers.get('content-length'), String(bytes.length));
        assert.equal(boundaryHead.bytes.length, 0);
      } else {
        assert.equal(bytes.length, 262145);
        await metadataUnavailable();
      }
    }

    // Repair a missing publication object and recover exact bytes at build 1.
    const repairedFeed = Buffer.from('<rss><channel>repaired inert fixture</channel></rss>\n');
    const repairedHash = digest(repairedFeed), repairedKey = `feeds/${repairedHash}.xml`;
    assert.equal(await bucket.get(repairedKey), null);
    await bucket.put('channels/stable.json', JSON.stringify({ ...pointer, build: 1, feedSHA256: repairedHash, feedKey: repairedKey }));
    await metadataUnavailable();
    await bucket.put(repairedKey, repairedFeed);
    const repairedPublication = await request('/appcast.xml', 200);
    assert.deepEqual(repairedPublication.bytes, repairedFeed);
    assertFeedHeaders(repairedPublication, repairedFeed);
    const unsignedKey = `releases/5/${'d'.repeat(64)}.zip`;
    await bucket.put(unsignedKey, 'unsigned');
    await request('/' + unsignedKey, 503);
    await bucket.put(unsignedKey, 'unsigned', { customMetadata: { sha256: 'e'.repeat(64) } });
    await request('/' + unsignedKey, 503);
    await request(`/releases/999/${'e'.repeat(64)}.zip`, 404);

    // Acceptance remains an explicit namespace, never a fallback stable release.
    const channel = 'acceptance-20261031', acceptanceBytes = Buffer.from('inert channel fixture');
    const acceptanceHash = digest(acceptanceBytes), acceptanceKey = `feeds/${acceptanceHash}.xml`;
    await bucket.delete('channels/stable.json');
    await bucket.put(acceptanceKey, acceptanceBytes);
    await bucket.put(`channels/${channel}.json`, JSON.stringify({ schema: 1, channel, build: 1002, feedSHA256: acceptanceHash, feedKey: acceptanceKey }));
    await request('/appcast.xml', 503);
    const acceptance = await request(`/channels/${channel}/appcast.xml`, 200);
    assert.deepEqual(acceptance.bytes, acceptanceBytes);
    await request(`/channels/${channel}/appcast.xml`, 405, { method: 'POST' });
    await request('/channels/stable/appcast.xml', 404);
    await request('/channels/beta/appcast.xml', 404);
    await bucket.put(`channels/${channel}.json`, JSON.stringify({ schema: 1, channel: 'stable', build: 1002, feedSHA256: acceptanceHash, feedKey: acceptanceKey }));
    await request(`/channels/${channel}/appcast.xml`, 503);
    // Conditional requests must re-check existence and metadata before returning 304.
    assert.equal(requests, 42);
    const staleTag = `"${'d'.repeat(64)}"`, conditional = { headers: { 'if-none-match': staleTag } };
    const corruptCached = await request('/' + unsignedKey, 503, conditional);
    assert.equal(corruptCached.bytes.toString(), 'Release artifact unavailable.');
    for (const name of ['etag', 'content-disposition', 'retry-after']) assert.equal(corruptCached.headers.get(name), null);
    assert.equal(corruptCached.headers.get('cache-control'), 'no-store');
    const corruptHead = await request('/' + unsignedKey, 503, { ...conditional, method: 'HEAD' });
    assert.equal(corruptHead.bytes.length, 0); assert.equal(corruptHead.headers.get('etag'), null); assert.equal(corruptHead.headers.get('cache-control'), 'no-store');
    await bucket.delete(unsignedKey); assert.equal(await bucket.get(unsignedKey), null);
    const missingCached = await request('/' + unsignedKey, 404, conditional);
    assert.equal(missingCached.bytes.toString(), 'Not found'); assert.equal(missingCached.headers.get('etag'), null); assert.equal(missingCached.headers.get('cache-control'), 'no-store');
    // A stale validator gets the real full artifact, while a matching HEAD is bodyless.
    const recoveredDownload = await request('/' + artifactKey, 200, conditional);
    assert.deepEqual(recoveredDownload.bytes, artifact); assert(verify(null, recoveredDownload.bytes, publicKey, signature));
    const cachedHead = await request('/' + artifactKey, 304, { method: 'HEAD', headers: { 'if-none-match': `"${digest(artifact)}"` } });
    assert.equal(cachedHead.bytes.length, 0); assert.equal(cachedHead.headers.get('content-length'), null);
    for (const response of [recoveredDownload, cachedHead]) {
      assert.equal(response.headers.get('content-type'), 'application/zip'); assert.equal(response.headers.get('etag'), `"${digest(artifact)}"`);
      assert.equal(response.headers.get('cache-control'), 'public, max-age=31536000, immutable'); assert.equal(response.headers.get('content-disposition'), 'attachment; filename="Scriv.zip"'); assert.equal(response.headers.get('retry-after'), null);
    }
    assert.equal(recoveredDownload.headers.get('content-length'), String(artifact.length));
    // Feed metadata remains freshly validated, with no conditional-cache shortcut.
    await bucket.put('channels/stable.json', JSON.stringify(pointer));
    const conditionalFeed = await request('/appcast.xml', 200, { headers: { 'if-none-match': `"${feedHash}"` } });
    assert.deepEqual(conditionalFeed.bytes, feed); assertFeedHeaders(conditionalFeed, feed); // GET transport may omit Content-Length; exact bytes are the oracle.
    assert.equal(requests, 48);
    console.log(JSON.stringify({kind:'update-cache-revalidation-evidence',httpChecks:6,metadataRefusals:2,missingArtifactRefusals:1,staleValidatorFullDownload:true,matchingHeadStatus:304,matchingFeedStatus:200,nativeScenarios:0}));
    assert.equal(outboundAttempts, 0, 'No outbound requests permitted');
    assert.deepEqual(await readFile(sourcePath), source, 'Production source unchanged');
    if (capture) await capture.end(base, requests);
    console.log(`PASS update-distribution journey: ${requests} loopback HTTP checks; zero outbound attempts.`);
    console.log(`Production worker SHA-256: ${digest(source)}`);
    console.log(`Inert artifact SHA-256: ${digest(artifact)}; signed feed SHA-256 (ephemeral per run): ${feedHash}`);
    console.log('Limits: 48 requests, 5 seconds/request, 16 KiB response, 90 seconds/process group; private temporary R2 only.');
    console.log('No real signing identity, provider publication, app install, native Sparkle, or Catalyst E2E claimed.');
  } finally { await mf.dispose(); }
}
