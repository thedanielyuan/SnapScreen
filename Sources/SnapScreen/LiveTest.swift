#if SNAPSCREEN_TEST_HOOKS
import AppKit
import Carbon.HIToolbox
import SnapScreenCore
import WebKit

// The live test, compiled only into the test-hooks build that scripts/test-app-live.sh makes, with
// its own bundle ID. A made-up capture replaces ScreenCaptureKit, because CI can't grant Screen
// Recording, and a scripted event stream replaces the API. Everything else is the real app: the
// session controller, the client reading the stream, and the overlay and conversation windows.

/// Answers the first request, the follow-up and the second snip as the API streams them, and keeps
/// the requests.
final class ScriptedAPI: HTTPTransport, @unchecked Sendable {
  static let firstAnswer = "SNAPSCREEN_LIVE_FIRST_ANSWER\n\n```python\nprint(2 + 2)\n```\n\nThe result is 4."
  static let followUp = "SNAPSCREEN_LIVE_FOLLOW_UP"
  static let followUpAnswer = "SNAPSCREEN_LIVE_FOLLOW_UP_ANSWER"
  static let secondSnipAnswer = "SNAPSCREEN_LIVE_SECOND_SNIP_ANSWER"

  private let lock = NSLock()
  private var bodies: [Data] = []

  /// Each request's JSON body, in order.
  var requests: [[String: Any]] {
    lock.withLock { bodies.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
  }

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    let index = lock.withLock { () -> Int in
      bodies.append(request.httpBody ?? Data())
      return bodies.count - 1
    }
    let text = [Self.firstAnswer, Self.followUpAnswer, Self.secondSnipAnswer][min(index, 2)]
    let half = text.index(text.startIndex, offsetBy: text.count / 2)
    let events: [[String: Any]] = [
      ["type": "message_start", "message": ["id": "msg_snapscreen_live", "type": "message", "role": "assistant",
        "model": AnthropicClient.model, "content": [] as [Any], "usage": ["input_tokens": 1, "output_tokens": 0]]],
      ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]],
      ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "c2lnbmF0dXJl"]],
      ["type": "content_block_stop", "index": 0],
      ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]],
      ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": String(text[..<half])]],
      ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": String(text[half...])]],
      ["type": "content_block_stop", "index": 1],
      ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 2]],
      ["type": "message_stop"],
    ]
    let chunks = try events.map { event -> Data in
      let json = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
      return Data("event: \(event["type"]!)\ndata: \(json)\n\n".utf8)
    }
    // Paced like a real stream, so the window shows thinking, then text arriving.
    let body = AsyncThrowingStream<Data, any Error> { continuation in
      let task = Task {
        for chunk in chunks {
          try? await Task.sleep(for: .milliseconds(150))
          continuation.yield(chunk)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return HTTPResponse(status: 200, headers: ["content-type": "text/event-stream"], body: body, cancel: {})
  }
}

/// A key kept in memory, starting empty, so the app shell shows its missing-key notice.
final class FocusTestKeyStore: APIKeyStore {
  private var key: String?
  var hasKey: Bool { key != nil }
  func read() throws -> String? { key }
  func save(_ key: String) throws { self.key = key }
  func remove() throws { key = nil }
}

/// Open at login for the app shell copy, which never registers it.
final class InertLoginItem: LoginItem {
  var isEnabled: Bool { false }
  var needsApproval: Bool { false }
  func setEnabled(_ enabled: Bool) throws {}
  func openSystemSettings() {}
}

extension AppServices {
  /// The real app with nothing real behind it, for the focus test's app shell copy: a key kept in
  /// memory, a made-up capture of the display, scripted answers, and Settings that leaves the
  /// login items, System Settings and the API alone.
  static var focusTest: AppServices {
    let keyStore = FocusTestKeyStore()
    return AppServices(keyStore: keyStore, answers: AnthropicClient(transport: ScriptedAPI()),
      screenRecordingGranted: { true },
      capture: { displayID in
        try await MainActor.run {
          guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
            throw CaptureError("The display went away.")
          }
          return FrozenScreen(image: LiveTest.fixture(for: screen), displayID: displayID)
        }
      },
      settings: { keyStore, shortcut in
        SettingsServices(keyStore: keyStore, verifyKey: { _ in }, screenRecordingGranted: { true },
          openScreenRecordingSettings: {}, loginItem: InertLoginItem(), shortcut: shortcut)
      })
  }
}

/// Snips twice through real windows. Pointer events select the regions without taking keyboard
/// focus. The first snip reads the answer, submits a follow-up programmatically and opens the
/// preview. The second replaces that conversation and preview, then closes its own as a click in
/// another app does. It exits 0 once every check passes, and 1 at the first that fails.
@MainActor
final class LiveTest: NSObject, NSApplicationDelegate, SessionControllerDelegate {
  static let timeout: TimeInterval = 45
  private let api = ScriptedAPI()
  /// Where Copy writes during the test, so it never touches the clipboard.
  private let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.snapscreen.app.test-hooks.\(UUID().uuidString)"))
  private var controller: SessionController?
  private var snips: SnipWindows?
  private var screen: NSScreen?
  private var capture: FrozenScreen?
  private var session: SnipSession?
  private var expectedCrop: (width: Int, height: Int)?
  private var selectionOnScreen: CGRect?
  /// The first snip's windows, open while the second snip selects.
  private var replaced: (windows: SessionWindows, panel: CompanionPanel, preview: CompanionPanel)?
  private var answers = 0
  private var checks = 0
  private var foregroundProcessID: Int32?
  private var focusMonitor: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    installEditingMenu(applicationName: "SnapScreen")
    Clipboard.pasteboard = pasteboard
    let controller = SessionController(answers: AnthropicClient(transport: api), apiKey: { "sk-ant-snapscreen-live-test" },
      settings: { .defaults })
    snips = SnipWindows(controller: controller, showNotice: { [weak self] message, _ in
      self?.fail("no notice is shown, but one said: \(message)")
    })
    // Watch what the windows are told, then pass it on.
    controller.delegate = self
    self.controller = controller
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
      self?.fail("the exchange finishes within \(Int(Self.timeout)) seconds")
    }
    guard let screen = screenUnderPointer(), let displayID = screen.displayID else {
      fail("there's a display to snip")
      return
    }
    self.screen = screen
    let capture = FrozenScreen(image: Self.fixture(for: screen), displayID: displayID)
    self.capture = capture
    foregroundProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    checkBackground("before capture")
    let monitor = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkBackground("while capture and answer windows are displayed") }
    }
    RunLoop.main.add(monitor, forMode: .common)
    focusMonitor = monitor
    controller.start { capture }
  }

  func session(_ session: SnipSession, didReport event: SessionEvent) {
    snips?.session(session, didReport: event)
    switch event {
    case .captured:
      self.session = session
      // As a person would, select once the overlay is up.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.selectRegion() }
    case .answer(_, .done):
      // The windows finish updating first.
      DispatchQueue.main.async { [weak self] in self?.answered() }
    case .failed(let error):
      fail("the request succeeds, but it failed: \(error.message)")
    case .ended:
      fail("the session stays open until it's closed")
    default:
      break
    }
  }

  func sessionController(_ controller: SessionController, showNotice message: String) {
    fail("no notice is shown, but one said: \(message)")
  }

  /// Whether SnapScreen took over the menu bar from the app beneath.
  private var isFrontmost: Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
  }

  private func checkBackground(_ stage: String) {
    check(!isFrontmost && !NSApp.isActive && NSApp.keyWindow == nil &&
      NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundProcessID,
      "the original app keeps focus \(stage)")
  }

  private func checkPassive(_ panel: CompanionPanel, _ stage: String) {
    check(panel.isVisible && !panel.canBecomeKey && !panel.canBecomeMain && !panel.isKeyWindow &&
      panel.styleMask.contains(.nonactivatingPanel) && panel.isFloatingPanel && panel.becomesKeyOnlyIfNeeded &&
      !panel.hidesOnDeactivate && panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary]),
      "the \(stage) panel remains non-key across applications and Spaces")
    checkBackground("with the \(stage) panel")
  }

  private func check(_ value: Bool, _ name: String) {
    if value { checks += 1 } else { fail(name) }
  }

  private func fail(_ name: String) {
    FileHandle.standardError.write(Data("SnapScreen live test failed: \(name)\n".utf8))
    focusMonitor?.invalidate()
    pasteboard.releaseGlobally()
    exit(1)
  }

  private func selectRegion() {
    guard let screen = screen, let windows = snips?.sessions.first(where: { $0.session === session }),
      let overlay = windows.overlay, let view = windows.selectionView, let image = view.image else {
      fail("the capture opens the overlay")
      return
    }
    check(overlay.isVisible && overlay.frame == screen.frame && !overlay.isOpaque && overlay.level == .screenSaver,
      "the overlay covers the display, above everything, and isn't opaque")
    checkPassive(overlay, "selection")
    if let earlier = replaced {
      check(earlier.panel.isVisible && earlier.preview.isVisible && earlier.windows.session.phase == .ready,
        "a new snip leaves the conversation and preview open while you select")
    }
    // The selection is small enough that image fitting won't reduce its expected crop.
    let width = min(320, view.imageRect.width / 2)
    let height = min(180, view.imageRect.height / 2)
    let start = NSPoint(x: view.imageRect.midX - width / 2, y: view.imageRect.midY - height / 2)
    let end = NSPoint(x: start.x + width, y: start.y + height)
    overlay.sendEvent(pointer(.leftMouseDown, at: view.convert(start, to: nil), in: overlay))
    checkPassive(overlay, "pressed selection")
    overlay.sendEvent(pointer(.leftMouseDragged, at: view.convert(end, to: nil), in: overlay))
    guard let selection = view.selection, let region = view.selectionDisplayRect else {
      fail("dragging places a pointer selection")
      return
    }
    check(view.isDragging && !view.isKeyboardSelection && view.canConfirm,
      "the pointer drag selects a region without keyboard input")
    checkPassive(overlay, "dragged selection")
    selectionOnScreen = overlay.convertToScreen(view.convert(region, to: nil))
    expectedCrop = (Int(((selection.maxX) * image.size.width).rounded()) - Int((selection.minX * image.size.width).rounded()),
      Int(((selection.maxY) * image.size.height).rounded()) - Int((selection.minY * image.size.height).rounded()))
    overlay.sendEvent(pointer(.leftMouseUp, at: view.convert(end, to: nil), in: overlay))
    check(windows.overlay == nil && windows.panel?.isVisible == true && windows.composer?.isRunning == true,
      "releasing the drag replaces the overlay with the conversation, waiting for its answer")
    if let panel = windows.panel { checkPassive(panel, "waiting conversation") }
    if let earlier = replaced {
      guard let panel = windows.panel, let shield = snips?.shields.shield else {
        fail("the new conversation opens above the pointer shield")
        return
      }
      check(!earlier.panel.isVisible && !earlier.preview.isVisible && earlier.windows.panel == nil &&
        earlier.windows.session.phase == .ended && snips?.sessions.count == 1,
        "the new snip's conversation closes the earlier conversation and preview, ending its session")
      checkPassive(panel, "replacement conversation")
      // Front to back, this app's windows on screen.
      let order = (NSWindow.windowNumbers(options: []) ?? []).map(\.intValue)
      check(order.firstIndex(of: panel.windowNumber).map { order.dropFirst($0 + 1).first == shield.windowNumber } == true &&
        shield.isVisible && shield.ignoresMouseEvents, "the pointer shield moves beneath the new conversation")
    }
  }

  private func pointer(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }

  private func answered() {
    answers += 1
    guard let windows = snips?.sessions.first(where: { $0.session === session }), let panel = windows.panel,
      let thread = windows.conversation, let composer = windows.composer, let turn = thread.latestTurn else {
      fail("the conversation stays open while it's answered")
      return
    }
    checkPassive(panel, "answered conversation")
    check(composer.isReadOnly && !composer.textView.isEditable && !composer.textView.isSelectable &&
      composer.sendButton.isHidden, "the finished conversation offers no editable field or Send button")
    if answers == 1 {
      check(turn.answer.renderedText == ScriptedAPI.firstAnswer && !thread.thumbnail.isHidden,
        "the first answer and the screenshot's thumbnail show")
      let scroll = thread.scrollView
      check(scroll.documentView!.frame.height <= scroll.contentSize.height + 1 &&
        panel.contentLayoutRect.height < SessionWindows.defaultConversationSize.height,
        "the conversation is only as tall as its answer needs")
      if let selection = selectionOnScreen, let screen = screen,
        screen.visibleFrame.maxX - selection.maxX > panel.frame.width + 16 {
        check(panel.frame.minX >= selection.maxX, "the conversation opens beside the selection")
      }
      // Pointer controls keep working without a key window or a keyboard shortcut.
      thread.codeToCopy?.copyButton?.performClick(nil)
      check(pasteboard.string(forType: .string) == "print(2 + 2)", "the Copy button copies its code block")
      checkPassive(panel, "conversation after Copy")
      check(windows.dismissesOnOutsideClick, "once the answer finishes, a click in another app can close it")
      // Retain the client/history replay check through a direct submission. The passive UI never
      // asks the user to type or takes keyboard focus for this synthetic follow-up.
      composer.setDraft(ScriptedAPI.followUp)
      composer.submit()
      check(thread.turns.count == 2 && composer.isRunning, "the follow-up starts a new turn")
      check(!windows.dismissesOnOutsideClick, "a click in another app can't close the follow-up as it's answered")
      return
    }
    if answers == 2 {
      check(turn.question == ScriptedAPI.followUp && turn.answer.renderedText == ScriptedAPI.followUpAnswer,
        "the follow-up and its answer show")
      checkRequests()
      thread.onPreview?()
      guard let preview = windows.previewPanel, let capture = capture else {
        fail("the screenshot preview opens")
        return
      }
      checkPassive(preview, "preview")
      check(windows.dismissesOnOutsideClick, "a click in another app can close the conversation and preview")
      // Snip again, as the shortcut does. Selecting its region replaces this conversation.
      replaced = (windows, panel, preview)
      controller?.start { capture }
      return
    }
    check(turn.question == nil && thread.turns.count == 1 && turn.answer.renderedText == ScriptedAPI.secondSnipAnswer,
      "the new snip's answer shows in a conversation of its own")
    check(api.requests.count == 3 && (api.requests[2]["messages"] as? [[String: Any]])?.count == 1,
      "the new snip's request carries none of the earlier conversation")
    thread.onPreview?()
    guard let preview = windows.previewPanel, let screen = screen else {
      fail("the new snip's preview opens")
      return
    }
    checkPassive(preview, "new snip's preview")
    check(windows.dismissesOnOutsideClick, "a click in another app can close the new conversation and preview")
    // Another panel, as a new snip's overlay would be. Closing the old windows must never make it
    // key, including when the original application has retained focus throughout.
    let other = CompanionPanel.make(title: "Other", contentSize: SessionWindows.minimumConversationSize,
      minimumSize: SessionWindows.minimumConversationSize, media: false)
    other.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.maxY - other.frame.height))
    other.orderFront(nil)
    checkPassive(other, "other conversation")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      self?.clickElsewhere(windows, panel: panel, preview: preview, other: other, on: screen)
    }
  }

  private func clickElsewhere(_ windows: SessionWindows, panel: CompanionPanel, preview: CompanionPanel,
    other: CompanionPanel, on screen: NSScreen) {
    checkPassive(preview, "preview before outside dismissal")
    // The click reaches the monitor with its position, away from the panels. It closes them as the
    // close button does, which ends the session and releases its windows.
    let margin = SessionWindows.outsideClickMargin + 1
    let visible = screen.visibleFrame.insetBy(dx: 1, dy: 1)
    guard let elsewhere = [NSPoint(x: visible.minX, y: visible.minY), NSPoint(x: visible.maxX, y: visible.minY),
      NSPoint(x: visible.minX, y: visible.maxY), NSPoint(x: visible.maxX, y: visible.maxY)].first(where: { point in
        ![panel.frame, preview.frame, other.frame].contains { $0.insetBy(dx: -margin, dy: -margin).contains(point) }
      }) else {
      fail("there's room on the display away from the panels")
      return
    }
    windows.clickedOutside(at: elsewhere)
    check(!panel.isVisible && !preview.isVisible && snips?.sessions.isEmpty == true && session?.phase == .ended &&
      !windows.dismissesOnOutsideClick, "a click in another app closes the conversation and preview, ending the session")
    checkPassive(other, "remaining conversation after dismissal")
    other.close()
    check(snips?.shields.shield.map { !$0.isVisible && $0.ignoresMouseEvents } ?? false,
      "the pointer shield is hidden and lets clicks through once they close")
    checkBackground("after all windows close")
    focusMonitor?.invalidate()
    print("SnapScreen live test passed (test hooks build): \(checks) checks, pointer selection, streamed answer, " +
      "programmatic follow-up, preview, replacement and dismissal through real windows without keyboard focus")
    pasteboard.releaseGlobally()
    exit(0)
  }

  private func checkRequests() {
    let requests = api.requests
    guard requests.count == 2, let first = requests[0]["messages"] as? [[String: Any]],
      let followUp = requests[1]["messages"] as? [[String: Any]] else {
      fail("the client sends one request for the answer and one for the follow-up")
      return
    }
    let blocks = first.first?["content"] as? [[String: Any]] ?? []
    let source = blocks.first?["source"] as? [String: Any]
    let crop = (source?["data"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(Self.pixelSize)
    check(first.count == 1 && blocks.count == 2 && source?["media_type"] as? String == "image/png" &&
      blocks.last?["text"] as? String == sessionGuidancePrefix + SessionSettings.defaults.defaultPrompt,
      "the first request sends the screenshot with the Default Prompt")
    check(crop.map { $0.width == expectedCrop?.width && $0.height == expectedCrop?.height } == true,
      "the screenshot is the selected region of the capture, in its pixels")
    check(followUp.count == 3 && followUp[1]["content"] as? String == ScriptedAPI.firstAnswer &&
      followUp[2]["content"] as? String == ScriptedAPI.followUp,
      "the follow-up resends the conversation with the new question")
    check(requests.allSatisfy { $0["model"] as? String == AnthropicClient.model && $0["stream"] as? Bool == true },
      "both requests stream from the app's model")
  }

  private static func pixelSize(_ png: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return (image.width, image.height)
  }

  /// A stand-in for the display's contents, at its pixel size.
  fileprivate static func fixture(for screen: NSScreen) -> CGImage {
    let scale = screen.backingScaleFactor
    let width = Int(screen.frame.width * scale)
    let height = Int(screen.frame.height * scale)
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
      CGColor(srgbRed: 0.16, green: 0.2, blue: 0.36, alpha: 1), CGColor(srgbRed: 0.42, green: 0.36, blue: 0.9, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let label = NSAttributedString(string: "SnapScreen live test: what is 2 + 2?", attributes: [
      .font: NSFont.systemFont(ofSize: 36 * scale, weight: .semibold), .foregroundColor: NSColor.white])
    let size = label.size()
    label.draw(at: CGPoint(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
  }
}

/// An opt-in WindowServer test. Unlike `LiveTest`, it posts the real shortcut and mouse events,
/// and types into a local webpage in a separate app to prove that keyboard focus stayed there.
/// Only the capture and API are fixtures. Event posting needs an existing macOS approval.
@MainActor
final class LiveFocusTest: NSObject, NSApplicationDelegate {
  private let hotkey = Hotkey(.snip)
  private let api = ScriptedAPI()
  private let target = Process()
  private let commands = Pipe()
  private let reports = Pipe()
  private let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.snapscreen.app.focus-test.\(UUID().uuidString)"))
  private var snips: SnipWindows?
  private var previousApp: NSRunningApplication?
  private var pending = Data()
  private var messages: [[String: Any]] = []
  private var expectedInput = ""
  private var nativeFailures = 0
  private var monitor: Timer?
  private var checks = 0
  private var pressedPoint: NSPoint?
  /// Who the app shell phase lets be in front: the target; Settings, which you open yourself; or
  /// SnapScreen, briefly, while it hands an activation it didn't ask for straight back.
  private enum Front { case target, settings, handback }
  private var front = Front.target
  private var activations: [(pid: pid_t, time: Date)] = []
  private var shellApp: NSRunningApplication?

  private struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { @MainActor in
      do {
        try await run()
        finish(nil)
      } catch {
        finish(String(describing: error))
      }
    }
  }

  private func require(_ value: Bool, _ message: String) throws {
    guard value else { throw Failure(description: message) }
    checks += 1
  }

  private func waitFor(_ message: String, _ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(15)
    while !predicate() {
      try require(target.isRunning, "the isolated focus target stays open")
      guard Date() < deadline else { throw Failure(description: message) }
      try await Task.sleep(for: .milliseconds(25))
    }
  }

  private func run() async throws {
    try require(CGPreflightPostEventAccess(),
      "event posting is not approved; grant Accessibility to the terminal running --focus, then retry")
    try require(NSApp.activationPolicy() == .accessory && Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true,
      "the test app is an accessory agent")
    try require(hotkey.register(), "⌥⇧S is in use; quit the running SnapScreen copy before --focus, then reopen it afterwards")
    guard let path = ProcessInfo.processInfo.environment["SNAPSCREEN_FOCUS_TARGET"] else {
      throw Failure(description: "run the focus test through scripts/test-app-live.sh --focus")
    }
    previousApp = NSWorkspace.shared.frontmostApplication
    target.executableURL = URL(fileURLWithPath: path)
    target.arguments = ["--focus-target"] + (CommandLine.arguments.contains("--fullscreen") ? ["--fullscreen"] : [])
    target.standardInput = commands
    target.standardOutput = reports
    reports.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task { @MainActor in self?.receive(data) }
    }
    try target.run()
    // If macOS refused the target's own activation, LaunchServices activates it, as a click would.
    try await Task.sleep(for: .seconds(1))
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
      let activate = Process()
      activate.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      activate.arguments = ["-e", "tell application id \"com.snapscreen.app.test-hooks.focus-target\" to activate"]
      try activate.run()
      activate.waitUntilExit()
    }
    try await waitFor("the local webpage becomes ready") { self.messages.contains { $0["ready"] as? Bool == true } }
    let ready = messages.removeFirst()
    try require(ready["positiveControl"] as? Bool == true,
      "the webpage's focus observer detects an intentional key-window change before measurement")
    guard let targetWindow = ready["window"] as? Int, let x = ready["x"] as? Double,
      let y = ready["y"] as? Double, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: x, y: y)) }),
      let displayID = screen.displayID else { throw Failure(description: "the target reports its focused field and display") }
    let field = NSPoint(x: x, y: y)
    let capture = FrozenScreen(image: LiveTest.fixture(for: screen), displayID: displayID)
    Clipboard.pasteboard = pasteboard
    let controller = SessionController(answers: AnthropicClient(transport: api),
      apiKey: { "sk-ant-snapscreen-focus-test" }, settings: { .defaults })
    snips = SnipWindows(controller: controller, showNotice: { [weak self] _, _ in self?.nativeFailures += 1 })
    hotkey.onPress = { controller.start { capture } }
    let monitor = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        if NSApp.isActive || NSApp.keyWindow != nil || NSApp.mainWindow != nil ||
          NSWorkspace.shared.frontmostApplication?.processIdentifier != self.target.processIdentifier {
          self.nativeFailures += 1
        }
      }
    }
    RunLoop.main.add(monitor, forMode: .common)
    self.monitor = monitor
    try await probe("before the hotkey")
    // Keep the pointer on the target's display before using the registered global shortcut.
    try postPointer(.mouseMoved, at: field)
    try postKey(CGKeyCode(kVK_ANSI_S), flags: [.maskAlternate, .maskShift])
    try await waitFor("the actual global hotkey opens the selection overlay") { self.snips?.sessions.first?.overlay != nil }
    guard let windows = snips?.sessions.first, let overlay = windows.overlay, let view = windows.selectionView else {
      throw Failure(description: "the hotkey creates a selection session")
    }
    try passive(overlay, above: targetWindow, stage: "selection")
    try await probe("with the selection open")
    let start = NSPoint(x: screen.frame.midX - 140, y: screen.frame.midY - 80)
    let end = NSPoint(x: start.x + 280, y: start.y + 160)
    try postPointer(.leftMouseDown, at: start)
    try await Task.sleep(for: .milliseconds(80))
    try postPointer(.leftMouseDragged, at: end)
    try await waitFor("WindowServer delivers the drag to the selection") { view.isDragging && view.canConfirm }
    try await probe("during the selection drag")
    try postPointer(.leftMouseUp, at: end)
    try await waitFor("releasing the selection opens the answer") { windows.panel?.isVisible == true }
    guard let panel = windows.panel else { throw Failure(description: "the answer panel exists") }
    try passive(panel, above: targetWindow, stage: "streaming answer")
    try await probe("while the answer streams")
    try await waitFor("the answer finishes") { windows.session.phase == .ready }
    guard let thread = windows.conversation, let copy = thread.codeToCopy?.copyButton else {
      throw Failure(description: "the answer exposes its Copy button")
    }
    try passive(panel, above: targetWindow, stage: "finished answer")
    try await probe("after answer completes, before Settings")
    // Settings deliberately takes focus. Closing it must return to the webpage even when a
    // visible passive conversation remains, without hiding that conversation along with the app.
    monitor.invalidate()
    let settings = NSWindow(contentRect: NSRect(x: screen.frame.midX - 160, y: screen.frame.midY - 100,
      width: 320, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    settings.isReleasedWhenClosed = false
    settings.title = "SnapScreen Focus Test — synthetic Settings"
    settings.level = .floating
    settings.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    settings.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(100))
    // macOS can reject a background process's unsolicited activation. Give this intentionally
    // foreground flow the real user gesture it has in the app: a click in its normal window.
    let titlebar = NSPoint(x: settings.frame.midX, y: settings.frame.maxY - 12)
    try postPointer(.mouseMoved, at: titlebar)
    try postPointer(.leftMouseDown, at: titlebar)
    releasePostedPointer()
    try await waitFor("the explicit Settings flow takes focus") { NSApp.isActive && settings.isKeyWindow }
    settings.close()
    ForegroundFocus.returnToPreviousApp(ignoring: settings)
    try await waitFor("closing Settings returns to the original app with an answer still open") {
      NSWorkspace.shared.frontmostApplication?.processIdentifier == self.target.processIdentifier && !NSApp.isActive
    }
    // Reset only after confirming Settings returned focus. The helper separately verifies that
    // its key window, original responder and webpage focus have all actually been restored.
    messages.removeAll()
    try commands.fileHandleForWriting.write(contentsOf: Data("reset\n".utf8))
    try await waitFor("the target confirms focus after Settings") { !self.messages.isEmpty }
    let restored = messages.removeFirst()
    try require(restored["restored"] as? Bool == true,
      "closing Settings restores the original webpage and native first responder")
    nativeFailures = 0
    let resumed = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        if NSApp.isActive || NSApp.keyWindow != nil || NSApp.mainWindow != nil ||
          NSWorkspace.shared.frontmostApplication?.processIdentifier != self.target.processIdentifier {
          self.nativeFailures += 1
        }
      }
    }
    RunLoop.main.add(resumed, forMode: .common)
    self.monitor = resumed
    try passive(panel, above: targetWindow, stage: "conversation after closing Settings")
    try await probe("after closing Settings")
    try await click(copy)
    try await waitFor("a real pointer click copies the code") { self.pasteboard.string(forType: .string) == "print(2 + 2)" }
    try await probe("after clicking Copy")
    try await click(thread.thumbnail)
    try await waitFor("a real pointer click opens the preview") { windows.previewPanel?.isVisible == true }
    guard let preview = windows.previewPanel else { throw Failure(description: "the preview exists") }
    try passive(preview, above: targetWindow, stage: "preview")
    try await probe("with the preview open")
    guard let close = preview.standardWindowButton(.closeButton) else {
      throw Failure(description: "the preview exposes its close button")
    }
    try await click(close)
    try await waitFor("the preview closes by its pointer button") { windows.previewPanel == nil }
    try await probe("after closing the preview")
    // Click the original textarea. Its input handler must still receive this click, and the global
    // mouse monitor must close the finished conversation without consuming it or taking focus.
    try require(!panel.frame.insetBy(dx: -10, dy: -10).contains(field), "the original field is outside the answer")
    try postPointer(.leftMouseDown, at: field)
    try postPointer(.leftMouseUp, at: field)
    try await waitFor("the actual outside click dismisses the answer") { self.snips?.sessions.isEmpty == true }
    try await probe("after outside dismissal")
    try require(nativeFailures == 0, "the original app remains frontmost with its key window throughout")
    try await runAppShell(at: field, on: screen)
    print("SnapScreen focus test passed (test hooks build): \(checks) checks, actual ⌥⇧S, pointer selection, " +
      "Settings return, Copy, preview, close and outside dismissal; then the real app shell launched through " +
      "LaunchServices, its notice, an activation it handed back, " +
      (CommandLine.arguments.contains("--fullscreen") ? "a conversation open through Settings" :
        "its menu's Snip, Close All, Settings and Quit,") + " and reopening; webpage focus and typed input preserved" +
      (CommandLine.arguments.contains("--fullscreen") ? " in a fullscreen Space" : "") + ". Capture and API used fixtures.")
  }

  private func receive(_ data: Data) {
    pending.append(data)
    while let newline = pending.firstIndex(of: 10) {
      let line = pending.prefix(upTo: newline)
      pending.removeSubrange(...newline)
      if let report = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { messages.append(report) }
    }
  }

  private func probe(_ stage: String) async throws {
    try postKey(CGKeyCode(kVK_ANSI_X))
    expectedInput += "x"
    try await Task.sleep(for: .milliseconds(100))
    messages.removeAll()
    try commands.fileHandleForWriting.write(contentsOf: Data("check\n".utf8))
    try await waitFor("the target reports webpage focus \(stage)") { !self.messages.isEmpty }
    let report = messages.removeFirst()
    try require(report["focused"] as? Bool == true && report["activeElement"] as? Bool == true &&
      report["blurCount"] as? Int == 0 && report["visible"] as? Bool == true &&
      report["hiddenCount"] as? Int == 0 && report["nativeFailures"] as? Int == 0 &&
      report["text"] as? String == expectedInput && nativeFailures == 0,
      "the original webpage retains its focus ring, first responder and keyboard input \(stage): \(report)")
  }

  private func passive(_ panel: CompanionPanel, above window: Int, stage: String) throws {
    try require(panel.isVisible && panel.isOnActiveSpace && !panel.isKeyWindow && !panel.isMainWindow &&
      !panel.canBecomeKey && !panel.canBecomeMain && panel.styleMask.contains(.nonactivatingPanel) &&
      panel.isFloatingPanel && panel.becomesKeyOnlyIfNeeded && !panel.hidesOnDeactivate &&
      panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary]), "the \(stage) panel stays passive")
    let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? Int }
    try require(order.firstIndex(of: panel.windowNumber).flatMap { panelIndex in
      order.firstIndex(of: window).map { panelIndex < $0 }
    } == true, "the \(stage) panel appears above the foreground webpage")
  }

  private func click(_ view: NSView) async throws {
    guard let window = view.window else { throw Failure(description: "the pointer control has a window") }
    window.contentView?.layoutSubtreeIfNeeded()
    let point = window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
    try postPointer(.mouseMoved, at: point)
    try postPointer(.leftMouseDown, at: point)
    try await Task.sleep(for: .milliseconds(60))
    try postPointer(.leftMouseUp, at: point)
    try await Task.sleep(for: .milliseconds(100))
  }

  /// `frontmost` is the app expected in front instead of the target, such as Settings' app.
  private func postPointer(_ type: CGEventType, at point: NSPoint, frontmost: pid_t? = nil) throws {
    if let frontmost {
      try require(target.isRunning && !NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost,
        "only the expected app is in front before posting input to it")
    } else {
      try requireInputTarget()
    }
    let height = CGDisplayBounds(CGMainDisplayID()).height
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: point.x, y: height - point.y),
      mouseButton: .left)?.post(tap: .cghidEventTap)
    if type == .leftMouseDown || (type == .leftMouseDragged && pressedPoint != nil) { pressedPoint = point }
    if type == .leftMouseUp { pressedPoint = nil }
  }

  private func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
    try requireInputTarget()
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
      event?.flags = flags
      event?.post(tap: .cghidEventTap)
    }
  }

  private func requireInputTarget() throws {
    try require(target.isRunning && nativeFailures == 0 && !NSApp.isActive &&
      NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
      "focus must remain on the isolated target before posting any input")
  }

  private func finish(_ failure: String?) {
    monitor?.invalidate()
    hotkey.unregister()
    releasePostedPointer()
    snips?.closeAll()
    reports.fileHandleForReading.readabilityHandler = nil
    if target.isRunning { target.terminate() }
    if let shellApp, !shellApp.isTerminated { shellApp.forceTerminate() }
    previousApp?.activate(options: [])
    pasteboard.releaseGlobally()
    if let failure { FileHandle.standardError.write(Data("SnapScreen focus test failed: \(failure)\n".utf8)) }
    exit(failure == nil ? 0 : 1)
  }

  private func releasePostedPointer() {
    // A failed assertion during a drag must release our own press even when the target lost
    // focus. So must the one intentional Settings click that activates this test process. This
    // pairs an already-posted event; it never starts input in another application.
    if let point = pressedPoint {
      let height = CGDisplayBounds(CGMainDisplayID()).height
      CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
        mouseCursorPosition: CGPoint(x: point.x, y: height - point.y), mouseButton: .left)?.post(tap: .cghidEventTap)
      pressedPoint = nil
    }
  }
}

// MARK: The app shell

extension LiveFocusTest {
  /// The real AppDelegate, in a copy with its own bundle ID that the target launches through
  /// LaunchServices, with a key kept in memory and fixtures for the capture and answers. Its menu
  /// bar item, notice, shortcut, Settings and reopening are the real ones: Accessibility finds
  /// them, and posted clicks use them. Only Settings, opened on purpose, may take the target's place.
  fileprivate func runAppShell(at field: NSPoint, on screen: NSScreen) async throws {
    try require(AXIsProcessTrusted(),
      "Accessibility isn't approved for the terminal running --focus, so the test can't find the menu bar item")
    try require(ProcessInfo.processInfo.environment["SNAPSCREEN_FOCUS_APP"] != nil,
      "run the focus test through scripts/test-app-live.sh --focus")
    // The app shell registers the shortcut itself.
    hotkey.unregister()
    monitor?.invalidate()
    let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
      object: nil, queue: .main) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
      MainActor.assumeIsolated { self?.activations.append((app.processIdentifier, Date())) }
    }
    defer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    let monitor = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        if NSApp.isActive || (self.front == .target &&
          NSWorkspace.shared.frontmostApplication?.processIdentifier != self.target.processIdentifier) {
          self.nativeFailures += 1
        }
      }
    }
    RunLoop.main.add(monitor, forMode: .common)
    self.monitor = monitor

    // Launched with activation, as Finder, Spotlight and login items launch it, it stays in the
    // background. With no key saved, it shows a passive notice.
    messages.removeAll()
    try commands.fileHandleForWriting.write(contentsOf: Data("launch\n".utf8))
    try await waitFor("LaunchServices launches the app shell") { self.messages.contains { $0["launched"] != nil } }
    guard let pid = (messages.first { $0["launched"] != nil }?["launched"] as? Int).map({ pid_t($0) }), pid > 0,
      let shell = NSRunningApplication(processIdentifier: pid) else {
      throw Failure(description: "the app shell launches")
    }
    shellApp = shell
    let app = AXUIElementCreateApplication(pid)
    var openSettings: NSPoint?
    try await waitFor("the app shell shows its menu bar item and its missing-key notice") {
      openSettings = self.axButton("Open Settings", in: app).flatMap { self.axCenter($0) }
      return self.statusItem(of: app) != nil && openSettings != nil
    }
    try await probe("after LaunchServices launches SnapScreen")

    // The notice's Open Settings takes the keyboard on purpose, and closing Settings returns it.
    front = .settings
    try await click(at: openSettings!)
    try await waitFor("the notice's Open Settings gives Settings the keyboard") { self.settingsHasKeyboard(app, pid) }
    try await closeSettings(app, pid)
    try await settle("after Settings opened from the notice closes", blurAllowed: true)
    try await probe("after Settings opened from the notice closes")

    // Another app activates SnapScreen, as a launcher or a script can. It has no window for the
    // keyboard, so it hands activation back.
    front = .handback
    activations.removeAll()
    try commands.fileHandleForWriting.write(contentsOf: Data("yield \(pid)\n".utf8))
    var held: TimeInterval?
    try await waitFor("SnapScreen is activated, then hands activation back") {
      guard let up = self.activations.firstIndex(where: { $0.pid == pid }),
        let back = self.activations[up...].first(where: { $0.pid == self.target.processIdentifier }) else { return false }
      held = back.time.timeIntervalSince(self.activations[up].time)
      return true
    }
    try require(held! < 0.5, "SnapScreen hands activation back within half a second, not after \(Int(held! * 1000)) ms")
    front = .target
    try await settle("after SnapScreen hands activation back", blurAllowed: true)
    try await probe("after another app activates SnapScreen")

    // A fullscreen Space hides the menu bar until the pointer reaches the top, which posted events
    // don't do, so the fullscreen run keeps its conversation open through Settings and quits by
    // request, which closes it.
    let menuBar = !CommandLine.arguments.contains("--fullscreen")
    if menuBar {
      // The menu bar item's Snip opens the overlay without taking the keyboard; a click cancels it.
      try await chooseMenuItem("Snip", in: app, pid)
      try await waitFor("the menu's Snip opens the selection overlay") { self.windowFrames(of: pid, .screenSaverWindow).count == 1 }
      try await settle("with the overlay opened from the menu", blurAllowed: false)
      try await probe("with the selection opened from the menu")
      let overlay = windowFrames(of: pid, .screenSaverWindow)[0]
      try await click(at: NSPoint(x: overlay.midX, y: overlay.midY))
      try await waitFor("a click cancels the selection") { self.windowFrames(of: pid, .screenSaverWindow).isEmpty }
      try await probe("after a click cancels the selection")
    }

    // The real shortcut and a selection open a conversation, which Close All Conversations closes.
    try postPointer(.mouseMoved, at: field)
    try postKey(CGKeyCode(kVK_ANSI_S), flags: [.maskAlternate, .maskShift])
    try await waitFor("⌥⇧S opens the app shell's selection overlay") { self.windowFrames(of: pid, .screenSaverWindow).count == 1 }
    let start = NSPoint(x: screen.frame.midX - 140, y: screen.frame.midY - 80)
    let end = NSPoint(x: start.x + 280, y: start.y + 160)
    try postPointer(.leftMouseDown, at: start)
    try await Task.sleep(for: .milliseconds(80))
    try postPointer(.leftMouseDragged, at: end)
    try await Task.sleep(for: .milliseconds(80))
    try postPointer(.leftMouseUp, at: end)
    try await waitFor("the selection opens a conversation") { self.hasConversation(pid) }
    try await probe("with the app shell's conversation open")
    if menuBar {
      try await chooseMenuItem("Close All Conversations", in: app, pid)
      try await waitFor("Close All Conversations closes it") { !self.hasConversation(pid) }
      try await settle("after Close All Conversations", blurAllowed: false)
      try await probe("after Close All Conversations")
    }

    // Settings… takes the keyboard on purpose, as does opening the running app again, which shows
    // Settings. Closing it returns the keyboard each time.
    if menuBar {
      front = .settings
      try await chooseMenuItem("Settings…", in: app, pid)
      try await waitFor("Settings… gives Settings the keyboard") { self.settingsHasKeyboard(app, pid) }
      try await closeSettings(app, pid)
      try await settle("after Settings from the menu closes", blurAllowed: true)
      try await probe("after Settings from the menu closes")
    }
    front = .settings
    try commands.fileHandleForWriting.write(contentsOf: Data("launch\n".utf8))
    try await waitFor("opening the running app again gives Settings the keyboard") { self.settingsHasKeyboard(app, pid) }
    try await closeSettings(app, pid)
    try await settle("after reopened Settings closes", blurAllowed: true)
    try await probe("after reopened Settings closes")

    if menuBar {
      try await chooseMenuItem("Quit SnapScreen", in: app, pid)
    } else {
      shell.terminate()
    }
    try await waitFor("the app shell quits") { shell.isTerminated }
    try await settle("after the app shell quits", blurAllowed: false)
    try await probe("after the app shell quits")
    try require(nativeFailures == 0, "only Settings, opened on purpose, ever took the target's place in front")
  }

  /// Clicks the menu bar item, waits for its menu, and chooses `title`.
  private func chooseMenuItem(_ title: String, in app: AXUIElement, _ pid: pid_t) async throws {
    guard let item = statusItem(of: app), let point = axCenter(item) else {
      throw Failure(description: "the app shell has a menu bar item")
    }
    try await click(at: point)
    var choice: NSPoint?
    try await waitFor("the menu bar item's menu opens with \(title)") {
      guard !self.windowFrames(of: pid, .popUpMenuWindow).isEmpty else { return false }
      choice = self.axDescendants(of: item, depth: 3).first { self.axString($0, kAXTitleAttribute) == title }
        .flatMap { self.axCenter($0) }
      return choice != nil
    }
    try await click(at: choice!)
    try await waitFor("the menu closes once \(title) is chosen") { self.windowFrames(of: pid, .popUpMenuWindow).isEmpty }
  }

  private func settingsHasKeyboard(_ app: AXUIElement, _ pid: pid_t) -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == pid &&
      axElement(app, kAXFocusedWindowAttribute).map { axString($0, kAXTitleAttribute) == "SnapScreen Settings" } == true
  }

  private func closeSettings(_ app: AXUIElement, _ pid: pid_t) async throws {
    guard let window = axElement(app, kAXFocusedWindowAttribute), let button = axElement(window, kAXCloseButtonAttribute),
      let point = axCenter(button) else { throw Failure(description: "Settings has a close button") }
    try await click(at: point, frontmost: pid)
    try await waitFor("closing Settings gives the keyboard back to the original app") {
      NSWorkspace.shared.frontmostApplication?.processIdentifier == self.target.processIdentifier
    }
    front = .target
  }

  /// Once the target is in front, checks that its webpage has the keyboard again, and, unless
  /// something took it on purpose, that the page never blurred or hid since the last check.
  private func settle(_ stage: String, blurAllowed: Bool) async throws {
    try await waitFor("the original app is in front \(stage)") {
      NSWorkspace.shared.frontmostApplication?.processIdentifier == self.target.processIdentifier
    }
    try await Task.sleep(for: .milliseconds(200))
    messages.removeAll()
    try commands.fileHandleForWriting.write(contentsOf: Data("reset\n".utf8))
    try await waitFor("the target reports its focus \(stage)") { self.messages.contains { $0["restored"] != nil } }
    let report = messages.first { $0["restored"] != nil }!
    messages.removeAll()
    try require(report["restored"] as? Bool == true &&
      (blurAllowed || report["blurCount"] as? Int == 0 && report["hiddenCount"] as? Int == 0),
      "the webpage has the keyboard \(stage)\(blurAllowed ? "" : ", and never blurred or hid"): \(report)")
  }

  private func click(at point: NSPoint, frontmost: pid_t? = nil) async throws {
    try postPointer(.mouseMoved, at: point, frontmost: frontmost)
    try postPointer(.leftMouseDown, at: point, frontmost: frontmost)
    try await Task.sleep(for: .milliseconds(60))
    try postPointer(.leftMouseUp, at: point, frontmost: frontmost)
    try await Task.sleep(for: .milliseconds(100))
  }

  /// The frames, in AppKit's screen coordinates, of the app's on-screen windows at a level.
  private func windowFrames(of pid: pid_t, _ level: CGWindowLevelKey) -> [NSRect] {
    let height = CGDisplayBounds(CGMainDisplayID()).height
    return (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
      .filter { $0[kCGWindowOwnerPID as String] as? Int == Int(pid) &&
        $0[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(level)) }
      .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
      .map { NSRect(x: $0.minX, y: height - $0.maxY, width: $0.width, height: $0.height) }
  }

  /// A conversation: a floating window, unlike a notice taller than 250 points, and unlike the
  /// pointer shield smaller than its display.
  private func hasConversation(_ pid: pid_t) -> Bool {
    windowFrames(of: pid, .floatingWindow).contains { frame in
      frame.height > 250 && !NSScreen.screens.contains { $0.frame.size == frame.size }
    }
  }

  private func axValue(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
  }

  private func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = axValue(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
  }

  private func axString(_ element: AXUIElement, _ name: String) -> String? { axValue(element, name) as? String }

  private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    axValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
  }

  private func axDescendants(of element: AXUIElement, depth: Int) -> [AXUIElement] {
    guard depth > 0 else { return [] }
    return axChildren(element).flatMap { [$0] + axDescendants(of: $0, depth: depth - 1) }
  }

  /// An element's center in AppKit's screen coordinates.
  private func axCenter(_ element: AXUIElement) -> NSPoint? {
    guard let position = axValue(element, kAXPositionAttribute), let size = axValue(element, kAXSizeAttribute),
      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent),
      extent.width > 0, extent.height > 0 else { return nil }
    return NSPoint(x: origin.x + extent.width / 2, y: CGDisplayBounds(CGMainDisplayID()).height - origin.y - extent.height / 2)
  }

  private func statusItem(of app: AXUIElement) -> AXUIElement? {
    axElement(app, "AXExtrasMenuBar").flatMap { axChildren($0).first }
  }

  private func axButton(_ title: String, in app: AXUIElement) -> AXUIElement? {
    (axValue(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).lazy.flatMap { self.axDescendants(of: $0, depth: 6) }
      .first { self.axString($0, kAXRoleAttribute) == kAXButtonRole && self.axString($0, kAXTitleAttribute) == title }
  }
}

/// The isolated foreground app used only by the opt-in focus test. Its local webpage contains no
/// user data or network resources. Reports describe that fixture only and travel through pipes.
@MainActor
final class LiveFocusTarget: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate {
  private var window: NSWindow!
  private var webView: WKWebView!
  private var monitor: Timer?
  private var responder: NSResponder?
  private var nativeFailures = 0
  private var pending = Data()
  private var positiveControl = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    let screen = screenUnderPointer() ?? NSScreen.main!
    window = NSWindow(contentRect: screen.visibleFrame.insetBy(dx: 20, dy: 20),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "SnapScreen Focus Test — local webpage"
    window.collectionBehavior = [.fullScreenPrimary]
    window.delegate = self
    webView = WKWebView(frame: window.contentLayoutRect)
    webView.navigationDelegate = self
    window.contentView = webView
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    webView.loadHTMLString("""
      <!doctype html><html><head><meta name="color-scheme" content="dark"><style>
      body { font: 22px -apple-system; padding: 32px; background: #172239; color: white }
      textarea { position: fixed; left: 40px; bottom: 40px; width: 220px; height: 90px;
        font: 24px -apple-system; } textarea:focus { outline: 4px solid #8bb9ff }
      </style></head><body>Focus must stay on this local webpage throughout the snip.
      <textarea id="field" aria-label="Keyboard focus test" autofocus></textarea>
      <script>window.blurCount = 0; window.hiddenCount = 0;
      window.addEventListener('blur', () => window.blurCount++);
      document.addEventListener('visibilitychange', () => { if (document.hidden) window.hiddenCount++; });
      document.getElementById('field').addEventListener('blur', () => window.blurCount++);</script>
      </body></html>
      """, baseURL: nil)
    FileHandle.standardInput.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty { exit(0) }
      Task { @MainActor in self?.receive(data) }
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    whenActive { [weak self] in
      guard let self else { return }
      if CommandLine.arguments.contains("--fullscreen") {
        self.window.toggleFullScreen(nil)
      } else {
        self.prepare()
      }
    }
  }

  /// macOS refuses this app's own activation when the terminal that launched it isn't in front,
  /// and the test then activates it, so measuring waits until it's active.
  private func whenActive(_ action: @escaping () -> Void) {
    guard !NSApp.isActive else { return action() }
    var observer: NSObjectProtocol?
    observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
      queue: .main) { _ in
      if let observer { NotificationCenter.default.removeObserver(observer) }
      action()
    }
  }

  func windowDidEnterFullScreen(_ notification: Notification) { prepare() }

  private func prepare() {
    window.makeFirstResponder(webView)
    webView.evaluateJavaScript("document.getElementById('field').focus(); window.blurCount = 0; window.hiddenCount = 0")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self else { return }
      // A positive control establishes that this WKWebView reports a real loss of page focus.
      // It happens before the measured snip, and uses no external application or user content.
      let other = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 100, height: 100),
        styleMask: [.titled], backing: .buffered, defer: false)
      other.isReleasedWhenClosed = false
      other.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      other.makeKeyAndOrderFront(nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        guard let self else { return }
        self.webView.evaluateJavaScript("!document.hasFocus() && window.blurCount > 0") { [weak self] value, _ in
          guard let self else { return }
          self.positiveControl = value as? Bool == true
          other.close()
          self.window.makeKeyAndOrderFront(nil)
          self.window.makeFirstResponder(self.webView)
          self.webView.evaluateJavaScript("document.getElementById('field').focus(); window.blurCount = 0; window.hiddenCount = 0")
          self.startMeasuring()
        }
      }
    }
  }

  private func startMeasuring() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self else { return }
      self.responder = self.window.firstResponder
      let monitor = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          if !NSApp.isActive || !self.window.isKeyWindow || self.window.firstResponder !== self.responder {
            self.nativeFailures += 1
          }
        }
      }
      RunLoop.main.add(monitor, forMode: .common)
      self.monitor = monitor
      // The HTML field sits 40 points above the content's bottom edge, in either Space mode.
      let field = self.window.convertPoint(toScreen: NSPoint(x: 150, y: 85))
      self.report(["ready": true, "window": self.window.windowNumber, "x": field.x, "y": field.y,
        "positiveControl": self.positiveControl])
    }
  }

  private func receive(_ data: Data) {
    pending.append(data)
    while let newline = pending.firstIndex(of: 10) {
      let command = String(decoding: pending.prefix(upTo: newline), as: UTF8.self).split(separator: " ")
      pending.removeSubrange(...newline)
      switch command.first {
      case "launch": launchAppShell()
      case "yield": yieldActivation(to: command.dropFirst().first.flatMap { pid_t($0) })
      default: reportState(reset: command.first == "reset")
      }
    }
  }

  /// `reset` also reports what the page saw since the last reset, then starts counting again.
  private func reportState(reset: Bool) {
    webView.evaluateJavaScript("""
      ({ focused: document.hasFocus(), activeElement: document.activeElement === document.getElementById('field'),
        blurCount: window.blurCount, visible: document.visibilityState === 'visible',
        hiddenCount: window.hiddenCount, text: document.getElementById('field').value })
      """) { [weak self] value, error in
      guard let self else { return }
      var result = value as? [String: Any] ?? ["error": error?.localizedDescription ?? "No webpage result"]
      result["nativeFailures"] = self.nativeFailures
      if reset {
        result["restored"] = NSApp.isActive && self.window.isKeyWindow && self.window.firstResponder === self.responder &&
          result["focused"] as? Bool == true && result["activeElement"] as? Bool == true &&
          result["visible"] as? Bool == true
        self.nativeFailures = 0
        self.webView.evaluateJavaScript("window.blurCount = 0; window.hiddenCount = 0") { [weak self] _, _ in
          self?.report(result)
        }
        return
      }
      self.report(result)
    }
  }

  /// Opens the app shell copy through LaunchServices, which activates it as Finder, Spotlight and
  /// login items do. Once it's running, opening it again reopens it instead.
  private func launchAppShell() {
    guard let path = ProcessInfo.processInfo.environment["SNAPSCREEN_FOCUS_APP"] else {
      return report(["launched": 0])
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = ["--focus-app"]
    configuration.addsToRecentItems = false
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { [weak self] app, _ in
      let pid = Int(app?.processIdentifier ?? 0)
      Task { @MainActor in self?.report(["launched": pid]) }
    }
  }

  /// As the active app, has macOS activate another, as a launcher or a script can.
  private func yieldActivation(to pid: pid_t?) {
    guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return report(["yielded": false]) }
    NSApp.yieldActivation(to: app)
    report(["yielded": app.activate(from: .current, options: [])])
  }

  private func report(_ value: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    data.append(10)
    FileHandle.standardOutput.write(data)
  }
}
#endif
