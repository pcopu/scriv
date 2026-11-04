import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, cp, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const root = new URL('../', import.meta.url);
const source = path => readFile(new URL(path, root), 'utf8');

test('generated and checked-in Catalyst package registration includes the required Editor role', async () => {
  const fixture = await mkdtemp(join(tmpdir(), 'scriv-package-registration-'));
  try {
    await mkdir(join(fixture, 'scripts'), { recursive: true });
    await mkdir(join(fixture, 'apps/mac/Sources'), { recursive: true });
    await cp(new URL('scripts/generate-catalyst-project.py', root), join(fixture, 'scripts/generate-catalyst-project.py'));
    await cp(new URL('apps/mac/Sources/ScrivCore', root), join(fixture, 'apps/mac/Sources/ScrivCore'), { recursive: true });
    execFileSync('python3', [join(fixture, 'scripts/generate-catalyst-project.py')]);
    const generated = join(fixture, 'apps/catalyst/Info.plist');
    assert.equal(await readFile(generated, 'utf8'), await source('apps/catalyst/Info.plist'));
    const plist = JSON.parse(execFileSync('python3', ['-c', 'import json,plistlib,sys; print(json.dumps(plistlib.load(open(sys.argv[1],"rb"))))', generated], { encoding: 'utf8' }));
    const document = plist.CFBundleDocumentTypes.find(type => type.LSItemContentTypes.includes('app.scriv.project'));
    assert.equal(document.CFBundleTypeRole, 'Editor');
    assert.equal(document.LSHandlerRank, 'Owner');
    assert.equal(plist.LSSupportsOpeningDocumentsInPlace, true);
    const type = plist.UTExportedTypeDeclarations.find(type => type.UTTypeIdentifier === 'app.scriv.project');
    assert.deepEqual(type.UTTypeConformsTo, ['com.apple.package']);
    assert.deepEqual(type.UTTypeTagSpecification['public.filename-extension'], ['scriv']);
  } finally { await rm(fixture, { recursive: true, force: true }); }
});

test('picker and authorized scene URLs share scope acquisition without altering package identity', async () => {
  const store = await source('apps/mac/Sources/ScrivApp/Services/WorkspaceStore.swift');
  const picker = store.split('    func openProject() {')[1].split('    private func openUserSelectedProject')[0];
  const scene = store.split('    func handleOpenURL(_ url: URL) {')[1].split('    func retryCloudSync')[0];
  const open = store.split('    private func openUserSelectedProject(_ url: URL) {')[1].split('    private func install(')[0];
  assert.match(picker, /self\.openUserSelectedProject\(url\)/);
  assert.match(scene, /url\.isFileURL && url\.pathExtension\.lowercased\(\) == "scriv"/);
  assert.match(scene, /#if targetEnvironment\(macCatalyst\)\s+openUserSelectedProject\(url\)/);
  assert.match(open, /rememberProject\(url\)[\s\S]*try await self\.open\(url\)/);
  assert.doesNotMatch(open, /try\?[^\n]*(rememberProject|restoreProjectAccess|recoverPendingSaves)/);
  assert.doesNotMatch(open, /UUID\(\)|\.id\s*=|cloudProjectId\s*=/);
  assert.match(open, /guard navigationGeneration == navigation else \{ throw CancellationError\(\) \}/);
});

test('each package-open boundary retains a bounded failure stage and cancellation is not relabeled', async () => {
  const store = await source('apps/mac/Sources/ScrivApp/Services/WorkspaceStore.swift');
  const error = await source('apps/catalyst/ScrivUIKit/Shared/ProjectOpeningFailure.swift');
  for (const stage of ['rememberAccess', 'restoreAccess', 'recoverChanges', 'readProject', 'readCheckpoint', 'readHistory']) {
    assert.match(store, new RegExp('throw ProjectOpeningFailure\\.annotating\\(error, stage: \\.' + stage + '\\)'));
    assert.match(error, new RegExp('case ' + stage + ' ='));
  }
  assert.match(error, /if error is CancellationError \{ return error \}/);
  assert.match(error, /source\.userInfo\[NSUnderlyingErrorKey\] as\? NSError/);
  assert.doesNotMatch(error, /String\(describing:.*userInfo|dump\(|print\(|Logger\(|URLSession/);
});

test('scope/bookmark failures still throw and existing integrity, size and identity checks remain', async () => {
  const access = await source('apps/catalyst/ScrivUIKit/Shared/UIKitFileAccess.swift');
  const repository = await source('apps/mac/Sources/ScrivCore/ProjectRepository.swift');
  assert.match(access, /init\(defaults: UserDefaults = \.standard\)/);
  assert.match(access, /let scoped = url\.startAccessingSecurityScopedResource\(\)/);
  assert.match(access, /catch \{ if scoped \{ url\.stopAccessingSecurityScopedResource\(\) \}; throw error \}/);
  assert.match(access, /if scoped \{ retainedScopes\[key\] = url \}/);
  assert.match(access, /forOpeningContentTypes: types, asCopy: false/);
  assert.match(repository, /guard expected == actual, actual\.path\.hasPrefix\(root\.path \+ "\/"\)/);
  assert.match(repository, /guard size <= 64\*1024\*1024/);
  assert.match(repository, /event\.snapshot\.id == current\.id/);
  assert.match(repository, /Project packages cannot contain symbolic links/);
});

test('Catalyst retains external packages with persistent app-scoped bookmarks', async () => {
  const entitlements = JSON.parse(execFileSync('python3', ['-c', 'import json,plistlib,sys; print(json.dumps(plistlib.load(open(sys.argv[1],"rb"))))', new URL('apps/catalyst/ScrivUIKit.entitlements', root).pathname], { encoding: 'utf8' }));
  assert.equal(entitlements['com.apple.security.files.bookmarks.app-scope'], true);
  const access = await source('apps/catalyst/ScrivUIKit/Shared/UIKitFileAccess.swift');
  assert.match(access, /#if targetEnvironment\(macCatalyst\)[\s\S]*bookmarkCreationOptions[^\n]*\.withSecurityScope/);
  assert.match(access, /bookmarkResolutionOptions[^\n]*\.withSecurityScope/);
  assert.match(access, /bookmarkData\(options: Self\.bookmarkCreationOptions/g);
  assert.match(access, /URL\(resolvingBookmarkData: data, options: Self\.bookmarkResolutionOptions/);
});

test('native regression covers bookmark restore, exact package bytes, authored edits and immutable image identity', async () => {
  const native = await source('apps/catalyst/Tests/ScrivUIKitTests/ProjectPackageOpeningTests.swift');
  assert.match(native, /UIKitFileAccess\(defaults: defaults\)/);
  assert.match(native, /try pickerAccess\.rememberProject\(export\)/);
  assert.match(native, /try reopenedAccess\.restoreProjectAccess\(export\)/);
  assert.match(native, /XCTAssertEqual\(reopened, expected\)/);
  assert.match(native, /repository\.assetData\(asset, at: reopenedURL\)/);
  assert.match(native, /generationPrompt/);
  assert.match(native, /originalBytes/);
});
