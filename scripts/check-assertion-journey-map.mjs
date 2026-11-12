#!/usr/bin/env node
// Integrity only. This command never grants behavioral coverage or retirement.
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
const read = async name => JSON.parse(await readFile(new URL(`../docs/testing/${name}`, import.meta.url), 'utf8'));
const baseline = await read('cli-migration-inventory.json');
const registry = await read('interaction-journey-registry.json');
const maps = await Promise.all(['native', 'services'].map(kind => read(`assertion-journey-map-${kind}.json`)));
const journeys = new Set(registry.journeys.map(row => row.id));
const scenarioRoot = new URL('../tests/e2e/', import.meta.url);
const directScenarios = (await readdir(scenarioRoot)).filter(name => /^[A-Za-z0-9_-]+\.mjs$/.test(name)).map(name => `tests/e2e/${name}`);
const journeyScenarios = (await readdir(new URL('journeys/', scenarioRoot))).filter(name => /^[A-Za-z0-9_-]+\.mjs$/.test(name)).map(name => `tests/e2e/journeys/${name}`);
const registeredSlices = registry.journeys.flatMap(row => row.current_scenario_slices.map(slice => slice.path));
assert.equal(new Set(registeredSlices).size, registeredSlices.length, 'Each entrypoint needs one primary journey destination');
assert.deepEqual([...registeredSlices].sort(), [...directScenarios, ...journeyScenarios].sort(), 'Registry must match executable slices exactly');
assert.equal(registry.current_scenario_slices, registeredSlices.length);

const expectedTests = new Map(baseline.tests.map(row => [row.id, row]));
const expectedAssertions = new Map(baseline.assertion_sites.map((row, index) => [`${row.source}:${row.line}`, { ...row, index }]));
assert.equal(expectedTests.size, baseline.tests.length, 'Frozen test keys must be unique');
assert.equal(expectedAssertions.size, baseline.assertion_sites.length, 'Frozen assertion keys must be unique');
const seenTests = new Set(), seenAssertions = new Set();
const semanticStatuses = {};
for (const map of maps) {
  assert.equal(map.baseline_commit, baseline.baseline_commit);
  for (const row of [...map.tests, ...map.assertion_sites]) {
    assert.ok(Array.isArray(row.journey_ids) && row.journey_ids.length, 'Every row needs a proposed destination');
    for (const id of row.journey_ids) assert.ok(journeys.has(id), `Unknown journey ${id}`);
    assert.equal(row.retirement_allowed, false, 'Mapping must not grant retirement');
    assert.deepEqual(row.actual_app_evidence, [], 'Mapping is separate from native evidence');
  }
  for (const row of map.tests) {
    const original = expectedTests.get(row.id);
    assert.ok(original, `Unknown test ${row.id}`);
    assert.ok(!seenTests.has(row.id), `Duplicate test ${row.id}`);
    seenTests.add(row.id);
    for (const key of ['source', 'suite', 'line', 'name']) assert.equal(row[key], original[key], `${row.id} ${key}`);
    const status = row.semantic_mapping_status ?? 'not-specified';
    semanticStatuses[status] = (semanticStatuses[status] ?? 0) + 1;
  }
  for (const row of map.assertion_sites) {
    const original = expectedAssertions.get(row.key);
    assert.ok(original, `Unknown assertion ${row.key}`);
    assert.ok(!seenAssertions.has(row.key), `Duplicate assertion ${row.key}`);
    seenAssertions.add(row.key);
    for (const key of ['source', 'line', 'expression']) assert.equal(row[key], original[key], `${row.key} ${key}`);
    assert.equal(row.inventory_assertion_index, original.index);
    if (row.test_id !== null) assert.ok(expectedTests.has(row.test_id), `Unknown owner ${row.test_id}`);
  }
}
assert.equal(seenTests.size, expectedTests.size, 'Every frozen test key must be accounted for');
assert.equal(seenAssertions.size, expectedAssertions.size, 'Every frozen assertion key must be accounted for');
// Acceptance is maintained separately; this only checks its referential integrity.
const acceptance = await read('cli-migration-candidates.json');
const serviceRegistry = await read('service-journey-registry.json');
const servicePaths = serviceRegistry.journeys.map(row => row.path);
assert.equal(new Set(servicePaths).size, servicePaths.length, 'Service paths must be unique');
for (const path of servicePaths) {
  assert.match(path, /^(cloud|updates)\/tests-e2e\/[A-Za-z0-9_-]+\.mjs$/);
  await readFile(new URL(`../${path}`, import.meta.url));
}
const retired = acceptance.candidate_mappings.filter(row => row.retirement_allowed);
assert.equal(retired.length, acceptance.verified_migrated_entries);
const serviceRetired = retired.filter(row => row.acceptance_kind === 'service-process-integration').length;
assert.equal(serviceRetired, acceptance.verified_service_migrated_entries);
assert.equal(retired.length - serviceRetired, acceptance.verified_native_migrated_entries);
assert.equal(new Set(retired.map(row => row.baseline_id)).size, retired.length);
for (const row of retired) {
  assert.ok(expectedTests.has(row.baseline_id), `Unknown retired baseline ${row.baseline_id}`);
  if (row.acceptance_kind === 'service-process-integration') {
    assert.ok(servicePaths.includes(row.candidate_scenario), `Missing service replacement ${row.candidate_scenario}`);
    assert.ok(Array.isArray(row.service_process_evidence) && row.service_process_evidence.length, 'Service retirement requires separately reviewed service evidence');
    assert.deepEqual(row.actual_app_evidence, [], 'Service evidence must not be labeled native app evidence');
  } else {
    assert.ok(row.acceptance_kind === undefined || row.acceptance_kind === 'native-app', 'Unknown acceptance kind');
    assert.ok(registeredSlices.includes(row.candidate_scenario), `Missing replacement ${row.candidate_scenario}`);
    assert.ok(Array.isArray(row.actual_app_evidence) && row.actual_app_evidence.length, 'Retirement must retain its separately reviewed evidence');
  }
}

console.log(`PASS mapping integrity: ${seenTests.size} test keys, ${seenAssertions.size} assertion keys, ${journeys.size} proposed journeys.`);
console.log(JSON.stringify({ semanticStatuses, semanticCompletenessCertified: false, nativeAcceptanceGranted: false, retirementGranted: false }, null, 2));
