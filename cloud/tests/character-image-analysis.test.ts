import { describe, expect, it } from 'vitest';
import { validateItem } from '../src/validation';
import type { Item } from '../src/types';
const region = { x: 0.1, y: 0.1, width: 0.2, height: 0.3 };
const annotation = { id: 'region-one', region, portraitRegion: region, kind: 'face', characterID: 'mara', confidence: 0.95, reason: 'Story character context', decision: 'automatic' };
function image(): Pick<Item, 'id' | 'kind' | 'data'> {
  return { id: 'image', kind: 'image', data: { id: 'image', version: 1, fileName: 'original.png', sha256: 'a'.repeat(64), mimeType: 'image/png', byteCount: 100, characterIds: ['mara'], prompt: '', createdAt: 1000, characterAnalysis: { imageSHA256: 'a'.repeat(64), imageVersion: 1, providerID: 'synthetic', completedAt: 1000, annotations: [structuredClone(annotation)], excludedCharacterIDs: [], manualCharacterIDs: [] } } };
}
describe('character image analysis metadata', () => {
  it('accepts exact-version bounded character regions and legacy images', () => {
    expect(() => validateItem(image())).not.toThrow(); const legacy = image(); delete legacy.data.characterAnalysis; expect(() => validateItem(legacy)).not.toThrow();
  });
  it('rejects stale image version or hash', () => {
    for (const field of ['imageVersion', 'imageSHA256']) { const value = image(); (value.data.characterAnalysis as any)[field] = field === 'imageVersion' ? 2 : 'b'.repeat(64); expect(() => validateItem(value)).toThrow(); }
  });
  it('rejects out of bounds, empty, nonfinite and duplicate regions', () => {
    for (const invalid of [{ ...region, x: -0.1 }, { ...region, width: 0 }, { ...region, y: Infinity }, { ...region, height: 1 }]) { const value = image(); (value.data.characterAnalysis as any).annotations[0].region = invalid; expect(() => validateItem(value)).toThrow(); }
    const duplicate = image(); (duplicate.data.characterAnalysis as any).annotations.push(structuredClone(annotation)); expect(() => validateItem(duplicate)).toThrow();
  });
  it('requires a canonical ID for accepted tags but allows unknown review candidates', () => {
    const value = image(), a = (value.data.characterAnalysis as any).annotations[0]; delete a.characterID; expect(() => validateItem(value)).toThrow(); a.decision = 'needsReview'; expect(() => validateItem(value)).not.toThrow(); a.confidence = 1.01; expect(() => validateItem(value)).toThrow();
  });
  it('limits corrections and rejects malformed portrait source metadata', () => {
    const value = image(); (value.data.characterAnalysis as any).excludedCharacterIDs = Array(101).fill('mara'); expect(() => validateItem(value)).toThrow();
    const character: Pick<Item, 'id' | 'kind' | 'data'> = { id: 'mara', kind: 'character', data: { id: 'mara', name: 'Mara', aliases: [], biography: '', appearance: '', color: 'blue', portraitImageId: 'image', portraitRegion: { imageID: 'other', imageSHA256: 'a'.repeat(64), region } } };
    expect(() => validateItem(character)).toThrow(); (character.data.portraitRegion as any).imageID = 'image'; expect(() => validateItem(character)).not.toThrow();
  });
});
