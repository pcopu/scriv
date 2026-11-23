import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { waitForSavedProject } from '../support/saved-projects.mjs';
import { audioProjectFixture } from './support/audio-library-fixtures.mjs';
import { audioLibrarySteps } from './support/audio-library-steps.mjs';
import { fixtureImageHash, startCodexFixture } from './support/codex-loopback-fixture.mjs';

assert.ok(process.env.SCRIV_E2E_APP, 'Requires the signed isolated Catalyst app');
const app = process.env.SCRIV_E2E_APP;
const input = audioProjectFixture();
input.title = 'Synthetic character analysis';
input.characters.push({ id: 'anna', name: 'Anna', aliases: [], biography: '', appearance: 'Green coat', color: 'blue' });
let session;
let failed = false;
let step = 'launch with the owned analysis fixture';
const fixture = await startCodexFixture(() => session.root, ['analysis-success', 'analysis-invalid-thread', 'analysis-tool']);
try {
  for (const codexAnalysisFixtureOrigin of ['ws://localhost:4500', 'ws://127.0.0.1:4500/foreign', 'wss://127.0.0.1:4500']) {
    await assert.rejects(ScrivSession.launch(app, { codexAnalysisFixtureOrigin }), /Invalid session options/);
  }
  await assert.rejects(ScrivSession.launch(app, { codexAnalysisFixtureOrigin: fixture.endpoint, persistent: true }), /Invalid session options/);
  session = await ScrivSession.launch(app, { codexAnalysisFixtureOrigin: fixture.endpoint });
  await fixture.race((async () => {
    const ui = audioLibrarySteps(session);
    const byID = id => node => node.identifier === id;
    const scan = node => node.type === 'UIButton' && node.title === 'Scan again';
    const untargeted = text => nodes => nodes.some(node => node.text?.includes(text));
    async function scanFinished(expected, previous) {
      const terminal = node => node.text?.includes(expected) || (/need retry|Character scan paused\./.test(node.text ?? '')
        && node.text !== previous);
      const result = await session.waitFor(nodes => nodes.some(node => scan(node) && node.enabled) && nodes.some(terminal));
      const status = result.find(terminal).text;
      assert.ok(status.includes(expected), `Unexpected result from the synthetic image scan: ${status}`);
      return status;
    };
    assert.equal((await session.command('capabilities')).cloudIsolation.network, 'disabled');
    await ui.tab('Script');
    await session.command('key', { input: 's', modifiers: ['command'] });
    await waitForSavedProject(session, project => project.title === 'YAM MAN');
    assert.deepEqual(await session.command('import-json', { text: JSON.stringify(input) }), { dispatched: true, projectChanged: true });
    const project = await waitForSavedProject(session, candidate => candidate.title === input.title);
    await ui.tab('Script');
    assert.deepEqual(await session.command('import-local-image', { fixture: 'coral' }, 30_000),
      { dispatched: true, imported: true, cleanupVerified: true });
    const original = await waitForSavedProject(session, candidate => candidate.id === project.id && candidate.images.length === 1);
    const [image] = original.images;
    assert.equal(image.sha256, fixtureImageHash);
    assert.equal(image.characterAnalysis, undefined);
    assert.deepEqual(image.characterIds, []);

    step = 'open Characters and connect through Settings';
    await ui.tab('Characters');
    const switchNode = await ui.reveal(node => node.label === 'Auto-tag new images' && node.type === 'UISwitch');
    await session.command('toggle', { target: switchNode.path, value: false });
    await session.waitFor(nodes => nodes.some(node => scan(node) && node.enabled === false));
    await session.command('key', { input: ',', modifiers: ['command'] });
    const codexSetting = node => node.identifier === 'scriv.settings.codex' && node.hittable;
    const settings = await session.waitFor(nodes => nodes.filter(codexSetting).length === 1);
    await session.command('activate', { target: settings.find(codexSetting).path });
    const field = await ui.reveal(node => node.type === 'UITextField' && node.label === 'Saved loopback server address');
    await session.command('text', { target: field.path, text: fixture.endpoint });
    await session.command('end-editing');
    await ui.activate(byID('codex-connect'));
    await session.waitFor(nodes => nodes.some(node => node.identifier === 'codex-connection-status' && node.text === 'Connected'));

    step = 'scan and save the recognized character and review candidate';
    await ui.tab('Characters');
    await session.waitFor(untargeted('Image analysis ready'));
    fixture.assertNoTurns();
    await ui.activate(scan);
    await scanFinished('1 of 1 images checked');
    const checked = await waitForSavedProject(session, candidate => candidate.id === original.id
      && candidate.images[0]?.characterAnalysis?.providerID === 'codex-app-server');
    await session.waitFor(nodes => nodes.some(node => scan(node) && node.enabled)
      && nodes.some(node => node.title === 'Review 1' && node.enabled));
    const [asset] = checked.images;
    assert.equal(asset.id, image.id);
    assert.equal(asset.sha256, image.sha256);
    assert.equal(asset.version, image.version);
    assert.equal(asset.characterAnalysis.imageSHA256, image.sha256);
    assert.deepEqual(asset.characterIds, ['anna']);
    assert.deepEqual(asset.characterAnalysis.annotations.map(({ decision, characterID }) => [decision, characterID]),
      [['automatic', 'anna'], ['needsReview', undefined]]);
    assert.equal(checked.characters[0].portraitImageId, image.id);
    assert.deepEqual(checked.entries, original.entries);
    assert.deepEqual(checked.cues, original.cues);

    step = 'decline an unconfirmed sandbox before the picture is sent';
    await ui.activate(scan);
    const refusal = await scanFinished('No analysis image was sent; the scan is paused.');
    assert.deepEqual((await session.command('loaded-project')).project, checked);

    step = 'stop unexpected tool activity and preserve the saved scan';
    await ui.activate(scan);
    await scanFinished('Codex attempted commandExecution during character analysis.', refusal);
    assert.deepEqual((await session.command('loaded-project')).project, checked);
    assert.deepEqual((await session.command('persisted-projects')).find(candidate => candidate.id === checked.id), checked);
    assert.deepEqual(await session.command('presented-alerts'), []);
  })());
} catch (error) {
  failed = true;
  throw new Error(`Native character analysis failed during ${step}`, { cause: error });
} finally {
  try { await session?.close(); }
  finally { await fixture.close().catch(error => { if (!failed) throw error; }); }
}
