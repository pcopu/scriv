import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile, copyFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'scriv-native-check-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  for (const path of ['scripts', 'tools', 'apps/mac/Sources', 'apps/mac/Tests']) {
    await mkdir(join(directory, path), { recursive: true });
  }
  await copyFile(join(root, 'scripts/verify-native.sh'), join(directory, 'scripts/verify-native.sh'));
  await writeFile(join(directory, 'apps/mac/Sources/Example.swift'), 'struct Example {}\n');
  await writeFile(join(directory, 'apps/mac/Tests/ExampleTests.swift'), '// parser fixture\n');
  await writeFile(join(directory, 'scripts/make-icon.swift'), '// parser fixture\n');
  const tool = '#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "$NATIVE_TEST_LOG"\nif [[ "$1" == "${FAIL_COMMAND:-never}" ]]; then exit 19; fi\n';
  for (const name of ['swift', 'swiftc']) {
    await writeFile(join(directory, 'tools', name), tool, { mode: 0o755 });
  }
  await writeFile(join(directory, 'tools/uname'), '#!/bin/bash\necho Linux\n', { mode: 0o755 });
  const log = join(directory, 'invocations.log');
  await writeFile(log, '');
  return {
    directory,
    log,
    run(args = [], extraEnvironment = {}) {
      return spawnSync('bash', [join(directory, 'scripts/verify-native.sh'), ...args], {
        encoding: 'utf8',
        env: {
          ...process.env,
          PATH: `${join(directory, 'tools')}:${process.env.PATH}`,
          SCRIV_SWIFT: join(directory, 'tools/swift'),
          SCRIV_SWIFTC: join(directory, 'tools/swiftc'),
          SCRIV_SWIFT_VERIFY_DIR: join(directory, 'build/verification'),
          NATIVE_TEST_LOG: log,
          ...extraEnvironment,
        },
      });
    },
  };
}

test('portable verification runs parsing, tests and release core build with local caches', async t => {
  const f = await fixture(t);
  const result = f.run(['--portable']);
  assert.equal(result.status, 0, result.stderr);
  const invocations = await readFile(f.log, 'utf8');
  assert.match(invocations, /swiftc -frontend -parse -swift-version 5/);
  assert.match(invocations, /swift test .*--manifest-cache local/);
  assert.match(invocations, /swift build .*--configuration release --target ScrivCore/);
  assert.ok(invocations.includes(`--cache-path ${f.directory}/build/verification/cache`));
  assert.ok(invocations.includes(`--config-path ${f.directory}/build/verification/config`));
  assert.ok(invocations.includes(`--security-path ${f.directory}/build/verification/security`));
  assert.match(result.stdout, /NOT RUN: Native AppKit\/SwiftUI type-check/);
  assert.doesNotMatch(result.stdout, /PASS: Native app packaging/);
});

test('native verification refuses Linux before running any compiler', async t => {
  const f = await fixture(t);
  const result = f.run(['--native']);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /BLOCKED: Native AppKit\/SwiftUI/);
  assert.equal(await readFile(f.log, 'utf8'), '');
});

test('test failures stop verification before release build and success summary', async t => {
  const f = await fixture(t);
  const result = f.run(['--portable'], { FAIL_COMMAND: 'test' });
  assert.equal(result.status, 19);
  assert.doesNotMatch(await readFile(f.log, 'utf8'), /swift build /);
  assert.doesNotMatch(result.stdout, /PASS: Portable Swift core/);
});

test('missing compiler and invalid arguments fail explicitly rather than skip', async t => {
  const f = await fixture(t);
  const missing = f.run(['--portable'], { SCRIV_SWIFT: join(f.directory, 'missing-swift') });
  assert.equal(missing.status, 127);
  assert.match(missing.stderr, /BLOCKED: Required Swift tool not found/);
  assert.equal(f.run(['--unknown']).status, 2);
  assert.equal(f.run(['--portable', '--native']).status, 2);
  assert.equal(await readFile(f.log, 'utf8'), '');
});
