import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');
test('Codex vision adapter uses explicit inline image and confirmed read-only policy, never a fake-ready stub', async () => {
  const controller = await source('apps/mac/Sources/ScrivApp/Services/CodexController.swift');
  const analysis = controller.slice(controller.indexOf('extension CodexController: CharacterImageAnalysisProvider'));
  for (const text of ['selectedModelSupportsImageInput', 'CodexCharacterAnalysisProtocol.validateThread', 'data:image/jpeg;base64,', '"outputSchema": CodexCharacterAnalysisProtocol.outputSchema', '"networkAccess": .bool(false)', '"approvalPolicy": .string("never")', 'verifiedCharacterImageBytes(request)', 'submittedTurn && characterTurn.lifecycle.completion == nil', 'characterTurn.startTurn(turnID)']) assert.ok(analysis.includes(text), text);
  assert.doesNotMatch(analysis, /rpc\("(?:config|mcp|command|fs|thread\/read)|dangerFullAccess|localImage|api[_-]?key|tool-free analysis is unavailable/i);
});
test('uncertain analysis and observed tools stop the whole queue, including reconnect and reopen', async () => {
  const coordinator = await source('apps/mac/Sources/ScrivApp/Services/CharacterAnalysisController.swift');
  const state = await source('apps/mac/Sources/ScrivCore/CodexCharacterTurnState.swift');
  assert.match(coordinator, /catch let interruption as CharacterAnalysisInterruption/);
  assert.match(coordinator, /UserDefaults\.standard\.set\(interruption\.reason/);
  assert.match(coordinator, /string\(forKey: interruptionKey\(store\.project\.id\)\)/);
  assert.match(coordinator, /scanAgain\(\)[\s\S]*?removeObject\(forKey: interruptionKey/);
  assert.match(coordinator, /bytes\.write\(to:file,options:\.atomic\)/);
  assert.ok(coordinator.indexOf('try self.recordPending(') < coordinator.indexOf('try await self.analyzeWithRetry(request)'));
  assert.match(coordinator, /task == nil, FileManager\.default\.fileExists\(atPath:pendingFile/);
  assert.match(state, /\["agentMessage", "reasoning", "userMessage"\]\.contains\(type\)/);
  assert.match(state, /failure == nil, !lifecycle\.cancellationRequested/);
});
test('native synthetic fixtures exercise races, tool activity, policy refusal, and queue manual retry', async () => {
  const wire = await source('apps/mac/Tests/ScrivCoreTests/CodexCharacterTurnStateTests.swift');
  const native = await source('apps/catalyst/Tests/ScrivUIKitTests/CharacterImageReviewTests.swift');
  for (const name of ['testEarlyItemsAndCompletionSurviveStartReplyRace', 'testToolActivityStopsAnalysisEvenBeforeStartReplyAndNeverYieldsJSON', 'testCancellationBeforeTurnIDInterruptsLateTurnExactlyOnce', 'testForeignToolActivityDoesNotCancelOwnedAnalysis']) assert.ok(wire.includes(name));
  assert.ok(native.includes('testUnexpectedActivityPausesWholeQueueAcrossReconnectAndReopenUntilExplicitRetry'));
  assert.ok(native.includes('testPendingMarkerPrecedesProviderAndBlocksReopenUntilExplicitRetry'));
  assert.ok(native.includes('testPendingMarkerWriteFailureNeverCallsProvider'));
});
