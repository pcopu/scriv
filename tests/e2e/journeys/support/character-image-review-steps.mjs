import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { packageImageFixture } from './package-image-fixture.mjs';

export const reviewFixtureToken = 'character-review-seeded-v1';
// Frozen synthetic prior-analysis input. This is not provider output observed by
// this journey: no scan/provider is invoked, and the PNGs contain no real faces.
export function characterReviewFixture() {
  const project = packageImageFixture();
  project.title = 'Synthetic character review';
  project.characters = [{ id: 'synthetic-existing', name: 'Synthetic Avery', aliases: [],
    biography: 'Synthetic review fixture only.', appearance: '', color: 'blue' }];
  project.images[0].characterAnalysis = {
    imageSHA256: project.images[0].sha256, imageVersion: 1,
    providerID: 'synthetic-seeded-review', completedAt: 1700000000000,
    annotations: [[0, 0], [0.5, 0], [0, 0.5]].map(([x, y], index) => ({
      id: `synthetic-review-${index + 1}`, region: { x, y, width: 0.5, height: 0.5 },
      portraitRegion: { x, y, width: 0.5, height: 0.5 }, kind: 'face', confidence: 0.5,
      reason: `Synthetic prior analysis candidate ${index + 1}.`, decision: 'needsReview',
    })), excludedCharacterIDs: [], manualCharacterIDs: [],
  };
  return project;
}
export function validateCharacterReviewFixture() {
  const source = readFileSync(new URL('../../../../apps/catalyst/ScrivUIKit/Automation/ScrivCLIPackageFixture.swift', import.meta.url), 'utf8');
  const literal = source.match(/static let reviewProjectJSON = #"""\n([\s\S]*?)\n    """#/);
  assert.ok(literal, 'Native input must remain a literal package');
  assert.deepEqual(JSON.parse(literal[1]), characterReviewFixture());
}
export function characterImageReviewSteps(session, ui) {
  const button = title => n => n.title === title && n.enabled !== undefined;
  async function candidate(index, count) {
    await session.waitFor(nodes => nodes.some(n => n.text === `Synthetic prior analysis candidate ${index}.`)
      && nodes.some(n => n.text === `${count} to review · Background · v1`)
      && nodes.some(n => n.identifier === 'character-review-save' && n.enabled === false));
  }
  async function open(index, count) {
    await ui.tab('Characters');
    await ui.activate(button('Review 1'));
    await candidate(index, count);
  }
  async function rejectDisabledSave() {
    const nodes = await session.waitFor(nodes => nodes.some(n => n.identifier === 'character-review-save' && n.enabled === false));
    const save = nodes.find(n => n.identifier === 'character-review-save');
    await assert.rejects(session.command('activate', { target: save.path }), /Target is disabled$/);
  }
  async function done() {
    await ui.activate(button('Done'));
    await session.waitFor(nodes => nodes.every(n => n.identifier !== 'character-review-save')
      && nodes.some(n => n.identifier === 'workspace-tabs' && n.hittable));
    // Never call loaded-project/local-image-evidence inside the review modal.
  }
  async function skip() { await ui.activate(button('Skip for now')); }
  async function chooseExisting() {
    await ui.activate(n => n.label === 'Synthetic Avery' && n.enabled !== undefined
      && n.identifier !== 'character-ribbon-synthetic-existing');
    await session.waitFor(nodes => nodes.some(n => n.identifier === 'character-review-save' && n.enabled === true));
  }
  return { candidate, open, done, skip, chooseExisting, rejectDisabledSave,
    save: () => ui.activate(n => n.identifier === 'character-review-save'),
    ignore: () => ui.activate(n => n.identifier === 'character-review-ignore') };
}
