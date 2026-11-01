import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = name => readFile(new URL(`../apps/catalyst/ScrivUIKit/${name}.swift`, import.meta.url), 'utf8');

test('secondary controls use the shared palette and a single-line action policy', async () => {
  const text = await source('Account/AccountUI');
  for (const token of ['accent', 'panel', 'inset']) assert.ok(text.includes(`static let ${token} = ScrivUIKitTheme.${token}`));
  assert.match(text, /configuration\.titleLineBreakMode = \.byTruncatingTail/);
  assert.match(text, /button\.titleLabel\?\.numberOfLines = 1/);
  assert.match(text, /button\.setContentCompressionResistancePriority\(\.required, for: \.horizontal\)/);
  assert.doesNotMatch(text, /UIHostingController|import SwiftUI/);
});

test('audio timing protects full action labels and moves explanatory copy responsively', async () => {
  const clip = await source('Audio/AudioClipEditorController');
  const words = await source('Audio/WordTimingEditorController');
  assert.match(clip, /cancel\.widthAnchor\.constraint\(greaterThanOrEqualToConstant: 86\)/);
  assert.match(clip, /apply\.widthAnchor\.constraint\(greaterThanOrEqualToConstant: 80\)/);
  assert.match(clip, /let footer = ScrivSecondaryAdaptiveRow/);
  assert.match(clip, /minimumHorizontalWidth: 460/);
  assert.match(words, /saveButton\.widthAnchor\.constraint\(greaterThanOrEqualToConstant: 112\)/);
  assert.match(words, /ScrivSecondaryAdaptiveRow\(\[footerCopy/);
  assert.match(clip, /draft\.applying\(to: store\.project\)/);
  assert.match(words, /expectedWords: draft\.original\.words, expectedDurationMs: draft\.original\.ownedDurationMs/);
});

test('responsive presentation never replaces or mutates active form controls', async () => {
  const text = (await source('Account/AccountUI')).split('final class ScrivSecondaryAdaptiveRow')[1];
  assert.match(text, /width < minimumHorizontalWidth \? \.vertical : \.horizontal/);
  assert.match(text, /axis = next; alignment = next == \.vertical \? \.fill : horizontalAlignment/);
  assert.doesNotMatch(text, /removeFromSuperview|\.text =|store\.|dismiss\(/);
});

test('generation details remain beside their real image and complete actions wrap as units', async () => {
  const text = await source('Account/ScrivGenerationJobsController');
  assert.match(text, /ScrivSecondaryAdaptiveRow\(\[image, detailsColumn\]/);
  assert.match(text, /let actions = CharacterChipWrapView/);
  assert.match(text, /actions\.chips = actionButtons/);
  assert.match(text, /detailsColumn\.addArrangedSubview\(AccountUI\.card/);
  assert.match(text, /try\? controller\.artifactURL\(for: job\.id\)/);
  assert.match(text, /UIAlertController\(title: "Start a new image request\?"/);
  assert.match(text, /self\.store\.codex\.onRetryJob\?\(current\)/);
});

test('refined authentication keeps inline expiry, local editing and owner-fenced challenge semantics', async () => {
  const text = await source('Account/ScrivSignInController');
  assert.match(text, /AccountUI\.stack\(\[expiry, resend\]/);
  assert.match(text, /centeredLink\("Keep writing locally"/);
  assert.match(text, /UIImage\(systemName: "laptopcomputer"\)/);
  assert.match(text, /store\.cloud\.cancelSignIn\(ownerID: ownerID\)/);
  assert.match(text, /verifyEmailCode\(entered, ownerID: self\.ownerID\)/);
  assert.match(text, /if case \.signIn = route \{ navigation\.setNavigationBarHidden\(true/);
  assert.doesNotMatch(text, /print\(|UserDefaults|Keychain/);
});

test('projects and history render real source identities while retaining restore fences', async () => {
  const projects = await source('Projects/ProjectBrowserController');
  const history = await source('Projects/HistoryController');
  assert.match(projects, /sourceIcon\.image = UIImage\(systemName: project\.symbol\)/);
  assert.match(projects, /ProjectBrowserLocalSummary\.load\(at: url\)/);
  assert.match(history, /minimumHorizontalWidth: 850/);
  assert.match(history, /requireCurrentContext\(\), canRestore, selection\?\.id == captured\.id/);
  assert.match(history, /table\.widthAnchor\.constraint\(equalTo: view\.widthAnchor, multiplier: 0\.36\)/);
});

test('compact settings and invitation UI preserve runtime and invitation safety boundaries', async () => {
  const settings = await source('Account/ScrivSettingsController');
  const teams = await source('Teams/TeamUIKitSupport');
  assert.match(settings, /self\?\.show\(\.codex\)/);
  assert.match(settings, /saveRuntimeFields\(\)/);
  assert.match(settings, /guard !store\.codex\.isConnected, !store\.codex\.isConnecting else/);
  assert.match(teams, /create\.isEnabled = UIKitTeamPolicy\.canManage\(team\) && team\.isPaid && !working/);
  assert.match(teams, /old link secrets cannot be retrieved/);
  assert.match(teams, /Existing members keep access/);
});

test('recovered draft keeps review boundaries and destructive action distinct', async () => {
  const text = await source('Script/RecoveredDraftController');
  assert.match(text, /ScrivSecondaryAdaptiveRow\(\[keepButton, applyButton\]/);
  assert.match(text, /discardButton\.configuration\?\.baseForegroundColor = \.systemRed/);
  assert.match(text, /UIImage\(systemName: "doc\.text"\)/);
  assert.match(text, /session\.record\?\.scope == reviewedScope && session\.navigation == initialNavigationContext/);
  assert.match(text, /applyButton\.isEnabled = !session\.applying && !session\.needsRebase/);
  assert.match(text, /requireCurrentContext\(\), sessionMatches/);
  assert.match(text, /session\.keepForLater\(\)/);
});
