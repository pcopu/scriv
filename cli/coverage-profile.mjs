import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
const MAX_BYTES = 16 * 1024 * 1024;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const sha = bytes => createHash('sha256').update(bytes).digest('hex');

// Bounded transport shared by genuine app-session coverage and the smoke probe.
export async function captureProfile(command, runID, diagnostic = () => {}, snapshotStage = 'before-snapshot', workspaceID, snapshotParameters) {
  diagnostic(snapshotStage, 'coverage-snapshot');
  const metadata = await command('coverage-snapshot', snapshotParameters);
  assert.match(metadata.token, UUID);
  const token = metadata.token;
  let primaryFailure = false;
  try {
    assert.equal(metadata.schemaVersion, 1);
    assert.equal(metadata.runID, runID);
    if (workspaceID !== undefined) assert.equal(metadata.workspaceID, workspaceID);
    assert.equal(metadata.format, 'llvm-profraw');
    assert.equal(metadata.cumulative, true);
    assert.match(metadata.sha256, /^[0-9a-f]{64}$/);
    assert.ok(Number.isSafeInteger(metadata.byteCount) && metadata.byteCount > 0 && metadata.byteCount <= MAX_BYTES);
    assert.ok(Number.isSafeInteger(metadata.maximumChunkBytes) && metadata.maximumChunkBytes > 0
      && metadata.maximumChunkBytes <= 128 * 1024);
    const buffer = Buffer.alloc(metadata.byteCount);
    let offset = 0;
    while (offset < buffer.length) {
      const length = Math.min(metadata.maximumChunkBytes, buffer.length - offset);
      diagnostic('chunk-read', 'coverage-read');
      const chunk = await command('coverage-read', { token, offset, length });
      assert.equal(chunk.schemaVersion, 1); assert.equal(chunk.token, token);
      assert.equal(chunk.offset, offset); assert.equal(chunk.byteCount, length);
      assert.equal(chunk.nextOffset, offset + length);
      assert.equal(chunk.eof, offset + length === buffer.length);
      assert.equal(typeof chunk.base64, 'string');
      assert.equal(chunk.base64.length, 4 * Math.ceil(length / 3));
      const bytes = Buffer.from(chunk.base64, 'base64');
      assert.equal(bytes.length, length); assert.equal(bytes.toString('base64'), chunk.base64);
      bytes.copy(buffer, offset); offset += length;
    }
    assert.equal(sha(buffer), metadata.sha256);
    return { buffer, byteCount: buffer.length, sha256: metadata.sha256 };
  } catch (error) {
    primaryFailure = true;
    throw error;
  } finally {
    // One release attempt. Preserve the original failure stage if cleanup also fails.
    if (!primaryFailure) diagnostic('release', 'coverage-release');
    try {
      const released = await command('coverage-release', { token });
      assert.equal(released.schemaVersion, 1); assert.equal(released.token, token);
      assert.equal(released.released, true);
    } catch (error) { if (!primaryFailure) throw error; }
  }
}
