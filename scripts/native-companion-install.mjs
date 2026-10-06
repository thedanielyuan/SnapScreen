import { constants } from 'node:fs';
import { access, lstat, mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, rmdir, unlink, writeFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const hostName = 'com.snapscreen.companion';
const appName = 'SnapScreenCompanion.app';
const executableRelative = 'Contents/MacOS/SnapScreenCompanion';
const receiptName = 'install-receipt.json';
const defaultExecutable = fileURLToPath(new URL('../native/macos/build/SnapScreenCompanion.app/Contents/MacOS/SnapScreenCompanion', import.meta.url));
const defaultInstallDirectory = join(homedir(), 'Library/Application Support/SnapScreen');

function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 30_000, maxBuffer: 1024 * 1024 });
  if (result.error || result.status !== 0) throw new Error(`${command} failed: ${result.error?.message ?? result.stderr.trim()}`);
  return result.stdout;
}

async function optionalRead(path) {
  try { return await readFile(path, 'utf8'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; return undefined; }
}

async function exists(path) {
  try { await lstat(path); return true; }
  catch (error) { if (error.code !== 'ENOENT') throw error; return false; }
}

// Canonicalize existing parents, including macOS /var -> /private/var, for durable receipts.
async function canonicalPath(path) {
  try { return await realpath(path); }
  catch (error) {
    if (error.code !== 'ENOENT' || dirname(path) === path) throw error;
    return join(await canonicalPath(dirname(path)), basename(path));
  }
}

async function plainPath(path, directory = false) {
  const info = await lstat(path);
  if (info.isSymbolicLink() || (directory ? !info.isDirectory() : !info.isFile())) {
    throw new Error(`Expected an ordinary ${directory ? 'directory' : 'file'}, without a symbolic link: ${path}`);
  }
}

async function digestBundle(bundle) {
  const hash = createHash('sha256');
  async function visit(path, relative) {
    const info = await lstat(path);
    if (info.isDirectory()) {
      hash.update(`directory:${relative}\0`);
      for (const name of (await readdir(path)).sort()) await visit(join(path, name), `${relative}/${name}`);
    } else if (info.isFile()) {
      hash.update(`file:${relative}:${info.mode & 0o777}:${info.size}\0`);
      hash.update(await readFile(path));
    } else {
      throw new Error(`Companion bundles must not contain symbolic links or special files: ${path}`);
    }
  }
  await visit(bundle, '');
  return hash.digest('hex');
}

async function inspectBundle(bundle) {
  await plainPath(bundle, true);
  const digest = await digestBundle(bundle);
  const invalid = new Error('The app is not a versioned production SnapScreen companion bundle.');
  let metadata;
  let plist;
  try {
    metadata = JSON.parse(await readFile(join(bundle, 'Contents/Resources/snapscreen-build.json'), 'utf8'));
    plist = JSON.parse(run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', join(bundle, 'Contents/Info.plist')]));
  } catch { throw invalid; }
  if (metadata?.schemaVersion !== 1 || metadata.bundleIdentifier !== hostName || metadata.testHooks !== false ||
    !/^\d+\.\d+\.\d+$/.test(metadata.version) || !Number.isSafeInteger(metadata.protocolVersion) || metadata.protocolVersion < 1 ||
    !Array.isArray(metadata.architectures) || metadata.architectures.length < 1 ||
    metadata.architectures.some(value => !['arm64', 'x86_64'].includes(value)) ||
    plist?.CFBundleIdentifier !== hostName || plist.CFBundleExecutable !== 'SnapScreenCompanion' ||
    plist.CFBundleShortVersionString !== metadata.version || plist.CFBundleVersion !== metadata.version) {
    throw invalid;
  }
  const executable = join(bundle, executableRelative);
  await access(executable, constants.X_OK);
  const output = run(executable, ['--self-test']);
  if (!/^Native companion self-test: \d+ checks passed\s*$/.test(output)) {
    throw new Error('The app failed production self-test validation or contains live-test hooks.');
  }
  return { version: metadata.version, protocolVersion: metadata.protocolVersion, digest };
}

function manifestFor(executable, origin) {
  return { name: hostName, description: 'SnapScreen macOS companion', path: executable,
    type: 'stdio', allowed_origins: [origin] };
}

function matchesManifest(value, executable, origin) {
  return value?.name === hostName && value.type === 'stdio' && value.path === executable &&
    Array.isArray(value.allowed_origins) && value.allowed_origins.length === 1 && value.allowed_origins[0] === origin;
}

async function registeredExecutable(path) {
  try {
    const value = JSON.parse(await optionalRead(path) ?? 'null');
    return typeof value?.path === 'string' ? value.path : undefined;
  } catch { return undefined; }
}

async function checkManifest(path, executable, origin) {
  try { await plainPath(dirname(path), true); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  const text = await optionalRead(path);
  if (text === undefined) return undefined;
  await plainPath(path);
  let value;
  try { value = JSON.parse(text); } catch { /* Reported below as a different registration. */ }
  if (!matchesManifest(value, executable, origin)) {
    throw new Error(`A different host registration exists at ${path} (executable ${JSON.stringify(value?.path ?? null)}, `
      + `origins ${JSON.stringify(value?.allowed_origins ?? null)}). Remove that registration explicitly before continuing: `
      + '--remove with its --executable path for a development build, or with --install-dir for a managed app elsewhere.');
  }
  return text;
}

async function writeAtomic(path, contents) {
  const temporary = join(dirname(path), `.${hostName}-${randomUUID()}.tmp`);
  try {
    await writeFile(temporary, contents, { mode: 0o600, flag: 'wx' });
    await rename(temporary, path);
  } finally { await rm(temporary, { force: true }); }
}

async function writeJson(path, value) {
  await writeAtomic(path, `${JSON.stringify(value, null, 2)}\n`);
}

function compareVersions(first, second) {
  const a = first.split('.').map(Number);
  const b = second.split('.').map(Number);
  for (let index = 0; index < 3; index += 1) if (a[index] !== b[index]) return a[index] - b[index];
  return 0;
}

/** Returns true when the final registration was removed together with the managed app/receipt. */
async function managedInstall({ values, installDirectory, location, origin }) {
  const bundle = join(installDirectory, appName);
  const executable = join(bundle, executableRelative);
  const receiptPath = join(installDirectory, receiptName);
  const lock = join(installDirectory, '.install-lock');
  if (values.remove && !await exists(installDirectory)) {
    // Nothing is installed. Remove only a leftover registration naming this exact app and origin.
    const previous = await checkManifest(location, executable, origin);
    if (previous !== undefined) await unlink(location);
    console.log(`${previous === undefined ? 'No registration at' : 'Removed'} ${location}`);
    return false;
  }
  await mkdir(installDirectory, { recursive: true, mode: 0o700 });
  await plainPath(installDirectory, true);
  try { await mkdir(lock, { mode: 0o700 }); }
  catch (error) {
    if (error.code === 'EEXIST') throw new Error(`Another installer may be running. If it stopped, remove the empty lock directory ${lock} and retry.`, { cause: error });
    throw error;
  }
  try {
    const oldReceipt = await optionalRead(receiptPath);
    let receipt = oldReceipt === undefined ? undefined : JSON.parse(oldReceipt);
    // An app deleted outside the installer must not block reinstalling or removing its registrations.
    const appInstalled = await exists(bundle);
    if (receipt) {
      await plainPath(receiptPath);
      if (receipt.schemaVersion !== 1 || receipt.bundleIdentifier !== hostName || receipt.bundlePath !== bundle ||
        !/^\d+\.\d+\.\d+$/.test(receipt.version) || !Array.isArray(receipt.registrations) ||
        receipt.registrations.length === 0 || new Set(receipt.registrations.map(value => value?.path)).size !== receipt.registrations.length ||
        !/^[a-f0-9]{64}$/.test(receipt.digest) || receipt.registrations.some(registration => !registration ||
          typeof registration.path !== 'string' || !isAbsolute(registration.path) ||
          !registration.path.endsWith(`/NativeMessagingHosts/${hostName}.json`) ||
          !/^chrome-extension:\/\/[a-p]{32}\/$/.test(registration.origin))) {
        throw new Error('The install receipt is invalid. No installed files were changed.');
      }
      if (appInstalled && await digestBundle(bundle) !== receipt.digest) {
        throw new Error(`The installed app at ${bundle} changed outside this installer. No installed files were changed. `
          + 'Move that app elsewhere, then rerun this command.');
      }
      // A shared app must not be upgraded or deleted while a recorded browser points elsewhere.
      const present = [];
      for (const registration of receipt.registrations) {
        if (await checkManifest(registration.path, executable, registration.origin) !== undefined) present.push(registration);
      }
      receipt.registrations = present;
    } else if (appInstalled && !values.remove) {
      throw new Error(`An unowned app exists at ${bundle}. Leave it intact or move it explicitly first.`);
    }
    const previousManifest = await checkManifest(location, executable, origin);
    const registrations = receipt?.registrations.filter(registration => registration.path !== location) ?? [];
    if (values.remove) {
      // checkManifest matched this exact app path and origin, so removal needs no receipt entry.
      if (previousManifest !== undefined) await unlink(location);
      let appAvailable = appInstalled;
      try {
        if (registrations.length > 0) await writeJson(receiptPath, { ...receipt, registrations });
        else if (receipt && appInstalled) {
          // Rename first: a failed directory removal cannot leave a live registration pointing at a missing app.
          const trash = await mkdtemp(join(installDirectory, '.uninstall-'));
          await rename(bundle, join(trash, appName));
          appAvailable = false;
          try { await unlink(receiptPath); }
          catch (error) {
            try { await rename(join(trash, appName), bundle); appAvailable = true; }
            catch (rollbackError) {
              throw new AggregateError([error, rollbackError], `Uninstall rollback failed. The previous app is preserved at ${trash}.`, { cause: rollbackError });
            }
            throw error;
          }
          // The uninstall is committed. A cleanup error must not resurrect a dangling registration.
          await rm(trash, { recursive: true, force: true }).catch(() => console.error(`Remove the leftover app backup manually: ${trash}`));
        } else if (receipt) await unlink(receiptPath);
      } catch (error) {
        // Failed app restoration leaves its backup for recovery; never recreate a dangling host.
        if (previousManifest !== undefined && appAvailable) await writeAtomic(location, previousManifest);
        throw error;
      }
      const uninstalled = receipt !== undefined && registrations.length === 0;
      console.log([`${previousManifest === undefined ? 'No registration at' : 'Removed'} ${location}`,
        ...(uninstalled ? [appInstalled ? 'Removed the managed companion app.' : 'Removed the record of the missing managed app.'] : []),
        ...(!receipt && appInstalled ? [`Left an app with no install record in place: ${bundle}`] : [])].join('\n'));
      return uninstalled;
    }
    const source = await realpath(values.app);
    const details = await inspectBundle(source);
    if (receipt && compareVersions(details.version, receipt.version) < 0) {
      throw new Error(`Refusing to downgrade the companion from ${receipt.version} to ${details.version}. Uninstall it explicitly first.`);
    }
    const stage = await mkdtemp(join(installDirectory, '.install-'));
    let oldBundleMoved = false;
    let newBundleMoved = false;
    let cleanupStage = true;
    try {
      run('/usr/bin/ditto', [source, join(stage, appName)]);
      if (await digestBundle(join(stage, appName)) !== details.digest) throw new Error('The copied bundle differs from the source app.');
      await mkdir(dirname(location), { recursive: true });
      await plainPath(dirname(location), true);
      if (receipt && appInstalled) { await rename(bundle, join(stage, 'previous.app')); oldBundleMoved = true; }
      await rename(join(stage, appName), bundle);
      newBundleMoved = true;
      await writeJson(location, manifestFor(executable, origin));
      registrations.push({ path: location, origin });
      receipt = { schemaVersion: 1, bundleIdentifier: hostName, bundlePath: bundle, ...details, registrations };
      await writeJson(receiptPath, receipt);
    } catch (error) {
      try {
        if (newBundleMoved) await rm(bundle, { recursive: true, force: true });
        if (oldBundleMoved) await rename(join(stage, 'previous.app'), bundle);
        if (previousManifest === undefined) await rm(location, { force: true });
        else await writeAtomic(location, previousManifest);
        if (oldReceipt !== undefined) await writeAtomic(receiptPath, oldReceipt);
      } catch (rollbackError) {
        cleanupStage = false;
        throw new AggregateError([error, rollbackError], `Install rollback failed. Recovery files are preserved at ${stage}.`, { cause: rollbackError });
      }
      throw error;
    } finally { if (cleanupStage) await rm(stage, { recursive: true, force: true }); }
    console.log(`Installed SnapScreen Companion ${details.version} (protocol ${details.protocolVersion})\n${bundle}\nRegistered ${origin}\n${location}`);
    return false;
  } finally { await rm(lock, { recursive: true, force: true }); }
}

async function main() {
  const { values } = parseArgs({ options: {
    'extension-id': { type: 'string' },
    'user-data-dir': { type: 'string' },
    executable: { type: 'string' },
    app: { type: 'string' },
    'install-dir': { type: 'string' },
    remove: { type: 'boolean', default: false },
    help: { type: 'boolean', default: false },
  } });
  if (values.help) {
    console.log(`SnapScreen companion installer (macOS, Node.js 22+)\n\nInstall or upgrade a packaged app:\n  node native-companion-install.mjs --app /absolute/SnapScreenCompanion.app --extension-id ID --user-data-dir /absolute/browser-root\n\nRemove one browser registration and, after the final registration, the managed app:\n  node native-companion-install.mjs --remove --extension-id ID --user-data-dir /absolute/browser-root\n\nDevelopment registration only:\n  npm run install:native -- --extension-id ID --user-data-dir /absolute/browser-root [--executable /absolute/host]\n\nUse chrome://extensions for ID and chrome://version for the browser user-data root\n(the parent of its Profile Path). For Google Chrome this is usually\n"$HOME/Library/Application Support/Google/Chrome". Each registration allows exactly one extension.\n--install-dir overrides the managed app location (${defaultInstallDirectory}).\nClose active SnapScreen windows before upgrading. Restart Chrome if it cached a failed launch.`);
    return;
  }
  const extensionId = values['extension-id'];
  if (typeof extensionId !== 'string' || extensionId.length !== 32 || !/^[a-p]{32}$/.test(extensionId)) {
    throw new Error('--extension-id must be the exact 32-character extension ID from chrome://extensions.');
  }
  const userDataDirectory = values['user-data-dir'];
  if (!userDataDirectory || !isAbsolute(userDataDirectory)) {
    throw new Error('--user-data-dir must be an explicit absolute browser user-data root (see chrome://version).');
  }
  if (process.platform !== 'darwin') throw new Error('The companion installer supports macOS only.');
  for (const option of ['app', 'executable', 'install-dir']) {
    if (values[option] !== undefined && !isAbsolute(values[option])) throw new Error(`--${option} must be absolute.`);
  }
  if (values.app !== undefined && values.executable !== undefined) throw new Error('Use either --app or --executable, not both.');
  if (values.app !== undefined && values.remove) throw new Error('--app is for installation; use --remove without --app to uninstall.');
  await access(userDataDirectory, constants.R_OK | constants.W_OK);
  const browserRoot = await realpath(userDataDirectory);
  // Chrome reads hosts from the user-data root (with Local State), never from a profile folder.
  if (await exists(join(browserRoot, 'Preferences')) && !await exists(join(browserRoot, 'Local State'))) {
    throw new Error(`${browserRoot} is a browser profile folder. Use its parent, the user-data root shown as the parent of Profile Path in chrome://version.`);
  }
  const origin = `chrome-extension://${extensionId}/`;
  const location = join(browserRoot, 'NativeMessagingHosts', `${hostName}.json`);
  const suppliedDirectory = resolve(values['install-dir'] ?? defaultInstallDirectory);
  if (await exists(suppliedDirectory)) await plainPath(suppliedDirectory, true);
  const installDirectory = await canonicalPath(suppliedDirectory);
  const registered = await registeredExecutable(location);
  // Removal follows the existing registration, so a development host and a managed app can coexist.
  if (values.app !== undefined || (values.remove && values.executable === undefined && (values['install-dir'] !== undefined
    || registered === join(installDirectory, appName, executableRelative)
    || (registered === undefined && await exists(join(installDirectory, receiptName)))))) {
    if (await managedInstall({ values, installDirectory, location, origin })
      && installDirectory === await canonicalPath(defaultInstallDirectory)) {
      // The default folder belongs to SnapScreen. rmdir keeps it if anything else remains inside.
      await rmdir(installDirectory).catch(() => undefined);
    }
    return;
  }
  if (values['install-dir'] !== undefined) throw new Error('--install-dir requires --app or an existing managed installation to remove.');
  const suppliedExecutable = values.executable ?? defaultExecutable;
  let executable;
  try { executable = await realpath(suppliedExecutable); }
  catch (error) { if (!values.remove || error.code !== 'ENOENT') throw error; executable = resolve(suppliedExecutable); }
  const existing = await checkManifest(location, executable, origin);
  if (values.remove) {
    if (existing !== undefined) await unlink(location);
    console.log(`${existing === undefined ? 'No registration at' : 'Removed'} ${location}`);
    return;
  }
  await access(executable, constants.X_OK);
  await mkdir(dirname(location), { recursive: true });
  await plainPath(dirname(location), true);
  await writeJson(location, manifestFor(executable, origin));
  console.log(`Registered ${hostName} for ${origin}\n${location}\nExecutable: ${executable}`);
}

try { await main(); }
catch (error) { console.error(`SnapScreen installer: ${error.message}`); process.exitCode = 1; }
