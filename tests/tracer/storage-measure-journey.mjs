/** Public CLI storage journeys. Forecast documents are synthetic arithmetic
 * fixtures, never evidence of APFS measurements or native app execution. */
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { link, lstat, mkdir, readFile, readdir, symlink, writeFile } from 'node:fs/promises';
import { hostname } from 'node:os';
import { dirname, join } from 'node:path';

const MiB = 1024 * 1024;
export async function runStorageMeasureJourney({ run, output, journey }) {
  const command = (args, expected = 0) => run(['app', '--', 'test', 'storage', ...args], expected);
  const json = args => JSON.parse(command(args).stdout);
  const archive = join(output, 'storage-measure-fixture');
  await mkdir(archive, { mode: 0o700 });
  let initialized, audited;
  await journey('audit actual storage with inode accounting and explicit physical availability', async () => {
    command(['init', '--archive', archive], 2);
    initialized = json(['init', '--archive', archive, '--budget-bytes', String(64 * MiB),
      '--run-reserve-bytes', '4096', '--min-free-bytes', '0']);
    assert.equal(initialized.policy.kind, 'scriv-coverage-storage-policy');
    assert.equal(initialized.measurement.kind, 'scriv-coverage-storage-measurement');
    assert.equal(initialized.measurement.platform, process.platform);
    const files = new Map([[join(archive, 'scriv-storage-policy.json'), await readFile(join(archive, 'scriv-storage-policy.json'))]]);
    async function put(path, contents) {
      await mkdir(join(path, '..'), { recursive: true, mode: 0o700 });
      const bytes = Buffer.from(contents);
      await writeFile(path, bytes, { flag: 'wx', mode: 0o600 }); files.set(path, bytes);
      return path;
    }
    const source = await put(join(archive, 'shared/sources/fixture/story.swift'), 'Synthetic source fixture\n');
    const build = await put(join(archive, 'shared/builds/fixture/Fixture.app/Contents/MacOS/Fixture'), 'Non-executable storage fixture; no app\n');
    await put(join(archive, 'old/source/design/diagram.svg'), '<svg>synthetic design fixture</svg>');
    const profile = await put(join(archive, 'profiles/fixture.profraw'), 'Not LLVM data; storage inventory fixture only\n');
    await put(join(archive, 'indexes/probe-index.json'), '{"fixture":"synthetic index"}');
    await put(join(archive, 'analysis/source/docs/testing/code-e2e-measurements.json'), '{"fixture":"synthetic dataset"}');
    await put(join(archive, 'reports/fixture-report.json'), '{"fixture":"synthetic report"}');
    await put(join(archive, 'notes.txt'), 'Synthetic ordinary file\n');
    await link(profile, join(archive, 'duplicate.profraw'));
    const outside = join(output, 'storage-measure-outside.txt');
    await writeFile(outside, 'Excluded symbolic-link target\n', { flag: 'wx', mode: 0o600 });
    await symlink(outside, join(archive, 'linked-outside'));
    const passedID = randomUUID(), failedID = randomUUID();
    async function receipt(name, status, invocationID, completed = true) {
      const directory = join(archive, `scriv-cli-e2e-${name}`);
      await put(join(directory, 'evidence.json'), JSON.stringify({ kind: 'actual-app-cli-scenarios', status,
        endedAt: completed ? '2026-11-25T10:00:00.000Z' : null,
        fixture: 'Synthetic receipt for inventory accounting; no native execution.' }));
      if (completed) await put(join(directory, 'coverage/capture.json'), JSON.stringify({ status: 'imported', invocationID,
        intervals: [{ runID: randomUUID(), imported: true, status: 'imported' }],
        fixture: 'Synthetic declaration; no counters were captured or imported.' }));
    }
    await receipt('passed-fixture', 'passed', passedID);
    await receipt('failed-fixture', 'failed', failedID);
    await receipt('duplicate-fixture', 'passed', passedID);
    await receipt('unfinished-fixture', 'not-run', randomUUID(), false);
    const before = await lstat(profile);
    audited = json(['audit', '--archive', archive]);
    assert.equal(audited.kind, 'scriv-coverage-storage-measurement');
    assert.equal(audited.archive, archive);
    assert.equal(audited.inventory.complete, true);
    const lease = audited.inventory.archiveLease;
    assert.ok(Number.isSafeInteger(lease?.logicalBytes) && lease.logicalBytes > 0 && lease.logicalBytes <= 16384);
    assert.ok(Number.isSafeInteger(lease.allocatedFileBytes) && lease.allocatedFileBytes >= 0);
    assert.match(audited.leaseNotice, /temporary archive lease is included in disk accounting/);
    assert.equal(audited.inventory.uniqueFileCount, files.size + 1);
    assert.equal(audited.inventory.logicalBytes, [...files.values()].reduce((sum, bytes) => sum + bytes.length, lease.logicalBytes));
    const allocations = await Promise.all([...files.keys()].map(async path => (await lstat(path)).blocks * 512));
    assert.equal(audited.inventory.allocatedFileBytes, allocations.reduce((sum, bytes) => sum + bytes, lease.allocatedFileBytes));
    await assert.rejects(lstat(join(archive, 'storage/archive.lock')), error => error.code === 'ENOENT');
    assert.equal(audited.inventory.hardlinkAliases, 1);
    assert.equal(audited.inventory.skippedSymlinks, 1);
    assert.equal(audited.inventory.runCount, 4);
    assert.equal(audited.inventory.finishedRunCount, 3);
    assert.equal(audited.inventory.completedRunCount, 2);
    assert.equal(audited.inventory.duplicateRunCount, 1);
    assert.equal(audited.inventory.incompleteRunCount, 1);
    assert.deepEqual(audited.inventory.completedRunIDs, [passedID, failedID].sort());
    for (const category of ['source', 'design', 'builds', 'profiles', 'indexes', 'datasets', 'reports', 'other']) {
      assert.ok(audited.inventory.byCategory[category].uniqueFileCount > 0, category);
    }
    assert.equal(audited.inventory.sharedInputBytes, (await lstat(source)).blocks * 512 + (await lstat(build)).blocks * 512);
    assert.equal(audited.inventory.sharedInputLogicalBytes, files.get(source).length + files.get(build).length);
    assert.equal(audited.filesystem.status, 'measured');
    assert.ok(Number.isSafeInteger(audited.filesystem.statfsAvailableBytes));
    if (process.platform !== 'darwin') {
      assert.equal(audited.physical.status, 'unavailable');
      assert.equal(audited.physical.usedBytes, null);
      assert.deepEqual(audited.meters, []);
      assert.equal(audited.budget.headroomSource, 'statfs-available');
      assert.equal(audited.budget.containerFreeBytes, null);
    } else if (audited.physical.status === 'measured-apfs') {
      assert.equal(audited.filesystem.format, 'apfs');
      assert.equal(audited.physical.usedBytes + audited.physical.freeBytes, audited.physical.capacityBytes);
      assert.ok(audited.meters.some(row => row.args.includes('list')));
    } else assert.equal(audited.physical.status, 'unavailable');
    assert.equal(audited.budget.projectedAllocatedFileBytes, audited.inventory.allocatedFileBytes + 4096);
    assert.equal(audited.budget.availableBytes, Math.min(audited.filesystem.statfsAvailableBytes,
      audited.physical.status === 'measured-apfs' ? audited.physical.freeBytes : Infinity));
    assert.match(audited.budget.basis, /Admission is not APFS benchmark evidence/);
    assert.equal((await lstat(profile)).ino, before.ino);
    for (const [path, bytes] of files) assert.deepEqual(await readFile(path), bytes);
  });

  await journey('enforce allocation budget and real filesystem headroom without deleting evidence', async () => {
    const limited = join(output, 'storage-budget-fixture'); await mkdir(limited, { mode: 0o700 });
    json(['init', '--archive', limited, '--budget-bytes', '1', '--run-reserve-bytes', '1', '--min-free-bytes', '0']);
    const retained = join(limited, 'retained-evidence.txt');
    await writeFile(retained, 'Retained evidence fixture\n'.repeat(4096), { flag: 'wx', mode: 0o600 });
    const original = await readFile(retained), limitedAudit = json(['audit', '--archive', limited]);
    assert.equal(limitedAudit.budget.allowed, false);
    assert.equal(limitedAudit.budget.status, 'blocked');
    assert.ok(limitedAudit.budget.reasons.includes('archive-allocation-budget-exceeded'));
    assert.deepEqual(await readFile(retained), original);
    const refused = run(['app', '--', 'test', '--scenario', 'workspace', '--output-dir', limited], 2);
    assert.equal(refused.stdout, '');
    assert.match(refused.stderr, /storage-budget-exhausted/);
    assert.equal((await readdir(limited)).some(name => name.startsWith('scriv-cli-e2e-')), false);
    await assert.rejects(lstat(join(limited, 'storage/archive.lock')), error => error.code === 'ENOENT');
    assert.deepEqual(await readFile(retained), original);
    const reserved = join(output, 'storage-headroom-fixture'); await mkdir(reserved, { mode: 0o700 });
    json(['init', '--archive', reserved, '--budget-bytes', String(64 * MiB), '--run-reserve-bytes', '4096',
      '--min-free-bytes', String(Number.MAX_SAFE_INTEGER - 4096)]);
    const headroom = json(['audit', '--archive', reserved]).budget;
    assert.equal(headroom.allowed, false); assert.equal(headroom.status, 'blocked');
    assert.ok(headroom.reasons.includes('insufficient-filesystem-free-headroom'));
  });

  await journey('finalize managed storage separately from an honestly blocked native outcome', async () => {
    const managed = join(output, 'storage-runner-fixture'); await mkdir(managed, { mode: 0o700 });
    json(['init', '--archive', managed, '--budget-bytes', String(64 * MiB),
      '--run-reserve-bytes', String(MiB), '--min-free-bytes', '0']);
    // A catalog restriction rejects this case before any app launch on every OS.
    const result = run(['app', '--', 'test', '--scenario', 'character-aliases', '--output-dir', managed], 2);
    const evidencePath = result.stdout.match(/evidence: (.+)\n?$/)?.[1]?.trim();
    assert.ok(evidencePath);
    const evidence = JSON.parse(await readFile(evidencePath));
    assert.equal(evidence.status, 'not-run');
    assert.equal(evidence.blocker, 'selected-scenarios-blocked');
    assert.equal(evidence.fullSuitePassed, false);
    assert.equal(evidence.app, null);
    const storage = JSON.parse(await readFile(join(dirname(evidencePath), 'storage.json')));
    assert.equal(storage.cleanup.status, 'partial');
    assert.equal(storage.runs[0].status, 'retained-unverified');
    assert.match(result.stderr, /Coverage storage partial/);
    await assert.rejects(lstat(join(managed, 'storage/archive.lock')), error => error.code === 'ENOENT');
  });

  await journey('refuse active or foreign leases and explicitly recover only a dead local lease', async () => {
    const lockPath = join(archive, 'storage/archive.lock');
    const lock = { version: 1, id: randomUUID(), pid: process.pid, host: hostname(), startedAt: new Date().toISOString() };
    const initial = JSON.stringify(lock) + '\n';
    await writeFile(lockPath, initial, { flag: 'wx', mode: 0o600 });
    assert.match(command(['clean', '--archive', archive], 2).stderr, /storage-archive-busy/);
    assert.equal(await readFile(lockPath, 'utf8'), initial);
    assert.match(command(['audit', '--archive', archive], 2).stderr, /storage-archive-busy/);
    assert.equal(await readFile(lockPath, 'utf8'), initial);
    assert.match(command(['unlock', '--archive', archive], 2).stderr, /storage-lease-still-active/);
    assert.equal(await readFile(lockPath, 'utf8'), initial);
    const deadPID = 2147483647;
    assert.throws(() => process.kill(deadPID, 0), error => error.code === 'ESRCH', 'The recovery fixture PID must actually be absent.');
    const foreign = JSON.stringify({ ...lock, pid: deadPID, host: 'foreign-storage-fixture-' + hostname() }) + '\n';
    await writeFile(lockPath, foreign, { mode: 0o600 });
    assert.match(command(['unlock', '--archive', archive], 2).stderr, /storage-lease-host-mismatch/);
    assert.equal(await readFile(lockPath, 'utf8'), foreign);
    await writeFile(lockPath, JSON.stringify({ ...lock, pid: deadPID }) + '\n', { mode: 0o600 });
    const recovered = json(['unlock', '--archive', archive]);
    assert.equal(recovered.recovered, true);
    await assert.rejects(lstat(lockPath), error => error.code === 'ENOENT');
  });

  await journey('forecast synthetic saved APFS records without claiming a live measurement', async () => {
    const ids = [randomUUID(), randomUUID(), randomUUID()], containerUUID = randomUUID(), volumeUUID = randomUUID();
    const fixture = 'Synthetic CLI arithmetic fixture; not an actual APFS measurement or native run.';
    const before = { version: 1, kind: 'scriv-coverage-storage-measurement', archive, platform: 'darwin', fixture,
      measuredAt: '2026-11-25T10:00:00.000Z', physical: { status: 'measured-apfs', containerID: 'disk9',
        containerUUID, volumeID: 'disk9s1', volumeUUID, capacityBytes: 1024 * MiB, usedBytes: 2 * MiB,
        freeBytes: 1022 * MiB, backgroundNoiseBytes: 0 },
      inventory: { complete: true, runCount: 1, completedRunCount: 1, completedRunIDs: [ids[0]],
        uniqueFileCount: 4, allocatedFileBytes: 4 * 4096, logicalBytes: 10000, sharedInputBytes: 4096, sharedInputLogicalBytes: 1024 },
      cleanup: { status: 'verified', verifiedRuns: 1, skippedRuns: 0, policySHA256: 'a'.repeat(64), inputsPlanSHA256: null } };
    const after = structuredClone(before);
    after.measuredAt = '2026-11-25T10:01:00.000Z';
    after.physical.usedBytes += 2 * 8192; after.physical.freeBytes -= 2 * 8192;
    Object.assign(after.inventory, { runCount: 3, completedRunCount: 3, completedRunIDs: ids,
      allocatedFileBytes: 8 * 4096, logicalBytes: 20000 });
    after.cleanup = { ...before.cleanup, verifiedRuns: 3 };
    const beforePath = join(output, 'synthetic-apfs-before.json'), afterPath = join(output, 'synthetic-apfs-after.json');
    const save = async (first, second, wrapped = false) => {
      await writeFile(beforePath, JSON.stringify(first), { mode: 0o600 });
      await writeFile(afterPath, JSON.stringify(wrapped ? { kind: 'scriv-coverage-storage-cleanup', after: second, fixture } : second), { mode: 0o600 });
    };
    const forecast = extra => json(['forecast', '--before', beforePath, '--after', afterPath, '--runs', '100', ...(extra || [])]);
    await save(before, after, true);
    const projected = forecast();
    assert.equal(projected.status, 'projected'); assert.equal(projected.sample.completedRuns, 2);
    assert.equal(projected.sample.containerGrowthBytes, 2 * 8192);
    assert.equal(projected.perRunBytes, 8192); assert.equal(projected.projectedAdditionalBytes, 100 * 8192);
    assert.match(projected.inputBasis, /does not perform a live APFS measurement/);
    const builds = forecast(['--new-builds', '2', '--build-bytes', '65536']);
    assert.equal(builds.projectedAdditionalBytes, 100 * 8192 + 2 * 65536);
    assert.equal(forecast(['--new-builds', '1']).reason, 'declared-additional-build-size-required');
    const shared = structuredClone(after); shared.inventory.sharedInputBytes += 4096;
    shared.inventory.sharedInputLogicalBytes += 2048; await save(before, shared);
    const sharedGrowth = forecast();
    assert.equal(sharedGrowth.sample.sharedInputAllocatedGrowthBytes, 4096);
    assert.equal(sharedGrowth.projectedAdditionalBytes, 100 * 8192);
    assert.equal(forecast(['--new-builds', '1', '--build-bytes', '65536']).reason, 'shared-input-growth-in-sample-cannot-be-charged-again');
    const cases = [
      ['verified-cleanup-required', row => { delete row.cleanup; }],
      ['verified-cleanup-required', row => { row.cleanup.skippedRuns = 1; }],
      ['verified-cleanup-required', row => { row.cleanup.verifiedRuns = 2; }],
      ['cleanup-policy-identity-required', row => { delete row.cleanup.policySHA256; }],
      ['cleanup-policy-changed', row => { row.cleanup.policySHA256 = 'b'.repeat(64); }],
      ['cleanup-inputs-plan-identity-required', row => { delete row.cleanup.inputsPlanSHA256; }],
      ['cleanup-inputs-plan-changed', row => { row.cleanup.inputsPlanSHA256 = 'c'.repeat(64); }],
      ['positive-physical-growth-not-resolved', row => { row.physical.usedBytes = before.physical.usedBytes; row.physical.freeBytes = before.physical.freeBytes; }],
      ['physical-growth-within-background-noise', row => { row.physical.backgroundNoiseBytes = 2 * 8192; }],
      ['sample-has-incomplete-duplicate-or-unverified-runs', row => { row.inventory.runCount++; row.cleanup.verifiedRuns++; }],
      ['previous-run-identities-not-preserved', row => { row.inventory.completedRunIDs[0] = randomUUID(); }],
      ['archive-or-apfs-container-changed', row => { row.physical.containerUUID = randomUUID(); }],
      ['complete-inventories-required', row => { row.inventory.complete = false; }],
    ];
    for (const [reason, change] of cases) {
      const altered = structuredClone(after); change(altered); await save(before, altered);
      const unresolved = forecast();
      assert.equal(unresolved.status, 'unresolved', reason); assert.equal(unresolved.reason, reason);
      assert.equal(unresolved.projectedAdditionalBytes, null);
    }
    for (const change of [row => { delete row.cleanup; }, row => { row.cleanup.skippedRuns = 1; },
      row => { row.cleanup.verifiedRuns = 0; }, row => { row.inventory.runCount = 2; }]) {
      const altered = structuredClone(before); change(altered); await save(altered, after);
      const unresolved = forecast();
      assert.equal(unresolved.status, 'unresolved');
      assert.equal(unresolved.reason, 'verified-baseline-cleanup-required');
      assert.equal(unresolved.projectedAdditionalBytes, null);
    }
    const empty = structuredClone(before);
    delete empty.cleanup;
    Object.assign(empty.inventory, { runCount: 0, completedRunCount: 0, completedRunIDs: [], uniqueFileCount: 0,
      logicalBytes: 0, allocatedFileBytes: 0, sharedInputBytes: 0, sharedInputLogicalBytes: 0 });
    await save(empty, after);
    assert.equal(forecast().status, 'projected', 'A literally empty baseline has no old retention work to offset growth.');
    empty.inventory.uniqueFileCount = 1; empty.inventory.logicalBytes = 100; empty.inventory.allocatedFileBytes = 4096;
    await save(empty, after);
    assert.equal(forecast().reason, 'verified-baseline-cleanup-required', 'Zero native runs does not prove that old reports were already cleaned.');
    const plannedBefore = structuredClone(before), plannedAfter = structuredClone(after);
    plannedBefore.cleanup.inputsPlanSHA256 = 'c'.repeat(64); plannedAfter.cleanup.inputsPlanSHA256 = 'c'.repeat(64);
    await save(plannedBefore, plannedAfter);
    assert.equal(forecast().status, 'projected', 'The same explicit input plan can qualify both settled samples.');
    await save(initialized.measurement, audited);
    if (process.platform !== 'darwin') assert.equal(forecast().reason, 'actual-apfs-before-and-after-required');
  });
}
