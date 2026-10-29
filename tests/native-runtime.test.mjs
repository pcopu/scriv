import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { deflateSync } from 'node:zlib';
import { mkdtemp, mkdir, readFile, rm, unlink, utimes, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { captureNames, pngDimensions, runStage, validateCaptures, validatePeerTransfer } from '../scripts/verify-native-runtime.mjs';

function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type, bytes) {
  const body = Buffer.concat([Buffer.from(type), bytes]), size = Buffer.alloc(4), crc = Buffer.alloc(4);
  size.writeUInt32BE(bytes.length); crc.writeUInt32BE(crc32(body));
  return Buffer.concat([size, body, crc]);
}
function testPNG(width, height) {
  const header = Buffer.alloc(13); header.writeUInt32BE(width); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2;
  return Buffer.concat([Buffer.from('89504e470d0a1a0a', 'hex'), chunk('IHDR', header), chunk('IDAT', deflateSync(Buffer.alloc((width * 3 + 1) * height))), chunk('IEND', Buffer.alloc(0))]);
}
async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'scriv-native-runtime-test-'));
  t.after(() => rm(directory, { force: true, recursive: true }));
  return directory;
}
async function captures(directory) {
  const records = [];
  for (const filename of captureNames) {
    const popover = filename === '04-codex-popover.png', width = popover ? 320 : 1200, height = popover ? 400 : 800;
    await writeFile(join(directory, filename), testPNG(width, height));
    records.push({ filename, windowRole: popover ? 'codex-popover' : 'workspace', pixelWidth: width, pixelHeight: height,
      selectedTab: filename === '02-characters.png' ? 'Characters' : filename === '03-storyboard.png' ? 'Storyboard' : 'Script',
      discussionVisible: filename.startsWith('04-'), codexConnected: false, codexStatus: 'Not running', collaboratorCount: 0, discussionMessageCount: 0,
      windowFrame: { x: 0, y: 0, width, height }, contentBounds: { x: 0, y: 0, width, height } });
  }
  const metadata = { schemaVersion: 1, status: 'captured', platform: 'macOS', captures: records };
  await writeFile(join(directory, 'capture-metadata.json'), JSON.stringify(metadata));
  await writeFile(join(directory, 'result.txt'), 'Native SwiftUI/AppKit screenshots captured successfully.');
  return metadata;
}

test('five raw capture artifacts validate without claiming human visual parity', async t => {
  const directory = await fixture(t);
  await captures(directory);
  const result = await validateCaptures(directory);
  assert.equal(result.images.length, 5);
  assert.match(result.limitation, /not human visual-parity acceptance/);
  assert.equal(result.images.find(image => image.filename === '04-codex-popover.png').width, 320);
});

test('missing popover, success marker or metadata cannot pass capture verification', async t => {
  const directory = await fixture(t);
  for (const filename of ['04-codex-popover.png', 'result.txt', 'capture-metadata.json']) {
    await captures(directory);
    await unlink(join(directory, filename));
    await assert.rejects(validateCaptures(directory));
  }
});

test('stale artifacts and native failure markers are rejected even with success files', async t => {
  const directory = await fixture(t);
  await captures(directory);
  const old = new Date(Date.now() - 60000);
  await utimes(join(directory, '01-script.png'), old, old);
  await assert.rejects(validateCaptures(directory, Date.now()), /Stale artifact/);
  await captures(directory);
  await writeFile(join(directory, 'error.txt'), 'Native popover failed');
  await assert.rejects(validateCaptures(directory), /failure marker/);
});

test('bad dimensions, duplicate capture metadata and damaged PNGs fail', async t => {
  const directory = await fixture(t), metadata = await captures(directory);
  metadata.captures[0].pixelWidth++;
  await writeFile(join(directory, 'capture-metadata.json'), JSON.stringify(metadata));
  await assert.rejects(validateCaptures(directory), /Pixel width differs/);
  metadata.captures[0].pixelWidth--;
  metadata.captures[4].filename = metadata.captures[0].filename;
  await writeFile(join(directory, 'capture-metadata.json'), JSON.stringify(metadata));
  await assert.rejects(validateCaptures(directory), /exactly once/);
  const bytes = testPNG(1200, 800); bytes[40] ^= 1;
  assert.throws(() => pngDimensions(bytes), /checksum/);
  assert.throws(() => pngDimensions(testPNG(1200, 800).subarray(0, 33)), /incomplete/);
});

test('native peer report must match actual fixture bytes, digest and multi-chunk transfer', async t => {
  const directory = await fixture(t), bytes = Buffer.alloc(17000, 29), source = join(directory, 'source.png');
  await writeFile(source, bytes);
  await writeFile(join(directory, 'received.png'), bytes);
  const report = { transport: 'WKWebView RTCPeerConnection', bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex'), byteEquality: true,
    higherIDRequester: true, iceServers: 0, connectRequests: 1, offererOffers: 1, signals: 5, elapsedSeconds: 1.2 };
  await writeFile(join(directory, 'result.json'), JSON.stringify(report));
  await writeFile(join(directory, 'result.txt'), 'PASS: native transport');
  assert.equal((await validatePeerTransfer(directory, source)).bytes, 17000);
  await writeFile(join(directory, 'received.png'), Buffer.alloc(17000, 30));
  await assert.rejects(validatePeerTransfer(directory, source), /bytes differ/);
});

test('stage runner refuses stale output, missing/failed markers, nonzero exits and timeouts', async t => {
  const directory = await fixture(t);
  let attempt = 0;
  async function run(code, prefill = false, timeoutMs = 2000) {
    const output = join(directory, `output-${attempt}`), log = join(directory, `log-${attempt++}.txt`);
    await mkdir(output);
    if (prefill) await writeFile(join(output, 'result.txt'), 'old success');
    return runStage(process.execPath, ['--input-type=module', '-e', code], { output, log, timeoutMs, env: { ...process.env, TEST_OUTPUT: output } });
  }
  await assert.rejects(run('', true), /refusing stale/);
  await assert.rejects(run(''), /ENOENT/);
  await assert.rejects(run('process.exit(7)'), /exited 7/);
  await assert.rejects(run("setTimeout(() => {}, 60000)", false, 50), /exceeded/);
  const marker = "import{writeFileSync}from'node:fs';writeFileSync(process.env.TEST_OUTPUT+'/result.txt','PASS:');";
  await assert.rejects(run(marker + "writeFileSync(process.env.TEST_OUTPUT+'/error.txt','failure');"), /failure marker/);
  assert.ok(await run(marker) > 0);
});
