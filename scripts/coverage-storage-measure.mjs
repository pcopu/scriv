/** Read-only storage accounting. File allocation is not exclusive APFS usage. */
import { execFile } from 'node:child_process';
import { constants } from 'node:fs';
import { lstat, open, opendir, realpath, statfs } from 'node:fs/promises';
import { basename, isAbsolute, join, relative } from 'node:path';

const maximumEntries = 1_000_000, maximumDepth = 128, maximumReceiptBytes = 4 * 1024 * 1024;
const categories = ['source', 'design', 'builds', 'profiles', 'indexes', 'datasets', 'reports', 'other'];
const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(value);
const digest = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const natural = value => Number.isSafeInteger(value) && value >= 0;
const bytes = value => {
  if (!['number', 'bigint'].includes(typeof value)) throw new Error('storage-measurement-integer-required');
  const result = Number(value);
  if (!natural(result)) throw new Error('storage-measurement-integer-out-of-range');
  return result;
};
const add = (first, second) => bytes(first + second);
const fileTotals = () => ({ logicalBytes: 0, allocatedFileBytes: 0, uniqueFileCount: 0 });
const limitations = [
  'File allocation counts each regular-file inode once; APFS clones may share extents despite having different inodes.',
  'Container usage includes other directories and volumes, metadata, snapshots and concurrent writes; its delta is not exclusive archive attribution.',
  'Inventory excludes symbolic-link targets and other mounted filesystems. Directory/container metadata is not included in allocatedFileBytes.',
  'Stop archive writers before measuring. This read-only scan is not an atomic filesystem snapshot.',
];

function categoryFor(path) {
  const parts = path.split('/'), name = parts.at(-1);
  if (parts.some(part => part.endsWith('.app')) || parts.includes('builds') || parts.includes('build')) return 'builds';
  if (parts.includes('design')) return 'design';
  if (/\.(?:profraw|profdata|lcov)$/.test(name) || parts.includes('profiles')) return 'profiles';
  if (parts.includes('datasets') || name === 'code-e2e-measurements.json') return 'datasets';
  if (parts.includes('indexes') || /(?:index|manifest|sources)\.json$/.test(name)) return 'indexes';
  if (parts.includes('source') || parts.includes('sources')) return 'source';
  if (parts.includes('reports') || /(?:report|evidence|capture|receipt|session|exports|import|analysis)\.json$/.test(name)
      || path.startsWith('storage/')) return 'reports';
  return 'other';
}

async function readReceipt(path, owner) {
  let handle;
  try {
    const info = await lstat(path);
    if (!info.isFile() || info.uid !== owner || info.size > maximumReceiptBytes || await realpath(path) !== path) return;
    handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    const current = await handle.stat();
    if (current.dev !== info.dev || current.ino !== info.ino || current.size !== info.size) return;
    const buffer = Buffer.alloc(info.size + 1);
    let length = 0;
    while (length < buffer.length) {
      const result = await handle.read(buffer, length, buffer.length - length, length);
      if (result.bytesRead === 0) break;
      length += result.bytesRead;
    }
    if (length !== info.size) return;
    return JSON.parse(buffer.subarray(0, length).toString('utf8'));
  } catch { return; }
  finally { await handle?.close().catch(() => {}); }
}

async function inventoryArchive(archive, rootInfo) {
  const inventory = { ...fileTotals(), byCategory: Object.fromEntries(categories.map(key => [key, fileTotals()])),
    sharedInputBytes: 0, sharedInputLogicalBytes: 0, sharedInputBasis: 'Regular-file inodes reachable under archive/shared/, counted once; allocated bytes are not exclusive extents.',
    runCount: 0, finishedRunCount: 0, completedRunCount: 0, duplicateRunCount: 0, completedRunIDs: [],
    completedRunBasis: 'Receipt-declared imported invocation IDs with finalized passed or failed runner outcomes; cleanup separately verifies the complete evidence.',
    complete: true, scannedEntries: 0, hardlinkAliases: 0, skippedSymlinks: 0, skippedOtherEntries: 0,
    archiveLease: null,
    bounds: { maximumEntries, maximumDepth, maximumReceiptBytes }, issues: [] };
  const inodes = new Map(), completed = new Set();
  function issue(path, reason) {
    inventory.complete = false;
    if (inventory.issues.length < 50) inventory.issues.push({ path: relative(archive, path) || '.', reason });
  }
  async function countRun(directory) {
    inventory.runCount++;
    const evidence = await readReceipt(join(directory, 'evidence.json'), rootInfo.uid);
    if (evidence?.kind !== 'actual-app-cli-scenarios' || !['passed', 'failed'].includes(evidence.status)
        || typeof evidence.endedAt !== 'string' || !Number.isFinite(Date.parse(evidence.endedAt))) return;
    inventory.finishedRunCount++;
    const capture = await readReceipt(join(directory, 'coverage', 'capture.json'), rootInfo.uid);
    if (capture?.status !== 'imported' || !uuid(capture.invocationID) || !Array.isArray(capture.intervals)
        || capture.intervals.length === 0 || !capture.intervals.every(row => uuid(row?.runID)
          && row.status === 'imported' && row.imported === true)) return;
    const id = capture.invocationID.toLowerCase();
    if (completed.has(id)) inventory.duplicateRunCount++;
    else { completed.add(id); inventory.completedRunCount++; }
  }
  async function walk(directory, depth) {
    if (depth > maximumDepth) { issue(directory, 'depth-limit'); return; }
    if (basename(directory).startsWith('scriv-cli-e2e-')) await countRun(directory);
    let stream;
    try {
      if (await realpath(directory) !== directory) { issue(directory, 'directory-changed-or-symlink'); return; }
      stream = await opendir(directory);
      for await (const entry of stream) {
        const path = join(directory, entry.name);
        if (++inventory.scannedEntries > maximumEntries) { issue(directory, 'entry-limit'); return; }
        let info;
        try { info = await lstat(path); }
        catch (error) { issue(path, error.code || 'stat-failed'); continue; }
        if (info.isSymbolicLink()) { inventory.skippedSymlinks++; continue; }
        if (info.uid !== rootInfo.uid) { issue(path, 'unowned-entry'); inventory.skippedOtherEntries++; continue; }
        if (info.dev !== rootInfo.dev) { issue(path, 'different-filesystem'); inventory.skippedOtherEntries++; continue; }
        if (info.isDirectory()) {
          await walk(path, depth + 1);
          if (inventory.scannedEntries > maximumEntries) return;
          continue;
        }
        if (!info.isFile()) { issue(path, 'special-file'); inventory.skippedOtherEntries++; continue; }
        const local = relative(archive, path), shared = local.startsWith('shared/');
        const key = `${info.dev}:${info.ino}`, previous = inodes.get(key);
        const logical = bytes(info.size), allocated = bytes(info.blocks * 512);
        if (local === 'storage/archive.lock') inventory.archiveLease = { logicalBytes: logical, allocatedFileBytes: allocated };
        if (previous) {
          inventory.hardlinkAliases++;
          if (previous.logical !== logical || previous.allocated !== allocated) issue(path, 'file-changed-during-scan');
          if (shared && !previous.shared) {
            inventory.sharedInputBytes = add(inventory.sharedInputBytes, allocated);
            inventory.sharedInputLogicalBytes = add(inventory.sharedInputLogicalBytes, logical);
            previous.shared = true;
          }
          continue;
        }
        inodes.set(key, { logical, allocated, shared });
        for (const total of [inventory, inventory.byCategory[categoryFor(local)]]) {
          total.logicalBytes = add(total.logicalBytes, logical);
          total.allocatedFileBytes = add(total.allocatedFileBytes, allocated);
          total.uniqueFileCount++;
        }
        if (shared) {
          inventory.sharedInputBytes = add(inventory.sharedInputBytes, allocated);
          inventory.sharedInputLogicalBytes = add(inventory.sharedInputLogicalBytes, logical);
        }
      }
    } catch (error) { issue(directory, error.code || error.message || 'scan-failed'); }
  }
  await walk(archive, 0);
  inventory.completedRunIDs = [...completed].sort();
  inventory.incompleteRunCount = inventory.runCount - inventory.completedRunCount - inventory.duplicateRunCount;
  return inventory;
}

function command(executable, args, input) {
  return new Promise(resolve => {
    const child = execFile(executable, args, { encoding: 'utf8', timeout: 15000, maxBuffer: 2 * 1024 * 1024,
      env: { ...process.env, LC_ALL: 'C', LANG: 'C' } }, (error, stdout, stderr) => resolve({ executable, args,
        exitCode: error ? (Number.isInteger(error.code) ? error.code : null) : 0,
        error: error ? (error.killed ? 'timeout-or-output-limit' : String(error.code || 'command-failed')) : null,
        stdout: stdout || '', stderr: stderr || '' }));
    child.stdin?.on('error', () => {});
    child.stdin?.end(input);
  });
}

async function plist(result) {
  if (result.exitCode !== 0) throw new Error('storage-meter-command-failed');
  const converted = await command('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '--', '-'], result.stdout);
  if (converted.exitCode !== 0) throw new Error('storage-meter-plist-unreadable');
  return JSON.parse(converted.stdout);
}

async function physicalStorage(archive, filesystem, meters) {
  const unavailable = reason => ({ status: 'unavailable', reason, containerID: null, volumeID: null,
    capacityBytes: null, usedBytes: null, freeBytes: null });
  if (process.platform !== 'darwin') return unavailable('actual-macos-apfs-host-required');
  const meter = async (executable, args) => {
    const result = await command(executable, args);
    meters.push(result);
    return result;
  };
  try {
    const df = await meter('/bin/df', ['-Pk', archive]);
    const devices = df.stdout.split('\n').map(line => /^(\/dev\/disk\d+(?:s\d+)*)\s/.exec(line)?.[1]).filter(Boolean);
    if (df.exitCode !== 0 || devices.length !== 1) return unavailable('archive-volume-device-unavailable');
    const device = devices[0], volumeID = device.slice('/dev/'.length);
    const info = await plist(await meter('/usr/sbin/diskutil', ['info', '-plist', device]));
    if (info.DeviceIdentifier !== volumeID || String(info.FilesystemType).toLowerCase() !== 'apfs') {
      return unavailable('archive-filesystem-is-not-verified-apfs');
    }
    const containerID = info.APFSContainerReference;
    if (typeof containerID !== 'string' || !/^disk\d+$/.test(containerID)) return unavailable('apfs-container-unavailable');
    const list = await plist(await meter('/usr/sbin/diskutil', ['apfs', 'list', '-plist', containerID]));
    const containers = list.Containers?.filter(row => row.ContainerReference === containerID);
    if (containers?.length !== 1) return unavailable('apfs-container-identity-mismatch');
    const container = containers[0], volumes = container.Volumes?.filter(row => row.DeviceIdentifier === volumeID);
    if (volumes?.length !== 1) return unavailable('apfs-volume-not-in-container');
    const containerUUID = container.APFSContainerUUID, volumeUUID = info.VolumeUUID || volumes[0].APFSVolumeUUID;
    if (!uuid(containerUUID) || !uuid(volumeUUID)) return unavailable('apfs-stable-identities-unavailable');
    const capacityBytes = bytes(container.CapacityCeiling), freeBytes = bytes(container.CapacityFree);
    if (capacityBytes === 0 || freeBytes > capacityBytes) return unavailable('apfs-capacity-invalid');
    const snapshots = await meter('/usr/sbin/diskutil', ['apfs', 'listSnapshots', volumeID, '-plist']);
    Object.assign(filesystem, { format: 'apfs', device, volumeID, volumeUUID,
      mountPoint: info.MountPoint || null, containerID });
    return { status: 'measured-apfs', containerID, containerUUID,
      volumeID, volumeUUID: filesystem.volumeUUID, capacityBytes, usedBytes: capacityBytes - freeBytes, freeBytes,
      measuredAt: new Date().toISOString(), source: 'diskutil apfs list -plist, verified against the archive device from df and diskutil info',
      snapshotListing: snapshots.exitCode === 0 ? 'recorded' : 'unavailable', backgroundNoiseBytes: null,
      attribution: 'Whole APFS container; includes retained snapshots and unrelated activity. No exclusive-extent or purgeable-space claim.' };
  } catch (error) { return unavailable(error.message || 'apfs-meter-unavailable'); }
}

export async function measureArchive(archive) {
  if (typeof archive !== 'string' || !isAbsolute(archive) || archive === '/' || await realpath(archive) !== archive) {
    throw new Error('storage-archive-must-be-canonical-directory');
  }
  const rootInfo = await lstat(archive);
  if (!rootInfo.isDirectory() || rootInfo.uid !== process.getuid?.()) throw new Error('storage-archive-must-be-owned-directory');
  const startedAt = new Date().toISOString(), inventory = await inventoryArchive(archive, rootInfo);
  const currentRoot = await lstat(archive);
  if (currentRoot.dev !== rootInfo.dev || currentRoot.ino !== rootInfo.ino || await realpath(archive) !== archive) {
    throw new Error('storage-archive-changed-during-measurement');
  }
  const filesystem = { status: 'unavailable', deviceNumber: rootInfo.dev, rootInode: rootInfo.ino };
  try {
    const value = await statfs(archive, { bigint: true });
    Object.assign(filesystem, { status: 'measured', statfsType: String(value.type), blockSizeBytes: bytes(value.bsize),
      blocks: bytes(value.blocks), freeBlocks: bytes(value.bfree), availableBlocks: bytes(value.bavail),
      statfsFreeBytes: bytes(value.bfree * value.bsize), statfsAvailableBytes: bytes(value.bavail * value.bsize) });
  } catch (error) { filesystem.reason = error.code || error.message || 'statfs-unavailable'; }
  const meters = [], physical = filesystem.status === 'measured'
    ? await physicalStorage(archive, filesystem, meters)
    : { status: 'unavailable', reason: 'statfs-unavailable', containerID: null, volumeID: null,
      capacityBytes: null, usedBytes: null, freeBytes: null };
  return { version: 1, kind: 'scriv-coverage-storage-measurement', archive, startedAt,
    measuredAt: new Date().toISOString(), platform: process.platform, filesystem, physical, inventory, meters, limitations };
}

/** cleanup is supplied by the caller after verifying retained evidence, never inferred from reduced size. */
export function forecastGrowth({ before, after, runs = 100, newBuilds = 0, buildBytes } = {}) {
  const result = { version: 1, kind: 'scriv-coverage-storage-growth', status: 'unresolved',
    projectedRuns: runs, newBuilds, projectedAdditionalBytes: null,
    inputBasis: 'Supplied measurement records; this command does not perform a live APFS measurement.',
    limitations: ['Projection is conditional on the same scenario mix, retention policy and a quiet APFS container.',
      'Shared-input allocation changes are reported separately and never subtracted from physical container growth.'] };
  const unresolved = reason => ({ ...result, reason });
  if (!Number.isSafeInteger(runs) || runs <= 0 || !natural(newBuilds)
      || buildBytes !== undefined && !natural(buildBytes)) return unresolved('invalid-projection-options');
  if ([before, after].some(row => row?.kind !== 'scriv-coverage-storage-measurement' || row.version !== 1
      || row.platform !== 'darwin' || row.physical?.status !== 'measured-apfs'
      || !uuid(row.physical.containerUUID) || !uuid(row.physical.volumeUUID)
      || !natural(row.physical.usedBytes) || !natural(row.physical.freeBytes) || !natural(row.physical.capacityBytes)
      || row.physical.usedBytes + row.physical.freeBytes !== row.physical.capacityBytes)) return unresolved('actual-apfs-before-and-after-required');
  if (before.archive !== after.archive || !before.physical.containerID
      || before.physical.containerID !== after.physical.containerID
      || before.physical.containerUUID !== after.physical.containerUUID
      || before.physical.volumeUUID !== after.physical.volumeUUID
      || before.physical.capacityBytes !== after.physical.capacityBytes) return unresolved('archive-or-apfs-container-changed');
  if (!(Date.parse(after.measuredAt) > Date.parse(before.measuredAt))) return unresolved('ordered-measurements-required');
  if (!before.inventory?.complete || !after.inventory?.complete) return unresolved('complete-inventories-required');
  if ([before, after].some(row => ['runCount', 'completedRunCount', 'allocatedFileBytes', 'logicalBytes',
    'sharedInputBytes', 'sharedInputLogicalBytes'].some(key => !natural(row.inventory[key])))) {
    return unresolved('valid-inventory-counters-required');
  }
  if (after.cleanup?.status !== 'verified' || !natural(after.cleanup.verifiedRuns)
      || after.cleanup.skippedRuns !== 0 || after.cleanup.verifiedRuns < after.inventory.runCount) {
    return unresolved('verified-cleanup-required');
  }
  // Old cleanup can offset new-run growth even when the net delta is positive.
  // Require a settled baseline, except when there was literally nothing to clean.
  const emptyBaseline = before.inventory.runCount === 0 && before.inventory.completedRunCount === 0
    && before.inventory.uniqueFileCount === 0 && before.inventory.logicalBytes === 0
    && before.inventory.allocatedFileBytes === 0;
  if (!emptyBaseline && (before.cleanup?.status !== 'verified' || before.cleanup.skippedRuns !== 0
      || !natural(before.cleanup.verifiedRuns) || before.cleanup.verifiedRuns < before.inventory.runCount)) {
    return unresolved('verified-baseline-cleanup-required');
  }
  if (!digest(after.cleanup.policySHA256) || !emptyBaseline && !digest(before.cleanup.policySHA256)) {
    return unresolved('cleanup-policy-identity-required');
  }
  if (!emptyBaseline && before.cleanup.policySHA256 !== after.cleanup.policySHA256) return unresolved('cleanup-policy-changed');
  const beforePlan = emptyBaseline ? null : before.cleanup.inputsPlanSHA256, afterPlan = after.cleanup.inputsPlanSHA256;
  if (afterPlan !== null && !digest(afterPlan) || !emptyBaseline && beforePlan !== null && !digest(beforePlan)) {
    return unresolved('cleanup-inputs-plan-identity-required');
  }
  if (!emptyBaseline && beforePlan !== afterPlan) return unresolved('cleanup-inputs-plan-changed');
  const completedRuns = after.inventory.completedRunCount - before.inventory.completedRunCount;
  if (!Number.isSafeInteger(completedRuns) || completedRuns <= 0) return unresolved('new-completed-imported-runs-required');
  if (after.inventory.runCount - before.inventory.runCount !== completedRuns) return unresolved('sample-has-incomplete-duplicate-or-unverified-runs');
  const oldIDs = before.inventory.completedRunIDs, newIDs = after.inventory.completedRunIDs;
  if (!Array.isArray(oldIDs) || !Array.isArray(newIDs) || !oldIDs.every(uuid) || !newIDs.every(uuid)) {
    return unresolved('completed-run-identities-required');
  }
  const retained = new Set(newIDs);
  if (new Set(oldIDs).size !== before.inventory.completedRunCount || retained.size !== after.inventory.completedRunCount
      || oldIDs.some(id => !retained.has(id))) return unresolved('previous-run-identities-not-preserved');
  const containerGrowthBytes = after.physical.usedBytes - before.physical.usedBytes;
  result.sample = { completedRuns, containerGrowthBytes,
    allocatedFileGrowthBytes: after.inventory.allocatedFileBytes - before.inventory.allocatedFileBytes,
    logicalGrowthBytes: after.inventory.logicalBytes - before.inventory.logicalBytes,
    sharedInputAllocatedGrowthBytes: after.inventory.sharedInputBytes - before.inventory.sharedInputBytes,
    sharedInputLogicalGrowthBytes: after.inventory.sharedInputLogicalBytes - before.inventory.sharedInputLogicalBytes };
  if (!Number.isSafeInteger(containerGrowthBytes) || containerGrowthBytes <= 0) return unresolved('positive-physical-growth-not-resolved');
  const noise = [before.physical.backgroundNoiseBytes, after.physical.backgroundNoiseBytes];
  result.sample.backgroundNoiseBoundBytes = noise.every(natural) ? noise[0] + noise[1] : null;
  if (result.sample.backgroundNoiseBoundBytes !== null && !natural(result.sample.backgroundNoiseBoundBytes)) {
    return unresolved('background-noise-bound-out-of-range');
  }
  if (result.sample.backgroundNoiseBoundBytes !== null && containerGrowthBytes <= result.sample.backgroundNoiseBoundBytes) {
    return unresolved('physical-growth-within-background-noise');
  }
  if (newBuilds > 0 && !(buildBytes > 0)) return unresolved('declared-additional-build-size-required');
  if (newBuilds > 0 && (result.sample.sharedInputAllocatedGrowthBytes !== 0 || result.sample.sharedInputLogicalGrowthBytes !== 0)) {
    return unresolved('shared-input-growth-in-sample-cannot-be-charged-again');
  }
  const perRunBytes = containerGrowthBytes / completedRuns;
  const additionalBuildBytes = newBuilds * (buildBytes || 0);
  const projectedAdditionalBytes = Math.ceil(perRunBytes * runs) + additionalBuildBytes;
  if (!natural(projectedAdditionalBytes)) return unresolved('projection-exceeds-safe-integer-range');
  return { ...result, status: 'projected', perRunBytes, additionalBuildBytes, projectedAdditionalBytes,
    buildBytes: buildBytes ?? null, buildSizeBasis: newBuilds ? 'Caller-declared additional physical bytes per new build.' : 'No additional builds in this projection.',
    growthBasis: 'Observed container growth per newly completed imported run after verified cleanup; includes shared-input changes in this batch.',
    backgroundActivity: result.sample.backgroundNoiseBoundBytes === null ? 'unmeasured; projection is conditional' : 'caller-recorded noise bound' };
}

/** An admission check only: this helper never deletes files or claims an exclusive archive extent total. */
export function checkBudget(snapshot, { budgetBytes, runReserveBytes = 256 * 1024 * 1024, minFreeBytes = 512 * 1024 * 1024 } = {}) {
  if (!natural(budgetBytes) || budgetBytes === 0 || !natural(runReserveBytes) || !natural(minFreeBytes)) {
    throw new Error('storage-budget-requires-nonnegative-byte-limits-and-positive-budget');
  }
  const allocatedFileBytes = snapshot?.inventory?.allocatedFileBytes;
  const result = { version: 1, kind: 'scriv-coverage-storage-budget', status: 'unavailable', allowed: false,
    budgetBytes, runReserveBytes, minFreeBytes, allocatedFileBytes: natural(allocatedFileBytes) ? allocatedFileBytes : null,
    projectedAllocatedFileBytes: null, availableBytes: null, containerFreeBytes: null, headroomSource: 'unavailable',
    requiredFreeBytes: add(runReserveBytes, minFreeBytes), reasons: [],
    basis: 'Conservative admission using inode-deduplicated file allocation and measured filesystem availability. APFS shared extents may be counted repeatedly; metadata is excluded. Admission is not APFS benchmark evidence.',
    action: 'No files are deleted by this check.' };
  if (snapshot?.kind !== 'scriv-coverage-storage-measurement' || snapshot.version !== 1
      || !snapshot.inventory?.complete || !natural(allocatedFileBytes)) {
    result.reasons.push('complete-file-inventory-required'); return result;
  }
  result.projectedAllocatedFileBytes = add(allocatedFileBytes, runReserveBytes);
  if (result.projectedAllocatedFileBytes > budgetBytes) result.reasons.push('archive-allocation-budget-exceeded');
  if (snapshot.filesystem?.status !== 'measured' || !natural(snapshot.filesystem.statfsAvailableBytes)) {
    result.reasons.push('measured-filesystem-availability-required');
    if (result.projectedAllocatedFileBytes > budgetBytes) result.status = 'blocked';
    return result;
  }
  result.availableBytes = snapshot.filesystem.statfsAvailableBytes;
  result.headroomSource = 'statfs-available';
  if (snapshot.platform === 'darwin' && snapshot.physical?.status === 'measured-apfs' && natural(snapshot.physical.freeBytes)) {
    result.containerFreeBytes = snapshot.physical.freeBytes;
    result.availableBytes = Math.min(result.availableBytes, result.containerFreeBytes);
    result.headroomSource = 'minimum-of-statfs-available-and-apfs-container-free';
  }
  if (result.availableBytes < result.requiredFreeBytes) result.reasons.push('insufficient-filesystem-free-headroom');
  result.allowed = result.reasons.length === 0;
  result.status = result.allowed ? 'within-budget' : 'blocked';
  return result;
}
