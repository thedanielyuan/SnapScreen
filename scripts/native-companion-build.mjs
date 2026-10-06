import { mkdir, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { parseArgs } from 'node:util';

// --test-hooks builds the unattended variant for the live integration test. It must go to an
// explicit --bundle path, so the registered production build can never contain the hooks.
const { values } = parseArgs({ options: {
  'test-hooks': { type: 'boolean', default: false },
  bundle: { type: 'string' },
} });
const testHooks = values['test-hooks'];
if (testHooks && !values.bundle) throw new Error('--test-hooks requires an explicit --bundle path.');
if (process.platform !== 'darwin') throw new Error('The native companion requires macOS and Xcode command-line tools.');
const root = fileURLToPath(new URL('../native/macos/', import.meta.url));
const bundle = values.bundle ? resolve(values.bundle) : resolve(root, 'build/SnapScreenCompanion.app');
const executable = resolve(bundle, 'Contents/MacOS/SnapScreenCompanion');
await mkdir(resolve(bundle, 'Contents/MacOS'), { recursive: true });
const result = spawnSync('xcrun', ['swiftc', '-swift-version', '5', '-O', '-framework', 'AppKit',
  ...(testHooks ? ['-D', 'SNAPSCREEN_TEST_HOOKS'] : []),
  ...['Protocol.swift', 'Session.swift', 'Controls.swift', 'AnswerView.swift', 'SelectionView.swift',
    'SelfTests.swift', 'AnswerViewTests.swift', 'SelectionViewTests.swift', 'main.swift'].map(file => resolve(root, file)),
  '-o', executable], { stdio: 'inherit' });
if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);
const identifier = testHooks ? 'com.snapscreen.companion.test' : 'com.snapscreen.companion';
const name = testHooks ? 'SnapScreen Companion Test' : 'SnapScreen Companion';
await writeFile(resolve(bundle, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${identifier}</string>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundleDisplayName</key><string>${name}</string>
  <key>CFBundleExecutable</key><string>SnapScreenCompanion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
`);
console.log(executable);
