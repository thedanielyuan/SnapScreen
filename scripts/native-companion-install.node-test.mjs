import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, readdir, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const installer = fileURLToPath(new URL('./native-companion-install.mjs', import.meta.url));
const extensionId = 'abcdefghijklmnopabcdefghijklmnop';
const hostName = 'com.snapscreen.companion';

test('registration requires explicit browser root and exact extension identity; removes only its matching fixture',
  { skip: process.platform !== 'darwin' }, async () => {
    const fixture = await mkdtemp(join(tmpdir(), 'snapscreen-native-install-'));
    try {
      const browserRoot = join(fixture, 'browser');
      const executable = join(fixture, 'fixture-executable');
      await mkdir(browserRoot);
      await writeFile(executable, '#!/bin/sh\nexit 0\n', { mode: 0o700 });
      const run = (...args) => spawnSync(process.execPath, [installer, ...args], { encoding: 'utf8' });
      const args = ['--extension-id', extensionId, '--user-data-dir', browserRoot, '--executable', executable];
      for (const invalid of [[], ['--extension-id', extensionId], ['--extension-id', '*', '--user-data-dir', browserRoot],
        ['--extension-id', `${extensionId}\n`, '--user-data-dir', browserRoot],
        ['--extension-id', extensionId, '--user-data-dir', 'relative']]) {
        assert.notEqual(run(...invalid).status, 0);
      }
      assert.equal(run(...args).status, 0);
      const manifestPath = join(browserRoot, 'NativeMessagingHosts', `${hostName}.json`);
      const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
      assert.deepEqual(manifest, { name: hostName, description: 'SnapScreen macOS companion',
        path: await realpath(executable), type: 'stdio',
        allowed_origins: [`chrome-extension://${extensionId}/`] });
      assert.equal(run(...args).status, 0, 'same registration can be upgraded');
      const different = { ...manifest, allowed_origins: ['chrome-extension://pppppppppppppppppppppppppppppppp/'] };
      await writeFile(manifestPath, JSON.stringify(different));
      assert.notEqual(run(...args).status, 0, 'conflicting extension cannot be overwritten');
      assert.notEqual(run(...args, '--remove').status, 0, 'conflicting extension cannot be removed');
      assert.deepEqual(JSON.parse(await readFile(manifestPath, 'utf8')), different);
      await writeFile(manifestPath, JSON.stringify(manifest));
      assert.equal(run(...args, '--remove').status, 0);
      await assert.rejects(readFile(manifestPath), { code: 'ENOENT' });
      assert.equal(run(...args, '--remove').status, 0, 'removing absent registration is harmless');
    } finally {
      await rm(fixture, { recursive: true, force: true });
    }
  });

async function packagedFixture(runTest) {
  const fixture = await mkdtemp(join(tmpdir(), 'snapscreen-packaged-install-'));
  try {
    const browserRoot = join(fixture, 'browser');
    const secondBrowser = join(fixture, 'second-browser');
    const installDirectory = join(fixture, 'installed');
    const source = join(fixture, 'source', 'SnapScreenCompanion.app');
    await mkdir(browserRoot);
    await mkdir(secondBrowser);
    await mkdir(join(source, 'Contents/MacOS'), { recursive: true });
    await mkdir(join(source, 'Contents/Resources'), { recursive: true });
    const sourceExecutable = join(source, 'Contents/MacOS/SnapScreenCompanion');
    const metadata = { schemaVersion: 1, bundleIdentifier: hostName, version: '1.1.0', protocolVersion: 3,
      testHooks: false, minimumMacOSVersion: '13.0', architectures: ['arm64'] };
    async function writeBundle(version = '1.1.0', extraMetadata = {}, output = 'Native companion self-test: 10 checks passed') {
      await writeFile(sourceExecutable, `#!/bin/sh\nprintf '%s\\n' '${output}'\n`, { mode: 0o700 });
      await writeFile(join(source, 'Contents/Resources/snapscreen-build.json'), JSON.stringify({ ...metadata, version, ...extraMetadata }));
      await writeFile(join(source, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${hostName}</string>
<key>CFBundleExecutable</key><string>SnapScreenCompanion</string>
<key>CFBundleVersion</key><string>${version}</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
</dict></plist>`);
    }
    await writeBundle();
    const run = (...args) => spawnSync(process.execPath, [installer,
      '--extension-id', extensionId, '--user-data-dir', browserRoot,
      '--install-dir', installDirectory, ...args], { encoding: 'utf8' });
    const manifestPath = join(browserRoot, 'NativeMessagingHosts', `${hostName}.json`);
    const receiptPath = join(installDirectory, 'install-receipt.json');
    await runTest({ fixture, browserRoot, secondBrowser, installDirectory, source, sourceExecutable, manifestPath,
      receiptPath, writeBundle, run });
  } finally { await rm(fixture, { recursive: true, force: true }); }
}

const macOnly = { skip: process.platform !== 'darwin' };
function succeeds(result) { assert.equal(result.status, 0, result.stderr || result.stdout); }

// These fixtures intentionally use a tiny shell self-test, not the machine's installed companion.
test('packaged install copies to a stable path, survives source removal, and safely uninstalls', macOnly, async () => {
  await packagedFixture(async ({ source, manifestPath, receiptPath, installDirectory, run }) => {
    succeeds(run('--app', source));
    const installed = join(await realpath(installDirectory), 'SnapScreenCompanion.app/Contents/MacOS/SnapScreenCompanion');
    const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
    assert.equal(manifest.path, installed);
    assert.deepEqual(manifest.allowed_origins, [`chrome-extension://${extensionId}/`]);
    assert.equal(JSON.parse(await readFile(receiptPath, 'utf8')).version, '1.1.0');
    await rm(source, { recursive: true });
    assert.equal(spawnSync(installed, ['--self-test']).status, 0);
    succeeds(run('--remove'));
    for (const path of [manifestPath, receiptPath, join(installDirectory, 'SnapScreenCompanion.app')]) {
      await assert.rejects(readFile(path), { code: 'ENOENT' });
    }
    succeeds(run('--remove'));
  });
});

test('packaged upgrades retain multiple exact browser registrations and reject downgrades', macOnly, async () => {
  await packagedFixture(async ({ source, secondBrowser, installDirectory, receiptPath, writeBundle, run }) => {
    succeeds(run('--app', source));
    const secondId = 'pppppppppppppppppppppppppppppppp';
    const secondArgs = ['--extension-id', secondId, '--user-data-dir', secondBrowser];
    succeeds(run('--app', source, ...secondArgs));
    await writeBundle('1.2.0');
    succeeds(run('--app', source));
    let receipt = JSON.parse(await readFile(receiptPath, 'utf8'));
    assert.equal(receipt.version, '1.2.0');
    assert.equal(receipt.registrations.length, 2);
    await writeBundle('1.1.0');
    assert.match(run('--app', source).stderr, /Refusing to downgrade/);
    succeeds(run('--remove'));
    receipt = JSON.parse(await readFile(receiptPath, 'utf8'));
    assert.equal(receipt.registrations.length, 1);
    assert.equal(receipt.registrations[0].origin, `chrome-extension://${secondId}/`);
    await readFile(join(installDirectory, 'SnapScreenCompanion.app/Contents/Info.plist'));
    succeeds(run('--remove', ...secondArgs));
    await assert.rejects(readFile(receiptPath), { code: 'ENOENT' });
  });
});

test('packaged installer rejects hook bundles and inconsistent versions before registration', macOnly, async () => {
  await packagedFixture(async ({ source, manifestPath, writeBundle, run }) => {
    await writeBundle('1.1.0', { testHooks: true });
    assert.notEqual(run('--app', source).status, 0);
    await writeBundle('1.1.0', {}, 'Native companion self-test: 10 checks passed (test hooks build)');
    assert.match(run('--app', source).stderr, /test hooks/);
    await writeBundle('1.1.0', { version: '1.2.0' });
    assert.notEqual(run('--app', source).status, 0);
    await assert.rejects(readFile(manifestPath), { code: 'ENOENT' });
  });
});

test('packaged installer refuses changed app content and conflicting manifests without deleting either', macOnly, async () => {
  await packagedFixture(async ({ source, manifestPath, installDirectory, run }) => {
    succeeds(run('--app', source));
    const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
    const different = { ...manifest, path: '/some/other/companion' };
    await writeFile(manifestPath, JSON.stringify(different));
    assert.notEqual(run('--app', source).status, 0);
    assert.notEqual(run('--remove').status, 0);
    assert.deepEqual(JSON.parse(await readFile(manifestPath, 'utf8')), different);
    await writeFile(manifestPath, JSON.stringify(manifest));
    const changedFile = join(installDirectory, 'SnapScreenCompanion.app/Contents/Resources/unowned.txt');
    await writeFile(changedFile, 'Do not delete this file.');
    assert.match(run('--remove').stderr, /changed outside this installer/);
    assert.match(run('--app', source).stderr, /changed outside this installer/);
    assert.equal(await readFile(changedFile, 'utf8'), 'Do not delete this file.');
    assert.deepEqual(JSON.parse(await readFile(manifestPath, 'utf8')), manifest);
  });
});

test('packaged installer refuses unowned destination apps and linked registration directories', macOnly, async () => {
  await packagedFixture(async ({ source, installDirectory, browserRoot, fixture, run }) => {
    const unowned = join(installDirectory, 'SnapScreenCompanion.app');
    await mkdir(unowned, { recursive: true });
    await writeFile(join(unowned, 'keep.txt'), 'keep');
    assert.match(run('--app', source).stderr, /unowned app/);
    assert.equal(await readFile(join(unowned, 'keep.txt'), 'utf8'), 'keep');
    await rm(unowned, { recursive: true });
    const elsewhere = join(fixture, 'elsewhere');
    await mkdir(elsewhere);
    await symlink(elsewhere, join(browserRoot, 'NativeMessagingHosts'));
    assert.match(run('--app', source).stderr, /symbolic link/);
    assert.deepEqual(await readdir(elsewhere), []);
  });
});

test('installer rejects profile folders and empty paths, and removal creates no install folder', macOnly, async () => {
  await packagedFixture(async ({ fixture, source, browserRoot, manifestPath, run }) => {
    const profileFolder = join(browserRoot, 'Default');
    await mkdir(profileFolder);
    await writeFile(join(profileFolder, 'Preferences'), '{}');
    assert.match(run('--app', source, '--user-data-dir', profileFolder).stderr, /profile folder/);
    assert.match(run('--app', source, '--install-dir', '').stderr, /--install-dir must be absolute/);
    const missing = join(fixture, 'missing-install');
    succeeds(run('--remove', '--install-dir', missing));
    await assert.rejects(readdir(missing), { code: 'ENOENT' });
    await assert.rejects(readFile(manifestPath), { code: 'ENOENT' });
  });
});

test('development registrations, deleted apps, and leftover registrations never block removal', macOnly, async () => {
  await packagedFixture(async ({ fixture, source, browserRoot, secondBrowser }) => {
    // A copied installer resolves its development default inside this fixture, not the checkout.
    const copied = join(fixture, 'checkout/scripts/native-companion-install.mjs');
    const developmentHost = join(fixture, 'checkout/native/macos/build/SnapScreenCompanion.app/Contents/MacOS/SnapScreenCompanion');
    await mkdir(dirname(copied), { recursive: true });
    await mkdir(dirname(developmentHost), { recursive: true });
    await writeFile(copied, await readFile(installer));
    await writeFile(developmentHost, '#!/bin/sh\nexit 0\n', { mode: 0o700 });
    const home = join(fixture, 'home');
    await mkdir(home);
    // The default managed location contains a space, like the real Application Support path.
    const run = (root, ...args) => spawnSync(process.execPath, [copied, '--extension-id', extensionId,
      '--user-data-dir', root, ...args], { encoding: 'utf8', env: { ...process.env, HOME: home } });
    const installDirectory = join(await realpath(home), 'Library/Application Support/SnapScreen');
    const manifest = root => join(root, 'NativeMessagingHosts', `${hostName}.json`);
    succeeds(run(browserRoot, '--app', source));
    succeeds(run(secondBrowser));
    assert.equal(JSON.parse(await readFile(manifest(secondBrowser), 'utf8')).path, await realpath(developmentHost));
    succeeds(run(secondBrowser, '--remove'));
    await assert.rejects(readFile(manifest(secondBrowser)), { code: 'ENOENT' });
    assert.equal(JSON.parse(await readFile(join(installDirectory, 'install-receipt.json'), 'utf8')).registrations.length, 1);
    // An app deleted outside the installer can be reinstalled, and its record removed.
    await rm(join(installDirectory, 'SnapScreenCompanion.app'), { recursive: true });
    succeeds(run(browserRoot, '--app', source));
    await rm(join(installDirectory, 'SnapScreenCompanion.app'), { recursive: true });
    assert.match(run(browserRoot, '--remove').stdout, /missing managed app/);
    await assert.rejects(readFile(manifest(browserRoot)), { code: 'ENOENT' });
    await assert.rejects(readdir(installDirectory), { code: 'ENOENT' }, 'the empty default folder is removed');
    // Deleting the whole folder leaves a registration that removal still cleans up.
    succeeds(run(browserRoot, '--app', source));
    await rm(installDirectory, { recursive: true });
    succeeds(run(browserRoot, '--remove'));
    await assert.rejects(readFile(manifest(browserRoot)), { code: 'ENOENT' });
    await assert.rejects(readdir(installDirectory), { code: 'ENOENT' });
  });
});

test('failed upgrade leaves the working app and receipt intact', macOnly, async () => {
  await packagedFixture(async ({ source, sourceExecutable, receiptPath, manifestPath, run }) => {
    succeeds(run('--app', source));
    const receipt = await readFile(receiptPath, 'utf8');
    const manifest = await readFile(manifestPath, 'utf8');
    await writeFile(sourceExecutable, '#!/bin/sh\nexit 1\n', { mode: 0o700 });
    assert.notEqual(run('--app', source).status, 0);
    assert.equal(await readFile(receiptPath, 'utf8'), receipt);
    assert.equal(await readFile(manifestPath, 'utf8'), manifest);
    assert.equal(spawnSync(JSON.parse(manifest).path, ['--self-test']).status, 0);
  });
});

test('uninstall restores registration only when the app rollback succeeded', macOnly, async () => {
  for (const failRestore of [false, true]) {
    await packagedFixture(async ({ fixture, source, installDirectory, receiptPath, manifestPath, browserRoot, run }) => {
      succeeds(run('--app', source));
      const manifest = await readFile(manifestPath, 'utf8');
      const receipt = await readFile(receiptPath, 'utf8');
      const canonicalDirectory = await realpath(installDirectory);
      const bundle = join(canonicalDirectory, 'SnapScreenCompanion.app');
      // Inject filesystem errors at the actual commit and rollback boundaries in a child process.
      // No installer-only hooks or machine-wide filesystem changes are needed.
      const preload = join(fixture, 'fail-uninstall.mjs');
      await writeFile(preload, `import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
const unlink = fs.promises.unlink;
const rename = fs.promises.rename;
fs.promises.unlink = async path => {
  if (path === ${JSON.stringify(join(canonicalDirectory, 'install-receipt.json'))}) {
    throw Object.assign(new Error('Injected receipt removal failure'), { code: 'EACCES' });
  }
  return unlink(path);
};
fs.promises.rename = async (from, to) => {
  if (${failRestore} && to === ${JSON.stringify(bundle)} && from.includes('/.uninstall-')) {
    throw Object.assign(new Error('Injected app restore failure'), { code: 'EACCES' });
  }
  return rename(from, to);
};
syncBuiltinESMExports();
`);
      const result = spawnSync(process.execPath, ['--import', preload, installer,
        '--extension-id', extensionId, '--user-data-dir', browserRoot,
        '--install-dir', installDirectory, '--remove'], { encoding: 'utf8' });
      assert.notEqual(result.status, 0);
      assert.equal(await readFile(receiptPath, 'utf8'), receipt);
      if (failRestore) {
        assert.match(result.stderr, /previous app is preserved/);
        await assert.rejects(readFile(manifestPath), { code: 'ENOENT' });
        await assert.rejects(readFile(join(bundle, 'Contents/Info.plist')), { code: 'ENOENT' });
        const recovery = (await readdir(installDirectory)).find(name => name.startsWith('.uninstall-'));
        assert.ok(recovery);
        assert.equal(spawnSync(join(installDirectory, recovery,
          'SnapScreenCompanion.app/Contents/MacOS/SnapScreenCompanion'), ['--self-test']).status, 0);
      } else {
        assert.match(result.stderr, /Injected receipt removal failure/);
        assert.equal(await readFile(manifestPath, 'utf8'), manifest);
        assert.equal(spawnSync(JSON.parse(manifest).path, ['--self-test']).status, 0);
      }
    });
  }
});
