import { mkdir, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { basename, dirname, resolve } from 'node:path';
import { parseArgs } from 'node:util';

export const ROOT = fileURLToPath(new URL('../', import.meta.url));
export const MINIMUM_MACOS_VERSION = '13.0';

export function buildArchitectures(architecture = 'native', host = process.arch) {
  const current = host === 'arm64' ? 'arm64' : host === 'x64' ? 'x86_64' : host;
  const selected = architecture === 'native' ? current : architecture;
  if (!['arm64', 'x86_64', 'universal'].includes(selected)) {
    throw new Error('--arch must be native, arm64, x86_64, or universal.');
  }
  return selected === 'universal' ? ['arm64', 'x86_64'] : [selected];
}

export async function buildMetadata({ testHooks = false, architecture = 'native' } = {}) {
  const { version } = JSON.parse(await readFile(resolve(ROOT, 'package.json'), 'utf8'));
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error('The app requires a numeric three-part package version.');
  const swift = await readFile(resolve(ROOT, 'native/macos/Protocol.swift'), 'utf8');
  const typescript = await readFile(resolve(ROOT, 'src/lib/native-protocol.ts'), 'utf8');
  const protocolVersion = Number(swift.match(/^let protocolVersion = (\d+)$/m)?.[1]);
  if (!protocolVersion || Number(typescript.match(/NATIVE_PROTOCOL_VERSION = (\d+)/)?.[1]) !== protocolVersion) {
    throw new Error('Swift and extension native protocol versions do not match.');
  }
  return {
    schemaVersion: 1,
    bundleIdentifier: testHooks ? 'com.snapscreen.companion.test' : 'com.snapscreen.companion',
    version,
    protocolVersion,
    testHooks,
    minimumMacOSVersion: MINIMUM_MACOS_VERSION,
    architectures: buildArchitectures(architecture),
  };
}

function run(command, args) {
  const result = spawnSync(command, args, { stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.status ?? result.signal}).`);
}

export async function buildCompanion(args = process.argv.slice(2)) {
  // The unattended variant never shares the production output path.
  const { values } = parseArgs({ args, options: {
    'test-hooks': { type: 'boolean', default: false },
    bundle: { type: 'string' },
    arch: { type: 'string', default: 'native' },
  } });
  const testHooks = values['test-hooks'];
  if (testHooks && !values.bundle) throw new Error('--test-hooks requires an explicit --bundle path.');
  if (process.platform !== 'darwin') throw new Error('The native companion requires macOS and Xcode command-line tools.');
  const source = resolve(ROOT, 'native/macos');
  // Views shared with the standalone app's Swift package.
  const shared = resolve(ROOT, 'Sources/SnapScreen/UI');
  const defaultBundle = resolve(source, 'build/SnapScreenCompanion.app');
  const bundle = values.bundle ? resolve(values.bundle) : defaultBundle;
  if (!basename(bundle).endsWith('.app')) throw new Error('--bundle must name an .app directory.');
  if (testHooks && bundle === defaultBundle) throw new Error('Test hooks cannot replace the default production bundle.');
  const metadata = await buildMetadata({ testHooks, architecture: values.arch });
  await mkdir(dirname(bundle), { recursive: true });
  const temporary = await mkdtemp(resolve(dirname(bundle), '.snapscreen-build-'));
  const staged = resolve(temporary, 'SnapScreenCompanion.app');
  const executable = resolve(staged, 'Contents/MacOS/SnapScreenCompanion');
  try {
    await mkdir(dirname(executable), { recursive: true });
    const outputs = [];
    for (const architecture of metadata.architectures) {
      const output = resolve(temporary, `SnapScreenCompanion-${architecture}`);
      run('xcrun', ['swiftc', '-swift-version', '5', '-O', '-framework', 'AppKit',
        '-module-name', 'SnapScreenCompanion', '-target', `${architecture}-apple-macosx${MINIMUM_MACOS_VERSION}`,
        ...(testHooks ? ['-D', 'SNAPSCREEN_TEST_HOOKS'] : []),
        ...['TextLimits.swift', 'Geometry.swift', 'Controls.swift', 'AnswerView.swift', 'ConversationView.swift',
          'Composer.swift', 'SelectionView.swift', 'GeometryTests.swift', 'AnswerViewTests.swift',
          'SelectionViewTests.swift', 'ConversationViewTests.swift'].map(file => resolve(shared, file)),
        ...['Protocol.swift', 'Session.swift', 'SelfTests.swift', 'main.swift'].map(file => resolve(source, file)),
        '-o', output]);
      outputs.push(output);
    }
    if (outputs.length === 1) await rename(outputs[0], executable);
    else run('xcrun', ['lipo', '-create', ...outputs, '-output', executable]);
    const name = testHooks ? 'SnapScreen Companion Test' : 'SnapScreen Companion';
    await writeFile(resolve(staged, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${metadata.bundleIdentifier}</string>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundleDisplayName</key><string>${name}</string>
  <key>CFBundleExecutable</key><string>SnapScreenCompanion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${metadata.version}</string>
  <key>CFBundleVersion</key><string>${metadata.version}</string>
  <key>LSMinimumSystemVersion</key><string>${MINIMUM_MACOS_VERSION}</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
`);
    await mkdir(resolve(staged, 'Contents/Resources'), { recursive: true });
    await writeFile(resolve(staged, 'Contents/Resources/snapscreen-build.json'), `${JSON.stringify(metadata, null, 2)}\n`);
    await rm(bundle, { recursive: true, force: true });
    await rename(staged, bundle);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
  return resolve(bundle, 'Contents/MacOS/SnapScreenCompanion');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  console.log(await buildCompanion());
}
