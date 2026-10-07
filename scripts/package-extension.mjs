import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rename, rm } from 'node:fs/promises';
import { basename, join, relative, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { verifyNativeArchive } from './extension-native-package.mjs';
import { hashSummary, selectNativeExtension } from './native-extension-artifact.mjs';

const ROOT = resolve(import.meta.dirname, '..');

export function parsePackageArguments(args) {
  let variant = 'ordinary';
  let selected = false;
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === '--help' || argument === '-h') return { help: true, variant };
    if (argument !== '--variant') throw new Error(`Unknown argument: ${argument}. Use --variant ordinary|native-only.`);
    if (selected) throw new Error('--variant can only be supplied once.');
    variant = args[++index];
    if (!['ordinary', 'native-only'].includes(variant)) throw new Error('--variant requires ordinary or native-only.');
    selected = true;
  }
  return { help: false, variant };
}

export async function packageExtension({ variant = 'ordinary', root = ROOT } = {}) {
  assert.ok(['ordinary', 'native-only'].includes(variant), 'Unknown extension package variant.');
  const source = join(root, variant === 'native-only' ? 'dist-native' : 'dist');
  const selected = await selectNativeExtension(source, { root });
  assert.equal(selected.variant, variant, `The selected ${source} build is not the requested ${variant} variant.`);
  const releaseDirectory = join(root, 'release');
  await mkdir(releaseDirectory, { recursive: true });
  const stage = await mkdtemp(join(releaseDirectory, '.extension-package-'));
  try {
    const filename = `snapscreen${variant === 'native-only' ? '-native-only' : ''}-${selected.manifest.version}.zip`;
    let verified;
    if (variant === 'native-only') {
      verified = await verifyNativeArchive(selected.directory, stage, { root });
    } else {
      const archivePath = join(stage, filename);
      const extensionDirectory = join(stage, 'extracted');
      // Preserve the ordinary archive filename/layout and Finder-metadata exclusion.
      execFileSync('zip', ['-q', '-r', archivePath, '.', '-x', '*.DS_Store'], { cwd: selected.directory });
      await mkdir(extensionDirectory);
      execFileSync('unzip', ['-q', archivePath, '-d', extensionDirectory]);
      const extracted = await selectNativeExtension(extensionDirectory, { root });
      const expectedHashes = Object.fromEntries(Object.entries(selected.hashes)
        .filter(([path]) => !basename(path).endsWith('.DS_Store')));
      assert.deepEqual(extracted.hashes, expectedHashes, 'Extracted ordinary archive differs from the build.');
      verified = { ...extracted, archivePath };
    }
    assert.equal(verified.manifest.version, selected.manifest.version);
    const sha256 = createHash('sha256').update(await readFile(verified.archivePath)).digest('hex');
    const archivePath = join(releaseDirectory, filename);
    // Replace a previous candidate only after its complete extracted contents pass.
    await rename(verified.archivePath, archivePath);
    return { archivePath, variant, version: selected.manifest.version, sha256,
      extensionSha256: hashSummary(verified.hashes), hashes: verified.hashes };
  } finally {
    await rm(stage, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const options = parsePackageArguments(process.argv.slice(2));
  if (options.help) process.stdout.write('Usage: node scripts/package-extension.mjs [--variant ordinary|native-only]\n');
  else {
    const result = await packageExtension(options);
    process.stdout.write(`Packaged ${relative(ROOT, result.archivePath)}\n`
      + `Variant: ${result.variant}; extension SHA-256: ${result.extensionSha256}\n`
      + `Archive SHA-256: ${result.sha256}\n`);
  }
}
