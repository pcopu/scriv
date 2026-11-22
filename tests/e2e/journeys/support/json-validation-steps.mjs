import assert from 'node:assert/strict';
import { ScrivSession } from '../../../../cli/scriv.mjs';
import { waitForSavedProject } from '../../support/saved-projects.mjs';
import { observePresentedError } from '../../support/presented-error.mjs';

const sorted = projects => [...projects].sort((left, right) => left.id.localeCompare(right.id));
const acknowledge = 'acknowledge-json-import-error';
const acknowledgementUnavailable = /No owned JSON import error can be acknowledged/;

export async function runJSONValidationCases(app, tests, { fresh }) {
  const roots = new Set();
  let next = 0;
  while (next < tests.length) {
    const session = await ScrivSession.launch(app);
    try {
      assert.ok(!roots.has(session.root), 'Each app process owns a unique isolated workspace');
      roots.add(session.root);
      const capabilities = await session.command('capabilities');
      for (const command of ['snapshot', 'key', 'select', 'import-json', 'persisted-projects', 'loaded-project', 'presented-alerts']) {
        assert.ok(capabilities.commands.includes(command), `Matching app supports ${command}`);
      }
      assert.equal(capabilities.cloudIsolation.network, 'disabled');
      assert.deepEqual(await session.command('presented-alerts'), [], 'Fresh session has no presented error');
      const nodes = await session.waitFor(snapshot => snapshot.some(node => node.identifier === 'workspace-tabs' && node.enabled && node.hittable));
      const tabs = nodes.find(node => node.identifier === 'workspace-tabs');
      const scriptIndex = tabs.segments.indexOf('Script');
      assert.ok(scriptIndex >= 0);
      if (tabs.selected !== scriptIndex) await session.command('select', { target: tabs.path, index: scriptIndex });
      await session.command('key', { input: 's', modifiers: ['command'] });
      const sample = await waitForSavedProject(session, project => project.title === 'YAM MAN'
        && project.entries.length === 18 && project.images.length === 0 && project.cues.every(cue => cue.imageId == null));
      assert.deepEqual(await session.command('persisted-projects'), [sample], 'Fresh run contains exactly the saved synthetic startup sample');

      const reuse = !fresh && capabilities.commands.includes(acknowledge);
      if (reuse) await assert.rejects(session.command(acknowledge), acknowledgementUnavailable);
      const end = reuse ? tests.length : next + 1;
      let saved = [sample];
      for (; next < end; next++) saved = await runJSONValidationCase(session, tests[next], sample, saved, reuse);
    } finally { await session.close(); }
  }
  return roots.size;
}

// Each valid counterpart gets its own imported package. Rejections and their
// acknowledgements must preserve all packages accumulated in this session.
async function runJSONValidationCase(session, test, sample, initial, reuse) {
  try {
    assert.deepEqual(sorted(await session.command('persisted-projects')), initial);
    assert.deepEqual(await session.command('presented-alerts'), []);
    const known = new Set(initial.map(project => project.id));
    // The fixture prepares serialized input. The production importer owns the model.
    const positive = test.makePositive(sample);
    assert.deepEqual(await session.command('import-json', { text: test.serializePositive(positive) }),
      { dispatched: true, projectChanged: true });
    const accepted = await waitForSavedProject(session, project => !known.has(project.id));
    assert.notEqual(accepted.id, positive.id, 'Production JSON import resets the source project identity');
    test.verifyPositive(accepted, positive);
    await session.waitFor(snapshot => test.acceptedVisible(snapshot, accepted, positive));
    const before = sorted(await session.command('persisted-projects'));
    assert.deepEqual(before, sorted([...initial, accepted]), 'Exactly one new package, with every prior package unchanged');
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
        'Repeated read retains every complete saved package');
      assert.deepEqual(await session.command('loaded-project'), loadedBefore,
        'Repeated observation retains the complete loaded model and exact Date storage bits');
      console.log(`PASS: IJ-02/json/${test.key}: ${test.id}: ${test.name}; accepted production import and exact loaded/saved payload`);
      return before;
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
    await observePresentedError(session, test.error);
    assert.deepEqual(sorted(await session.command('persisted-projects')), before);
    assert.deepEqual(await session.command('loaded-project'), loadedBefore,
      'Repeated read-only observations preserve the loaded model and Date storage bits');
    if (reuse) {
      await assert.rejects(session.command(acknowledge, { target: 'unrelated' }), acknowledgementUnavailable);
      await observePresentedError(session, test.error);
      assert.deepEqual(await session.command(acknowledge), { dispatched: true });
      await session.waitFor(nodes => nodes.some(node => node.identifier === 'workspace-tabs' && node.enabled && node.hittable));
      assert.deepEqual(await session.command('presented-alerts'), []);
      await assert.rejects(session.command(acknowledge), acknowledgementUnavailable);
      assert.deepEqual(sorted(await session.command('persisted-projects')), before);
      assert.deepEqual(await session.command('loaded-project'), loadedBefore,
        'Closing the exact rejection leaves the same loaded model and date bits');
    }
    console.log(`PASS: IJ-02/json/${test.key}: ${test.id}: ${test.name}; public-controller presentation state and unchanged loaded/saved projects`);
    return before;
  } catch (error) {
    throw new Error(`IJ-02/json/${test.key}: ${test.id}: ${test.name} failed`, { cause: error });
  }
}
