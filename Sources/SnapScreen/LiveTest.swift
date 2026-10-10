#if SNAPSCREEN_TEST_HOOKS
import AppKit
import SnapScreenCore

// The live test, compiled only into the test-hooks build that scripts/test-app-live.sh makes, with
// its own bundle ID. A made-up capture replaces ScreenCaptureKit, because CI can't grant Screen
// Recording, and a scripted event stream replaces the API. Everything else is the real app: the
// session controller, the client reading the stream, and the overlay and conversation windows.

/// Answers the first request and the follow-up as the API streams them, and keeps the requests.
final class ScriptedAPI: HTTPTransport, @unchecked Sendable {
  static let firstAnswer = "SNAPSCREEN_LIVE_FIRST_ANSWER\n\n```python\nprint(2 + 2)\n```\n\nThe result is 4."
  static let followUp = "SNAPSCREEN_LIVE_FOLLOW_UP"
  static let followUpAnswer = "SNAPSCREEN_LIVE_FOLLOW_UP_ANSWER"

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
    let text = index == 0 ? Self.firstAnswer : Self.followUpAnswer
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

/// Snips once through real windows: selects a region with the keyboard, reads the answer, asks one
/// follow-up, and closes. It exits 0 once every check passes, and 1 at the first that fails.
@MainActor
final class LiveTest: NSObject, NSApplicationDelegate, SessionControllerDelegate {
  static let timeout: TimeInterval = 45
  private let api = ScriptedAPI()
  private var controller: SessionController?
  private var snips: SnipWindows?
  private var screen: NSScreen?
  private var session: SnipSession?
  private var expectedCrop: (width: Int, height: Int)?
  private var selectionOnScreen: CGRect?
  private var answers = 0
  private var checks = 0

  func applicationDidFinishLaunching(_ notification: Notification) {
    installEditingMenu(applicationName: "SnapScreen")
    let controller = SessionController(answers: AnthropicClient(transport: api), apiKey: { "sk-ant-snapscreen-live-test" },
      settings: { .defaults })
    snips = SnipWindows(controller: controller, showNotice: { [weak self] message in
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
    let image = Self.fixture(for: screen)
    controller.start { FrozenScreen(image: image, displayID: displayID) }
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

  /// Whether SnapScreen took over the menu bar from the app beneath. A key panel that doesn't
  /// activate the app still makes `NSApp.isActive` true, so that can't tell.
  private var isFrontmost: Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
  }

  private func check(_ value: Bool, _ name: String) {
    if value { checks += 1 } else { fail(name) }
  }

  private func fail(_ name: String) {
    FileHandle.standardError.write(Data("SnapScreen live test failed: \(name)\n".utf8))
    exit(1)
  }

  private func selectRegion() {
    guard let screen = screen, let windows = snips?.sessions.first, let overlay = windows.overlay,
      let view = windows.selectionView, let image = view.image else {
      fail("the capture opens the overlay")
      return
    }
    check(overlay.isVisible && overlay.frame == screen.frame && !overlay.isOpaque && overlay.level == .screenSaver,
      "the overlay covers the display, above everything, and isn't opaque")
    check(overlay.isKeyWindow && !isFrontmost, "the overlay takes the keyboard without activating SnapScreen")
    // Return places a keyboard selection, and Return again asks about it.
    overlay.sendEvent(key(.keyDown, in: overlay))
    overlay.sendEvent(key(.keyUp, in: overlay))
    guard let selection = view.selection, let region = view.selectionDisplayRect else {
      fail("Return places a keyboard selection")
      return
    }
    selectionOnScreen = overlay.convertToScreen(view.convert(region, to: nil))
    expectedCrop = (Int(((selection.maxX) * image.size.width).rounded()) - Int((selection.minX * image.size.width).rounded()),
      Int(((selection.maxY) * image.size.height).rounded()) - Int((selection.minY * image.size.height).rounded()))
    overlay.sendEvent(key(.keyDown, in: overlay))
    check(windows.overlay == nil && windows.panel?.isVisible == true && windows.composer?.isRunning == true,
      "asking replaces the overlay with the conversation, waiting for its answer")
  }

  private func key(_ type: NSEvent.EventType, in window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
      isARepeat: false, keyCode: 36)!
  }

  private func answered() {
    answers += 1
    guard let windows = snips?.sessions.first, let panel = windows.panel, let thread = windows.conversation,
      let composer = windows.composer, let turn = thread.latestTurn else {
      fail("the conversation stays open while it's answered")
      return
    }
    if answers == 1 {
      check(turn.answer.renderedText == ScriptedAPI.firstAnswer && !thread.thumbnail.isHidden,
        "the first answer and the screenshot's thumbnail show")
      if let selection = selectionOnScreen, let screen = screen,
        screen.visibleFrame.maxX - selection.maxX > panel.frame.width + 16 {
        check(panel.frame.minX >= selection.maxX, "the conversation opens beside the selection")
      }
      composer.setDraft(ScriptedAPI.followUp)
      composer.submit()
      check(thread.turns.count == 2 && composer.isRunning, "the follow-up starts a new turn")
      return
    }
    check(turn.question == ScriptedAPI.followUp && turn.answer.renderedText == ScriptedAPI.followUpAnswer,
      "the follow-up and its answer show")
    checkRequests()
    // Close as the close button does, which ends the session and releases its windows.
    panel.performClose(nil, during: nil)
    check(!panel.isVisible && snips?.sessions.isEmpty == true && session?.phase == .ended,
      "closing the conversation ends the session")
    check(!isFrontmost, "SnapScreen never became the active app")
    print("SnapScreen live test passed (test hooks build): \(checks) checks, keyboard selection, streamed answer, " +
      "follow-up and Close through real windows")
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
