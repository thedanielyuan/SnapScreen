#if SNAPSCREEN_TEST_HOOKS
import AppKit
import SnapScreenCore

private enum NoticeFocusFailure: Error { case failed(String), unknownCapture }

/// A cancellable clock for the real notice center. Its deadlines remain eight seconds initially
/// and three seconds after hover; advancing it never posts input or opens another application.
private final class NoticeFocusClock {
  private final class Entry {
    let deadline: TimeInterval
    let action: () -> Void
    var active = true

    init(deadline: TimeInterval, action: @escaping () -> Void) {
      self.deadline = deadline
      self.action = action
    }
  }

  private var now: TimeInterval = 0
  private var entries: [Entry] = []
  private(set) var delays: [TimeInterval] = []
  var pendingCount: Int { entries.filter(\.active).count }

  func schedule(after seconds: TimeInterval, action: @escaping () -> Void) -> () -> Void {
    let entry = Entry(deadline: now + seconds, action: action)
    entries.append(entry)
    delays.append(seconds)
    return { entry.active = false }
  }

  func advance(by seconds: TimeInterval) {
    now += seconds
    for entry in entries where entry.active && entry.deadline <= now {
      entry.active = false
      entry.action()
    }
  }
}

/// Before-capture failures use the production notice paths. Only time and the explicit System
/// Settings action are substituted; panels, hover tracking, close buttons and dismissal are real.
@MainActor
func runNoticeFocusTests(using driver: FocusTestDriver) async throws {
  let clock = NoticeFocusClock()
  let notices = NoticeCenter(schedule: clock.schedule)
  let controller = SessionController(answers: AnthropicClient(transport: ScriptedAPI()),
    apiKey: { "sk-ant-snapscreen-notice-test" }, settings: { .defaults })
  let snips = SnipWindows(controller: controller, showNotice: { notices.show($0, action: $1) })
  defer {
    notices.dismiss()
    snips.closeAll()
    snips.shields.stop()
  }
  let away = NSPoint(x: driver.screen.visibleFrame.midX, y: driver.screen.visibleFrame.midY)
  try await driver.movePointer(away)

  func notice(_ stage: String) async throws -> (NoticePanel, NoticePanelView) {
    guard let panel = notices.panel, let view = panel.contentView as? NoticePanelView else {
      throw NoticeFocusFailure.failed("\(stage) displays a notice")
    }
    try driver.require(panel.isVisible, "\(stage) is visible")
    // orderFront schedules WindowServer presentation. Wait for that presentation, keeping the
    // focus observers running, before checking its order relative to the foreground window.
    try await driver.wait("\(stage) reaches WindowServer") {
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]] ?? []
      return windows.contains { $0[kCGWindowNumber as String] as? Int == panel.windowNumber }
    }
    try driver.checkPanel(panel, stage)
    return (panel, view)
  }

  // Both expected capture failures and unexpected errors flow from the session controller into
  // SnipWindows, rather than constructing a notice with a duplicate test-only message.
  for expectedFailure in [true, false] {
    let message = expectedFailure ? "The display was disconnected." :
      "SnapScreen couldn't capture the screen. Try again."
    let session = controller.start {
      if expectedFailure { throw CaptureError(message) }
      throw NoticeFocusFailure.unknownCapture
    }
    try await driver.wait("a failed capture presents its notice") { notices.panel != nil }
    let (panel, view) = try await notice("capture failure notice")
    try driver.require(view.messageLabel.stringValue == message && view.actionButton == nil &&
      session?.phase == .ended && snips.sessions.isEmpty,
      "the capture failure has the expected message, no action and no capture windows")
    try await driver.probe("with the capture failure notice visible")
    if expectedFailure {
      try driver.require(!view.messageLabel.isSelectable, "the notice's message isn't selectable text")
      try await driver.checkNoNativeMenu(on: view.messageLabel, "the notice's message")
    }
    try await driver.click(view.closeButton)
    try await driver.wait("the capture failure close button dismisses its notice") { notices.panel == nil }
    try driver.require(!panel.isVisible && clock.pendingCount == 0,
      "closing the capture failure notice also cancels its deadline")
    try await driver.probe("after the capture failure notice closes")
    try await driver.movePointer(away)
  }

  var permissionChecks = 0
  var settingsRequests = 0
  let services = AppServices(keyStore: FocusTestKeyStore(),
    answers: AnthropicClient(transport: ScriptedAPI()),
    screenRecordingGranted: { permissionChecks += 1; return false },
    openScreenRecordingSettings: { settingsRequests += 1 })
  // No launch callback is needed: the permission guard in the actual Snip action precedes
  // capture/session setup and must show the same notice even before either can run.
  let app = AppDelegate(services: services, notices: notices)
  app.snip()
  let (deniedPanel, deniedView) = try await notice("Screen Recording permission notice")
  try driver.require(permissionChecks == 1 && settingsRequests == 0 &&
    deniedView.messageLabel.stringValue == "SnapScreen needs Screen Recording permission to snip." &&
    deniedView.actionButton?.title == "Open System Settings",
    "denied Screen Recording shows an explicit action without requesting permission")
  try driver.require(clock.delays.last == 8 && clock.pendingCount == 1,
    "the notice initially schedules the production eight-second deadline")
  try await driver.probe("with Screen Recording denied")
  try await driver.click(deniedView.closeButton)
  try await driver.wait("the denied permission notice closes") { notices.panel == nil }
  try driver.require(!deniedPanel.isVisible && settingsRequests == 0 && clock.pendingCount == 0,
    "closing the permission notice does not open System Settings")
  try await driver.probe("after closing the denied permission notice")

  try await driver.movePointer(away)
  app.snip()
  let (timedPanel, _) = try await notice("automatically dismissed permission notice")
  clock.advance(by: 7)
  try driver.require(notices.panel === timedPanel && timedPanel.isVisible,
    "an untouched notice remains visible before its initial deadline")
  clock.advance(by: 1)
  try await driver.wait("the untouched notice dismisses at its initial deadline") { notices.panel == nil }
  try driver.require(!timedPanel.isVisible && settingsRequests == 0 && clock.pendingCount == 0,
    "the initial deadline closes the notice without opening System Settings")
  try await driver.probe("after the untouched permission notice automatically dismisses")

  app.snip()
  let (hoverPanel, _) = try await notice("hoverable permission notice")
  try await driver.movePointer(NSPoint(x: hoverPanel.frame.midX, y: hoverPanel.frame.midY))
  try await driver.wait("hovering pauses the notice's dismissal") { clock.pendingCount == 0 }
  clock.advance(by: NoticeCenter.duration)
  try driver.require(notices.panel === hoverPanel && hoverPanel.isVisible,
    "a hovered notice survives its original dismissal deadline")
  try await driver.probe("while hovering over the permission notice")
  try await driver.movePointer(away)
  try await driver.wait("leaving the notice restarts its dismissal deadline") { clock.pendingCount == 1 }
  try driver.require(clock.delays.last == 3,
    "leaving the notice schedules the production three-second grace period")
  clock.advance(by: 2)
  try driver.require(notices.panel === hoverPanel && hoverPanel.isVisible,
    "the restarted deadline keeps the notice visible through its grace period")
  try await driver.probe("after leaving the permission notice before dismissal")
  clock.advance(by: 1)
  try await driver.wait("the notice automatically dismisses after its grace period") { notices.panel == nil }
  try driver.require(!hoverPanel.isVisible && clock.pendingCount == 0 && settingsRequests == 0,
    "automatic dismissal cancels its timer and leaves System Settings closed")
  try await driver.probe("after the permission notice automatically dismisses")

  app.snip()
  let (actionPanel, actionView) = try await notice("permission notice action")
  guard let actionButton = actionView.actionButton else {
    throw NoticeFocusFailure.failed("the permission notice offers Open System Settings")
  }
  try await driver.click(actionButton)
  try await driver.wait("Open System Settings dispatches and closes its notice") { notices.panel == nil }
  try driver.require(settingsRequests == 1 && !actionPanel.isVisible && clock.pendingCount == 0,
    "only an explicit action dispatches Open System Settings once and dismisses the notice")
  try await driver.probe("after the explicit System Settings action dispatches to its test substitute")
}
#endif
