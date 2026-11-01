import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');
const storePath = 'apps/mac/Sources/ScrivApp/Services/WorkspaceStore.swift';
const section = (text, begin, end) => {
  const a = text.indexOf(begin), b = text.indexOf(end, a + begin.length);
  assert.ok(a >= 0 && b > a, `${begin} / ${end}`);
  return text.slice(a, b);
};

test('presentation getters and source preview do not transitively read the journal or filesystem', async () => {
  const store = await source(storePath);
  const getters = section(store, '    var generationPrompt: String {', '    private func invalidatePromptPresentationContextIfNeeded');
  const helpers = section(store, '    private func promptPresentationInput(', '    var generationPrompt: String {');
  const preview = section(store, '    var selectedImageGenerationContext:', '    func generateImage(');
  const status = section(store, '    private var localStorageIssueMessage:', '    @Published var errorMessage:');
  for (const value of [getters, helpers, preview, status]) {
    assert.doesNotMatch(value, /promptDraft\(|promptScope\(|promptJournal\(|\.load\(|resolvingSymlinksInPath|standardizedFileURL|CuePromptDraftScope\(|resourceValues|Data\(contentsOf|assetURL\(/);
  }
  const lexical = section(store, '    private struct PromptPresentationScope:', '    private struct PromptPresentationInput:');
  assert.doesNotMatch(lexical, /URL\(|standardized|resolvingSymlinks/);
  assert.match(helpers, /let scope = PromptPresentationScope\(/);
  assert.match(preview, /cachedPromptDraft\(for:cue\)/);
  assert.match(preview, /promptAvailableAssets\[generationPromptScopeKey\]/);
});

test('background recovery distinguishes busy from absent and retries with cancellation', async () => {
  const store = await source(storePath);
  const journal = await source('apps/mac/Sources/ScrivCore/CuePromptDraftJournal.swift');
  const read = section(store, '    private nonisolated static func readPromptPresentation(', '    private nonisolated static func availablePromptAssets(');
  assert.match(read, /journal\.loadIfAvailable\(scope\)/);
  assert.match(read, /case \.busy: try await Task\.sleep\(for:\.milliseconds\(50\)\)/);
  assert.ok((read.match(/Task\.checkCancellation\(\)/g) ?? []).length >= 2);
  assert.match(journal, /case ready\(LocalCuePromptDraft\?\)/);
  assert.match(journal, /LOCK_EX \| \(nonBlocking \? LOCK_NB : 0\)/);
  assert.match(journal, /nonBlocking: Bool = false/);
  assert.match(journal, /O_RDWR \| O_CREAT \| O_NOFOLLOW/);
  assert.match(journal, /current\.revisionID == draft\.revisionID/);
  assert.match(journal, /current\?\.revisionID == revisionID/);
});

test('native edit uses observed revision including known absence before durable acceptance', async () => {
  const store = await source(storePath);
  const edit = section(store, '    private func persistGenerationPrompt(', '    func retryGenerationPrompt(');
  const observed = section(edit, '            if generationPromptRecoveryIsReady {', '            } else { existing = try promptDraft(for:cue) }');
  assert.match(observed, /existing = generationPromptDrafts\[scope\.key\]/);
  assert.match(observed, /promptResolvedScopes\[generationPromptScopeKey\] == scope/);
  assert.doesNotMatch(observed, /promptDraft\(|\.load\(/);
  assert.ok(edit.indexOf('try promptJournal().save(draft,replacing:existing?.revisionID)') < edit.indexOf('generationPromptDrafts[scope.key] = draft'));
});

test('stable retained-text identity is separate from request fences and completed asset state', async () => {
  const store = await source(storePath);
  const legacy = await source('apps/mac/Sources/ScrivApp/Views/PreviewPane.swift');
  assert.match(store, /var key: String \{ scope\.key \}/);
  assert.match(store, /scope == other\.scope && navigation == other\.navigation && lifecycle == other\.lifecycle/);
  assert.match(store, /promptAvailableAssetInputs\[input\.key\] != input/);
  assert.match(store, /if assetsOnly \{ return \}/);
  assert.match(store, /promptAvailableAssetInputs\[key\] = input/);
  assert.match(legacy, /\.task\(id: store\.generationPromptPreparationID\)/);
  assert.match(legacy, /let force = preparedPromptScope != scope/);
  assert.doesNotMatch(legacy, /\.task\(id: store\.generationPromptScopeKey\)/);
});

test('clear and cache publication stay serialized and a flush drains replacement work', async () => {
  const store = await source(storePath);
  const clear = section(store, '    private func tryClearSavedPromptDraft(', '    @Published var projectURL:');
  assert.doesNotMatch(clear, /await/);
  assert.match(clear, /journal\.clearIfAvailable\(draft\)/);
  assert.match(clear, /cancelPromptPresentationReads\(for:draft\.scope\)/);
  assert.match(clear, /promptPresentationReady\.insert\(input\.key\)/);
  assert.match(clear, /prepareGenerationPromptForPresentation\(\)/);
  assert.match(store, /promptClearGenerations\[result\.scope\.key\] \?\? 0\) > readGeneration/);
  assert.match(store, /promptPresentationReady\.contains\(key\) && promptAvailableAssetInputs\[key\] == input/);
  assert.ok(clear.indexOf('journal.clearIfAvailable') < clear.indexOf('generationPromptDrafts.removeValue'));
  const flush = section(store, '    func flushPendingSaves() async {', '    func importScript()');
  assert.match(flush, /while true/);
  assert.match(flush, /generation == promptWorkGeneration && promptReadTasks\.isEmpty/);
  assert.match(flush, /for task in pendingReads \{ await task\.value \}/);
  assert.match(flush, /for task in pendingClears \{ await task\.value \}/);
});

test('pending reads cancel independently of rendering and busy workers do not retain their owner', async () => {
  const store = await source(storePath);
  for (const field of ['project: ScrivProject', 'selectedSceneID: String', 'selectedCueID: String?', 'playheadMs: Double = 0', 'projectURL: URL?']) {
    const line = store.split('\n').find(value => value.includes(`@Published var ${field}`));
    assert.ok(line?.includes('invalidatePromptPresentationContextIfNeeded()'), field);
  }
  const schedule = section(store, '    private func schedulePromptSave(', '    private func preparePromptApplication(');
  assert.match(schedule, /\[weak self\]/);
  assert.match(schedule, /await self\?\.preparePromptApplication/);
  assert.match(schedule, /onCancel: \{ worker\.cancel\(\) \}/);
  assert.match(store, /deinit \{\s*for worker in promptReadWorkers\.values \{ worker\.cancel\(\) \}/);
});

test('native diagnostics cover contention, newer edits, negative cache, cancellation and replacement flush', async () => {
  const native = await source('apps/catalyst/Tests/ScrivUIKitTests/PromptRecoveryPresentationTests.swift');
  const core = await source('apps/mac/Tests/ScrivCoreTests/CuePromptDraftNonblockingTests.swift');
  for (const name of [
    'testBusyRecoveryKeepsRenderResponsiveAndEditingClosedUntilExactDraftLoads',
    'testCueSwitchCancelsBusyReadAndOldResultCannotRetargetTheNewCue',
    'testAcceptedEditInvalidatesInFlightReadAndRetainsExactNewerBytes',
    'testForeignNewerDraftStillRejectsStaleEditWithoutOverwritingEitherText',
    'testKnownAbsentRecoveryDoesNotAdoptAndOverwriteAnUnseenForeignDraft',
    'testNoCueTransitionCancelsBusyReadWithoutNeedingAVisibleRenderer',
    'testFlushDrainsReplacementReadRatherThanReportingCancelledSnapshotAsSaved',
    'testImageMetadataRefreshDoesNotReloadForeignDraftOrDisableKnownRecovery',
    'testAcceptedEditDuringAssetRefreshPublishesTheCompletedAvailabilitySnapshot',
  ]) assert.ok(native.includes(`func ${name}(`));
  assert.doesNotMatch(native, /sourceEpoch:-/);
  for (const text of [native, core]) {
    assert.match(text, /LockLease: @unchecked Sendable/);
    assert.match(text, /guard descriptor >= 0 else \{ return \}/);
    assert.match(text, /DispatchQueue\.global\(qos:\.userInitiated\)\.asyncAfter/);
  }
});

// Protocol model only: these executable checks are NOT Swift/UIKit execution.
class Journal {
  value = null;
  save(next, expected) {
    if ((this.value?.revision ?? null) !== expected) throw Error('CAS conflict');
    this.value = next;
  }
}
class Presentation {
  cache = null; token = 0; context = 'A'; ready = false;
  begin(context = this.context) { this.context = context; this.ready = false; return ++this.token; }
  finish(token, context, value) {
    if (token !== this.token || context !== this.context) return false;
    this.cache = value; this.ready = true; return true;
  }
  edit(journal, next) {
    const expected = this.ready ? this.cache?.revision ?? null : journal.value?.revision ?? null;
    ++this.token;
    journal.save(next, expected);
    this.cache = next; this.ready = true;
  }
}
test('protocol model rejects foreign positive and negative-cache writes without losing the attempted value', () => {
  for (const initial of [null, { revision: 1, text: 'observed' }]) {
    const journal = new Journal(); journal.value = initial;
    const view = new Presentation(); view.finish(view.begin(), 'A', initial);
    journal.save({ revision: 2, text: 'foreign' }, initial?.revision ?? null);
    const attempted = { revision: 3, text: 'retained attempted text' };
    assert.throws(() => view.edit(journal, attempted), /CAS conflict/);
    assert.equal(journal.value.text, 'foreign');
    assert.deepEqual(view.cache, initial);
    assert.equal(attempted.text, 'retained attempted text');
  }
});
test('protocol model rejects stale read after edit or context switch', () => {
  const journal = new Journal(), view = new Presentation();
  const pending = view.begin();
  view.edit(journal, { revision: 1, text: 'accepted edit' });
  assert.equal(view.finish(pending, 'A', null), false);
  assert.equal(view.cache.text, 'accepted edit');
  const old = view.begin('A'), current = view.begin('B');
  assert.equal(view.finish(old, 'A', { revision: 2, text: 'wrong cue' }), false);
  assert.equal(view.finish(current, 'B', { revision: 3, text: 'correct cue' }), true);
  assert.equal(view.cache.text, 'correct cue');
});

test('protocol model refuses pre-clear alias snapshots and restores known-absence readiness', () => {
  let serial = 1;
  const cleared = new Map();
  const canonical = 'same-resolved-package-and-cue';
  const request = { started: serial, canonical, value: { revision: 1, text: 'now cleared' } };
  cleared.set(canonical, ++serial);
  const accepts = result => (cleared.get(result.canonical) ?? 0) <= result.started;
  assert.equal(accepts(request), false, 'An unresolved lexical alias cannot republish a pre-clear draft');
  assert.equal(accepts({ ...request, canonical: 'unrelated-B' }), true);
  assert.equal(accepts({ ...request, started: ++serial, value: null }), true);
  const view = new Presentation(); view.finish(view.begin(), 'A', request.value);
  const forcedRead = view.begin();
  ++view.token; view.cache = null; view.ready = true; // Synchronous successful CAS/cache publication.
  assert.equal(view.finish(forcedRead, 'A', request.value), false);
  assert.equal(view.ready, true);
  assert.equal(view.cache, null);
});
