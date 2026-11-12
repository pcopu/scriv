import assert from 'node:assert/strict';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { audioProjectFixture } from './audio-library-fixtures.mjs';
import { audioLibrarySteps } from './audio-library-steps.mjs';
import { coverageSteps, ready, sorted } from './picture-coverage-steps.mjs';

export const followCases = ['startup-scene-word-inventory', 'word-inventory', 'three-select-deselect-cycles', 'current-moment-changed-cue',
  'preview-follow-retains-words', 'current-moment-same-cue', 'repeat-navigation', 'browser-reopen'];
export const followListing = {
  journey: 'AUT-J09', portion: 'cue-follow', nativeVerified: false, optIn: false, cases: followCases,
  inputRoute: 'Production JSON import > Script playback UISlider > Storyboard word UIButton > Current moment / Preview Follow playhead UIButton',
  additionalAcceptance: ['complete startup-scene word inventory', 'exact preview cue and unchanged playhead', 'non-playhead word coverage values',
    'changed-cue versus same-cue word selection', 'disabled Deselect rejection',
    'all saved packages and entire loaded model including Date witnesses unchanged', 'browser reopen'],
  excluded: ['selected accessibility traits', 'scroll displacement', 'physical input', 'drag', 'pixels', 'restart recovery', 'legacy retirement'],
};

// Finite synthetic serialized document, imported through the production route.
// No helper mutates the installed model or calls a private action handler.
export function followFixture() {
  const source = audioProjectFixture();
  source.title = 'Synthetic picture follow journey';
  source.cues[0].label = 'Opening'; source.cues[1].label = 'Ending';
  return source;
}
const word = id => node => node.identifier === `storyboard-word-${id}`;
const deselect = nodes => nodes.find(node => node.identifier === 'storyboard-deselect');
const covered = 'Covered by selected picture';

export async function runFollowJourney() {
  assert.ok(process.env.SCRIV_E2E_APP, 'Requires an isolated automation-enabled Catalyst app');
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const ui = coverageSteps(session), browser = audioLibrarySteps(session);
  let stage = 'setup', sample, current, loaded;
  async function invariant() {
    assert.deepEqual(sorted(await session.command('persisted-projects')), sorted([sample, current]),
      'Every saved field, revision, timestamp and startup package remains exact');
    assert.deepEqual(await session.command('loaded-project'), loaded,
      'Entire loaded model and exact Date witnesses remain unchanged');
    assert.deepEqual(await session.command('presented-alerts'), []);
  }
  async function step(name, body) {
    stage = name; await body(); await invariant(); console.log(`PASS AUT-J09/follow/${name}`);
  }
  async function selection(selectedCue, count) {
    const values = selectedCue === 'Opening' ? [covered, covered, 'Playhead word', '']
      : ['', '', 'Playhead word', covered];
    const ids = ['w1', 'w2', 'w3', 'line2-word'];
    await session.waitFor(nodes => ids.every((id, index) => nodes.find(word(id))?.value === values[index])
      && deselect(nodes)?.enabled === (count > 0)
      && (count ? nodes.some(n => n.text === '1 word selected') : !nodes.some(n => n.text === '1 word selected')));
    // w3 intentionally proves the playhead but cannot prove selected coverage:
    // its value masks coverage. Both w1/w2 and line2-word must independently match.
  }
  async function preview(label, inspecting) {
    await session.waitFor(nodes => nodes.filter(n => n.text === `${label} · No image chosen`).length === 1
      && nodes.some(n => n.identifier === 'scene-playback-position'
        && n.slider?.value === 2500 && n.slider.maximum === 5000)
      && (inspecting ? nodes.some(n => n.text === 'Inspecting selected image · starts 00:03.0')
        && nodes.some(n => n.label === 'Follow playhead' && ready(n))
        : !nodes.some(n => n.text?.startsWith('Inspecting selected image'))
          && !nodes.some(n => n.label === 'Follow playhead')));
  }
  async function inspectEnding() {
    await ui.tab('Script');
    const slider = await ui.reveal(n => n.identifier === 'scene-playback-position');
    assert.equal(slider.slider.maximum, 5000);
    // Seek FIRST: seeking after the word tap would erase the off-time inspection.
    await session.command('slider', { target: slider.path, value: 2500 });
    await preview('Opening', false);
    await ui.tab('Storyboard'); await ui.activate(word('line2-word'));
    await selection('Ending', 1);
    await ui.tab('Script'); await preview('Ending', true);
    await invariant(); await ui.tab('Storyboard'); await selection('Ending', 1);
  }
  async function currentMoment() {
    await inspectEnding(); await ui.button('Current moment'); await selection('Opening', 0);
    // Observe without reveal: the button belongs to the target card. With two
    // cards this is visibility evidence only, not proof of scroll displacement.
    await session.waitFor(nodes => nodes.some(n => n.identifier === 'storyboard-duration-image1' && ready(n)));
    await assert.rejects(session.command('activate', { target: 'storyboard-deselect' }), /disabled/);
    await ui.tab('Script'); await preview('Opening', false);
  }
  async function followPlayhead() {
    await inspectEnding(); await ui.tab('Script'); await preview('Ending', true);
    await ui.button('Follow playhead'); await preview('Opening', false);
    await ui.tab('Storyboard'); await selection('Opening', 1);
    await ui.activate(n => n.identifier === 'storyboard-deselect'); await selection('Opening', 0);
  }
  try {
    const capabilities = await session.command('capabilities');
    for (const command of ['import-json', 'persisted-projects', 'loaded-project', 'snapshot',
      'activate', 'select', 'slider', 'scroll', 'key', 'text', 'presented-alerts']) {
      assert.ok(capabilities.commands.includes(command), `App supports ${command}`);
    }
    assert.equal(capabilities.cloudIsolation.network, 'disabled');
    await ui.tab('Script'); await session.command('key', { input: 's', modifiers: ['command'] });
    sample = await waitForSavedProject(session, p => p.entries.length > 0);
    assert.equal((await session.command('persisted-projects')).length, 1);
    stage = 'startup-scene-word-inventory';
    const sampleLoaded = await session.command('loaded-project');
    assert.deepEqual(sampleLoaded.project, sample);
    await ui.tab('Storyboard');
    const startupNodes = await session.waitFor(nodes => nodes.some(n =>
      n.identifier?.startsWith('storyboard-word-') && ready(n)) && deselect(nodes));
    const startupIDs = startupNodes.filter(n => n.identifier?.startsWith('storyboard-word-'))
      .map(n => n.identifier);
    assert.equal(new Set(startupIDs).size, startupIDs.length, 'One mounted control per startup word');
    // Preserve the standalone journey's larger startup-scene witness without
    // assuming which scene was chosen or deriving UI content from timing rules.
    const matchingScenes = sample.scenes.filter(scene => {
      const expectedIDs = sample.entries.filter(entry => entry.sceneId === scene.id)
        .flatMap(entry => entry.words.map(word => `storyboard-word-${word.id}`));
      return expectedIDs.length === startupIDs.length && expectedIDs.every(id => startupIDs.includes(id));
    });
    assert.equal(matchingScenes.length, 1,
      'Every saved word in the displayed startup scene has exactly one control');
    assert.equal(deselect(startupNodes).enabled, false, 'Startup Deselect is disabled without selection');
    assert.deepEqual(await session.command('persisted-projects'), [sample]);
    assert.deepEqual(await session.command('loaded-project'), sampleLoaded,
      'Startup inventory navigation preserves the entire model and exact Date witnesses');
    assert.deepEqual(await session.command('presented-alerts'), []);
    console.log('PASS AUT-J09/follow/startup-scene-word-inventory');
    await ui.tab('Script');
    stage = 'synthetic-import';
    const source = followFixture();
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(source) }),
      { dispatched: true, projectChanged: true });
    current = await waitForSavedProject(session, p => p.id !== sample.id);
    assert.notEqual(current.id, source.id);
    assert.match(current.id, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
    assert.ok(Number.isFinite(current.createdAt) && Number.isFinite(current.modifiedAt));
    assert.equal(current.createdAt, current.modifiedAt);
    const expected = structuredClone(source);
    for (const key of ['id', 'createdAt', 'modifiedAt']) expected[key] = current[key];
    assert.deepEqual(current, expected, 'Only import identity/timestamp envelope changes');
    loaded = await session.command('loaded-project'); assert.deepEqual(loaded.project, current);
    await ui.tab('Storyboard');
    await step('word-inventory', async () => {
      const nodes = await session.waitFor(nodes => nodes.some(word('w1')) && deselect(nodes));
      const ids = nodes.filter(n => n.identifier?.startsWith('storyboard-word-')).map(n => n.identifier).sort();
      assert.equal(new Set(ids).size, ids.length, 'Exactly one mounted control per word');
      assert.deepEqual(ids, current.entries.flatMap(e => e.words.map(w => `storyboard-word-${w.id}`)).sort());
      assert.equal(deselect(nodes).enabled, false);
    });
    await step('three-select-deselect-cycles', async () => {
      for (const id of ['w1', 'w2', 'line2-word']) {
        await ui.activate(word(id));
        await session.waitFor(nodes => deselect(nodes)?.enabled && nodes.some(n => n.text === '1 word selected'));
        await ui.activate(n => n.identifier === 'storyboard-deselect');
        await session.waitFor(nodes => deselect(nodes)?.enabled === false && !nodes.some(n => n.text === '1 word selected'));
        await assert.rejects(session.command('activate', { target: 'storyboard-deselect' }), /disabled/);
        await invariant();
      }
    });
    await step('current-moment-changed-cue', currentMoment);
    await step('preview-follow-retains-words', followPlayhead);
    await step('current-moment-same-cue', async () => {
      await ui.activate(word('w1')); await selection('Opening', 1);
      await ui.button('Current moment'); await selection('Opening', 1);
      await ui.activate(n => n.identifier === 'storyboard-deselect'); await selection('Opening', 0);
    });
    await step('repeat-navigation', async () => { await currentMoment(); await followPlayhead(); });
    await step('browser-reopen', async () => {
      await ui.tab('Script'); await session.command('key', { input: 's', modifiers: ['command'] });
      await invariant();
      assert.deepEqual((await browser.openProject(sample)).project, sample);
      assert.deepEqual(await browser.openProject(current), loaded, 'Project browser reopen preserves exact model and Date witnesses');
      await invariant();
      await currentMoment(); await followPlayhead();
    });
    console.log('PASS AUT-J09 follow: real word/buttons, unmasked coverage values, preview identity, selection branch behavior and exact persistence. No physical input or scroll-displacement claim.');
  } catch (error) { console.error(`FAIL AUT-J09/follow/${stage}`); throw error; }
  finally { await session.close(); }
}

// Portable fixture bounds only, never reported as native application evidence.
const fixture = followFixture();
assert.deepEqual(fixture.cues.map(c => [c.label, c.startMs, c.endMs]), [['Opening', 0, 3000], ['Ending', 3000, 5000]]);
assert.deepEqual(fixture.entries.map(e => e.ownedDurationMs), [3000, 2000]);
assert.equal(fixture.entries.flatMap(e => e.words).length, 4);
