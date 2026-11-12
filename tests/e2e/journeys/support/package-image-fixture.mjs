import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
// Literal frozen ImageInspectorInvariantTests fixture. Synthetic identities and
// dates replace initializer randomness; only fake image hashes/counts become
// real allowlisted PNG metadata. In particular nil characterLinks stay absent.
export const packageFixtureToken = 'image-inspector-invariants-v1';
export const inspectorBaseline = 'apps/mac/Tests/ScrivCoreTests/ImageInspectorInvariantTests.swift';
export function packageImageFixture() { return {
  "schemaVersion": 1,
  "id": "BBFD7B11-2D02-4000-8000-000000000001",
  "title": "Synthetic image inspector invariants",
  "createdAt": 1700000000000,
  "modifiedAt": 1700000000000,
  "revision": 0,
  "scenes": [
    {
      "id": "scene",
      "title": "Untitled scene",
      "order": 0
    }
  ],
  "entries": [
    {
      "id": "a",
      "sceneId": "scene",
      "order": 0,
      "kind": "dialogue",
      "text": "First source",
      "ownedDurationMs": 1000,
      "coverageDurationMs": 0,
      "color": "purple",
      "words": [
        {
          "id": "a-word-1",
          "text": "First",
          "startMs": 0,
          "endMs": 454
        },
        {
          "id": "a-word-2",
          "text": "source",
          "startMs": 454,
          "endMs": 1000
        }
      ]
    },
    {
      "id": "b",
      "sceneId": "scene",
      "order": 1,
      "kind": "dialogue",
      "text": "Second source",
      "ownedDurationMs": 2000,
      "coverageDurationMs": 0,
      "color": "purple",
      "words": [
        {
          "id": "b-word-1",
          "text": "Second",
          "startMs": 0,
          "endMs": 1000
        },
        {
          "id": "b-word-2",
          "text": "source",
          "startMs": 1000,
          "endMs": 2000
        }
      ]
    }
  ],
  "characters": [],
  "images": [
    {
      "id": "v1",
      "version": 1,
      "fileName": "one.png",
      "sha256": "827d9145314e931860ee40b45f8348ad3527c93e008d1490b687265d947fb577",
      "mimeType": "image/png",
      "byteCount": 73,
      "characterIds": [],
      "prompt": "Manual direction one",
      "createdAt": 1700000000000,
      "generationPrompt": "Exact submitted prompt one\nSource at generation time."
    },
    {
      "id": "v2",
      "version": 2,
      "fileName": "two.png",
      "sha256": "3fba282698b3df63c76fb40e529943fb6da6d28bafa6ff9e3a75c0c4a0cbb784",
      "mimeType": "image/png",
      "byteCount": 73,
      "characterIds": [],
      "prompt": "Manual direction two",
      "createdAt": 1700000000000,
      "previousVersionId": "v1"
    }
  ],
  "cues": [
    {
      "id": "background",
      "sceneId": "scene",
      "imageId": "v1",
      "label": "Background",
      "startMs": 0,
      "endMs": 3000,
      "prompt": "Current cue direction",
      "startAnchor": {
        "entryId": "a",
        "offsetMs": 0
      },
      "authoredDurationMs": 3000
    },
    {
      "id": "foreground",
      "sceneId": "scene",
      "imageId": "v2",
      "label": "Foreground",
      "startMs": 1000,
      "endMs": 2000,
      "prompt": "",
      "startAnchor": {
        "entryId": "b",
        "offsetMs": 0
      },
      "authoredDurationMs": 1000
    }
  ],
  "audioAssets": [],
  "audioClips": [],
  "audioVolume": 1
}; }
export function validatePackageImageFixture() {
  const source = readFileSync(new URL('../../../../apps/catalyst/ScrivUIKit/Automation/ScrivCLIPackageFixture.swift', import.meta.url), 'utf8');
  const literal = source.match(/static let projectJSON = #"""\n([\s\S]*?)\n    """#/);
  assert.ok(literal, 'App stages a literal JSON fixture, not a second model constructor');
  assert.deepEqual(JSON.parse(literal[1]), packageImageFixture());
  const fixture = packageImageFixture();
  assert.ok(fixture.entries.every(e => !Object.hasOwn(e, 'characterLinks')));
  assert.deepEqual(fixture.characters, []); assert.deepEqual(fixture.audioAssets, []); assert.deepEqual(fixture.audioClips, []);
  assert.equal(fixture.images[0].generationPrompt, 'Exact submitted prompt one\nSource at generation time.');
  assert.ok(!Object.hasOwn(fixture.images[1], 'generationPrompt'));
}
