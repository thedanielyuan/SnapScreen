import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { inspectNativeExtension, NATIVE_CSP, NATIVE_OPTIONS_PATH, verifyNativeArchive } from './extension-native-package.mjs';

async function write(path, content) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, content);
}

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'snapscreen-native-package-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const directory = join(root, 'dist-native');
  const manifest = {
    manifest_version: 3,
    minimum_chrome_version: '116',
    version: '1.2.3',
    permissions: ['activeTab', 'storage', 'nativeMessaging'],
    host_permissions: ['https://api.anthropic.com/*'],
    optional_host_permissions: ['file:///*'],
    content_security_policy: { extension_pages: NATIVE_CSP },
    background: { service_worker: 'service-worker-loader.js', type: 'module' },
    options_page: NATIVE_OPTIONS_PATH,
    icons: { 16: 'icon.png' },
    action: { default_icon: { 16: 'icon.png' } },
    commands: { snip: { suggested_key: { default: 'Alt+Shift+S' } } },
  };
  await Promise.all([
    write(join(root, 'package.json'), '{"version":"1.2.3"}'),
    write(join(root, 'src/lib/native-protocol.ts'), 'export const NATIVE_PROTOCOL_VERSION = 3;\n'),
    write(join(root, 'native/macos/Protocol.swift'), 'let protocolVersion = 3\n'),
    write(join(directory, 'manifest.json'), JSON.stringify(manifest)),
    write(join(directory, 'service-worker-loader.js'), "import './assets/worker.js';\n"),
    write(join(directory, 'assets/worker.js'), "import { version } from './protocol.js'; globalThis.version = version;\n"),
    write(join(directory, 'assets/protocol.js'), 'export const version = 3;\n'),
    write(join(directory, 'assets/settings.js'), "import { version } from './protocol.js'; document.title = String(version);\n"),
    write(join(directory, 'assets/settings.css'), 'body { color: black; }\n'),
    write(join(directory, NATIVE_OPTIONS_PATH), '<!doctype html><html><head>'
      + '<script type="module" src="/assets/settings.js"></script>'
      + '<link rel="stylesheet" href="/assets/settings.css"></head><body></body></html>'),
    write(join(directory, 'icon.png'), Buffer.from([137, 80, 78, 71])),
  ]);
  return {
    root, directory, manifest,
    saveManifest: () => write(join(directory, 'manifest.json'), JSON.stringify(manifest)),
  };
}

test('inspects the complete packaged Settings/worker graph and round-trips it through a ZIP', async t => {
  const { root, directory } = await fixture(t);
  const built = await inspectNativeExtension(directory, { root });
  assert.equal(built.protocolVersion, 3);
  assert.equal(built.manifest.version, '1.2.3');
  assert.equal(built.files.length, 8);
  assert.ok(Object.values(built.hashes).every(hash => /^[a-f\d]{64}$/u.test(hash)));
  const extracted = await verifyNativeArchive(directory, root, { root });
  assert.notEqual(extracted.extensionDirectory, directory);
  assert.match(extracted.archivePath, /snapscreen-native-only-1\.2\.3\.zip$/u);
  assert.deepEqual(extracted.hashes, built.hashes);
  assert.equal((await readFile(extracted.archivePath)).subarray(0, 2).toString(), 'PK');
});

for (const [name, modify, message] of [
  ['scripting permission', manifest => { manifest.permissions.push('scripting'); }, /Expected values to be strictly deep-equal/],
  ['optional injection permission', manifest => { manifest.optional_permissions = ['scripting']; }, /optional permissions/],
  ['content declaration', manifest => { manifest.content_scripts = []; }, /content scripts/],
  ['web-accessible declaration', manifest => { manifest.web_accessible_resources = []; }, /exposes resources/],
  ['wrong package version', manifest => { manifest.version = '9.9.9'; }, /version must match/],
  ['relaxed CSP', manifest => { manifest.content_security_policy.extension_pages += "; frame-src https:"; }, /Expected values to be strictly deep-equal/],
  ['missing worker', manifest => { manifest.background.service_worker = 'missing.js'; }, /Missing packaged asset/],
  ['outside icon', manifest => { manifest.icons['16'] = '../icon.png'; }, /escapes package/],
]) {
  test(`rejects ${name}`, async t => {
    const { root, directory, manifest, saveManifest } = await fixture(t);
    modify(manifest);
    await saveManifest();
    await assert.rejects(inspectNativeExtension(directory, { root }), message);
  });
}

for (const [name, file, source, message] of [
  ['content bundle', 'src/content/index.js', 'export {};', /Excluded UI file/],
  ['hashed injected bundle', 'assets/content-a1b2.js', 'export {};', /Excluded UI file/],
  ['result frame', 'src/ui/result-frame.html', '<html></html>', /Excluded UI file/],
  ['workspace', 'src/workspace/workspace.html', '<html></html>', /Excluded UI file/],
  ['orphan code', 'assets/extra.js', 'export {};', /unreferenced assets/],
  ['test shim filename', 'assets/native-acceptance-shim.js', 'export {};', /Test-only file/],
  ['live-test hooks', 'assets/settings.js', 'globalThis.SNAPSCREEN_TEST_HOOKS = true;', /test hook/],
  ['live-test observer', 'assets/settings.js', 'globalThis.__nativeLive = {};', /test hook/],
  ['acceptance shim body', 'assets/settings.js', 'function installAcceptanceShim() {}', /test hook/],
  ['minified acceptance shim', 'assets/settings.js', 'globalThis.nativeAcceptance = {};', /test hook/],
  ['browser shim body', 'assets/settings.js', 'globalThis.__snapscreenNativeActions = [];', /test hook/],
  ['injection API', 'assets/settings.js', "chrome['scripting'].executeScript({});", /Script injection API/],
  ['missing dependency', 'assets/settings.js', "import './missing.js';", /Missing packaged asset/],
  ['remote dependency', 'assets/settings.js', "import 'https://example.com/code.js';", /Non-local asset/],
  ['nonliteral import', 'assets/settings.js', 'import(globalThis.modulePath);', /Non-literal dynamic import/],
  ['unbundled Settings', NATIVE_OPTIONS_PATH, '<script type="module" src="./options-native.ts"></script>', /unbundled script/],
  ['inline Settings', NATIVE_OPTIONS_PATH, '<script type="module" src="/assets/settings.js">alert(1)</script>', /Inline Settings script/],
  ['remote Settings', NATIVE_OPTIONS_PATH, '<script type="module" src="https://example.com/code.js"></script>', /Non-local asset/],
  ['remote CSS', 'assets/settings.css', '@import "https://example.com/style.css";', /Non-local asset/],
]) {
  test(`rejects ${name} even when the manifest is valid`, async t => {
    const { root, directory } = await fixture(t);
    await write(join(directory, file), source);
    await assert.rejects(inspectNativeExtension(directory, { root }), message);
  });
}

test('rejects extension/companion protocol drift', async t => {
  const { root, directory } = await fixture(t);
  await write(join(root, 'native/macos/Protocol.swift'), 'let protocolVersion = 4\n');
  await assert.rejects(inspectNativeExtension(directory, { root }), /protocol versions do not match/);
});

test('rejects symlinks before creating an archive', async t => {
  const { root, directory } = await fixture(t);
  await symlink(join(root, 'package.json'), join(directory, 'linked.json'));
  await assert.rejects(verifyNativeArchive(directory, root, { root }), /Non-regular package entry/);
});

test('re-inspects extracted artifacts and rejects changes after a valid archive round-trip', async t => {
  const { root, directory } = await fixture(t);
  const { extensionDirectory } = await verifyNativeArchive(directory, root, { root });
  await write(join(extensionDirectory, 'assets/settings.js'), 'globalThis.SNAPSCREEN_TEST_HOOKS = true;');
  await assert.rejects(inspectNativeExtension(extensionDirectory, { root }), /test hook/);
});
