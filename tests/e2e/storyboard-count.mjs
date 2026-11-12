import assert from 'node:assert/strict';
import { ScrivSession } from '../../cli/scriv.mjs';
import { waitForSavedProject } from './support/saved-projects.mjs';

// Candidate replacement for frozen inventory WorkspaceEndToEndTests.swift::0013
// (testStoryboardCountIsSingularForOnePicture). Native execution/review is still
// required before retirement. The key command invokes UIKit's responder action;
// this does not claim physical keyboard delivery or window-size parity.
assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to an automation-enabled Catalyst bundle');
const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
const readyTabs = nodes => nodes.find(node => node.identifier === 'workspace-tabs' && node.enabled && node.hittable);

try {
  await session.waitFor(readyTabs);
  // Verification startup may not have saved the sample yet. Use the real Save
  // action before recording IDs, so a delayed sample save cannot be mistaken
  // for the project created by New.
  await session.command('key', { input: 's', modifiers: ['command'] });
  await waitForSavedProject(session, project => typeof project.id === 'string');
  const originalIDs = new Set((await session.command('persisted-projects')).map(project => project.id));
  await session.command('key', { input: 'n', modifiers: ['command'] });
  await session.command('key', { input: 's', modifiers: ['command'] });
  const created = await waitForSavedProject(session, project => !originalIDs.has(project.id));

  // The single-scene guard makes persisted scene membership unambiguous,
  // without inventing an unobservable selected-scene value.
  assert.equal(created.scenes.length, 1, 'New project has exactly one scene');
  const sceneID = created.scenes[0].id;
  assert.equal(created.cues.filter(cue => cue.sceneId === sceneID).length, 1,
    'A new project starts with one picture placement (baseline assertion 1)');

  const tabs = readyTabs(await session.waitFor(readyTabs));
  const storyboard = tabs.segments.indexOf('Storyboard');
  assert.ok(storyboard >= 0, 'Storyboard tab is exposed by the actual app');
  await session.command('select', { target: tabs.identifier, index: storyboard });
  await session.waitFor(nodes => readyTabs(nodes)?.selected === storyboard
    && nodes.some(node => /Label/.test(node.type) && node.windowPath !== undefined
      && node.text?.startsWith('1 image · ')));
  // Check the same singular label again after a real tab round trip.
  const script = tabs.segments.indexOf('Script');
  assert.ok(script >= 0);
  await session.command('select', { target: tabs.identifier, index: script });
  await session.waitFor(nodes => readyTabs(nodes)?.selected === script);
  await session.command('select', { target: tabs.identifier, index: storyboard });
  await session.waitFor(nodes => readyTabs(nodes)?.selected === storyboard
    && nodes.some(node => /Label/.test(node.type) && node.text?.startsWith('1 image · ')));
  console.log('PASS: actual UIKit new-project single picture placement and singular Storyboard header');
} finally { await session.close(); }
