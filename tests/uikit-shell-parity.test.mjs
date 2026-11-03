import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = path => readFile(new URL(`../apps/catalyst/ScrivUIKit/${path}`, import.meta.url), 'utf8');

// Source-contract checks only. Native XCTest and screenshots on a Mac are the
// authority for UIKit layout, rendering and responder behavior.
test('approved light workspace does not silently inherit the host dark theme', async () => {
  const app = await source('App/AppDelegate.swift');
  const theme = await source('Shared/ScrivUIKitTheme.swift');
  assert.match(app, /window\.overrideUserInterfaceStyle = \.light/);
  assert.match(theme, /static let ink = adaptive\(/);
  assert.match(theme, /titleTextAttributesTransformer/);
  assert.match(theme, /titleLineBreakMode = \.byTruncatingTail/);
});

test('header centers navigation independently of title and toolbar width', async () => {
  const header = await source('App/ScrivWorkspaceHeader.swift');
  assert.match(header, /tabs\.centerXAnchor\.constraint\(equalTo: centerXAnchor\)/);
  assert.match(header, /tabs\.heightAnchor\.constraint\(equalToConstant: 48\)/);
  assert.match(header, /configuration\.subtitle = "Scriv"/);
  assert.doesNotMatch(header, /WorkspaceStore|SwiftUI|NSHosting/);
});

test('each workspace tab has exactly one reachable transport and bounded split constraints', async () => {
  const shell = await source('App/ScrivWorkspaceController.swift');
  assert.match(shell, /transport\.isHidden = !ScrivWorkspaceLayout\.usesFooterTransport\(for: store\.tab\)/);
  assert.match(shell, /splitConstraint\?\.isActive = false/);
  assert.match(shell, /multiplier: ScrivWorkspaceLayout\.scriptPanelRatio/);
  const layout = await source('App/ScrivWorkspaceHeader.swift');
  assert.match(layout, /scriptPanelRatio: CGFloat = 1\.1/);
  assert.match(layout, /usesFooterTransport\(for tab: WorkspaceTab\) -> Bool \{ true \}/);
  for (const path of ['Images/PreviewViewController.swift', 'Images/StoryboardViewController.swift']) {
    assert.doesNotMatch(await source(path), /ScrivPlaybackControlsView\(store: store/);
  }
});

test('compact chrome preserves project and workspace destinations', async () => {
  const shell = await source('App/ScrivWorkspaceController.swift');
  for (const route of ['projects', 'audio', 'history', 'teams', 'generationJobs', 'codex']) {
    assert.ok(shell.includes(`show(.${route})`), `missing ${route} route`);
  }
  for (const action of ['newProject()', 'openProject()', 'renameProject()', 'importScript()', 'exportScript()', 'exportProject()', 'loadDiscussion(itemId:', 'focusSearch()']) {
    assert.ok(shell.includes(action), `missing ${action}`);
  }
});

test('discussion remains a full-height non-overlapping dock rather than an overlay', async () => {
  const shell = await source('App/ScrivWorkspaceController.swift');
  assert.match(shell, /workspaceBody\.addArrangedSubview\(dock\)/);
  assert.match(shell, /panel\.view\.bottomAnchor\.constraint\(equalTo: dock\.bottomAnchor\)/);
  assert.match(shell, /dock\.widthAnchor\.constraint\(equalTo: workspaceBody\.widthAnchor, multiplier: 0\.28\)/);
  assert.doesNotMatch(shell, /discussionHeight|panel\.preferredContentSize\.height/);
});
