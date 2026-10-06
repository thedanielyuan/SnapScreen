import { constants } from 'node:fs';
import { access, mkdir, readFile, realpath, unlink, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: {
  'extension-id': { type: 'string' },
  'user-data-dir': { type: 'string' },
  executable: { type: 'string' },
  remove: { type: 'boolean', default: false },
} });
const extensionId = values['extension-id'];
const userDataDirectory = values['user-data-dir'];
if (!extensionId || extensionId.length !== 32 || !/^[a-p]{32}$/.test(extensionId)) {
  throw new Error('--extension-id must be the exact 32-character extension ID from chrome://extensions.');
}
if (!userDataDirectory || !isAbsolute(userDataDirectory)) {
  throw new Error('--user-data-dir must be an explicit absolute browser user-data root (see chrome://version).');
}
if (process.platform !== 'darwin') throw new Error('This development installer supports macOS only.');
const defaultExecutable = fileURLToPath(new URL('../native/macos/build/SnapScreenCompanion.app/Contents/MacOS/SnapScreenCompanion', import.meta.url));
const suppliedExecutable = values.executable ?? defaultExecutable;
if (!isAbsolute(suppliedExecutable)) throw new Error('--executable must be absolute.');
const hostName = 'com.snapscreen.companion';
const origin = `chrome-extension://${extensionId}/`;
const location = resolve(userDataDirectory, 'NativeMessagingHosts', `${hostName}.json`);
let existing;
try { existing = JSON.parse(await readFile(location, 'utf8')); }
catch (error) { if (error.code !== 'ENOENT') throw error; }
if (existing && (existing.name !== hostName || existing.type !== 'stdio' ||
  !Array.isArray(existing.allowed_origins) || existing.allowed_origins.length !== 1 || existing.allowed_origins[0] !== origin)) {
  throw new Error('A different host registration exists at the target. Leave it intact or remove it explicitly first.');
}
if (values.remove) {
  if (existing) await unlink(location);
  console.log(existing ? `Removed ${location}` : `No registration at ${location}`);
} else {
  const executable = await realpath(suppliedExecutable);
  await access(executable, constants.X_OK);
  // Requiring the browser's existing root avoids silently registering a different browser/profile.
  await access(userDataDirectory, constants.R_OK | constants.W_OK);
  const manifest = {
    name: hostName,
    description: 'SnapScreen macOS companion',
    path: executable,
    type: 'stdio',
    allowed_origins: [origin],
  };
  await mkdir(dirname(location), { recursive: true });
  await writeFile(location, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
  console.log(`Registered ${hostName} for ${origin}\n${location}\nExecutable: ${executable}`);
}
