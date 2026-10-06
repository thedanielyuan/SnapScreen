import { mkdir, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

if (process.platform !== 'darwin') throw new Error('The native companion requires macOS and Xcode command-line tools.');
const root = fileURLToPath(new URL('../native/macos/', import.meta.url));
const bundle = resolve(root, 'build/SnapScreenCompanion.app');
const executable = resolve(bundle, 'Contents/MacOS/SnapScreenCompanion');
await mkdir(resolve(bundle, 'Contents/MacOS'), { recursive: true });
const result = spawnSync('xcrun', ['swiftc', '-swift-version', '5', '-O', '-framework', 'AppKit',
  ...['Protocol.swift', 'Session.swift', 'SelfTests.swift', 'main.swift'].map(file => resolve(root, file)),
  '-o', executable], { stdio: 'inherit' });
if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);
await writeFile(resolve(bundle, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.snapscreen.companion</string>
  <key>CFBundleName</key><string>SnapScreen Companion</string>
  <key>CFBundleDisplayName</key><string>SnapScreen Companion</string>
  <key>CFBundleExecutable</key><string>SnapScreenCompanion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
`);
console.log(executable);
