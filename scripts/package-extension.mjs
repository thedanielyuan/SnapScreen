import { execFileSync } from 'node:child_process';
import { mkdir, readFile, rm } from 'node:fs/promises';
import { join, relative, resolve } from 'node:path';

const ROOT = resolve(import.meta.dirname, '..');
const DIST = join(ROOT, 'dist');
const RELEASE_DIR = join(ROOT, 'release');

async function readJson(path) {
  return JSON.parse(await readFile(path, 'utf8'));
}

const { version } = await readJson(join(ROOT, 'package.json'));
let manifest;
try {
  manifest = await readJson(join(DIST, 'manifest.json'));
} catch (error) {
  throw new Error('Could not read dist/manifest.json. Run npm run build first.', { cause: error });
}
if (manifest.version !== version) {
  throw new Error(
    `dist/ is version ${manifest.version}, but package.json is ${version}. Run npm run build first.`,
  );
}

// The store expects manifest.json at the root of the zip.
const zipPath = join(RELEASE_DIR, `snapscreen-${version}.zip`);
await mkdir(RELEASE_DIR, { recursive: true });
await rm(zipPath, { force: true });
execFileSync('zip', ['-q', '-r', zipPath, '.', '-x', '*.DS_Store'], {
  cwd: DIST,
  stdio: 'inherit',
});
process.stdout.write(`Packaged ${relative(ROOT, zipPath)}\n`);
