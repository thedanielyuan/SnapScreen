import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cp, lstat, mkdir, mkdtemp, readFile, readdir, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { NATIVE_CSP, NATIVE_OPTIONS_PATH } from './extension-native-package.mjs';
import { describeFileChanges, hashFiles, hashSummary, selectNativeExtension } from './native-extension-artifact.mjs';
import { packageExtension, parsePackageArguments } from './package-extension.mjs';

const ROOT = resolve(import.meta.dirname, '..');

async function write(path, contents) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, contents);
}

async function fixture(t, variant = 'ordinary') {
  // Selection returns real paths; macOS temporary directories sit behind /var -> /private/var.
  const root = await realpath(await mkdtemp(join(tmpdir(), 'snapscreen-extension-selection-')));
  t.after(() => rm(root, { recursive: true, force: true }));
  const directory = join(root, variant === 'ordinary' ? 'dist' : 'dist-native');
  const manifest = {
    manifest_version: 3, minimum_chrome_version: '116', version: '1.2.3',
    permissions: ['activeTab', 'storage', 'nativeMessaging', ...(variant === 'ordinary' ? ['scripting'] : [])],
    host_permissions: ['https://api.anthropic.com/*'], optional_host_permissions: ['file:///*'],
    content_security_policy: { extension_pages: NATIVE_CSP },
    background: { service_worker: 'worker.js', type: 'module' },
    options_page: variant === 'ordinary' ? 'src/options/options.html' : NATIVE_OPTIONS_PATH,
    icons: { 16: 'icon.png' }, action: { default_icon: { 16: 'icon.png' } },
    commands: { snip: { suggested_key: { default: 'Alt+Shift+S' } } },
    ...(variant === 'ordinary' ? { web_accessible_resources: [{ resources: ['icon.png'], matches: ['https://*/*'] }] } : {}),
  };
  const saveManifest = () => write(join(directory, 'manifest.json'), JSON.stringify(manifest));
  await Promise.all([
    write(join(root, 'package.json'), '{"version":"1.2.3"}'),
    write(join(root, 'src/lib/native-protocol.ts'), 'export const NATIVE_PROTOCOL_VERSION = 3;\n'),
    write(join(root, 'native/macos/Protocol.swift'), 'let protocolVersion = 3\n'),
    saveManifest(),
    write(join(directory, 'worker.js'), "import './assets/shared.js';\n"),
    write(join(directory, 'assets/shared.js'), 'export const protocolVersion = 3;\n'),
    write(join(directory, 'assets/settings.js'), "import './shared.js';\n"),
    write(join(directory, manifest.options_page), '<script type="module" src="/assets/settings.js"></script>'),
    write(join(directory, 'icon.png'), Buffer.from([137, 80, 78, 71])),
  ]);
  return { root, directory, manifest, saveManifest };
}

test('defaults to ordinary dist independently of the caller working directory', async t => {
  const { root, directory } = await fixture(t);
  const selected = await selectNativeExtension(undefined, { root, cwd: '/' });
  assert.equal(selected.directory, directory);
  assert.equal(selected.variant, 'ordinary');
  assert.equal(selected.protocolVersion, 3);
  assert.equal(selected.sha256, hashSummary(selected.hashes));
  assert.deepEqual(Object.keys(selected.hashes), Object.keys(selected.hashes).sort());
  // The ordinary content bootstrap's legitimate marker must not look like a fixture hook.
  await write(join(directory, 'assets/shared.js'), 'globalThis.__snapscreenListenerReady = true;\n');
  await selectNativeExtension(directory, { root });
});

test('resolves relative native-only selection against cwd and records every file', async t => {
  const { root, directory } = await fixture(t, 'native-only');
  const selected = await selectNativeExtension('./dist-native', { root, cwd: root });
  assert.equal(selected.directory, directory);
  assert.equal(selected.variant, 'native-only');
  assert.deepEqual(selected.hashes, await hashFiles(directory));
  assert.equal(Object.keys(selected.hashes).length, 6);
});

test('selects the real build behind a symlink, so runner copies cannot write through to it', async t => {
  const { root, directory } = await fixture(t, 'native-only');
  await symlink(directory, join(root, 'linked-build'));
  const selected = await selectNativeExtension('linked-build', { root, cwd: root });
  assert.equal(selected.directory, directory);
  const copy = join(root, 'copy');
  await cp(selected.directory, copy, { recursive: true });
  assert.equal((await lstat(copy)).isSymbolicLink(), false);
  await assert.rejects(selectNativeExtension(join(root, 'linked-missing'), { root }),
    error => error.message.includes(`${join(root, 'linked-missing')}/manifest.json`));
});

test('summary and modification evidence include additions, removals, names, and byte changes', () => {
  const original = { 'z.js': 'a', 'same.js': 'b', 'removed.js': 'c' };
  const modified = { 'same.js': 'b', 'z.js': 'd', 'added.js': 'e' };
  assert.equal(hashSummary(original), hashSummary({ 'removed.js': 'c', 'same.js': 'b', 'z.js': 'a' }));
  assert.notEqual(hashSummary(original), hashSummary(modified));
  assert.notEqual(hashSummary({ old: 'a' }), hashSummary({ new: 'a' }));
  assert.deepEqual(describeFileChanges(original, modified), [
    { path: 'added.js', beforeSha256: null, afterSha256: 'e' },
    { path: 'removed.js', beforeSha256: 'c', afterSha256: null },
    { path: 'z.js', beforeSha256: 'a', afterSha256: 'd' },
  ]);
});

for (const variant of ['ordinary', 'native-only']) {
  test(`${variant} rejects missing, malformed, stale, and source manifests`, async t => {
    const { root, directory, manifest, saveManifest } = await fixture(t, variant);
    for (const value of ['', '  ', null]) {
      await assert.rejects(selectNativeExtension(value, { root }), /non-empty path/);
    }
    await assert.rejects(selectNativeExtension(join(root, 'missing'), { root }), /Could not read built extension manifest/);
    await write(join(directory, 'manifest.json'), '{');
    await assert.rejects(selectNativeExtension(directory, { root }), /Could not read built extension manifest/);
    await write(join(directory, 'manifest.json'), 'null');
    await assert.rejects(selectNativeExtension(directory, { root }), /Invalid built extension manifest/);
    manifest.version = '1.0.0';
    await saveManifest();
    await assert.rejects(selectNativeExtension(directory, { root }), /does not match package.json/);
    manifest.version = '1.2.3';
    manifest.background.service_worker = 'src/background/worker.ts';
    await write(join(directory, manifest.background.service_worker), 'export {};');
    await saveManifest();
    await assert.rejects(selectNativeExtension(directory, { root }), /Worker is not bundled JavaScript/);
  });

  test(`${variant} validates bundled worker/Settings and nativeMessaging before instrumentation`, async t => {
    const { root, directory, manifest, saveManifest } = await fixture(t, variant);
    manifest.permissions = manifest.permissions.filter(value => value !== 'nativeMessaging');
    await saveManifest();
    await assert.rejects(selectNativeExtension(directory, { root }), /must require nativeMessaging/);
    manifest.permissions.push('nativeMessaging');
    manifest.options_page = 'different.html';
    await saveManifest();
    await assert.rejects(selectNativeExtension(directory, { root }), /unrecognized Settings page/);
    manifest.options_page = variant === 'ordinary' ? 'src/options/options.html' : NATIVE_OPTIONS_PATH;
    await saveManifest();
    await write(join(directory, manifest.options_page), '<script type="module" src="./settings.ts"></script>');
    await assert.rejects(selectNativeExtension(directory, { root }), /unbundled script/);
    await write(join(directory, manifest.options_page), '<script type="module" src="/assets/settings.js"></script>');
    await write(join(directory, 'worker.js'), "import './missing.js';\n");
    await assert.rejects(selectNativeExtension(directory, { root }), /Missing packaged asset/);
  });

  for (const source of ['globalThis.__nativeLive = {};', 'globalThis.__packagedAction = [];', 'globalThis.__managedTypes = [];']) {
    test(`${variant} rejects fixture body ${source}`, async t => {
      const { root, directory } = await fixture(t, variant);
      await write(join(directory, 'assets/settings.js'), source);
      await assert.rejects(selectNativeExtension(directory, { root }), /[Tt]est hook/);
    });
  }

  test(`${variant} rejects symlinks and protocol drift`, async t => {
    const { root, directory } = await fixture(t, variant);
    await symlink(join(root, 'package.json'), join(directory, 'linked.json'));
    await assert.rejects(selectNativeExtension(directory, { root }), /Non-regular artifact entry/);
    await rm(join(directory, 'linked.json'));
    await write(join(root, 'native/macos/Protocol.swift'), 'let protocolVersion = 4\n');
    await assert.rejects(selectNativeExtension(directory, { root }), /protocol versions do not match/);
  });
}

test('native-only variant selection enforces package boundary before any fixture edits', async t => {
  const { root, directory, manifest, saveManifest } = await fixture(t, 'native-only');
  manifest.permissions.push('scripting');
  await saveManifest();
  await assert.rejects(selectNativeExtension(directory, { root }), /deep-equal/);
  manifest.permissions.pop();
  manifest.web_accessible_resources = [];
  await saveManifest();
  await assert.rejects(selectNativeExtension(directory, { root }), /exposes resources/);
  delete manifest.web_accessible_resources;
  await saveManifest();
  await write(join(directory, 'src/content/index.js'), 'export {};');
  await assert.rejects(selectNativeExtension(directory, { root }), /Excluded UI file/);
});

test('package argument parsing preserves ordinary default and rejects variant mistakes', () => {
  assert.deepEqual(parsePackageArguments([]), { help: false, variant: 'ordinary' });
  assert.deepEqual(parsePackageArguments(['--variant', 'native-only']), { help: false, variant: 'native-only' });
  assert.equal(parsePackageArguments(['--help']).help, true);
  for (const args of [['--variant'], ['--variant', 'native'], ['--variant', ''], ['--varaint', 'native-only'],
    ['--variant', 'ordinary', '--variant', 'native-only'], ['dist-native']]) {
    assert.throws(() => parsePackageArguments(args), /argument|variant/);
  }
});

test('native-only release ZIP is verified, distinct, and never overwrites the ordinary archive', async t => {
  const { root, directory } = await fixture(t, 'native-only');
  const release = join(root, 'release');
  const ordinaryPath = join(release, 'snapscreen-1.2.3.zip');
  await write(ordinaryPath, 'existing ordinary archive');
  const before = await hashFiles(directory);
  const packaged = await packageExtension({ root, variant: 'native-only' });
  assert.equal(packaged.archivePath, join(release, 'snapscreen-native-only-1.2.3.zip'));
  assert.equal(packaged.extensionSha256, hashSummary(before));
  assert.deepEqual(packaged.hashes, before);
  assert.equal((await readFile(packaged.archivePath)).subarray(0, 2).toString(), 'PK');
  assert.equal(await readFile(ordinaryPath, 'utf8'), 'existing ordinary archive');
  assert.deepEqual((await readdir(release)).sort(), ['snapscreen-1.2.3.zip', 'snapscreen-native-only-1.2.3.zip']);
  assert.deepEqual(await hashFiles(directory), before);
  await write(join(directory, 'assets/settings.js'), 'globalThis.__nativeLive = {};');
  const archive = await readFile(packaged.archivePath);
  await assert.rejects(packageExtension({ root, variant: 'native-only' }), /test hook/);
  assert.deepEqual(await readFile(packaged.archivePath), archive);
});

test('ordinary release keeps its filename/layout and excludes Finder metadata', async t => {
  const { root, directory } = await fixture(t);
  await write(join(directory, '.DS_Store'), 'Finder metadata');
  const packaged = await packageExtension({ root });
  assert.equal(packaged.archivePath, join(root, 'release/snapscreen-1.2.3.zip'));
  assert.ok(packaged.hashes['manifest.json']);
  assert.equal(packaged.hashes['.DS_Store'], undefined);
});

test('native-only packaging cannot silently select ordinary dist or a missing/stale build', async t => {
  const { root, directory } = await fixture(t);
  await assert.rejects(packageExtension({ root, variant: 'native-only' }), /Could not read built extension manifest/);
  await cp(directory, join(root, 'dist-native'), { recursive: true });
  await assert.rejects(packageExtension({ root, variant: 'native-only' }), /not the requested native-only variant/);
  await write(join(root, 'package.json'), '{"version":"2.0.0"}');
  await assert.rejects(packageExtension({ root }), /does not match package.json/);
});

for (const runner of ['native-companion-live-test.mjs', 'native-companion-packaged-test.mjs', 'native-companion-acceptance.mjs']) {
  test(`${runner} rejects CLI mistakes before native side effects`, async t => {
    const cwd = await mkdtemp(join(tmpdir(), 'snapscreen-runner-arguments-'));
    t.after(() => rm(cwd, { recursive: true, force: true }));
    for (const [args, expected] of [
      [['--extension-dri', 'dist-native'], /Unknown option/],
      [['--extension-dir'], /argument missing|requires an argument/],
      [['--extension-dir', ''], /non-empty path/],
      [['--extension-dir', 'missing-build'], /Could not read built extension manifest/],
    ]) {
      const result = spawnSync(process.execPath, [join(ROOT, 'scripts', runner), ...args], { cwd, encoding: 'utf8', timeout: 10_000 });
      assert.equal(result.error, undefined);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, expected);
      if (args[1] === 'missing-build') assert.ok(result.stderr.includes(join(cwd, 'missing-build')));
      assert.deepEqual(await readdir(cwd), []);
    }
    const help = spawnSync(process.execPath, [join(ROOT, 'scripts', runner), '--help'], { cwd, encoding: 'utf8', timeout: 10_000 });
    assert.equal(help.status, 0);
    assert.match(help.stdout, /--extension-dir/);
  });
}
