import AppKit

if CommandLine.arguments.contains("--self-test") {
  do {
    _ = NSApplication.shared
    let count = try runGeometryTests() + runAnswerViewTests() + runSelectionViewTests() + runConversationViewTests() +
      runAppShellTests() + runSettingsWindowTests()
    print("SnapScreen self-test: \(count) checks passed")
    exit(0)
  } catch {
    fputs("SnapScreen self-test failed: \(error)\n", stderr)
    exit(1)
  }
}

// Settings, the Keychain item and macOS's approvals belong to the app bundle, so the bare binary
// that `swift build` writes doesn't run as the app.
guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
  fputs("Run SnapScreen from build/SnapScreen.app, which scripts/build-app.sh builds.\n", stderr)
  exit(1)
}
// One copy at a time, since only one can have the shortcut. Opening the app again normally reaches
// the running copy instead, which shows its Settings.
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
  .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
  fputs("SnapScreen is already running.\n", stderr)
  exit(0)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
