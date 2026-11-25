#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { serviceUsage } from '../scripts/service-catalog.mjs';
import { createInterface } from 'node:readline';
import { realpath, stat, lstat, mkdtemp, open, unlink, rmdir, writeFile } from 'node:fs/promises';
import { randomUUID, createHash } from 'node:crypto';
import { constants, createReadStream } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { retainOwnedWorkspace, validateOwnedWorkspace, inspectOwnedWorkspace } from './owned-workspace.mjs';

async function executableDigest(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}

async function openCloudFixtureGrant(runID, origin) {
  const directory = await mkdtemp(join(tmpdir(), 'scriv-cloud-grant-'));
  const path = join(directory, 'grant');
  const mailbox = join(directory, 'mailbox');
  let handle, reader, writer;
  try {
    await writeFile(path, `ScrivCLICloudFixture-v1\n${runID}\n${origin}\n`, { flag: 'wx', mode: 0o600 });
    try { handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW); }
    finally { await unlink(path); }
    writer = await open(mailbox, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try { reader = await open(mailbox, constants.O_RDONLY | constants.O_NOFOLLOW); }
    finally { await unlink(mailbox); }
    await rmdir(directory);
    return { handle, reader, writer };
  } catch (error) {
    await Promise.allSettled([handle?.close(), reader?.close(), writer?.close()]);
    await rmdir(directory).catch(() => {});
    throw error;
  }
}

/** One actual Catalyst app per session. No mock backend or in-process model. */
export class ScrivSession {
  #child; #pending = new Map(); #sequence = 0; #closed = false; #exited = false; #reader; #coverage = null; #closing = null;
  #workspace = null; #stopping = false; #relaunching = false; #uncertain = false;
  #fixtureMailbox = null;
  constructor(child, root) {
    this.#child = child; this.root = root;
    this.#reader = createInterface({ input: child.stdout });
    this.#reader.on('line', line => {
      if (!line.startsWith('SCRIV_CLI ')) return;
      let reply;
      try { reply = JSON.parse(line.slice(10)); } catch { return; }
      const pending = this.#pending.get(reply.id);
      if (!pending) return;
      this.#pending.delete(reply.id); clearTimeout(pending.timer);
      reply.ok ? pending.resolve(reply.result) : pending.reject(new Error(`${pending.command}: ${reply.error}`));
    });
    child.stderr.on('data', () => {}); // Drain logs; do not leak local diagnostics to results.
    child.on('error', error => this.#fail(error));
    child.on('exit', (code, signal) => { this.#exited = true; this.#fail(new Error(`Scriv exited (${code ?? signal})`)); this.#releaseStreams(); });
    child.stdin.on('error', error => this.#fail(error));
  }
  #releaseStreams() {
    this.#reader?.close();
    this.#child.stdin.destroy();
    this.#child.stdout.destroy();
    this.#child.stderr.destroy();
  }
  #fail(error) {
    this.#closed = true;
    for (const pending of this.#pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.#pending.clear();
  }
  static async launch(app, options = {}) {
    if (!options || typeof options !== 'object' || Array.isArray(options)
        || Object.keys(options).some(key => !['persistent', 'freshStartup', 'cloudFixtureOrigin', 'codexAnalysisFixtureOrigin'].includes(key))
        || options.persistent !== undefined && typeof options.persistent !== 'boolean'
        || options.freshStartup !== undefined && typeof options.freshStartup !== 'boolean') throw new Error('Invalid session options');
    const { cloudFixtureOrigin, codexAnalysisFixtureOrigin, freshStartup = false } = options;
    if (freshStartup && (options.persistent || cloudFixtureOrigin !== undefined || codexAnalysisFixtureOrigin !== undefined)) {
      throw new Error('Invalid session options');
    }
    if (cloudFixtureOrigin !== undefined) {
      const origin = typeof cloudFixtureOrigin === 'string' && /^http:\/\/127\.0\.0\.1:([1-9][0-9]{0,4})$/.exec(cloudFixtureOrigin);
      if (options.persistent || !origin || Number(origin[1]) > 65535 || origin[0] !== cloudFixtureOrigin) throw new Error('Invalid session options');
    }
    if (codexAnalysisFixtureOrigin !== undefined) {
      const origin = typeof codexAnalysisFixtureOrigin === 'string' && /^ws:\/\/127\.0\.0\.1:([1-9][0-9]{3,4})$/.exec(codexAnalysisFixtureOrigin);
      if (options.persistent || cloudFixtureOrigin !== undefined || !origin || Number(origin[1]) < 1024
          || Number(origin[1]) > 65535 || origin[0] !== codexAnalysisFixtureOrigin) throw new Error('Invalid session options');
    }
    return ScrivSession.#launch(app, options.persistent === true, null, { cloudFixtureOrigin, codexAnalysisFixtureOrigin, freshStartup });
  }
  static async #launch(app, persistent, workspace, { cloudFixtureOrigin, codexAnalysisFixtureOrigin, recoverPending = false, freshStartup = false } = {}) {
    if (process.platform !== 'darwin') throw new Error('Actual Scriv E2E requires macOS and an automation-enabled Catalyst build. No fallback driver is used.');
    const bundle = await realpath(app);
    if (!bundle.endsWith('.app')) throw new Error('Pass the automation .app bundle');
    const executable = join(bundle, 'Contents/MacOS/Scriv');
    if (!(await stat(executable)).isFile()) throw new Error('Missing Scriv executable');
    const runID = workspace?.runID ?? randomUUID(), sessionID = workspace ? randomUUID() : runID;
    const digest = persistent ? await executableDigest(executable) : null;
    if (workspace) {
      await validateOwnedWorkspace(workspace);
      if (bundle !== workspace.bundle || digest !== workspace.executableSHA256) throw new Error('Owned workspace requires the unchanged app executable');
    }
    const env = { ...process.env, SCRIV_CLI_RUN_ID: runID, SCRIV_CLI_SESSION_ID: sessionID };
    delete env.SCRIV_VERIFICATION_ROOT;
    delete env.SCRIV_VERIFICATION_AUTOPLAY;
    delete env.SCRIV_E2E_COVERAGE_CONTEXT; // Host collector metadata is not an app input.
    delete env.SCRIV_E2E_COVERAGE_STARTUP;
    delete env.SCRIV_CLI_CODEX_ANALYSIS_FIXTURE;
    if (codexAnalysisFixtureOrigin) env.SCRIV_CLI_CODEX_ANALYSIS_FIXTURE = codexAnalysisFixtureOrigin;
    for (const key of ['SCRIV_CLI_RESUME', 'SCRIV_CLI_RESUME_FD', 'SCRIV_CLI_WORKSPACE', 'SCRIV_CLI_PERSISTENT']) delete env[key];
    const arguments_ = ['--screenshots', '--scriv-cli', ...(persistent ? [workspace ? '--scriv-cli-resume' : '--scriv-cli-persistent'] : [])];
    if (recoverPending) arguments_.push('--scriv-cli-recover-pending');
    if (freshStartup) arguments_.push('--scriv-cli-fresh-startup');
    if (process.env.SCRIV_E2E_COVERAGE_CONTEXT && process.env.SCRIV_E2E_COVERAGE_STARTUP === '1') arguments_.push('--scriv-cli-coverage-startup');
    const grant = cloudFixtureOrigin ? await openCloudFixtureGrant(runID, cloudFixtureOrigin) : null;
    if (grant) arguments_.push('--scriv-cli-cloud-fixture');
    const inherited = grant ? [grant.handle.fd, grant.reader.fd] : workspace ? [workspace.handle.fd] : [];
    let session;
    try {
      try {
        const child = spawn(executable, arguments_, {
          env, stdio: ['pipe', 'pipe', 'pipe', ...inherited]
        });
        session = new ScrivSession(child, null);
        session.#fixtureMailbox = grant?.writer ?? null;
      } finally {
        if (grant) {
          await Promise.all([grant.handle.close(), grant.reader.close(), session ? undefined : grant.writer.close()]);
        }
      }
      let capabilities = await session.command('capabilities', {}, 30000);
      const root = capabilities.verificationRoot;
      if (capabilities.runID !== runID || typeof root !== 'string' || !isAbsolute(root)
          || basename(root) !== `ScrivVerification-CLI-${runID}`) throw new Error('App did not confirm this isolated run');
      if (capabilities.sessionID !== sessionID || capabilities.workspace?.persistent !== persistent
          || capabilities.workspace?.resumed !== Boolean(workspace)) throw new Error('App did not confirm this process and workspace mode');
      if (recoverPending || freshStartup) {
        const mode = recoverPending ? 'startupRecovery' : 'freshStartup';
        const deadline = Date.now() + 30000;
        while (capabilities.workspace?.[mode] === true && capabilities.workspace.bootstrapping === true
            && Date.now() < deadline) {
          await new Promise(resolve => setTimeout(resolve, 25));
          capabilities = await session.command('capabilities', {}, Math.max(1, deadline - Date.now()));
        }
        // Startup snapshots must include the completed launch before any scenario input.
        if (capabilities.workspace?.[mode] !== true || capabilities.workspace.bootstrapping !== false) {
          throw new Error(recoverPending ? 'App did not confirm completion of owned startup recovery'
            : 'App did not confirm completion of isolated first startup');
        }
      }
      if (grant && capabilities.cloudIsolation?.network !== 'loopback-only') throw new Error('App did not confirm isolated Worker access');
      const info = await lstat(root);
      if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('Isolated app root is not a real directory');
      session.root = await realpath(root);
      if (persistent) {
        if (workspace) {
          if (session.root !== workspace.root) throw new Error('Resumed app changed the owned root');
          await validateOwnedWorkspace(workspace);
        } else {
          session.#workspace = { ...await retainOwnedWorkspace(session.root, runID), bundle, executableSHA256: digest };
        }
      }
      if (process.env.SCRIV_E2E_COVERAGE_CONTEXT) {
        const { observeSession } = await import('./coverage-session.mjs');
        session.#coverage = await observeSession({ command: session.#issue.bind(session) }, executable, capabilities);
      }
      if (workspace) session.#workspace = workspace;
      return session;
    } catch (error) { await session?.close(); throw error; }
  }
  command(command, parameters = {}, timeout = 15000) {
    if (this.#stopping) return Promise.reject(new Error('Session is closing or relaunching'));
    return this.#issue(command, parameters, timeout);
  }
  async deliverFixtureEmailCode(code) {
    if (!this.#fixtureMailbox || this.#stopping || this.#closed || this.#uncertain
        || typeof code !== 'string' || code.length !== 6 || !/^[0-9]{6}$/.test(code)) {
      throw new Error('An owned synthetic sign-in mailbox is unavailable');
    }
    const mailbox = this.#fixtureMailbox;
    this.#fixtureMailbox = null;
    try { await mailbox.writeFile(code, 'ascii'); }
    finally { await mailbox.close(); }
    return this.command('receive-fixture-email-code');
  }
  #issue(command, parameters = {}, timeout = 15000) {
    if (this.#closed) return Promise.reject(new Error('Session is closed'));
    const selector = command === 'menu-action' ? parameters?.scope : command === 'activate' ? parameters?.target : undefined;
    const observed = this.#coverage?.record(command, selector);
    const id = ++this.#sequence;
    const response = new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.#pending.delete(id); this.#uncertain = true; reject(new Error(`Timed out: ${command}; outcome uncertain, do not blindly repeat mutations`)); }, timeout);
      this.#pending.set(id, { resolve, reject, timer, command });
      this.#child.stdin.write(JSON.stringify({ ...parameters, id, command }) + '\n');
    });
    return response.then(value => { observed?.('completed'); return value; }, error => { observed?.('failed-or-uncertain'); throw error; });
  }
  async waitFor(predicate, timeout = 15000) {
    const deadline = Date.now() + timeout;
    do {
      const snapshot = await this.command('snapshot');
      if (predicate(snapshot)) return snapshot;
      await new Promise(resolve => setTimeout(resolve, 50));
    } while (Date.now() < deadline);
    throw Object.assign(new Error('UI condition did not become true'), { code: 'SCRIV_UI_WAIT_TIMEOUT' });
  }
  async waitForUnique(predicate, timeout = 15000) {
    let matches;
    try {
      return await this.waitFor(nodes => {
        matches = nodes.filter(predicate).length;
        return matches === 1;
      }, timeout);
    } catch (cause) {
      if (cause?.code !== 'SCRIV_UI_WAIT_TIMEOUT') throw cause;
      const code = matches ? 'SCRIV_UI_TARGET_AMBIGUOUS' : 'SCRIV_UI_TARGET_MISSING';
      throw Object.assign(new Error(`Expected exactly one native control, found ${matches}`, { cause }), { code, matches });
    }
  }
  async close() {
    if (this.#relaunching) throw new Error('Await relaunch before closing its returned session');
    this.#stopping = true;
    this.#closing ??= (async () => {
      try { await this.#closeOnce(); }
      finally {
        const workspace = this.#workspace, mailbox = this.#fixtureMailbox;
        this.#workspace = null; this.#fixtureMailbox = null;
        await Promise.all([workspace?.handle.close(), mailbox?.close()]);
      }
    })();
    return this.#closing;
  }
  relaunch(...args) { return this.#relaunch(args, false); }
  relaunchRecoveringPendingSaves(...args) { return this.#relaunch(args, true); }
  async #relaunch(args, recoverPending) {
    if (args.length || !this.#workspace || this.#closed || this.#stopping || this.#pending.size || this.#uncertain) throw new Error('Relaunch requires a live persistent session with no arguments, pending commands or uncertain outcomes');
    this.#stopping = true; this.#relaunching = true;
    const workspace = this.#workspace; this.#workspace = null;
    try {
      // The old process and its separately opened native lock must be gone
      // before any new child receives the retained root descriptor.
      this.#closing ??= this.#closeOnce(); await this.#closing;
      if (!this.#exited) throw new Error('Prior app exit was not confirmed');
      await validateOwnedWorkspace(workspace);
      return await ScrivSession.#launch(workspace.bundle, true, workspace, { recoverPending });
    } catch (error) { await workspace.handle.close(); throw error; }
    finally { this.#relaunching = false; }
  }
  async #closeOnce() {
    const coverage = this.#coverage; this.#coverage = null;
    try { await coverage?.finish(); }
    finally { await this.#terminate(); }
  }
  async #terminate() {
    if (this.#exited || !this.#child.pid) { this.#releaseStreams(); return; }
    const exited = new Promise(resolve => this.#child.once('exit', resolve));
    this.#child.kill('SIGTERM');
    const force = setTimeout(() => { if (!this.#exited) this.#child.kill('SIGKILL'); }, 5000);
    try { await exited; } finally { clearTimeout(force); this.#releaseStreams(); }
  }
}

async function main(args = process.argv.slice(2)) {
  if (args[0] === 'workspace') {
    if (args.length !== 3 || args[1] !== 'inspect') throw new Error('Use workspace inspect ROOT for read-only ownership checks; path-based resume is unavailable');
    console.log(JSON.stringify(await inspectOwnedWorkspace(args[2]))); return 0;
  }
  if (args[0] === 'test') {
    if (args[1] === 'compact') {
      const { compactArchive } = await import('../scripts/compact-cli-archive.mjs');
      console.log(JSON.stringify(await compactArchive(args.slice(2), resolve(dirname(fileURLToPath(import.meta.url)), '..'))));
      return 0;
    }
    if (args[1] === 'provenance') {
      if (process.env.SCRIV_CLI_TOOLING_ACTIVE === '1' || args.length !== 2) throw new Error('Invalid or nested provenance journey');
      const { main } = await import('../tests/tracer/source-provenance-journey.mjs');
      return main();
    }
    if (args[1] === 'services') {
      const { main } = await import('../scripts/run-service-journeys.mjs');
      return main(args.slice(2));
    }
    if (args[1] === 'tooling') {
      if (process.env.SCRIV_CLI_TOOLING_ACTIVE === '1') throw new Error('nested-tooling-journey-refused');
      if (args.length !== 2) throw new Error('The tooling journey accepts no extra arguments.');
      const { main } = await import('../tests/tracer/cli-front-door.mjs');
      return main().catch(error => { console.error(error.message); return 1; });
    }
    // Reuse the real-app runner, including its provenance, cleanup and failure
    // gates. This is not a second implementation or a mock-app fallback.
    const { main } = await import('../scripts/run-cli-e2e.mjs');
    return main(args.slice(1));
  }
  const app = args[0];
  if (!app || args.includes('--help')) {
    console.log('Scriv CLI through Tracer\n  tracer actions\n  tracer app -- test --list\n  tracer app -- test --scenario ID --group NAME --app /path/to/ScrivAutomation.app\n  tracer app -- test [--scenario ID ...] --app /path/to/ScrivAutomation.app\n  tracer app -- test --help\n  tracer app -- test tooling\n  tracer app -- test provenance\n  tracer app -- test compact --archive /absolute/archived-runs [--apply]\n  ' + serviceUsage + '\n  tracer app -- /path/to/ScrivAutomation.app [--persistent-workspace|--fresh-startup]\n  tracer app -- workspace inspect /absolute/owned/root\n\nFresh startup opens an empty isolated workspace through normal local startup. Persistent mode permits the host JSON commands {"command":"relaunch"} and {"command":"relaunch-recover"} with no arguments. Recovery checks the retained workspace for pending local saves at startup. Both commands use only this process-owned synthetic workspace. workspace inspect is read-only and never grants resume authority.\n\nThe last form preserves JSON-line control: {"command":"snapshot"} or {"command":"select","target":"workspace-tabs","index":1}. Results are JSON lines.\nCharacter portraits use menu-action with scope/target character-portrait-options, exact action title, characterID and imageID. The supported operation is stored public menu-action dispatch, not a native menu click or alert action.\nNative tests/control require a real automation-enabled Catalyst build on macOS. Tooling journeys check the public CLI, not native app behavior.\nDirect compatibility: node cli/scriv.mjs /path/to/ScrivAutomation.app');
    return app ? 0 : 2;
  }
  if (!(args.length === 1 || args.length === 2 && ['--persistent-workspace', '--fresh-startup'].includes(args[1]))
      || /[\x00-\x1f\x7f]/.test(app)) throw new Error('Expected an automation app path or test. Use tracer actions.');
  let session = await ScrivSession.launch(app, { persistent: args[1] === '--persistent-workspace', freshStartup: args[1] === '--fresh-startup' });
  try {
    await session.command('capabilities');
    for await (const line of createInterface({ input: process.stdin })) {
      try {
        const { command, ...parameters } = JSON.parse(line);
        if (command === 'relaunch' || command === 'relaunch-recover') {
          if (Object.keys(parameters).length) throw new Error('Relaunch accepts no path, token or other parameters');
          session = command === 'relaunch-recover' ? await session.relaunchRecoveringPendingSaves() : await session.relaunch();
          console.log(JSON.stringify({ ok: true, result: await session.command('capabilities') }));
        } else console.log(JSON.stringify({ ok: true, result: await session.command(command, parameters) }));
      } catch (error) { console.log(JSON.stringify({ ok: false, error: error.message })); process.exitCode = 1; }
    }
  } finally { await session.close(); }
  return process.exitCode ?? 0;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main().then(code => { process.exitCode = code; }).catch(error => { console.error(error.message); process.exitCode = process.argv[2] === 'test' ? 2 : 1; });
