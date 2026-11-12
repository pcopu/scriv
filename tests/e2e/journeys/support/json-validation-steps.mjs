import assert from 'node:assert/strict';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { observePresentedError } from '../../support/presented-error.mjs';

const sorted = projects => [...projects].sort((left, right) => left.id.localeCompare(right.id));

// One valid counterpart -> one invalid document -> repeated read-only evidence.
// Every invalid document owns a fresh app. There is no supported alert-dismissal
// route, so sharing an alert-bearing session or clearing errors would be false
// coverage. Only public-controller presentation state is observed, NOT pixels,
// accessibility reachability or invocation of the alert's action.
export async function runJSONValidationCase(app, test, roots) {
  const session = await ScrivSession.launch(app);
  try {
    assert.ok(!roots.has(session.root), 'Each rejection has its own isolated app run');
    roots.add(session.root);
    const capabilities = await session.command('capabilities');
    for (const command of ['snapshot', 'key', 'select', 'import-json', 'persisted-projects', 'loaded-project', 'presented-alerts']) {
      assert.ok(capabilities.commands.includes(command), `Matching app supports ${command}`);
    }
    assert.deepEqual(await session.command('presented-alerts'), [], 'Fresh session has no presented error');
    const nodes = await session.waitFor(snapshot => snapshot.some(node => node.identifier === 'workspace-tabs' && node.enabled && node.hittable));
    const tabs = nodes.find(node => node.identifier === 'workspace-tabs');
    const scriptIndex = tabs.segments.indexOf('Script');
    assert.ok(scriptIndex >= 0);
    if (tabs.selected !== scriptIndex) await session.command('select', { target: tabs.path, index: scriptIndex });
    await session.command('key', { input: 's', modifiers: ['command'] });
    const sample = await waitForSavedProject(session, project => project.title === 'YAM MAN'
      && project.entries.length === 18 && project.images.length === 0 && project.cues.every(cue => cue.imageId == null));
    const initial = sorted(await session.command('persisted-projects'));
    assert.equal(initial.length, 1, 'Fresh run contains exactly one saved synthetic startup sample');
    assert.deepEqual(initial[0], sample);

    // makePositive prepares serialized INPUT, never assigns an app model.
    const positive = test.makePositive(sample);
    assert.deepEqual(await session.command('import-json', { text: test.serializePositive(positive) }),
      { dispatched: true, projectChanged: true });
    const accepted = await waitForSavedProject(session, project => project.id !== sample.id);
    assert.notEqual(accepted.id, positive.id, 'Production JSON import resets the source project identity');
    test.verifyPositive(accepted, positive);
    await session.waitFor(snapshot => test.acceptedVisible(snapshot, accepted, positive));
    const before = sorted(await session.command('persisted-projects'));
    assert.equal(before.length, 2, 'One accepted import adds exactly one saved package');
    assert.deepEqual(before.find(project => project.id === sample.id), sample, 'Positive import retains the complete original package');
    assert.deepEqual(before.find(project => project.id === accepted.id), accepted);
    assert.deepEqual(await session.command('presented-alerts'), [], 'Accepted counterpart presents no error');
    const loadedBefore = await session.command('loaded-project');
    assert.deepEqual(loadedBefore.project, accepted,
      'The actual loaded Swift model equals every field in the accepted saved package');
    assert.match(loadedBefore.dateReferenceTimeBits.createdAt, /^\d+$/);
    assert.match(loadedBefore.dateReferenceTimeBits.modifiedAt, /^\d+$/);
    assert.deepEqual(loadedBefore.dateReferenceTimeBits.images.map(image => image.id), accepted.images.map(image => image.id));
    for (const image of loadedBefore.dateReferenceTimeBits.images) assert.match(image.createdAt, /^\d+$/);

    if (test.acceptanceOnly) {
      assert.deepEqual(sorted(await session.command('persisted-projects')), before,
        'Repeated read retains both complete saved packages');
      assert.deepEqual(await session.command('loaded-project'), loadedBefore,
        'Repeated observation retains the complete loaded model and exact Date storage bits');
      console.log(`PASS: IJ-02/json/${test.key}: ${test.id}: ${test.name}; accepted production import and exact loaded/saved payload`);
      return;
    }

    const invalid = structuredClone(positive);
    test.invalidate(invalid);
    test.verifyInvalid(invalid, positive);
    assert.deepEqual(await session.command('import-json', { text: test.serializeInvalid(invalid) }),
      { dispatched: true, projectChanged: false }, 'Production validation rejects installation');
    const observation = await observePresentedError(session, test.error);
    const headers = observation.nodes.filter(node => node.identifier === 'workspace-project');
    assert.equal(headers.length, 1);
    assert.equal(headers[0].title, accepted.title, 'Accepted project remains mounted behind its error alert');
    assert.equal(headers[0].label, accepted.title + ', Projects');
    assert.equal(headers[0].hittable, false);
    assert.deepEqual(sorted(await session.command('persisted-projects')), before,
      'Rejected import neither adds a package nor changes any saved project field');
    assert.deepEqual(await session.command('loaded-project'), loadedBefore,
      'Rejected import preserves the entire loaded model and exact Date storage bits behind the public alert');
    // Only repeat observation, never a mutation, model reset or silent dismissal.
    await observePresentedError(session, test.error);
    assert.deepEqual(sorted(await session.command('persisted-projects')), before);
    assert.deepEqual(await session.command('loaded-project'), loadedBefore,
      'Repeated read-only observations preserve the loaded model and Date storage bits');
    console.log(`PASS: IJ-02/json/${test.key}: ${test.id}: ${test.name}; public-controller presentation state and unchanged loaded/saved projects`);
  } catch (error) {
    throw new Error(`IJ-02/json/${test.key}: ${test.id}: ${test.name} failed`, { cause: error });
  } finally { await session.close(); }
}
