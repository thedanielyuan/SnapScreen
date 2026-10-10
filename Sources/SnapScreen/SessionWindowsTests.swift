import AppKit
import SnapScreenCore

private enum SessionWindowsTestError: Error { case failed(String) }

/// Answers each question at once, or holds the answer until it's stopped.
private final class SelfTestAnswers: AnswerClient, @unchecked Sendable {
  private let lock = NSLock()
  private var holding = false
  private var asked: [String] = []

  var holds: Bool {
    get { lock.withLock { holding } }
    set { lock.withLock { holding = newValue } }
  }

  /// "(first)" for each first answer without a question, then each question.
  var questions: [String] { lock.withLock { asked } }

  func analyzeImage(apiKey: String, image: Data, hiddenInstruction: String?, userQuestion: String?,
    limits: SnapScreenLimits, handlers: StreamHandlers) async throws -> Answer {
    try await answer(userQuestion ?? "(first)", handlers)
  }

  func followUp(apiKey: String, text: String, history: [AnthropicMessage], sessionInstruction: String?,
    limits: SnapScreenLimits, handlers: StreamHandlers) async throws -> Answer {
    try await answer(text, handlers)
  }

  private func answer(_ question: String, _ handlers: StreamHandlers) async throws -> Answer {
    let holds = lock.withLock { () -> Bool in
      asked.append(question)
      return holding
    }
    let text = "Answer to \(question)"
    handlers.onThinking()
    handlers.onDelta(text)
    if holds { try await Task.sleep(for: .seconds(60)) }
    return Answer(text: text, history: [])
  }
}

/// The API key the self-test's sessions read.
private final class KeySlot {
  var key: String? = "sk-ant-self-test"
}

/// Snips through the real session controller, with a scripted client, a made-up capture and real
/// cropping. Windows are never shown.
@MainActor
func runSessionWindowsTests() throws -> Int {
  var count = 0
  func check(_ value: Bool, _ name: String) throws {
    guard value else { throw SessionWindowsTestError.failed(name) }
    count += 1
  }
  func waitUntil(_ condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: 5)
    while !condition() && Date() < deadline { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    return condition()
  }
  _ = NSApplication.shared
  guard let screen = NSScreen.main ?? NSScreen.screens.first, let displayID = screen.displayID else {
    throw SessionWindowsTestError.failed("a display to cover")
  }

  let overlay = SelectionOverlay.make(covering: screen)
  try check(!overlay.isOpaque && overlay.backgroundColor == .clear && !overlay.hasShadow,
    "the overlay is non-opaque, so Chrome doesn't mark the page as hidden")
  try check(overlay.styleMask == [.borderless, .nonactivatingPanel] && overlay.canBecomeKey && !overlay.canBecomeMain &&
    !overlay.hidesOnDeactivate, "the overlay takes the keyboard without activating SnapScreen")
  try check(overlay.frame == screen.frame && overlay.level == .screenSaver &&
    overlay.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary]),
    "the overlay covers its whole display, above the menu bar and fullscreen apps")

  let answers = SelfTestAnswers()
  let slot = KeySlot()
  var notices: [String] = []
  let controller = SessionController(answers: answers, apiKey: { slot.key }, settings: { .defaults })
  let snips = SnipWindows(controller: controller, showNotice: { notices.append($0) }, present: { _ in })
  defer { snips.shields.stop() }
  let context = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
  context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
  let frozen = FrozenScreen(image: context.makeImage()!, displayID: displayID)
  func snip(_ screen: FrozenScreen? = nil) -> SessionWindows? {
    let capture = screen ?? frozen
    let session = controller.start { capture }
    guard waitUntil({ snips.sessions.last?.session === session && snips.sessions.last?.overlay != nil }) else { return nil }
    return snips.sessions.last
  }
  func select(_ windows: SessionWindows) -> Bool {
    windows.selectionView?.selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    windows.selectionView?.confirm()
    return waitUntil { windows.conversation?.latestTurn?.state == .done }
  }
  func keyEvent(_ type: NSEvent.EventType, _ code: UInt16, _ characters: String, in window: NSWindow?) -> NSEvent {
    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0,
      context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
  }

  // Escape cancels on release, so the release never reaches the app you snip.
  guard let cancelled = snip(), let cancelledOverlay = cancelled.overlay else {
    throw SessionWindowsTestError.failed("a capture opens the overlay")
  }
  try check(cancelled.selectionView?.fillsBounds == true && cancelled.selectionView?.image?.size == NSSize(width: 64, height: 40)
    && cancelledOverlay.frame == screen.frame && cancelledOverlay.contentView === cancelled.selectionView,
    "the overlay shows the frozen display, sized in its pixels")
  cancelledOverlay.sendEvent(keyEvent(.keyDown, 53, "\u{1B}", in: cancelledOverlay))
  try check(cancelled.session.phase == .selecting, "Escape waits for its release")
  NSApp.sendEvent(keyEvent(.keyUp, 53, "\u{1B}", in: cancelledOverlay))
  try check(cancelled.session.phase == .ended && cancelled.overlay == nil && snips.sessions.isEmpty,
    "releasing Escape cancels the selection and closes the overlay")

  // A new snip replaces a selection that hasn't been answered.
  guard let replaced = snip(), let windows = snip() else { throw SessionWindowsTestError.failed("a second snip") }
  try check(replaced.session.phase == .ended && replaced.overlay == nil && snips.sessions.count == 1,
    "a new snip replaces the unfinished selection and closes its overlay")

  // Selecting opens the conversation beside the selection and asks for the first answer. The
  // thumbnail holds the crop's place until it arrives.
  windows.selectionView?.selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
  windows.selectionView?.confirm()
  let reserved = windows.conversation?.thumbnail.frame ?? .zero
  try check(windows.conversation?.thumbnail.isHidden == false && windows.conversation?.thumbnail.screenshot == nil &&
    reserved.width > 0, "the thumbnail holds the crop's place before it arrives")
  try check(waitUntil { windows.conversation?.latestTurn?.state == .done }, "the first answer arrives")
  try check(windows.conversation?.thumbnail.screenshot != nil && windows.conversation?.thumbnail.frame == reserved,
    "the crop fills its place without moving the thread")
  try check(windows.overlay == nil && windows.selectionView == nil && windows.panel?.title == "SnapScreen",
    "selecting replaces the overlay with the conversation")
  try check(windows.panel.map { panel in NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) } } == true,
    "the conversation opens within a display")
  try check(windows.conversation?.latestTurn?.answer.renderedText == "Answer to (first)" &&
    windows.conversation?.thumbnail.isHidden == false, "the answer and the screenshot's thumbnail show")
  try check(windows.composer?.canSubmit == true && windows.composer?.isRunning == false &&
    windows.composer?.maximumCharacters == SnapScreenLimits.defaults.maxInputCharacters,
    "the composer accepts a follow-up within the limit")

  // The conversation opens only as tall as its answer needs, and grows down with its thread.
  guard let panel = windows.panel, let thread = windows.conversation else {
    throw SessionWindowsTestError.failed("the conversation stays open")
  }
  func fitsThread() -> Bool { thread.scrollView.documentView!.frame.height <= thread.scrollView.contentSize.height + 1 }
  let largest = panel.frameRect(forContentRect: NSRect(origin: .zero, size: SessionWindows.defaultConversationSize))
  let top = panel.frame.maxY
  try check(panel.frame.height < largest.height && fitsThread() && windows.fitsContent,
    "the conversation opens only as tall as its answer needs")

  windows.composer?.setDraft("Why?")
  windows.composer?.submit()
  try check(windows.conversation?.turns.count == 2 && windows.composer?.draft.isEmpty == true &&
    windows.composer?.isRunning == true, "a follow-up starts a new turn")
  try check(waitUntil { windows.conversation?.latestTurn?.state == .done } && answers.questions == ["(first)", "Why?"],
    "the follow-up is answered")
  let longQuestion = (1...30).map { "Line \($0) of a long question" }.joined(separator: "\n")
  let shorter = panel.frame.height
  windows.composer?.setDraft(longQuestion)
  windows.composer?.submit()
  try check(waitUntil { windows.conversation?.latestTurn?.state == .done } && shorter < largest.height &&
    abs(panel.frame.height - largest.height) < 1 && abs(panel.frame.maxY - top) < 1 && !fitsThread(),
    "a longer thread grows it down to its largest, then scrolls")

  // Resizing it yourself stops the fitting, and later conversations take the size you chose.
  windows.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: panel))
  panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - 420, width: 400, height: 420), display: false)
  windows.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel))
  let chosen = panel.contentRect(forFrameRect: panel.frame).size
  try check(!windows.fitsContent && snips.chosenSize.size == chosen, "resizing a conversation keeps its size for the next")
  let resized = panel.frame
  windows.composer?.setDraft(longQuestion)
  windows.composer?.submit()
  try check(waitUntil { windows.conversation?.latestTurn?.state == .done } && panel.frame == resized,
    "a conversation you resized keeps its size")

  answers.holds = true
  windows.composer?.setDraft("Hold on")
  windows.composer?.submit()
  try check(waitUntil { windows.conversation?.latestTurn?.state == .streaming } && windows.composer?.canStop == true,
    "streaming text shows while Stop is available")
  windows.composer?.onStop?()
  try check(windows.conversation?.latestTurn?.state == .stopped && windows.conversation?.canRetry == true &&
    windows.composer?.isRunning == false, "Stop keeps the text so far and offers Retry")
  answers.holds = false
  windows.conversation?.onRetry?()
  try check(waitUntil { windows.conversation?.latestTurn?.state == .done } &&
    windows.conversation?.latestTurn?.answer.renderedText == "Answer to Hold on", "Retry asks again")
  try check(answers.questions == ["(first)", "Why?", longQuestion, longQuestion, "Hold on", "Hold on"],
    "each request asks its own question")

  slot.key = nil
  windows.composer?.setDraft("No key")
  windows.composer?.submit()
  try check(waitUntil {
    windows.conversation?.latestTurn?.state == .failed("Add your Anthropic API key in SnapScreen Settings, then Retry.")
  }, "a missing key fails the request with a way forward")
  slot.key = "sk-ant-self-test"

  // A session that ends on its own leaves only a notice, and closing it lets the windows go.
  windows.handle(.ended)
  try check(windows.panel?.title == "SnapScreen — Session ended" && windows.conversation == nil &&
    (windows.panel?.contentView as? SessionEndedView)?.messageLabel.stringValue == SessionWindows.endedMessage,
    "an ended session keeps no screenshot, answer or draft")
  windows.panel?.performClose(nil)
  try check(windows.session.phase == .ended && windows.panel == nil && snips.sessions.isEmpty,
    "closing the conversation ends the session")

  // A scroller that comes and goes as the conversation grows changes how wide its thread is, so how
  // its text wraps and how tall its thumbnail is. It still ends up fitting. This conversation opens
  // at the default size, whose height holds its whole thread, rather than the size chosen above.
  let keptSize = snips.chosenSize.size
  snips.chosenSize.size = nil
  let largeContext = CGContext(data: nil, width: 1800, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
  largeContext.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
  largeContext.fill(CGRect(x: 0, y: 0, width: 1800, height: 1000))
  guard let scrolling = snip(FrozenScreen(image: largeContext.makeImage()!, displayID: displayID)) else {
    throw SessionWindowsTestError.failed("a snip of a large display")
  }
  scrolling.selectionView?.selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
  scrolling.selectionView?.confirm()
  scrolling.conversation?.scrollView.scrollerStyle = .legacy
  try check(waitUntil { scrolling.conversation?.latestTurn?.state == .done }, "the large snip is answered")
  scrolling.composer?.setDraft("Why is that?\nAnd what about this?")
  scrolling.composer?.submit()
  try check(waitUntil { scrolling.conversation?.latestTurn?.state == .done } &&
    scrolling.conversation.map { $0.scrollView.documentView!.frame.height <= $0.scrollView.contentSize.height + 1 } == true,
    "a conversation whose scroller came and went still fits its thread")
  scrolling.panel?.performClose(nil)
  snips.chosenSize.size = keptSize

  // Notices for snips that fail before they have a window.
  controller.start { throw CaptureError("The display was disconnected.") }
  try check(waitUntil { notices == ["The display was disconnected."] } && snips.sessions.isEmpty,
    "a capture failure shows its notice")
  var open: [SessionWindows] = []
  for _ in 0..<SessionController.maxSessions {
    guard let windows = snip(), select(windows) else { throw SessionWindowsTestError.failed("an answered snip") }
    open.append(windows)
  }
  let next = open[0].panel.map { $0.contentRect(forFrameRect: $0.frame).size }
  try check(next.map { $0.width == chosen.width && $0.height <= chosen.height } == true && open[0].fitsContent,
    "a later conversation opens at the width you chose, and fits its thread up to your height")
  try check(controller.start { frozen } == nil && notices.last == "Close a SnapScreen window before starting another snip.",
    "a fifth snip asks for a window to close")
  for windows in open { windows.panel?.performClose(nil) }
  let room = controller.start { frozen }
  try check(snips.sessions.isEmpty && room != nil, "closing windows makes room again")
  room?.close()
  return count
}
