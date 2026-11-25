import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { audioProjectFixture, audioDirectionProjectFixture, syntheticPCM, verifyImportedAsset, invalidAudioRequests,
  invalidTimingDrafts, stableContent, editedContent, syntheticFilename, draftBaseline, trackBaseline } from './support/audio-library-fixtures.mjs';
import { audioLibrarySteps, sortedProjects } from './support/audio-library-steps.mjs';
import { audioBoundaryCases, runAudioBoundarySteps } from './support/audio-boundary-steps.mjs';
import { sourceShrinkCases, runAudioSourceShrinkSteps } from './support/audio-source-shrink-steps.mjs';
import { attachmentCases, directionAttachmentCases, runAudioAttachmentSteps } from './support/audio-attachment-steps.mjs';

// AUT-J13/AUT-J14 initial semantic-import/library/numeric-timing portions only.
// Each group owns a fresh actual app. No picker, microphone, playback-output,
// private menu handler, domain-model setter, storage fault or parallel decoder.
const defaultGroups = ['import', 'mix', 'timing', 'attachment', 'attachment-direction', 'timing-source-shrink', 'timing-boundaries'];
// Each accepted interaction group runs in its own isolated app session.
const groups = defaultGroups;
const args = process.argv.slice(2);
assert.ok(args.every((arg, index) => arg === '--list-cases' || arg === '--group'
  || args[index - 1] === '--group' && groups.includes(arg)), 'Unknown argument');
const selected = args.includes('--group') ? [args[args.indexOf('--group') + 1]] : defaultGroups;
assert.ok(selected.every(group => groups.includes(group)), `Choose --group ${groups.join(', ')}`);
const cases = {
  'timing-boundaries': audioBoundaryCases,
  'timing-source-shrink': sourceShrinkCases,
  attachment: attachmentCases,
  'attachment-direction': directionAttachmentCases,
  import: [...invalidAudioRequests().map(test => `reject-${test.name}`),
    'dialogue-import', 'scene-silence-import', 'library-preserves-two-clips', 'browser-reopen'],
  mix: ['scene-import', 'library-import-rejected', 'clip-volume', 'clip-mute', 'clip-unmute',
    'reopen-library', 'master-volume', 'master-mute', 'master-unmute', 'browser-reopen'],
  timing: ['dialogue-import', 'baseline-trim', 'cancel-draft-1', 'cancel-draft-2', 'step-source-in',
    ...invalidTimingDrafts.map(test => `reject-${test.name}`), 'correct-and-apply',
    'reopen-noop', 'browser-reopen'],
};
if (args.includes('--list-cases')) {
  console.log(JSON.stringify({ journeys: ['AUT-J13', 'AUT-J14'], groups, nativeVerified: false,
    cases: selected.flatMap(group => cases[group].map(id => ({ group, id }))),
    partialBaselineIDs: [`${draftBaseline}::0001`, `${draftBaseline}::0002`, `${draftBaseline}::0003`, `${draftBaseline}::0004`],
    relatedUncoveredBaselineIDs: [`${trackBaseline}::0001`, `${trackBaseline}::0002`, `${trackBaseline}::0005`, `${trackBaseline}::0006`],
    excluded: ['document picker/cancel', 'microphone', 'audible playback/source-position',
      'waveform crop/drag/pixels', 'physical/native attachment menu interaction', 'removed-entry draft rejection', 'remove/confirmation',
      'stale concurrent draft', 'arbitrary storage faults', 'corruption/repair/package export'],
  }, null, 2));
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'Requires an isolated automation-enabled Catalyst app');
  for (const group of selected) await runGroup(group);
}

async function runGroup(group) {
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const ui = audioLibrarySteps(session);
  let currentCase = 'setup';
  const completed = [];
  const saved = async () => sortedProjects(await session.command('persisted-projects'));
  let sample, current;
  async function run(name, body) {
    currentCase = name; await body(); completed.push(name);
    console.log(`PASS: AUT-J13/AUT-J14/${group}/${name}`);
  }
  async function unchanged(before) {
    assert.deepEqual(await saved(), before, 'Every field of every saved project is unchanged');
    assert.deepEqual(await session.command('presented-alerts'), [], 'No hidden error alert is dismissed or ignored');
  }
  async function mutation(before, expected) {
    const after = await waitForSavedProject(session, project => project.id === before.id && project.revision > before.revision);
    assert.equal(after.revision, before.revision + 1, 'One production edit creates one saved revision');
    assert.deepEqual(stableContent(after), expected, 'Only the intended fields and normal revision/time change');
    const packages = await saved();
    assert.equal(packages.length, 2); assert.deepEqual(packages.find(project => project.id === sample.id), sample);
    return after;
  }
  async function importClip(attachment, { silence = false, startMs = 0, entryId, durationMs = 4000 } = {}) {
    const before = current;
    const bytes = syntheticPCM({ silence });
    const result = await session.command('import-audio', { base64: bytes.toString('base64'), attachment }, 30000);
    assert.deepEqual(result, { dispatched: true, imported: true, cleanupVerified: true },
      'Success waits for the production decoder/store and owned-source cleanup');
    const after = await waitForSavedProject(session, project => project.id === before.id && project.audioClips.length === before.audioClips.length + 1);
    assert.equal(after.audioAssets.length, before.audioAssets.length + 1);
    const asset = after.audioAssets.at(-1), clip = after.audioClips.at(-1);
    verifyImportedAsset(asset, bytes, { silence });
    assert.match(clip.id, /^[0-9A-Fa-f-]{36}$/);
    const expectedClip = { id: clip.id, sceneId: 'scene', assetId: asset.id, startMs,
      sourceStartMs: 0, durationMs, volume: 1, isMuted: false };
    if (entryId !== undefined) expectedClip.entryId = entryId;
    assert.deepEqual(clip, expectedClip, 'Import preserves explicit scene versus selected-dialogue placement');
    current = await mutation(before, editedContent(before, project => {
      project.audioAssets.push(asset); project.audioClips.push(expectedClip);
    }));
    assert.deepEqual((await session.command('loaded-project')).project, current);
  }
  async function reopen() {
    const baseline = await session.command('loaded-project');
    assert.deepEqual(baseline.project, current);
    await session.command('key', { input: 's', modifiers: ['command'] });
    assert.deepEqual((await ui.openProject(sample)).project, sample);
    assert.deepEqual(await ui.openProject(current), baseline,
      'Real save/project-browser/reopen retains the entire Swift model and exact Date witnesses');
    await unchanged(sortedProjects([sample, current]));
  }
  try {
    const capabilities = await session.command('capabilities');
    for (const command of ['import-audio', 'import-json', 'loaded-project', 'persisted-projects',
      'snapshot', 'activate', 'text', 'select', 'slider', 'scroll', 'key', 'menu', 'presented-alerts']) {
      assert.ok(capabilities.commands.includes(command), `Matching compiled app supports ${command}`);
    }
    assert.ok(capabilities.semanticApplicationCommands.includes('import-audio'), 'Audio import is explicitly semantic, not a picker gesture');
    await ui.tab('Script');
    await session.command('key', { input: 's', modifiers: ['command'] });
    sample = await waitForSavedProject(session, project => project.title === 'YAM MAN');
    assert.equal((await saved()).length, 1);
    if (group.startsWith('attachment')) {
      assert.ok(capabilities.commands.includes('menu-action'));
      assert.ok(capabilities.semanticMenuActionScopes.includes('audio-anchor'));
    }
    const fixture = group === 'attachment-direction' ? audioDirectionProjectFixture() : audioProjectFixture();
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(fixture) }), { dispatched: true, projectChanged: true });
    current = await waitForSavedProject(session, project => project.id !== sample.id);
    const expected = structuredClone(fixture);
    for (const key of ['id', 'createdAt', 'modifiedAt']) expected[key] = current[key];
    assert.deepEqual(current, expected, 'Only documented import envelope fields change');
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-project' && node.title === fixture.title && node.hittable));

    if (group === 'import') {
      const before = await saved();
      for (const test of invalidAudioRequests()) {
        await run(`reject-${test.name}`, async () => {
          await assert.rejects(session.command('import-audio', test.request), /import-audio: Synthetic audio import is unavailable or invalid\.?$/);
          await unchanged(before);
        });
      }
      await run('dialogue-import', () => importClip('selected-dialogue', { entryId: 'line1' }));
      await run('scene-silence-import', async () => {
        await ui.slider('Playback position', 3500);
        await importClip('scene', { silence: true, startMs: 3500, durationMs: 1500 });
      });
      await run('library-preserves-two-clips', async () => {
        const before = await saved(); await ui.openLibrary();
        const nodes = await session.waitFor(nodes => current.audioClips.every(clip => nodes.some(node => node.identifier === 'audio-clip-trim-' + clip.id)));
        assert.ok(nodes.some(node => node.text === 'Stored in this project on this Mac · Not shared'));
        assert.ok(nodes.some(node => node.text === 'Scene track'));
        assert.ok(nodes.some(node => node.text === 'Follows dialogue'));
        for (const clip of current.audioClips) {
          assert.equal(nodes.filter(node => node.identifier === 'audio-clip-play-' + clip.id && node.enabled).length, 1,
            'Actual library sees the imported file and valid placement; no playback is dispatched');
        }
        await ui.closeLibrary(); await unchanged(before);
      });
      await run('browser-reopen', reopen);
    } else if (group === 'mix') {
      await run('scene-import', () => importClip('scene'));
      await ui.openLibrary();
      await run('library-import-rejected', async () => {
        const before = await saved();
        await assert.rejects(session.command('import-audio', { base64: syntheticPCM().toString('base64'), attachment: 'scene' }),
          /import-audio: Synthetic audio import is unavailable or invalid\.?$/);
        await unchanged(before);
      });
      await run('clip-volume', async () => {
        const before = current; await ui.slider('Clip volume for ' + syntheticFilename, 0.375);
        current = await mutation(before, editedContent(before, project => { project.audioClips[0].volume = 0.375; }));
      });
      for (const muted of [true, false]) {
        await run(muted ? 'clip-mute' : 'clip-unmute', async () => {
          const before = current;
          await ui.activate(node => node.label === (muted ? 'Mute ' : 'Unmute ') + syntheticFilename && node.enabled !== undefined);
          current = await mutation(before, editedContent(before, project => { project.audioClips[0].isMuted = muted; }));
        });
      }
      await run('reopen-library', async () => {
        const before = await saved(); await ui.closeLibrary(); await ui.openLibrary();
        const volume = await ui.reveal(node => node.label === 'Clip volume for ' + syntheticFilename && !!node.slider);
        assert.equal(volume.slider.value, 0.375);
        await ui.reveal(node => node.label === 'Mute ' + syntheticFilename && node.enabled !== undefined);
        await ui.closeLibrary(); await unchanged(before);
      });
      await run('master-volume', async () => {
        const before = current; await ui.slider('Local audio volume', 0.25);
        current = await mutation(before, editedContent(before, project => { project.audioVolume = 0.25; }));
      });
      for (const muted of [true, false]) {
        await run(muted ? 'master-mute' : 'master-unmute', async () => {
          const before = current;
          await ui.activate(node => node.label === (muted ? 'Mute local audio' : 'Unmute local audio') && node.enabled !== undefined);
          current = await mutation(before, editedContent(before, project => { project.audioVolume = muted ? 0 : 0.25; }));
        });
      }
      await run('browser-reopen', reopen);
    } else if (group === 'timing-boundaries') {
      await run('dialogue-import', () => importClip('selected-dialogue', { entryId: 'line1' }));
      current = await runAudioBoundarySteps({ session, ui, run, saved, unchanged, mutation, current });
      await run('browser-reopen', reopen);
    } else if (group === 'timing-source-shrink') {
      await run('dialogue-import', () => importClip('selected-dialogue', { entryId: 'line1' }));
      current = await runAudioSourceShrinkSteps({ session, ui, run, saved, unchanged, mutation, current });
      await run('browser-reopen', reopen);
    } else if (group.startsWith('attachment')) {
      await run('dialogue-import', () => importClip('selected-dialogue', { entryId: 'line1' }));
      current = await runAudioAttachmentSteps({ session, ui, run, saved, unchanged, mutation, current,
        direction: group === 'attachment-direction' });
      await run('browser-reopen', reopen);
    } else {
      await run('dialogue-import', () => importClip('selected-dialogue', { entryId: 'line1' }));
      await ui.openLibrary();
      await run('baseline-trim', async () => {
        const before = current; await ui.openTrim(current.audioClips[0], ['0.000', '4.000', '0.000']);
        await ui.draft('0.500', '2.500', '0.250'); await ui.finishTrim();
        current = await mutation(before, editedContent(before, project => {
          Object.assign(project.audioClips[0], { sourceStartMs: 500, durationMs: 2500, startMs: 250 });
        }));
      });
      const baseline = current;
      async function escapeFrom(responderType, action) {
        await session.command('end-editing');
        const binding = (await session.command('keys')).find(key => key.input === 'Escape' && !key.modifiers.length);
        assert.deepEqual([binding?.responderType, binding?.action], [responderType, action]);
        assert.deepEqual(await session.command('key', { input: 'Escape', modifiers: [] }), { dispatched: true });
      }
      for (const cycle of [1, 2]) {
        await run(`cancel-draft-${cycle}`, async () => {
          const before = await saved();
          await ui.openTrim(current.audioClips[0], ['0.500', '2.500', '0.250']);
          await ui.draft('1.000', '2.000', '0.250');
          await unchanged(before);
          if (cycle === 1) await ui.finishTrim(false);
          else {
            await escapeFrom('AudioClipEditorController', 'cancelDraft');
            await session.waitFor(nodes => nodes.every(node => node.identifier !== 'audio-trim-editor')
              && nodes.some(node => node.identifier === 'local-audio-sheet' && node.hittable));
          }
          await unchanged(before);
        });
      }
      await ui.openTrim(current.audioClips[0], ['0.500', '2.500', '0.250']);
      const beforeInvalid = await saved();
      await run('step-source-in', async () => {
        await ui.input('audio-source-in', '0.050');
        assert.deepEqual(await session.command('end-editing'), true);
        await ui.activate(node => node.label === 'Decrease Source in by 0.100 seconds');
        await ui.fields(['0.000', '2.500', '0.250']);
        await ui.activate(node => node.label === 'Increase Source in by 0.100 seconds');
        await ui.fields(['0.100', '2.500', '0.250']);
        await unchanged(beforeInvalid);
      });
      for (const test of invalidTimingDrafts) {
        await run(`reject-${test.name}`, async () => {
          await ui.draft(test.source, test.duration, test.offset);
          await ui.activate(node => node.identifier === 'audio-apply');
          await session.waitFor(nodes => nodes.some(node => node.identifier === 'audio-timing-validation')
            && nodes.some(node => node.text === 'Your changes are still in this editor. Nothing was applied from this draft.'));
          await ui.fields([test.source, test.duration, test.offset]);
          await unchanged(beforeInvalid);
        });
      }
      await run('correct-and-apply', async () => {
        await ui.draft('1.000', '2.000', '0.250'); await ui.finishTrim();
        current = await mutation(baseline, editedContent(baseline, project => {
          Object.assign(project.audioClips[0], { sourceStartMs: 1000, durationMs: 2000 });
        }));
        assert.equal(current.audioClips[0].entryId, 'line1'); assert.equal(current.audioClips[0].startMs, 250);
        assert.deepEqual(current.audioAssets, baseline.audioAssets);
        assert.deepEqual(current.cues, baseline.cues); assert.deepEqual(current.entries, baseline.entries);
      });
      await run('reopen-noop', async () => {
        const before = await saved();
        await ui.openTrim(current.audioClips[0], ['1.000', '2.000', '0.250']);
        const menu = await session.command('menu', { target: 'audio-anchor' });
        const actions = menu.primary.flatMap(item => item.children ?? []);
        assert.deepEqual(actions.map(action => [action.title, action.state]), [
          ['Scene time', 'off'], ['Dialogue · one two three', 'on'], ['Dialogue · four', 'off'],
        ], 'Attachment options are observed only, never private-handler activated');
        await ui.finishTrim(); await unchanged(before);
        await escapeFrom('AudioLibraryController', 'closeAudio');
        await session.waitFor(nodes => nodes.every(node => node.identifier !== 'local-audio-sheet'));
      });
      await run('browser-reopen', reopen);
    }
    assert.deepEqual(completed, cases[group], 'Every declared selected case ran exactly once');
    assert.deepEqual(await session.command('presented-alerts'), []);
    console.log(`PASS: AUT-J13/AUT-J14/${group}; semantic audio import and actual UIKit controls only`);
  } catch (error) {
    throw new Error(`AUT-J13/AUT-J14/${group}/${currentCase} failed`, { cause: error });
  } finally { await session.close(); }
}
