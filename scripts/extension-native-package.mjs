import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { join, posix, resolve } from 'node:path';
import ts from 'typescript';

const ROOT = resolve(import.meta.dirname, '..');
export const NATIVE_OPTIONS_PATH = 'src/options/options-native.html';
export const NATIVE_CSP = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src https://api.anthropic.com data:; object-src 'none'; base-uri 'none'";
const EXCLUDED_SOURCE = /SNAPSCREEN_(?:TEST_|LIVE_)|__snapscreen|__nativeLive|__companionAvailabilityTrace|nativeAcceptance|installAcceptanceShim|Acceptance fixture blocks external fetch|sk-ant-snapscreen-physical-fixture-only|snapscreen-ui-host|snapscreenWorkspace:|\?script&iife|result-frame\.html|workspace\.html/u;

async function readJson(path) {
  return JSON.parse(await readFile(path, 'utf8'));
}

async function listFiles(directory, prefix = '') {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = await Promise.all(entries.map(async entry => {
    const path = prefix + entry.name;
    assert.ok(entry.isFile() || entry.isDirectory(), `Non-regular package entry: ${path}`);
    return entry.isDirectory() ? listFiles(join(directory, entry.name), `${path}/`) : [path];
  }));
  return files.flat().sort();
}

function assetPath(reference, owner, files) {
  assert.equal(typeof reference, 'string', `Missing asset reference in ${owner}`);
  assert.ok(reference.length > 0 && !/[\\?#%]/u.test(reference)
    && !/^[a-z][a-z\d+.-]*:/iu.test(reference) && !reference.startsWith('//'),
  `Non-local asset reference in ${owner}: ${reference}`);
  const path = posix.normalize(reference.startsWith('/')
    ? reference.slice(1) : posix.join(posix.dirname(owner), reference));
  assert.ok(path !== '..' && !path.startsWith('../'), `Asset escapes package in ${owner}: ${reference}`);
  assert.ok(files.includes(path), `Missing packaged asset in ${owner}: ${reference}`);
  return path;
}

function scriptReferences(source, file) {
  const tree = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
  assert.equal(tree.parseDiagnostics.length, 0, `Invalid bundled JavaScript in ${file}`);
  const imports = [];
  function visit(node) {
    if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) && node.moduleSpecifier) {
      assert.ok(ts.isStringLiteral(node.moduleSpecifier), `Non-literal module reference in ${file}`);
      imports.push(node.moduleSpecifier.text);
    }
    if (ts.isCallExpression(node) && node.expression.kind === ts.SyntaxKind.ImportKeyword) {
      assert.ok(node.arguments.length === 1 && ts.isStringLiteralLike(node.arguments[0]),
        `Non-literal dynamic import in ${file}`);
      imports.push(node.arguments[0].text);
    }
    if (ts.isPropertyAccessExpression(node) || ts.isElementAccessExpression(node)) {
      const property = ts.isPropertyAccessExpression(node) ? node.name.text
        : ts.isStringLiteralLike(node.argumentExpression) ? node.argumentExpression.text : undefined;
      assert.notEqual(property, 'scripting', `Script injection API shipped in ${file}`);
    }
    ts.forEachChild(node, visit);
  }
  visit(tree);
  return imports;
}

function htmlReferences(source, file) {
  const references = [];
  const scripts = [...source.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/giu)];
  assert.ok(scripts.length > 0, `Settings has no bundled script: ${file}`);
  for (const [, attributes, body] of scripts) {
    assert.ok(!body.trim(), `Inline Settings script shipped in ${file}`);
    const src = attributes.match(/\bsrc\s*=\s*["']([^"']+)["']/iu)?.[1];
    assert.ok(src?.endsWith('.js'), `Settings references an unbundled script in ${file}`);
    assert.match(attributes, /\btype\s*=\s*["']module["']/iu, `Settings script is not a module in ${file}`);
    references.push(src);
  }
  for (const [, attributes] of source.matchAll(/<link\b([^>]*)>/giu)) {
    if (!/\brel\s*=\s*["'](?:stylesheet|modulepreload)["']/iu.test(attributes)) continue;
    const href = attributes.match(/\bhref\s*=\s*["']([^"']+)["']/iu)?.[1];
    assert.ok(href && /\.(?:css|js)$/u.test(href), `Unbundled Settings link in ${file}`);
    references.push(href);
  }
  assert.ok(!/<style\b|\bon\w+\s*=|\bstyle\s*=/iu.test(source), `Inline Settings code/style shipped in ${file}`);
  return references;
}

// Inspect the unmodified build and extracted ZIP before the browser harness adds
// its disposable transport shim. The returned version is also checked against
// the bundled worker/Settings hello messages, rather than minifier symbol names.
export async function inspectNativeExtension(directory, { root = ROOT } = {}) {
  const [manifest, packageJson, typescript, swift, files] = await Promise.all([
    readJson(join(directory, 'manifest.json')),
    readJson(join(root, 'package.json')),
    readFile(join(root, 'src/lib/native-protocol.ts'), 'utf8'),
    readFile(join(root, 'native/macos/Protocol.swift'), 'utf8'),
    listFiles(directory),
  ]);
  assert.equal(manifest.version, packageJson.version, 'Native-only package version must match package.json.');
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.minimum_chrome_version, '116');
  assert.deepEqual([...manifest.permissions].sort(), ['activeTab', 'nativeMessaging', 'storage']);
  assert.deepEqual(manifest.host_permissions, ['https://api.anthropic.com/*']);
  assert.deepEqual(manifest.optional_host_permissions, ['file:///*']);
  assert.equal(manifest.optional_permissions, undefined, 'Native-only package adds optional permissions.');
  assert.equal(manifest.content_scripts, undefined, 'Native-only package declares content scripts.');
  assert.equal(manifest.web_accessible_resources, undefined, 'Native-only package exposes resources.');
  assert.equal(manifest.options_page, NATIVE_OPTIONS_PATH);
  assert.equal(manifest.background?.type, 'module');
  assert.deepEqual(manifest.content_security_policy, { extension_pages: NATIVE_CSP });
  assert.ok(manifest.commands?.snip?.suggested_key?.default);
  assert.ok(manifest.action?.default_icon?.['16']);

  const protocolVersion = Number(typescript.match(/NATIVE_PROTOCOL_VERSION = (\d+)/u)?.[1]);
  assert.ok(protocolVersion > 0, 'Extension native protocol version is missing.');
  assert.equal(protocolVersion, Number(swift.match(/^let protocolVersion = (\d+)$/mu)?.[1]),
    'Swift and extension native protocol versions do not match.');
  const hashes = {};
  const sources = new Map();
  for (const file of files) {
    assert.ok(!/^src\/(?:content|ui|workspace)\//u.test(file)
      && !/(?:^|\/)(?:content(?:[.-]|\/)|result[-.]frame|workspace)/iu.test(file),
    `Excluded UI file shipped: ${file}`);
    assert.ok(!/test|smoke|acceptance/iu.test(file), `Test-only file shipped: ${file}`);
    const bytes = await readFile(join(directory, file));
    hashes[file] = createHash('sha256').update(bytes).digest('hex');
    if (!/\.(?:js|html|json|css)$/u.test(file)) continue;
    const source = bytes.toString('utf8');
    assert.ok(!EXCLUDED_SOURCE.test(source), `Page UI or test hook shipped in ${file}`);
    sources.set(file, source);
  }

  const reachable = new Set(['manifest.json']);
  for (const icon of [...Object.values(manifest.icons ?? {}), ...Object.values(manifest.action.default_icon)]) {
    const path = assetPath(icon, 'manifest.json', files);
    assert.match(path, /\.png$/u, `Unexpected manifest icon: ${path}`);
    reachable.add(path);
  }
  const worker = assetPath(manifest.background.service_worker, 'manifest.json', files);
  assert.match(worker, /\.js$/u, 'Worker is not bundled JavaScript.');
  const pending = [worker, manifest.options_page];
  while (pending.length) {
    const file = pending.pop();
    if (reachable.has(file)) continue;
    reachable.add(file);
    assert.ok(sources.has(file), `Missing bundled source: ${file}`);
    const source = sources.get(file);
    let references = [];
    if (file.endsWith('.js')) references = scriptReferences(source, file);
    else if (file.endsWith('.html')) references = htmlReferences(source, file);
    else if (file.endsWith('.css')) {
      references = [...source.matchAll(/(?:@import\s*|url\(\s*)["']?([^"'\s;)]+)/giu)]
        .map(match => match[1]);
    }
    for (const reference of references) pending.push(assetPath(reference, file, files));
  }
  assert.deepEqual([...reachable].sort(), files,
    'Package contains unreferenced assets outside the Settings/worker dependency graph.');
  return { manifest, files, protocolVersion, hashes };
}

// A temporary archive gate, not a release packaging command. Keep archive
// publication and explicit native-runner variant selection in their own work.
export async function verifyNativeArchive(directory, scratchDirectory, options = {}) {
  const built = await inspectNativeExtension(directory, options);
  const stage = await mkdtemp(join(scratchDirectory, 'native-package-'));
  try {
    const archivePath = join(stage, `snapscreen-native-only-${built.manifest.version}.zip`);
    const extensionDirectory = join(stage, 'extracted');
    execFileSync('zip', ['-q', '-r', archivePath, '.'], { cwd: directory });
    await mkdir(extensionDirectory);
    execFileSync('unzip', ['-q', archivePath, '-d', extensionDirectory]);
    const extracted = await inspectNativeExtension(extensionDirectory, options);
    assert.deepEqual(extracted.hashes, built.hashes, 'Extracted native-only archive differs from the build.');
    return { ...extracted, extensionDirectory, archivePath };
  } catch (error) {
    await rm(stage, { recursive: true, force: true });
    throw error;
  }
}
