import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const storePath = '../apps/mac/Sources/ScrivApp/Services/WorkspaceStore.swift';
const source = await readFile(new URL(storePath, import.meta.url), 'utf8');

// This is an explicitly portable ordering model driven by the two production
// guard expressions. It is not Swift execution, a network stub or UIKit QA.
// Whitelist the source's equality terms rather than eval/guessing Swift syntax.
const operands = {
  request: state => state.captured.request,
  'self.sharedJobRefreshGeneration': state => state.current.request,
  navigation: state => state.captured.navigation,
  'self.navigationGeneration': state => state.current.navigation,
  server: state => state.captured.server,
  'self.cloud.baseURL': state => state.current.server,
  user: state => state.captured.user,
  'self.account?.id': state => state.current.user,
};
function predicate(expression) {
  assert.ok(expression, 'Missing production refresh condition');
  const comparisons = expression.split(',').map(term => {
    const match = term.trim().match(/^(\S+) == (\S+)$/);
    assert.ok(match && operands[match[1]] && operands[match[2]], `Unsupported condition: ${term}`);
    return state => operands[match[1]](state) === operands[match[2]](state);
  });
  return state => comparisons.every(compare => compare(state));
}
function policy(text) {
  const section = text.split('private func refreshSharedGenerationJobs() {')[1]?.split('func downloadImage(')[0];
  assert.ok(section, 'Missing shared-job refresh function');
  const success = section.match(/guard (request == [^\n]+) else \{ return \}/)?.[1];
  const failure = section.match(/catch \{ if ([^\n]+?) \{ self\.codex\.sharedJobsError = error\.localizedDescription \} \}/)?.[1];
  assert.match(section, /catch is CancellationError \{ \}/);
  return { section, success, failure, acceptsSuccess: predicate(success), acceptsFailure: predicate(failure) };
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
class Cancelled extends Error {}
function harness(conditions) {
  const current = { request: 0, navigation: 1, server: 'synthetic-server', user: 'synthetic-user' };
  const display = { jobs: ['retained-job'], error: null };
  return {
    current, display,
    refresh(result) {
      current.request += 1;
      const captured = { ...current };
      return (async () => {
        try {
          const jobs = await result.promise;
          if (conditions.acceptsSuccess({ captured, current })) { display.jobs = jobs; display.error = null; }
        } catch (error) {
          if (!(error instanceof Cancelled) && conditions.acceptsFailure({ captured, current })) display.error = error.message;
        }
      })();
    },
  };
}

test('shared-job success and failure use the same request and scope fences', async () => {
  const conditions = policy(source);
  assert.equal(conditions.failure, conditions.success);
  assert.match(conditions.failure, /^request == self\.sharedJobRefreshGeneration, /);
  assert.match(conditions.section, /sharedJobRefreshGeneration \+= 1; let request = sharedJobRefreshGeneration/);
  assert.match(conditions.section, /self\.codex\.sharedJobs = jobs; self\.codex\.sharedJobsError = nil/);
  const jobs = await readFile(new URL('../apps/catalyst/ScrivUIKit/Account/ScrivGenerationJobsController.swift', import.meta.url), 'utf8');
  assert.match(jobs, /button\("Refresh shared jobs", symbol: "arrow.clockwise"\) \{ \[weak self\] in self\?\.store\.codex\.onRefreshSharedJobs\?\(\) \}/);
});

test('source-derived ordering model rejects an old failure after latest success, and reproduces the unfenced defect', async () => {
  async function latestSuccessThenOldFailure(conditions) {
    const state = harness(conditions), old = deferred(), latest = deferred();
    const oldTask = state.refresh(old), latestTask = state.refresh(latest);
    latest.resolve(['newest-job']); await latestTask;
    old.reject(new Error('obsolete failure')); await oldTask;
    return state.display;
  }
  assert.deepEqual(await latestSuccessThenOldFailure(policy(source)), { jobs: ['newest-job'], error: null });
  const unfenced = source.replace('catch { if request == self.sharedJobRefreshGeneration, navigation == self.navigationGeneration', 'catch { if navigation == self.navigationGeneration');
  assert.notEqual(unfenced, source);
  assert.deepEqual(await latestSuccessThenOldFailure(policy(unfenced)), { jobs: ['newest-job'], error: 'obsolete failure' });
});

test('source-derived ordering model keeps the latest failure and ignores older success or failure', async () => {
  for (const oldOutcome of ['success', 'failure']) {
    const state = harness(policy(source)), old = deferred(), latest = deferred();
    const oldTask = state.refresh(old), latestTask = state.refresh(latest);
    latest.reject(new Error('latest failure')); await latestTask;
    if (oldOutcome === 'success') old.resolve(['obsolete-job']); else old.reject(new Error('obsolete failure'));
    await oldTask;
    assert.deepEqual(state.display, { jobs: ['retained-job'], error: 'latest failure' });
    const retry = deferred(), retryTask = state.refresh(retry);
    retry.resolve(['retry-job']); await retryTask;
    assert.deepEqual(state.display, { jobs: ['retry-job'], error: null });
  }
  const state = harness(policy(source)), old = deferred(), latest = deferred();
  const oldTask = state.refresh(old), latestTask = state.refresh(latest);
  old.reject(new Error('obsolete failure')); await oldTask;
  assert.equal(state.display.error, null, 'Older failure must not flash an error while a newer refresh is pending');
  latest.resolve(['latest-job']); await latestTask;
  assert.deepEqual(state.display, { jobs: ['latest-job'], error: null });
});

test('source-derived ordering model preserves navigation, server, account and cancellation fences', async () => {
  for (const [field, changed] of [['navigation', 2], ['server', 'different-synthetic-server'], ['user', 'different-synthetic-user'], ['user', null]]) {
    for (const outcome of ['success', 'failure']) {
      const state = harness(policy(source)), pending = deferred(), task = state.refresh(pending);
      state.current[field] = changed;
      if (outcome === 'success') pending.resolve(['wrong-scope-job']); else pending.reject(new Error('wrong-scope failure'));
      await task;
      assert.deepEqual(state.display, { jobs: ['retained-job'], error: null }, `${field} / ${outcome}`);
    }
  }
  const state = harness(policy(source)), pending = deferred(), task = state.refresh(pending);
  pending.reject(new Cancelled('cancelled')); await task;
  assert.deepEqual(state.display, { jobs: ['retained-job'], error: null });
});
