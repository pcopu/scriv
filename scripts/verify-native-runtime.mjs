#!/usr/bin/env node
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { constants } from 'node:fs';
import { access, lstat, mkdir, mkdtemp, open, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const captureNames = ['01-script.png', '02-characters.png', '03-storyboard.png', '04-collaboration-local.png', '04-codex-popover.png'];
const digest = data => createHash('sha256').update(data).digest('hex');
const exists = async path => { try { await lstat(path); return true; } catch (error) { if (error.code === 'ENOENT') return false; throw error; } };
const crcTable = Array.from({ length: 256 }, (_, value) => {
  for (let bit = 0; bit < 8; bit++) value = (value & 1) ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  return value >>> 0;
});
function crc32(data) {
  let value = 0xffffffff;
  for (const byte of data) value = crcTable[(value ^ byte) & 0xff] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}

async function freshFile(path, startedAt) {
  const info = await lstat(path);
  assert.ok(info.isFile() && !info.isSymbolicLink(), `Not a regular artifact file: ${path}`);
  // Allow filesystem timestamp rounding, but reject previous-run artifacts.
  assert.ok(info.mtimeMs >= startedAt - 2000, `Stale artifact: ${path}`);
  return readFile(path);
}
async function marker(directory, startedAt, prefix) {
  assert.ok(!await exists(join(directory, 'error.txt')), `Native failure marker exists: ${join(directory, 'error.txt')}`);
  const text = (await freshFile(join(directory, 'result.txt'), startedAt)).toString('utf8');
  assert.ok(text.startsWith(prefix), 'Missing or invalid native success marker');
}
export function pngDimensions(data) {
  assert.ok(data.length >= 33 && data.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex')), 'Artifact is not a PNG');
  assert.equal(data.readUInt32BE(8), 13, 'PNG must start with an IHDR chunk');
  assert.equal(data.toString('ascii', 12, 16), 'IHDR', 'PNG has no IHDR header');
  const width = data.readUInt32BE(16), height = data.readUInt32BE(20);
  assert.ok(width > 0 && height > 0, 'PNG dimensions must be positive');
  let position = 8, imageData = false, ended = false;
  while (position + 12 <= data.length) {
    const length = data.readUInt32BE(position), end = position + 12 + length;
    assert.ok(end <= data.length, 'Truncated PNG chunk');
    const type = data.toString('ascii', position + 4, position + 8);
    assert.equal(crc32(data.subarray(position + 4, end - 4)), data.readUInt32BE(end - 4), `PNG chunk checksum failed: ${type}`);
    if (type === 'IDAT' && length > 0) imageData = true;
    if (type === 'IEND') { assert.equal(length, 0); ended = true; position = end; break; }
    position = end;
  }
  assert.ok(imageData && ended && position === data.length, 'PNG is incomplete or has trailing bytes');
  return { width, height };
}
export async function validateCaptures(directory, startedAt = 0) {
  await marker(directory, startedAt, 'Native SwiftUI/AppKit screenshots captured successfully.');
  const metadata = JSON.parse(await freshFile(join(directory, 'capture-metadata.json'), startedAt));
  assert.equal(metadata.schemaVersion, 1);
  assert.equal(metadata.status, 'captured');
  assert.equal(metadata.platform, 'macOS');
  assert.deepEqual((await readdir(directory)).filter(name => name.endsWith('.png')).sort(), [...captureNames].sort(), 'All five exact raw captures are required');
  assert.ok(Array.isArray(metadata.captures));
  assert.deepEqual(metadata.captures.map(value => value.filename).sort(), [...captureNames].sort(), 'Metadata must describe each capture exactly once');
  const images = [];
  for (const filename of captureNames) {
    const record = metadata.captures.find(value => value.filename === filename);
    const bytes = await freshFile(join(directory, filename), startedAt);
    const size = pngDimensions(bytes), popover = filename === '04-codex-popover.png';
    assert.equal(record.pixelWidth, size.width, `Pixel width differs: ${filename}`);
    assert.equal(record.pixelHeight, size.height, `Pixel height differs: ${filename}`);
    assert.ok(size.width >= (popover ? 200 : 1000) && size.height >= (popover ? 100 : 600), `Capture is unexpectedly small: ${filename}`);
    assert.equal(record.windowRole, popover ? 'codex-popover' : 'workspace');
    assert.equal(record.selectedTab, filename === '02-characters.png' ? 'Characters' : filename === '03-storyboard.png' ? 'Storyboard' : 'Script');
    assert.equal(record.discussionVisible, filename.startsWith('04-'));
    assert.equal(record.collaboratorCount, 0, 'This signed-out smoke fixture must not invent collaborators');
    assert.equal(record.discussionMessageCount, 0, 'This signed-out smoke fixture must not invent messages');
    assert.equal(record.codexConnected, false, 'Runtime verification must not start/sign into Codex');
    assert.ok(typeof record.codexStatus === 'string' && record.codexStatus.length > 0);
    for (const rectangle of [record.windowFrame, record.contentBounds]) {
      assert.ok(rectangle && ['x', 'y', 'width', 'height'].every(key => Number.isFinite(rectangle[key])), `Missing window geometry: ${filename}`);
      assert.ok(rectangle.width > 0 && rectangle.height > 0);
    }
    images.push({ filename, ...size, bytes: bytes.length, sha256: digest(bytes), windowFrame: record.windowFrame, contentBounds: record.contentBounds });
  }
  return { images, metadata, limitation: 'Five unmodified content-view captures for four concepts; the Codex popover is separate, not composited. Artifact checks are not human visual-parity acceptance.' };
}
export async function validatePeerTransfer(directory, sourcePath, startedAt = 0) {
  await marker(directory, startedAt, 'PASS:');
  const result = JSON.parse(await freshFile(join(directory, 'result.json'), startedAt));
  const bytes = await freshFile(join(directory, 'received.png'), startedAt), expected = await readFile(sourcePath);
  assert.ok(expected.length > 16 * 1024, 'Peer fixture must span multiple chunks');
  assert.ok(bytes.equals(expected), 'Native peer bytes differ from the current repository fixture');
  assert.equal(result.transport, 'WKWebView RTCPeerConnection');
  assert.equal(result.bytes, bytes.length);
  assert.equal(result.sha256, digest(bytes));
  assert.equal(result.byteEquality, true);
  assert.equal(result.higherIDRequester, true);
  assert.equal(result.iceServers, 0);
  assert.ok(result.connectRequests >= 1 && result.offererOffers >= 1 && result.signals >= 2);
  assert.ok(Number.isFinite(result.elapsedSeconds) && result.elapsedSeconds > 0);
  return result;
}
export async function runStage(command, args, { output, log, timeoutMs, env = process.env }) {
  assert.deepEqual(await readdir(output), [], 'Native stage output must be empty; refusing stale evidence');
  const startedAt = Date.now(), handle = await open(log, 'wx');
  try {
    await new Promise((resolvePromise, reject) => {
      const child = spawn(command, args, { cwd: root, env, stdio: ['ignore', handle.fd, handle.fd] });
      let timedOut = false, killTimer;
      const timeout = setTimeout(() => {
        timedOut = true;
        child.kill('SIGTERM');
        killTimer = setTimeout(() => child.kill('SIGKILL'), 3000);
      }, timeoutMs);
      const clear = () => { clearTimeout(timeout); clearTimeout(killTimer); };
      child.once('error', error => { clear(); reject(error); });
      child.once('close', (code, signal) => {
        clear();
        if (timedOut) reject(new Error(`Native stage exceeded ${timeoutMs} ms; its child was stopped. See ${log}`));
        else if (code !== 0) reject(new Error(`Native stage exited ${code ?? signal}. See ${log}`));
        else resolvePromise();
      });
    });
    assert.ok(!await exists(join(output, 'error.txt')), `Native failure marker exists: ${output}/error.txt`);
    await freshFile(join(output, 'result.txt'), startedAt);
    return startedAt;
  } finally { await handle.close(); }
}
async function main() {
  assert.equal(process.argv.length, 2, 'Usage: node scripts/verify-native-runtime.mjs');
  if (process.platform !== 'darwin') throw new Error('BLOCKED: Native runtime verification requires an authorized macOS executor. It is not run on Linux.');
  assert.ok(process.env.SCRIV_RELEASE !== '1' && !process.env.SCRIV_SIGN_IDENTITY, 'This verifier is for ad-hoc development builds only; unset release/private signing configuration.');
  await mkdir(join(root, 'build/native-runtime'), { recursive: true });
  const directory = await mkdtemp(join(root, 'build/native-runtime/run-'));
  const buildLog = await open(join(directory, 'build.log'), 'wx');
  try {
    await new Promise((resolvePromise, reject) => {
      const child = spawn('bash', ['scripts/verify-native.sh', '--native'], { cwd: root, env: { ...process.env, SCRIV_UNIVERSAL: '1' }, stdio: ['ignore', buildLog.fd, buildLog.fd] });
      child.once('error', reject);
      child.once('close', code => code === 0 ? resolvePromise() : reject(new Error(`Native build failed (${code}); see ${directory}/build.log`)));
    });
  } finally { await buildLog.close(); }
  const executable = join(root, 'build/Scriv.app/Contents/MacOS/Scriv');
  await access(executable, constants.X_OK);
  const peerOutput = join(directory, 'peer-smoke'), screenshots = join(directory, 'screenshots');
  await mkdir(peerOutput); await mkdir(screenshots);
  const env = { ...process.env, SCRIV_VERIFICATION_ROOT: join(directory, 'isolated-app-data') };
  const peerStarted = await runStage(executable, ['--peer-smoke', peerOutput], { output: peerOutput, log: join(directory, 'peer-smoke.log'), timeoutMs: 75000, env });
  const peer = await validatePeerTransfer(peerOutput, join(root, 'apps/mac/Sources/ScrivApp/Resources/SampleImages/farm-wide.png'), peerStarted);
  const captureStarted = await runStage(executable, ['--screenshots', screenshots], { output: screenshots, log: join(directory, 'screenshots.log'), timeoutMs: 90000, env });
  const captures = await validateCaptures(screenshots, captureStarted);
  const report = { schemaVersion: 1, verifiedAt: new Date().toISOString(), platform: process.platform, architecture: process.arch, executableSha256: digest(await readFile(executable)), peer, captures, productionAccountChecksRun: false, humanVisualParityAccepted: false };
  await writeFile(join(directory, 'verification.json'), `${JSON.stringify(report, null, 2)}\n`, { flag: 'wx' });
  console.log(`PASS: native development build, WebKit byte transfer and five fresh raw captures. Evidence: ${directory}`);
  console.log('NOT VERIFIED: human screenshot parity, live-account flows, notarization, or execution on the other CPU architecture.');
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
