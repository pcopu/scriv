import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { ScrivSession } from '../../cli/scriv.mjs';

// Frozen CodexConnectionCheckTests.swift::0006. These are expected display
// strings, never shell input. No command is copied, installed or executed.
const instructions = Object.freeze([
  { id: 'codex-copy-install-command', text: 'curl -fsSL https://chatgpt.com/codex/install.sh | sh' },
  { id: 'codex-copy-sign-in-command', text: 'codex' },
  { id: 'codex-copy-server-command', text: 'codex app-server --listen ws://127.0.0.1:4500' },
]);
const setupSource = await readFile(new URL('../../apps/catalyst/ScrivUIKit/Account/ScrivCodexSetupView.swift', import.meta.url), 'utf8');
const normalized = value => value?.replace(/\s+/g, ' ').trim();
// Fail closed if the one activated disclosure ceases to be presentation-only.
// This exact-source guard is not a Swift parser, binary attestation, network
// trace or substitute for observing the labels in the native application.
const disclosureStart = 'body.addArrangedSubview(button("Installation help", id: "installation-help", plain: true) { [weak self] in';
assert.equal(setupSource.split(disclosureStart).length, 2, 'Re-review the installation disclosure before running');
const disclosure = setupSource.split(disclosureStart)[1]?.split('\n        })')[0];
assert.equal(normalized(disclosure), 'guard let self else { return }; self.installationExpanded.toggle(); self.updateDisclosures()',
  'Installation help must only toggle its disclosure');
const updateStart = 'private func updateDisclosures() {';
assert.equal(setupSource.split(updateStart).length, 2, 'Expected one disclosure updater');
const update = setupSource.split(updateStart)[1]?.split('\n    private func button(')[0];
assert.equal(normalized(update), normalized(`
    installation.isHidden = !installationExpanded; pairingContent.isHidden = !pairingExpanded
    for (id, expanded) in [("installation-help", installationExpanded), ("pairing-controls", pairingExpanded)] {
        controls[id]?.configuration?.image = UIImage(systemName: expanded ? "chevron.down" : "chevron.right")
        controls[id]?.configuration?.imagePadding = 8
        controls[id]?.accessibilityValue = expanded ? "Expanded" : "Collapsed"
    }
    setNeedsLayout()
}`), 'Re-review disclosure presentation changes before running');

if (process.argv.includes('--check-source-only')) {
  console.log('PASS: disclosure-only source guard; actual UIKit setup-command scenario NOT run');
} else {
  assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to a verified automation-enabled build of this checkout');
  const session = await ScrivSession.launch(process.env.SCRIV_E2E_APP);
  const byID = (nodes, id) => nodes.filter(node => node.identifier === id);
  const paneNodes = nodes => {
    const panes = byID(nodes, 'codex-settings');
    if (panes.length !== 1) return [];
    return nodes.filter(node => node.path === panes[0].path || node.path.startsWith(`${panes[0].path}.`));
  };
  const one = (nodes, id) => {
    const matches = byID(nodes, id);
    assert.equal(matches.length, 1, `Exactly one ${id} is present in the current pane`);
    return matches[0];
  };
  const disconnected = nodes => {
    const pane = paneNodes(nodes);
    return byID(pane, 'codex-connection-status').length === 1
      && byID(pane, 'codex-connection-status')[0].text === 'Not connected'
      && ['codex-account-status', 'codex-account', 'codex-refresh-account', 'codex-model', 'codex-stop', 'codex-cancel-check', 'codex-setup-error']
        .every(id => byID(pane, id).length === 0)
      && ['codex-check', 'codex-connect'].every(id => byID(pane, id).length === 1 && byID(pane, id)[0].enabled === true);
  };
  const fieldValues = nodes => ['Installed Codex executable', 'Saved loopback server address'].map(label => {
    const matches = paneNodes(nodes).filter(node => node.type === 'UITextField' && node.label === label);
    assert.equal(matches.length, 1, `Exactly one untouched ${label} field`);
    assert.equal(matches[0].firstResponder, false, 'Instruction observation never edits runtime fields');
    assert.equal(matches[0].enabled, true);
    return { label, text: matches[0].text };
  });
  let originalFields;
  const assertIdle = nodes => {
    assert.ok(disconnected(nodes), 'Settings instruction observation must remain disconnected and error-free');
    if (originalFields) assert.deepEqual(fieldValues(nodes), originalFields, 'Runtime fields remain unchanged');
  };
  const contains = (outer, inner) => outer && inner
    && [outer.x, outer.y, outer.width, outer.height, inner.x, inner.y, inner.width, inner.height].every(Number.isFinite)
    && outer.width > 0 && outer.height > 0 && inner.width > 0 && inner.height > 0
    && inner.x >= outer.x - 0.5 && inner.y >= outer.y - 0.5
    && inner.x + inner.width <= outer.x + outer.width + 0.5
    && inner.y + inner.height <= outer.y + outer.height + 0.5;
  const isDisplayed = (nodes, node) => {
    const pane = paneNodes(nodes);
    const scroll = one(pane, 'codex-setup-scroll');
    const windows = nodes.filter(candidate => candidate.path === node.windowPath);
    return windows.length === 1 && contains(scroll.frame, node.frame) && contains(windows[0].frame, node.frame);
  };
  async function reveal(id, { actionable = false } = {}) {
    const initial = await session.command('snapshot');
    assertIdle(initial);
    const scroll = one(paneNodes(initial), 'codex-setup-scroll');
    const height = scroll.scroll?.contentHeight;
    assert.ok(Number.isFinite(height) && height >= 0 && height <= 20000, 'Bound the real settings scroll');
    assert.ok(Number.isFinite(scroll.frame?.height) && scroll.frame.height >= 100, 'Settings viewport has usable geometry');
    const step = Math.min(200, scroll.frame.height / 2);
    for (let y = 0; y <= height + step; y += step) {
      const before = await session.command('snapshot');
      assertIdle(before);
      const currentScroll = one(paneNodes(before), 'codex-setup-scroll');
      await session.command('scroll', { target: currentScroll.path, y });
      const nodes = await session.command('snapshot');
      assertIdle(nodes);
      const target = one(paneNodes(nodes), id);
      if (isDisplayed(nodes, target) && (!actionable || (target.hittable && target.enabled))) return target;
    }
    throw new Error(`${id} did not become fully displayed in the settings viewport`);
  }
  async function observeInstruction(expected) {
    const label = await reveal(expected.id);
    assert.equal(label.type, 'UILabel', 'Read the actual command label, not a Copy control or source constant');
    assert.equal(label.text, expected.text, `${expected.id} preserves the frozen literal exactly`);
    // UILabel is deliberately not interactive, so hittable is not a visibility
    // criterion. reveal requires its full native frame inside scroll and window.
  }
  async function setDisclosure(expanded) {
    const button = await reveal('codex-installation-help', { actionable: true });
    assert.equal(button.label, 'Installation help');
    assert.equal(button.value, expanded ? 'Collapsed' : 'Expanded', 'Never blindly toggle an uncertain disclosure state');
    const before = await session.command('snapshot');
    assertIdle(before);
    const current = one(paneNodes(before), 'codex-installation-help');
    assert.equal(current.path, button.path);
    assert.equal(current.label, 'Installation help');
    assert.equal(current.value, button.value);
    assert.equal(current.enabled, true);
    assert.equal(current.hittable, true);
    // This helper activates the installation disclosure in the Codex pane.
    // Never activate check/connect/start/account/guide/copy/pairing/picker actions.
    await session.command('activate', { target: current.path });
    const after = await session.waitFor(nodes => {
      const pane = paneNodes(nodes);
      return disconnected(nodes) && byID(pane, 'codex-installation-help').length === 1
        && byID(pane, 'codex-installation-help')[0].value === (expanded ? 'Expanded' : 'Collapsed')
        && instructions.slice(0, 2).every(expected => byID(pane, expected.id).length === (expanded ? 1 : 0));
    });
    assertIdle(after);
  }
  try {
    await session.waitFor(nodes => byID(nodes, 'workspace-tabs').some(node => node.hittable && node.enabled));
    // loaded-project binds its read-only model to an existing owned package.
    // Prepare that fixture through normal Save before opening Settings.
    const { waitForSavedProject } = await import('./support/saved-projects.mjs');
    await session.command('key', { input: 's', modifiers: ['command'] });
    const preparedProject = await waitForSavedProject(session, project => project.title === 'YAM MAN');
    assert.ok(preparedProject.scenes.some(scene => scene.id === 'scene-farm'), 'The prepared package is the original synthetic farm sample');
    const preparedModel = await session.command('loaded-project');
    assert.deepEqual(preparedModel.project, preparedProject, 'Normal Save publishes the complete loaded model');
    const preparedPackages = await session.command('persisted-projects');
    assert.deepEqual(preparedPackages, [preparedProject], 'The isolated fixture contains exactly its saved startup package');
    await session.command('key', { input: ',', modifiers: ['command'] });
    const settings = await session.waitFor(nodes => byID(nodes, 'scriv.settings.codex').filter(node => node.hittable).length === 1);
    const codex = byID(settings, 'scriv.settings.codex').find(node => node.hittable);
    // This is Settings navigation, not the connection popup or account pane.
    await session.command('activate', { target: codex.path });
    const initial = await session.waitFor(disconnected);
    originalFields = fieldValues(initial);
    assertIdle(initial);
    assert.equal(one(paneNodes(initial), 'codex-installation-help').value, 'Collapsed');
    for (const expected of instructions.slice(0, 2)) assert.equal(byID(paneNodes(initial), expected.id).length, 0);
    await observeInstruction(instructions[2]);
    for (let cycle = 1; cycle <= 2; cycle++) {
      await setDisclosure(true);
      for (const expected of instructions) await observeInstruction(expected);
      await setDisclosure(false);
      await observeInstruction(instructions[2]);
      const collapsed = await session.command('snapshot');
      assertIdle(collapsed);
      for (const expected of instructions.slice(0, 2)) assert.equal(byID(paneNodes(collapsed), expected.id).length, 0);
      console.log(`Observed setup instruction cycle ${cycle}: three exact displayed commands; disclosure closed; disconnected`);
    }
    // Return to the top of the unchanged Settings pane with help collapsed.
    await reveal('codex-installation-help', { actionable: true });
    assertIdle(await session.command('snapshot'));
    const jobsBaseline = await session.command('loaded-project');
    const sorted = projects => [...projects].sort((left, right) => left.id.localeCompare(right.id));
    const savedBaseline = sorted(await session.command('persisted-projects'));
    assert.deepEqual(jobsBaseline, preparedModel, 'Instruction inspection preserves every prepared model field and exact date');
    assert.deepEqual(savedBaseline, sorted(preparedPackages), 'Instruction inspection preserves the complete prepared package set');
    assert.equal((await session.command('capabilities')).cloudIsolation.network, 'disabled');
    const jobSources = nodes => nodes.filter(node => node.type === 'UISegmentedControl' && node.hittable
      && node.segments?.length === 2 && node.segments[0] === 'This Mac' && node.segments[1] === 'Shared project');
    async function settledControl(predicate) {
      // The public snapshot exposes geometry before UIKit presentation completes.
      // Bound settling to waitFor's deadline and never repeat a mutation.
      let signature = '', stableSince = 0;
      return session.waitFor(nodes => {
        const matches = nodes.filter(node => node.hittable && node.enabled && predicate(node));
        const next = matches.length === 1 ? JSON.stringify([matches[0].path, matches[0].frame]) : '';
        if (!next || next !== signature) { signature = next; stableSince = Date.now(); return false; }
        return Date.now() - stableSince >= 1000;
      });
    }
    for (let cycle = 0; cycle < 2; cycle++) {
      await reveal('codex-jobs', { actionable: true });
      const ready = await settledControl(node => node.identifier === 'codex-jobs');
      await session.command('activate', { target: one(paneNodes(ready), 'codex-jobs').path });
      let nodes = await session.waitFor(nodes => jobSources(nodes).length === 1 && nodes.some(node => node.text === 'No generation jobs yet'));
      assert.equal(jobSources(nodes)[0].selected, 0, 'Reopened generation history starts on This Mac');
      assert.ok(nodes.some(node => node.text === 'Jobs are saved on this Mac. Reconnecting never starts a new generation.'));
      assert.ok(nodes.some(node => node.text === 'Select an image placement, write a direction and choose Generate. Starting or reconnecting Codex never starts generation.'));
      assert.equal(nodes.some(node => ['Inspect existing turn', 'Retry…', 'Use in original project', 'Open image'].includes(node.title) && node.hittable), false,
        'Fresh isolated history has no executable generation job actions');
      await session.command('select', { target: jobSources(nodes)[0].path, index: 1 });
      nodes = await session.waitFor(nodes => nodes.some(node => node.text === 'No shared jobs for this project')
        && jobSources(nodes).length === 1 && jobSources(nodes)[0].selected === 1);
      assert.ok(nodes.some(node => node.text === 'Image prompts sync with the project. Local recovery paths and runtime credentials stay on their owning Mac.'));
      const refresh = await settledControl(node => node.title === 'Refresh shared jobs');
      await session.command('activate', { target: refresh.find(node => node.title === 'Refresh shared jobs' && node.hittable && node.enabled).path });
      nodes = await session.waitFor(nodes => nodes.some(node => node.text === 'No shared jobs for this project') && jobSources(nodes).length === 1);
      await session.command('select', { target: jobSources(nodes)[0].path, index: 0 });
      await session.waitFor(nodes => nodes.some(node => node.text === 'No generation jobs yet') && jobSources(nodes).some(node => node.selected === 0));
      // Catalyst's native navigation-bar Done item is outside the UIView snapshot.
      // Discover the sheet's actual public Escape handler before dismissing it.
      const closing = (await session.command('keys')).find(command => command.input === 'Escape' && command.modifiers.length === 0);
      assert.ok(closing, 'The active responder chain offers sheet dismissal');
      assert.equal(closing.responderType, 'ScrivGenerationJobsController');
      assert.equal(closing.action, 'scrivEscapeSheet');
      assert.equal(closing.wantsPriorityOverSystemBehavior, true);
      assert.deepEqual(await session.command('key', { input: 'Escape', modifiers: [] }), { dispatched: true });
      await session.waitFor(nodes => disconnected(nodes) && jobSources(nodes).length === 0);
      await settledControl(node => node.identifier === 'codex-jobs');
      assertIdle(await session.command('snapshot'));
      assert.deepEqual(await session.command('loaded-project'), jobsBaseline, 'History navigation and signed-out refresh preserve every loaded project field/date');
      assert.deepEqual(sorted(await session.command('persisted-projects')), savedBaseline, 'History navigation preserves all complete saved packages');
      assert.deepEqual(await session.command('presented-alerts'), []);
    }
    console.log('PASS: actual UIKit installation/sign-in/custom-server labels and local/shared generation history, repeated close/reopen, disconnected runtime and complete model preservation');
  } finally { await session.close(); }
}
