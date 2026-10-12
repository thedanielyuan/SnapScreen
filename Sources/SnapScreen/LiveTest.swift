#if SNAPSCREEN_TEST_HOOKS
import AppKit
import SnapScreenCore

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
      self?.checkBackground("while capture and answer windows are displayed")
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
      panel.styleMask.contains(.nonactivatingPanel), "the \(stage) panel remains non-key")
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
  private static func fixture(for screen: NSScreen) -> CGImage {
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
#endif
