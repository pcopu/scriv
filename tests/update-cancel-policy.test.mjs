import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const read = p => readFile(new URL('../' + p, import.meta.url), 'utf8');
test('policy rejection cancels the prepared update immediately, never Dismiss or error-ack deferred', async () => {
  const source = await read('apps/catalyst/UpdatePlugin/ScrivSparklePlugin.m');
  const rejection = source.split('if (!allowed || !newerBuild')[1].split('[self emit:@{@"phase":@"available"')[0];
  assert.match(rejection, /cancelUpdateWithReply:reply/);
  assert.doesNotMatch(rejection, /SPUUserUpdateChoiceDismiss|reply:\^/);
  const cancel = source.split('- (void)cancelUpdateWithReply:')[1].split('- (void)prepareAndReply:')[0];
  assert.match(cancel, /reply\(SPUUserUpdateChoiceSkip\);/);
  assert.match(cancel, /@"phase":@"error".*reply:nil/);
  assert.doesNotMatch(cancel, /reply:\^/);
});
test('failed or missing save fence cancels immediately and late/duplicate completion cannot install', async () => {
  const source = await read('apps/catalyst/UpdatePlugin/ScrivSparklePlugin.m');
  const prepare = source.split('- (void)prepareAndReply:')[1].split('- (void)showUpdateReleaseNotes')[0];
  assert.equal((prepare.match(/cancelUpdateWithReply:reply/g) || []).length, 2);
  assert.match(prepare, /completed \|\| generation != self.eventGeneration/);
  assert.match(prepare, /completed = YES;/);
  assert.doesNotMatch(prepare, /reply:\^/);
  assert.match(source, /if \(self.cancellationMessage\) \{ \+\+self.eventGeneration; return; \}/);
  assert.match(source, /self.cancellationMessage && self.updater && !self.updater.canCheckForUpdates/);
});
