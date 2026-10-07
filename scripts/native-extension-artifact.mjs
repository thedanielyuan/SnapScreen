import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, readdir, realpath } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import {
  assetPath, htmlReferences, inspectNativeExtension, NATIVE_CSP, NATIVE_OPTIONS_PATH, scriptReferences,
} from './extension-native-package.mjs';

const ROOT = resolve(import.meta.dirname, '..');
const ORDINARY_OPTIONS_PATH = 'src/options/options.html';
const TEST_SOURCE = /SNAPSCREEN_(?:TEST_|LIVE_)|__snapscreen(?:Smoke|Native|Diagnostic)|__nativeLive|__packaged|__managedTypes|__companionAvailabilityTrace|nativeAcceptance|installAcceptanceShim|Acceptance fixture blocks external fetch|sk-ant-snapscreen-physical-fixture-only/u;

export async function hashFiles(directory) {
  const hashes = {};
  async function visit(current, prefix = '') {
    for (const entry of await readdir(current, { withFileTypes: true })) {
      const file = prefix + entry.name;
      const path = join(current, entry.name);
      assert.ok(entry.isFile() || entry.isDirectory(), `Non-regular artifact entry: ${path}`);
      if (entry.isDirectory()) await visit(path, `${file}/`);
      else hashes[file] = createHash('sha256').update(await readFile(path)).digest('hex');
    }
  }
  await visit(directory);
  return Object.fromEntries(Object.entries(hashes).sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0));
}

// Hash the complete, sorted path-to-content-hash map, so names, additions, removals,
// and byte changes all affect the artifact identity. This is not the ZIP checksum.
export function hashSummary(hashes) {
  const sorted = Object.fromEntries(Object.keys(hashes).sort().map(file => [file, hashes[file]]));
  return createHash('sha256').update(JSON.stringify(sorted)).digest('hex');
}

export function describeFileChanges(originalHashes, fixtureHashes) {
  return [...new Set([...Object.keys(originalHashes), ...Object.keys(fixtureHashes)])].sort()
    .filter(path => originalHashes[path] !== fixtureHashes[path])
    .map(path => ({ path, beforeSha256: originalHashes[path] ?? null, afterSha256: fixtureHashes[path] ?? null }));
}

async function inspectOrdinaryExtension(directory, manifest, hashes) {
  const files = Object.keys(hashes);
  assert.deepEqual([...manifest.permissions].sort(), ['activeTab', 'nativeMessaging', 'scripting', 'storage'],
    'Ordinary extension permissions do not match the build variant.');
  assert.equal(manifest.content_scripts, undefined, 'Unexpected declared content scripts in ordinary extension.');
  assert.ok(Array.isArray(manifest.web_accessible_resources) && manifest.web_accessible_resources.length > 0,
    'Ordinary extension is missing its web-accessible resources.');
  const sources = new Map();
  for (const file of files) {
    assert.ok(!/test|smoke|acceptance/iu.test(file), `Test-only file shipped: ${file}`);
    if (!/\.(?:js|html|json|css)$/u.test(file)) continue;
    const source = await readFile(join(directory, file), 'utf8');
    assert.ok(!TEST_SOURCE.test(source), `Test hook shipped in ${file}`);
    sources.set(file, source);
  }
  const worker = assetPath(manifest.background.service_worker, 'manifest.json', files);
  assert.match(worker, /\.js$/u, 'Worker is not bundled JavaScript.');
  const pending = [worker, manifest.options_page];
  const seen = new Set();
  for (const icon of [...Object.values(manifest.icons ?? {}), ...Object.values(manifest.action.default_icon)]) {
    assetPath(icon, 'manifest.json', files);
  }
  for (const resource of manifest.web_accessible_resources) {
    assert.ok(Array.isArray(resource.resources), 'Invalid web-accessible resource declaration.');
    for (const path of resource.resources) assetPath(path, 'manifest.json', files);
  }
  while (pending.length) {
    const file = pending.pop();
    if (seen.has(file)) continue;
    seen.add(file);
    assert.ok(sources.has(file), `Missing bundled source: ${file}`);
    const source = sources.get(file);
    let references = [];
    if (file.endsWith('.js')) references = scriptReferences(source, file, { allowInjection: true });
    else if (file.endsWith('.html')) references = htmlReferences(source, file);
    else if (file.endsWith('.css')) references = [...source.matchAll(/(?:@import\s*|url\(\s*)["']?([^"'\s;)]+)/giu)].map(match => match[1]);
    for (const reference of references) pending.push(assetPath(reference, file, files));
  }
}

// Always call this on the pristine selected build, before any runner copies or
// instruments it. A native-only directory must pass the complete package boundary.
export async function selectNativeExtension(extensionDir, { root = ROOT, cwd = process.cwd() } = {}) {
  assert.ok(extensionDir === undefined || (typeof extensionDir === 'string' && extensionDir.trim()),
    '--extension-dir requires a non-empty path.');
  const requested = extensionDir === undefined ? join(root, 'dist') : resolve(cwd, extensionDir);
  let directory;
  let manifest;
  try {
    // Return the real build: fs.cp copies a symlinked directory as a link, so runner
    // fixture edits would otherwise write through it into the selected artifact.
    directory = await realpath(requested);
    manifest = JSON.parse(await readFile(join(directory, 'manifest.json'), 'utf8'));
  } catch (error) {
    throw new Error(`Could not read built extension manifest at ${requested}/manifest.json. Run npm run build or npm run build:extension-native for the selected variant.`, { cause: error });
  }
  assert.ok(manifest && typeof manifest === 'object' && !Array.isArray(manifest), 'Invalid built extension manifest.');
  const variant = manifest.options_page === NATIVE_OPTIONS_PATH ? 'native-only'
    : manifest.options_page === ORDINARY_OPTIONS_PATH ? 'ordinary' : null;
  assert.ok(variant, 'Selected directory is not a built SnapScreen extension: unrecognized Settings page.');
  const [packageJson, typescript, swift, hashes] = await Promise.all([
    readFile(join(root, 'package.json'), 'utf8').then(JSON.parse),
    readFile(join(root, 'src/lib/native-protocol.ts'), 'utf8'),
    readFile(join(root, 'native/macos/Protocol.swift'), 'utf8'),
    hashFiles(directory),
  ]);
  const buildCommand = variant === 'native-only' ? 'npm run build:extension-native' : 'npm run build';
  assert.equal(manifest.version, packageJson.version,
    `Selected extension version ${manifest.version} does not match package.json ${packageJson.version}. Run ${buildCommand}.`);
  assert.equal(manifest.manifest_version, 3, 'Selected extension must use Manifest V3.');
  assert.equal(manifest.minimum_chrome_version, '116');
  assert.ok(Array.isArray(manifest.permissions) && manifest.permissions.includes('nativeMessaging'),
    'Selected extension must require nativeMessaging.');
  assert.equal(manifest.background?.type, 'module', 'Selected extension worker must be a module.');
  assert.deepEqual(manifest.host_permissions, ['https://api.anthropic.com/*']);
  assert.deepEqual(manifest.optional_host_permissions, ['file:///*']);
  assert.equal(manifest.optional_permissions, undefined, 'Selected extension adds optional permissions.');
  assert.deepEqual(manifest.content_security_policy, { extension_pages: NATIVE_CSP });
  assert.ok(manifest.action?.default_icon?.['16'], 'Selected extension is missing its toolbar icon.');
  assert.ok(manifest.commands?.snip?.suggested_key?.default, 'Selected extension is missing its snip command.');
  const protocolVersion = Number(typescript.match(/NATIVE_PROTOCOL_VERSION = (\d+)/u)?.[1]);
  assert.ok(protocolVersion > 0, 'Extension native protocol version is missing.');
  assert.equal(protocolVersion, Number(swift.match(/^let protocolVersion = (\d+)$/mu)?.[1]),
    'Swift and extension native protocol versions do not match.');
  if (variant === 'native-only') {
    const inspected = await inspectNativeExtension(directory, { root });
    assert.deepEqual(inspected.hashes, hashes, 'Selected native-only artifact changed during validation.');
  } else await inspectOrdinaryExtension(directory, manifest, hashes);
  return { directory, manifest, variant, hashes, sha256: hashSummary(hashes), protocolVersion };
}
