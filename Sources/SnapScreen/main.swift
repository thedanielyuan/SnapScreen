import AppKit

if CommandLine.arguments.contains("--self-test") {
  do {
    _ = NSApplication.shared
    let count = try runGeometryTests() + runAnswerViewTests() + runSelectionViewTests() + runConversationViewTests() +
      runAppShellTests() + runSettingsWindowTests() + MainActor.assumeIsolated { try runSessionWindowsTests() }
    #if SNAPSCREEN_TEST_HOOKS
    print("SnapScreen self-test: \(count) checks passed (test hooks build)")
    #else
    print("SnapScreen self-test: \(count) checks passed")
    #endif
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
#if SNAPSCREEN_TEST_HOOKS
// scripts/test-app-live.sh runs the live test in the test-hooks build, which has its own bundle ID.
let delegate: NSApplicationDelegate = CommandLine.arguments.contains("--live-test")
  ? MainActor.assumeIsolated { LiveTest() } : AppDelegate()
#else
let delegate = AppDelegate()
#endif
application.delegate = delegate
application.run()
