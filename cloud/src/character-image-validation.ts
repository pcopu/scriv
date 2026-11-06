import { assert, id, record, str } from './http';

function region(value: unknown): void {
  const r = record(value, 'character region');
  for (const key of ['x', 'y', 'width', 'height']) assert(typeof r[key] === 'number' && Number.isFinite(r[key]), 400, 'invalid_character_region', 'Character regions must contain finite normalized coordinates.');
  const x = r.x as number, y = r.y as number, width = r.width as number, height = r.height as number;
  assert(x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.000001 && y + height <= 1.000001, 400, 'invalid_character_region', 'Character regions must be inside the image.');
}
function identities(value: unknown, name: string): string[] {
  assert(Array.isArray(value) && value.length <= 100, 400, 'invalid_character_analysis', `${name} must contain at most 100 identities.`);
  const result = value.map(v => id(v, name));
  assert(new Set(result).size === result.length, 400, 'invalid_character_analysis', `${name} must not contain duplicates.`);
  return result;
}
export function validateCharacterImageAnalysis(data: Record<string, unknown>): void {
  if (data.characterAnalysis === undefined || data.characterAnalysis === null) return;
  const a = record(data.characterAnalysis, 'characterAnalysis');
  assert(a.imageSHA256 === data.sha256 && a.imageVersion === data.version, 400, 'stale_character_analysis', 'Character analysis must match the exact image version.');
  str(a.providerID, 'analysis.providerID', 200);
  assert(typeof a.completedAt === 'number' && Number.isFinite(a.completedAt) && a.completedAt >= 0, 400, 'invalid_character_analysis', 'Analysis completion time must be valid.');
  identities(a.excludedCharacterIDs, 'excludedCharacterIDs'); identities(a.manualCharacterIDs, 'manualCharacterIDs');
  assert(Array.isArray(a.annotations) && a.annotations.length <= 100, 400, 'invalid_character_analysis', 'Analysis must contain at most 100 regions.');
  const ids = new Set<string>();
  for (const raw of a.annotations) {
    const annotation = record(raw, 'character annotation'), identity = id(annotation.id, 'annotation.id');
    assert(!ids.has(identity), 400, 'invalid_character_analysis', 'Character region identities must be unique.'); ids.add(identity);
    region(annotation.region); region(annotation.portraitRegion);
    assert(typeof annotation.kind === 'string' && ['face', 'figure', 'partial', 'obscured'].includes(annotation.kind), 400, 'invalid_character_analysis', 'Unknown character region type.');
    assert(typeof annotation.decision === 'string' && ['automatic', 'needsReview', 'confirmed', 'ignored'].includes(annotation.decision), 400, 'invalid_character_analysis', 'Unknown character review decision.');
    if (annotation.characterID !== undefined && annotation.characterID !== null) id(annotation.characterID, 'annotation.characterID');
    assert(!['automatic', 'confirmed'].includes(annotation.decision) || typeof annotation.characterID === 'string', 400, 'invalid_character_analysis', 'Accepted character regions require a canonical identity.');
    assert(typeof annotation.confidence === 'number' && Number.isFinite(annotation.confidence) && annotation.confidence >= 0 && annotation.confidence <= 1, 400, 'invalid_character_analysis', 'Confidence must be between zero and one.');
    str(annotation.reason, 'annotation.reason', 1000, 0);
    if (annotation.suggestedName !== undefined && annotation.suggestedName !== null) str(annotation.suggestedName, 'annotation.suggestedName', 200, 0);
  }
}
export function validateCharacterPortrait(data: Record<string, unknown>): void {
  if (data.portraitRegion === undefined || data.portraitRegion === null) return;
  const crop = record(data.portraitRegion, 'portraitRegion');
  assert(id(crop.imageID, 'portraitRegion.imageID') === data.portraitImageId, 400, 'invalid_character_portrait', 'The crop must refer to the selected portrait image.');
  assert(typeof crop.imageSHA256 === 'string' && /^[a-fA-F0-9]{64}$/.test(crop.imageSHA256), 400, 'invalid_character_portrait', 'Portrait crops require an exact image digest.');
  assert(crop.isAutomatic === undefined || crop.isAutomatic === null || typeof crop.isAutomatic === 'boolean', 400, 'invalid_character_portrait', 'Portrait provenance must be explicit when supplied.');
  region(crop.region);
}
