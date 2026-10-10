import AppKit

// Until the menu bar app exists (Phase 2 of docs/standalone-app-plan.md), the executable only
// runs the shared views' self-tests.
if CommandLine.arguments.contains("--self-test") {
  do {
    _ = NSApplication.shared
    let count = try runGeometryTests() + runAnswerViewTests() + runSelectionViewTests() + runConversationViewTests()
    print("SnapScreen self-test: \(count) checks passed")
    exit(0)
  } catch {
    fputs("SnapScreen self-test failed: \(error)\n", stderr)
    exit(1)
  }
}

fputs("SnapScreen has no app yet. Run it with --self-test to check the shared views.\n", stderr)
exit(1)
