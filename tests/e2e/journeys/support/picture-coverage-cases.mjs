import { anchoredFixture } from './json-model-cases.mjs';

export const foregroundID = 'apps/mac/Tests/ScrivCoreTests/CueAnchoringTests.swift::0003';
export const clippedID = 'apps/mac/Tests/ScrivCoreTests/CueAnchoringTests.swift::0005';
export const invalidSeconds = ['', '0', '-1', '0.0009', '86400.001', '1.2.3', 'NaN', 'inf', '-inf', '1e309'];
// Literal expected outputs, not a JavaScript implementation of timing rules.
export const validCases = [
  { text: '0.001', authored: 1, end: 1001, display: '0.001' },
  { text: '86400', authored: 86400000, end: 4000, display: '86400.000' },
  { text: '1.2345', authored: 1235, end: 2235, display: '1.235' },
  { text: '10', authored: 10000, end: 4000, display: '10.000', partialBaselineID: clippedID },
  { text: '0.5', authored: 500, end: 1500, display: '0.500', candidateBaselineID: foregroundID },
];
export const foregroundCases = [
  { milliseconds: 999, label: 'Parent' },
  { milliseconds: 1000, label: 'Child' },
  { milliseconds: 1500, label: 'Parent' },
];
export function fixture() {
  // This is serialized input to the production document importer, never an
  // assignment to installed app state. Frozen timing fixture with explicit empty
  // annotations: restoreContent intentionally bootstraps absent legacy links on
  // Undo, so this journey begins with established empty metadata. Do not strip
  // or normalize links from persistence comparisons.
  const project = anchoredFixture();
  for (const entry of project.entries) entry.characterLinks = [];
  return project;
}
export function content(project) {
  const copy = structuredClone(project);
  delete copy.revision;
  delete copy.modifiedAt;
  return copy;
}
export function expectedContent(before, test) {
  const expected = content(before);
  const child = expected.cues.find(cue => cue.id === 'child');
  child.authoredDurationMs = test.authored;
  child.endMs = test.end;
  return expected;
}
