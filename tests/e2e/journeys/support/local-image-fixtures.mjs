import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { inflateSync } from 'node:zlib';
const automation = new URL('../../../../apps/catalyst/ScrivUIKit/Automation/', import.meta.url);
// Source/fixture checks only. These do not prove native decoding, isolation or UI behavior.
export function validateLocalImageFixtures() {
  const source = readFileSync(new URL('ScrivCLILocalImageFixtures.swift', automation), 'utf8');
  const matches = [...source.matchAll(/case "([^"]+)": encoded = "([^"]+)"/g)];
  assert.equal(matches.length, 2);
  const expected = {
    coral: ['827d9145314e931860ee40b45f8348ad3527c93e008d1490b687265d947fb577', [240, 80, 60]],
    blue: ['3fba282698b3df63c76fb40e529943fb6da6d28bafa6ff9e3a75c0c4a0cbb784', [40, 100, 220]],
  };
  for (const [, token, encoded] of matches) {
    const bytes = Buffer.from(encoded, 'base64'); assert.equal(bytes.length, 73);
    assert.equal(createHash('sha256').update(bytes).digest('hex'), expected[token][0]);
    assert.deepEqual([...bytes.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
    assert.equal(bytes.readUInt32BE(16), 2); assert.equal(bytes.readUInt32BE(20), 2);
    assert.deepEqual([...inflateSync(bytes.subarray(41, 57))], [0, ...expected[token][1], ...expected[token][1], 0, ...expected[token][1], ...expected[token][1]]);
  }
}
