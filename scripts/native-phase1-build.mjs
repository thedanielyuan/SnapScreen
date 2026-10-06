import { createHash } from 'node:crypto';
import { copyFile, mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { EXTENSION_ID, EXTENSION_KEY, manifest } from '../experiments/native-phase1/extension/config.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = resolve(root, 'experiments/native-phase1/extension');
const output = resolve(root, 'experiments/native-phase1/build/extension');
const derivedId = createHash('sha256').update(Buffer.from(EXTENSION_KEY, 'base64'))
  .digest('hex').slice(0, 32).replace(/[0-9a-f]/g, digit => String.fromCharCode(97 + parseInt(digit, 16)));
if (derivedId !== EXTENSION_ID) throw new Error('The Phase 1 public key and extension ID disagree.');

await mkdir(output, { recursive: true });
for (const file of ['background.mjs', 'protocol.mjs', 'config.mjs']) {
  await copyFile(resolve(source, file), resolve(output, file));
}
await writeFile(resolve(output, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`Experimental extension: ${output}\nExtension ID: ${EXTENSION_ID}`);
