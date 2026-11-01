import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const root = new URL('../', import.meta.url);
test('Sparkle package is linked once and its automatic framework embed is not duplicated', async () => {
  const project = await readFile(new URL('apps/catalyst/ScrivUIKit.xcodeproj/project.pbxproj', root), 'utf8');
  const generator = await readFile(new URL('scripts/generate-catalyst-project.py', root), 'utf8');
  assert.match(generator, /add\('SparkleLink','PBXBuildFile',productRef=sparkle\)/);
  assert.doesNotMatch(generator, /add\('SparkleEmbed','PBXBuildFile'/);
  assert.doesNotMatch(project, /Embed Sparkle in native update plug-in/);
});

test('archive has only Catalyst ScrivCore package variants; native targets share canonical source membership', async () => {
  const { cp, mkdir, mkdtemp, readdir, rm } = await import('node:fs/promises');
  const { execFileSync } = await import('node:child_process');
  const { join } = await import('node:path');
  const { tmpdir } = await import('node:os');
  const fixture = await mkdtemp(join(tmpdir(), 'scriv-native-archive-graph-'));
  try {
    await mkdir(join(fixture, 'scripts'), { recursive: true });
    await mkdir(join(fixture, 'apps/mac/Sources'), { recursive: true });
    await cp(new URL('scripts/generate-catalyst-project.py', root), join(fixture, 'scripts/generate-catalyst-project.py'));
    await cp(new URL('apps/mac/Sources/ScrivCore', root), join(fixture, 'apps/mac/Sources/ScrivCore'), { recursive: true });
    const output = execFileSync('python3', ['-c', 'import runpy,json,sys; m=runpy.run_path(sys.argv[1]); print(json.dumps(m["objects"]))', join(fixture, 'scripts/generate-catalyst-project.py')], { encoding: 'utf8' });
    const objects = JSON.parse(output.trim().split('\n').at(-1));
    const values = Object.values(objects);
    const target = name => values.find(x => x.isa === 'PBXNativeTarget' && x.name === name);
    const configs = t => objects[t.buildConfigurationList].buildConfigurations.map(id => objects[id]);
    const products = t => t.packageProductDependencies.map(id => objects[id].productName);
    const coreNames = (await readdir(new URL('apps/mac/Sources/ScrivCore', root))).filter(x => x.endsWith('.swift')).sort();
    assert.equal(values.filter(x => x.isa === 'XCSwiftPackageProductDependency' && x.productName === 'ScrivCore').length, 2);
    for (const name of ['ScrivUIKit', 'ScrivUIKitTests']) {
      assert.deepEqual(products(target(name)), ['ScrivCore']);
      for (const c of configs(target(name))) assert.ok(!c.buildSettings.SWIFT_ACTIVE_COMPILATION_CONDITIONS?.includes('SCRIV_EMBEDDED_NATIVE_CORE'));
    }
    for (const [name, expectedProducts] of [['ScrivUpdatePlugin', ['Sparkle']], ['ScrivRuntimeBootstrap', []]]) {
      const t = target(name); assert.deepEqual(products(t), expectedProducts);
      const sources = t.buildPhases.map(id => objects[id]).find(x => x.isa === 'PBXSourcesBuildPhase');
      const paths = sources.files.map(id => objects[objects[id].fileRef].path);
      assert.equal(paths.length, new Set(paths).size, name + ' must not compile a source twice');
      assert.deepEqual(paths.filter(p => p.startsWith('../mac/Sources/ScrivCore/')).map(p => p.split('/').at(-1)).sort(), coreNames);
      for (const c of configs(t)) {
        assert.equal(c.buildSettings.SDKROOT, 'macosx'); assert.equal(c.buildSettings.SUPPORTS_MACCATALYST, 'NO');
        assert.equal(c.buildSettings.ENABLE_HARDENED_RUNTIME, 'YES'); assert.equal(c.buildSettings.SKIP_INSTALL, 'YES');
        assert.match(c.buildSettings.SWIFT_ACTIVE_COMPILATION_CONDITIONS, /SCRIV_EMBEDDED_NATIVE_CORE/);
        if (c.name === 'Debug') assert.match(c.buildSettings.SWIFT_ACTIVE_COMPILATION_CONDITIONS, /DEBUG/);
      }
    }
    const generated = await readFile(join(fixture, 'apps/catalyst/ScrivUIKit.xcodeproj/project.pbxproj'), 'utf8');
    assert.equal(generated, await readFile(new URL('apps/catalyst/ScrivUIKit.xcodeproj/project.pbxproj', root), 'utf8'), 'Checked-in graph must match the deterministic generator');
    for (const path of ['Integration/ScrivRuntimeBootstrapClient.swift', 'Sources/ScrivRuntimeCompanion/main.swift', 'Sources/ScrivRuntimeCompanion/RuntimeBootstrapXPC.swift']) {
      const source = await readFile(new URL('apps/runtime-bridge/' + path, root), 'utf8');
      assert.match(source, /#if !SCRIV_EMBEDDED_NATIVE_CORE\s+import ScrivCore\s+#endif/);
    }
  } finally { await rm(fixture, { recursive: true, force: true }); }
});
