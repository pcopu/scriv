import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdtemp, writeFile, rm, mkdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const root = new URL('../', import.meta.url);
const text = path => readFile(new URL(path, root), 'utf8');
const icon = 'apps/catalyst/ScrivUIKit/Assets.xcassets/AppIcon.appiconset/';
test('approved transparent blue Ribbon mark has every exact Mac icon slot and real PNG bytes', async () => {
  const catalog = JSON.parse(await text(icon + 'Contents.json'));
  const mac = catalog.images.filter(x => x.idiom === 'mac');
  assert.equal(mac.length, 10);
  for (const size of [16,32,128,256,512]) for (const scale of [1,2]) {
    const entry = mac.find(x => x.size === `${size}x${size}` && x.scale === `${scale}x`);
    assert.ok(entry);
    const bytes = await readFile(new URL(icon + entry.filename, root));
    assert.equal(bytes.subarray(0,8).toString('hex'), '89504e470d0a1a0a');
    assert.equal(bytes.readUInt32BE(16), size * scale); assert.equal(bytes.readUInt32BE(20), size * scale);
    assert.ok(bytes.length > 500);
  }
  assert.ok(catalog.images.some(x => x.idiom === 'universal' && x.platform === 'ios' && x.size === '1024x1024'));
});
test('normal Xcode target compiles AppIcon without post-build icon patching', async () => {
  const generator = await text('scripts/generate-catalyst-project.py'), project = await text('apps/catalyst/ScrivUIKit.xcodeproj/project.pbxproj');
  assert.match(generator, /ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon'/);
  assert.equal((project.match(/"ASSETCATALOG_COMPILER_APPICON_NAME" = "AppIcon"/g) ?? []).length, 2);
  assert.match(generator, /'CharacterAnalysisController'/); assert.match(project, /CharacterAnalysisController\.swift/);
  const script = await text('scripts/build-catalyst.sh');
  assert.match(script, /verify-catalyst-icon\.py/); assert.doesNotMatch(script, /iconutil|PlistBuddy.*CFBundleIcon|make-icon\.swift/);
});
test('built-bundle verifier rejects absent actual compiled resources', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'scriv-icon-test-'));
  try {
    await mkdir(join(dir, 'Contents/Resources'), {recursive:true});
    const plist = '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIconName</key><string>AppIcon</string><key>CFBundleIconFile</key><string>AppIcon</string></dict></plist>';
    await writeFile(join(dir, 'Contents/Info.plist'), plist);
    const run = () => execFileSync('python3', [new URL('scripts/verify-catalyst-icon.py',root).pathname, dir], {stdio:'pipe'});
    assert.throws(run); await writeFile(join(dir, 'Contents/Resources/Assets.car'), 'synthetic compiled catalog fixture');
    assert.throws(run); await writeFile(join(dir, 'Contents/Resources/AppIcon.icns'), 'synthetic compiled icon fixture');
    assert.match(run().toString(), /Verified Xcode-compiled/);
  } finally { await rm(dir,{recursive:true,force:true}); }
});
