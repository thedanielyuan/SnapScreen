import AppKit
import SnapScreenCore

private enum SessionWindowsTestError: Error { case failed(String) }

/// Answers each request at once, or holds the answer until it's stopped.
private final class SelfTestAnswers: AnswerClient, @unchecked Sendable {
  /// A short answer with a code block, which the first snip copies.
  static let codeAnswer = "Code:\n```py\nprint(1)\n```"

  private let lock = NSLock()
  private var holding = false
  private var pausing = false
  private var answer = SelfTestAnswers.codeAnswer
  private var count = 0

  var holds: Bool {
    get { lock.withLock { holding } }
    set { lock.withLock { holding = newValue } }
  }

  /// Answers stream until this is turned off, then finish.
  var pauses: Bool {
    get { lock.withLock { pausing } }
    set { lock.withLock { pausing = newValue } }
  }

  /// What each answer streams, then returns.
  var text: String {
    get { lock.withLock { answer } }
    set { lock.withLock { answer = newValue } }
  }

  /// How many requests have been made.
  var requests: Int { lock.withLock { count } }

  func analyzeImage(apiKey: String, image: Data, hiddenInstruction: String?, userQuestion: String?,
    limits: SnapScreenLimits, handlers: StreamHandlers) async throws -> String {
    let (holds, text) = lock.withLock { () -> (Bool, String) in
      count += 1
      return (holding, answer)
    }
    handlers.onThinking()
    handlers.onDelta(text)
    while pauses { try await Task.sleep(for: .milliseconds(10)) }
    if holds { try await Task.sleep(for: .seconds(60)) }
    return text
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
  try check(overlay.styleMask == [.borderless, .nonactivatingPanel] && hasPassivePanelConfiguration(overlay),
    "the selection overlay cannot take the keyboard or activate SnapScreen")
  try check(overlay.frame == screen.frame && overlay.level == .screenSaver &&
    overlay.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary]),
    "the overlay covers its whole display, above the menu bar and fullscreen apps")
  try check(BackgroundCursor.isAvailable, "the overlay can show its crosshair while SnapScreen isn't frontmost")
  let shield = PointerShield(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
  try check(hasPassivePanelConfiguration(shield) && shield.level == .floating,
    "the pointer shield inherits the passive panel behavior even without an explicit style flag")

  let answers = SelfTestAnswers()
  let slot = KeySlot()
  var notices: [String] = []
  var noticeActions: [NoticeAction?] = []
  // The window shown last, which must leave the keyboard in the app beneath.
  weak var presented: NSWindow?
  let controller = SessionController(answers: answers, apiKey: { slot.key }, settings: { .defaults })
  let snips = SnipWindows(controller: controller, showNotice: { notices.append($0); noticeActions.append($1) },
    present: { presented = $0 })
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
  func confirm(_ windows: SessionWindows) {
    windows.selectionView?.selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    windows.selectionView?.confirm()
  }
  func select(_ windows: SessionWindows) -> Bool {
    confirm(windows)
    return waitUntil { windows.conversation?.turn?.state == .done }
  }
  func fitsThread(_ thread: ConversationView) -> Bool {
    thread.scrollView.documentView!.frame.height <= thread.scrollView.contentSize.height + 1
  }
  func editableViews(in view: NSView?) -> [NSView] {
    guard let view = view else { return [] }
    let editable = (view as? NSTextView)?.isEditable == true || (view as? NSTextField)?.isEditable == true
    return (editable ? [view] : []) + view.subviews.flatMap { editableViews(in: $0) }
  }
  func pointer(_ type: NSEvent.EventType, in window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }

  // A click without a drag cancels without needing any keyboard input.
  guard let cancelled = snip(), let cancelledOverlay = cancelled.overlay else {
    throw SessionWindowsTestError.failed("a capture opens the overlay")
  }
  try check(cancelled.selectionView?.fillsBounds == true && cancelled.selectionView?.image?.size == NSSize(width: 64, height: 40)
    && cancelledOverlay.frame == screen.frame && cancelledOverlay.contentView === cancelled.selectionView,
    "the overlay shows the frozen display, sized in its pixels")
  cancelled.selectionView?.mouseDown(with: pointer(.leftMouseDown, in: cancelledOverlay))
  try check(cancelled.session.phase == .selecting, "a pointer press waits for its release")
  cancelled.selectionView?.mouseUp(with: pointer(.leftMouseUp, in: cancelledOverlay))
  try check(cancelled.session.phase == .ended && cancelled.overlay == nil && snips.sessions.isEmpty,
    "releasing a click without a drag cancels the selection and closes the overlay")

  // A new snip replaces a selection that hasn't been answered.
  guard let replaced = snip(), let windows = snip() else { throw SessionWindowsTestError.failed("a second snip") }
  try check(replaced.session.phase == .ended && replaced.overlay == nil && snips.sessions.count == 1,
    "a new snip replaces the unfinished selection and closes its overlay")

  // Selecting opens the conversation beside the selection and asks for the answer. The thumbnail
  // holds the crop's place until it arrives, and Stop shows until the answer finishes.
  confirm(windows)
  let reserved = windows.conversation?.thumbnail.frame ?? .zero
  try check(windows.conversation?.thumbnail.isHidden == false && windows.conversation?.thumbnail.screenshot == nil &&
    reserved.width > 0, "the thumbnail holds the crop's place before it arrives")
  try check(windows.stopButton?.isHidden == false && windows.stopButton?.isEnabled == false,
    "Stop shows as soon as the region is selected, and waits for the request to start")
  try check(waitUntil { windows.conversation?.turn?.state == .done }, "the answer arrives")
  try check(windows.conversation?.thumbnail.screenshot != nil && windows.conversation?.thumbnail.frame == reserved,
    "the crop fills its place without moving the thread")
  try check(windows.overlay == nil && windows.selectionView == nil && windows.panel?.title == "SnapScreen",
    "selecting replaces the overlay with the conversation")
  try check(windows.panel.map { panel in NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) } } == true,
    "the conversation opens within a display")
  try check(windows.conversation?.turn?.answer.renderedText == SelfTestAnswers.codeAnswer &&
    windows.conversation?.thumbnail.isHidden == false, "the answer and the screenshot's thumbnail show")
  try check(windows.stopButton?.isHidden == true && windows.conversation?.canRetry == false && answers.requests == 1,
    "a finished answer offers neither Stop nor Retry")

  // The conversation opens only as tall as its answer needs.
  guard let panel = windows.panel, let thread = windows.conversation else {
    throw SessionWindowsTestError.failed("the conversation stays open")
  }
  try check(hasPassivePanelConfiguration(panel) && panel.level == .floating,
    "the conversation is a floating panel that cannot take keyboard focus")
  try check(editableViews(in: panel.contentView).isEmpty, "the conversation has no editable field")
  let largest = panel.frameRect(forContentRect: NSRect(origin: .zero, size: SessionWindows.defaultConversationSize))
  try check(panel.frame.height < largest.height && fitsThread(thread) && windows.fitsContent,
    "the conversation opens only as tall as its answer needs")
  try check(panel.standardWindowButton(.closeButton)?.isHidden == false &&
    panel.standardWindowButton(.miniaturizeButton)?.isHidden == true && panel.standardWindowButton(.zoomButton)?.isHidden == true &&
    panel.titleVisibility == .hidden && panel.title == "SnapScreen", "the conversation's title bar holds only its close button")
  windows.conversation?.onPreview?()
  try check(windows.previewPanel.map {
    !$0.frame.intersects(panel.frame) && hasPassivePanelConfiguration($0) && $0.level == .floating
  } == true,
    "the screenshot preview opens beside the conversation without eligibility for keyboard focus")
  windows.previewPanel?.performClose(nil)
  try check(windows.previewPanel == nil && windows.panel === panel, "closing the preview keeps the conversation")

  // The Copy buttons work in a panel that never becomes key. These checks write to a private
  // pasteboard, never the clipboard.
  let general = Clipboard.pasteboard
  let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.snapscreen.self-test.\(UUID().uuidString)"))
  Clipboard.pasteboard = pasteboard
  windows.conversation?.turn?.copyButton.performClick(nil)
  try check(pasteboard.string(forType: .string) == SelfTestAnswers.codeAnswer, "Copy copies the answer")
  windows.conversation?.codeToCopy?.copyButton?.performClick(nil)
  try check(pasteboard.string(forType: .string) == "print(1)", "a code block's Copy copies its code")
  Clipboard.pasteboard = general
  pasteboard.releaseGlobally()

  // A session that ends on its own leaves only a notice, and closing it lets the windows go.
  windows.handle(.ended)
  try check(windows.panel?.title == "SnapScreen — Session ended" && windows.conversation == nil &&
    windows.stopButton == nil &&
    (windows.panel?.contentView as? SessionEndedView)?.messageLabel.stringValue == SessionWindows.endedMessage,
    "an ended session keeps no screenshot or answer")
  windows.panel?.performClose(nil)
  try check(windows.session.phase == .ended && windows.panel == nil && snips.sessions.isEmpty,
    "closing the conversation ends the session")

  // A long answer grows the conversation down to its largest, keeping its top edge, then scrolls.
  answers.text = (1...60).map { "Line \($0) of a long answer." }.joined(separator: "\n")
  guard let long = snip() else { throw SessionWindowsTestError.failed("a snip with a long answer") }
  confirm(long)
  guard let longPanel = long.panel, let longThread = long.conversation else {
    throw SessionWindowsTestError.failed("the long answer's conversation")
  }
  let top = longPanel.frame.maxY
  let opened = longPanel.frame.height
  try check(waitUntil { longThread.turn?.state == .done } && opened < largest.height &&
    abs(longPanel.frame.height - largest.height) < 1 && abs(longPanel.frame.maxY - top) < 1 && !fitsThread(longThread),
    "a long answer grows it down to its largest, then scrolls")
  longPanel.performClose(nil)

  // Resizing a conversation yourself stops the fitting, and later conversations take the size you
  // chose. Stop keeps the text so far and offers Retry, which asks again without resizing it.
  answers.text = "Held answer"
  answers.holds = true
  guard let resizing = snip() else { throw SessionWindowsTestError.failed("a snip to resize") }
  confirm(resizing)
  guard let resizingPanel = resizing.panel, let resizingThread = resizing.conversation else {
    throw SessionWindowsTestError.failed("a conversation to resize")
  }
  try check(waitUntil { resizingThread.turn?.state == .streaming } && resizing.stopButton?.isHidden == false &&
    resizing.stopButton?.isEnabled == true, "streaming text shows while Stop can act")
  resizing.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: resizingPanel))
  resizingPanel.setFrame(NSRect(x: resizingPanel.frame.minX, y: resizingPanel.frame.maxY - 420, width: 400, height: 420),
    display: false)
  resizing.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: resizingPanel))
  let chosen = resizingPanel.contentRect(forFrameRect: resizingPanel.frame).size
  try check(!resizing.fitsContent && snips.chosenSize.size == chosen, "resizing a conversation keeps its size for the next")
  let resized = resizingPanel.frame
  resizing.stopButton?.performClick(nil)
  try check(resizingThread.turn?.state == .stopped && resizingThread.canRetry && resizing.stopButton?.isHidden == true &&
    resizingThread.turn?.answer.renderedText == "Held answer", "Stop keeps the text so far and offers Retry")
  answers.holds = false
  let asked = answers.requests
  resizingThread.onRetry?()
  try check(resizing.stopButton?.isHidden == false && !resizingThread.canRetry, "Retry shows Stop again")
  try check(waitUntil { resizingThread.turn?.state == .done } && answers.requests == asked + 1 &&
    resizingPanel.frame == resized, "Retry asks again, and a conversation you resized keeps its size")
  resizingPanel.performClose(nil)

  // Once its answer has finished, a click in another app closes the conversation and its preview,
  // as the close button does. The global monitor never fires here, so these checks pass each
  // click's position as it would. Until then, while the answer or a Retry runs, or after one fails
  // or stops, the conversation stays open. This one first fails for want of a key.
  answers.text = "Finished answer"
  slot.key = nil
  guard let finished = snip() else { throw SessionWindowsTestError.failed("a snip to dismiss") }
  confirm(finished)
  guard let finishedPanel = finished.panel else { throw SessionWindowsTestError.failed("a conversation to dismiss") }
  // Well clear of the conversation and the preview.
  func elsewhere() -> NSPoint {
    let frames = [finished.panel, finished.previewPanel].compactMap { $0?.frame }.reduce(NSRect.null) { $0.union($1) }
    return NSPoint(x: frames.minX - 60, y: frames.midY)
  }
  func stillOpen(_ phase: SnipSession.Phase) -> Bool {
    finished.clickedOutside(at: elsewhere())
    return finished.panel === finishedPanel && finished.session.phase == phase && snips.sessions.contains { $0 === finished }
  }
  try check(finished.stopButton?.isHidden == false && !finished.dismissesOnOutsideClick && stillOpen(.cropping),
    "a click in another app doesn't close a conversation waiting for its answer")
  try check(waitUntil {
    finished.conversation?.turn?.state == .failed("Add your Anthropic API key in SnapScreen Settings, then Retry.")
  } && finished.stopButton?.isHidden == true && finished.conversation?.canRetry == true,
    "a missing key fails the request with a way forward")
  try check(!finished.dismissesOnOutsideClick && stillOpen(.failed), "a failed answer stays open until you close it")
  slot.key = "sk-ant-self-test"
  answers.pauses = true
  finished.conversation?.onRetry?()
  try check(waitUntil { finished.conversation?.turn?.state == .streaming } && !finished.dismissesOnOutsideClick &&
    stillOpen(.running), "a click in another app doesn't close or stop a Retry as it streams")
  finished.stopButton?.performClick(nil)
  try check(!finished.dismissesOnOutsideClick && stillOpen(.stopped), "a stopped answer stays open until you close it")
  finished.conversation?.onRetry?()
  try check(!finished.dismissesOnOutsideClick && stillOpen(.running), "a click in another app doesn't close or stop a Retry")
  answers.pauses = false
  try check(waitUntil { finished.conversation?.turn?.state == .done } && finished.dismissesOnOutsideClick,
    "once the answer finishes, a click in another app can close the conversation")

  // Clicks in the conversation or the preview go to SnapScreen, so the monitor, which sees only
  // other apps, never gets them, and they'd leave both open anyway. So does a click in another app
  // just outside either panel, where a press resizes it.
  finished.conversation?.onPreview?()
  guard let preview = finished.previewPanel, let previewView = preview.contentView as? PreviewView else {
    throw SessionWindowsTestError.failed("the preview opens")
  }
  let margin = SessionWindows.outsideClickMargin - 1
  for point in [NSPoint(x: finishedPanel.frame.midX, y: finishedPanel.frame.midY),
    NSPoint(x: preview.frame.midX, y: preview.frame.midY),
    NSPoint(x: finishedPanel.frame.minX - margin, y: finishedPanel.frame.midY),
    NSPoint(x: finishedPanel.frame.midX, y: finishedPanel.frame.maxY + margin),
    NSPoint(x: preview.frame.maxX + margin, y: preview.frame.minY - margin)] {
    finished.clickedOutside(at: point)
  }
  try check(finished.panel === finishedPanel && finished.previewPanel === preview && finished.dismissesOnOutsideClick,
    "clicks on or at the edge of the conversation and the preview leave both open")
  preview.performClose(nil)
  try check(finished.previewPanel == nil && finished.panel === finishedPanel && finished.dismissesOnOutsideClick,
    "closing the preview keeps the conversation dismissible")
  finished.conversation?.onPreview?()

  // While a panel is resized, a click elsewhere leaves it open. The resize keeps its size for the
  // next conversation, as before.
  let keptChosenSize = snips.chosenSize.size
  finished.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: finishedPanel))
  try check(snips.shields.isTrackingPanel && stillOpen(.ready), "a click in another app during a resize leaves the conversation open")
  finished.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: finishedPanel))
  try check(!snips.shields.isTrackingPanel && finished.dismissesOnOutsideClick &&
    snips.chosenSize.size == finishedPanel.contentRect(forFrameRect: finishedPanel.frame).size,
    "after the resize, the conversation is dismissible again and its size is kept for the next")
  snips.chosenSize.size = keptChosenSize

  // A new snip leaves it open and dismissible while you select. Selecting happens in SnapScreen's
  // overlay, which the monitor never sees.
  guard let selecting = snip() else { throw SessionWindowsTestError.failed("another snip") }
  try check(selecting.overlay != nil && finished.panel === finishedPanel && finished.dismissesOnOutsideClick &&
    snips.sessions.count == 2, "a new snip leaves a finished conversation open and dismissible while you select")
  selecting.selectionView?.onCancel?()
  try check(snips.sessions.count == 1 && finished.panel === finishedPanel && finished.dismissesOnOutsideClick,
    "cancelling the new snip leaves it as it was")

  // The click closes both windows through the close button's path, which ends the session, releases
  // the screenshot and answer, and stops watching. Meanwhile no other panel, such as a new snip's
  // overlay, can take the keyboard, which AppKit would otherwise hand it from the closing ones.
  guard let finishedThread = finished.conversation, let finishedPreview = finished.previewPanel,
    let finishedPreviewView = finishedPreview.contentView as? PreviewView else {
    throw SessionWindowsTestError.failed("the conversation and preview stay open")
  }
  try check(finishedPreviewView !== previewView && finishedPreviewView.image != nil, "the preview opens again")
  guard let next = snip(), let nextOverlay = next.overlay else { throw SessionWindowsTestError.failed("a new snip's overlay") }
  var keyableWhileClosing: Bool?
  let closed = finished.onClose
  finished.onClose = {
    keyableWhileClosing = nextOverlay.canBecomeKey
    closed?()
  }
  finished.clickedOutside(at: elsewhere())
  try check(finished.session.phase == .ended && finished.panel == nil && finished.previewPanel == nil &&
    finished.conversation == nil && finished.stopButton == nil && !finished.dismissesOnOutsideClick &&
    !finishedPanel.isVisible && !finishedPreview.isVisible && !snips.shields.isTrackingPanel,
    "a click in another app ends the session and closes the conversation and preview")
  try check(finishedPreviewView.image == nil && finishedThread.turn == nil && finishedThread.thumbnail.screenshot == nil,
    "closing them releases the screenshot and answer")
  try check(keyableWhileClosing == false && !nextOverlay.canBecomeKey && snips.sessions.count == 1 && next.overlay === nextOverlay,
    "a new snip's overlay cannot take the keyboard during or after another conversation closes")
  finished.clickedOutside(at: elsewhere())
  try check(finished.session.phase == .ended && snips.sessions.count == 1, "a later click finds nothing more to close")

  // Selecting a region in a new snip closes the earlier conversation and preview through the close
  // button's path, even while it answers, which ends its session and releases its screenshot and
  // answer. The new conversation is presented before the earlier one closes.
  answers.pauses = true
  confirm(next)
  guard let nextPanel = next.panel, let nextThread = next.conversation,
    waitUntil({ nextThread.turn?.state == .streaming }) else {
    throw SessionWindowsTestError.failed("the new snip's conversation streams its answer")
  }
  next.conversation?.onPreview?()
  guard let nextPreview = next.previewPanel, let nextPreviewView = nextPreview.contentView as? PreviewView else {
    throw SessionWindowsTestError.failed("the new snip's preview")
  }
  let requested = answers.requests
  guard let latest = snip() else { throw SessionWindowsTestError.failed("a snip while the answer streams") }
  try check(next.panel === nextPanel && next.previewPanel === nextPreview && next.session.phase == .running &&
    snips.sessions.count == 2, "a new snip leaves a streaming conversation open while you select")
  var shownFirst: Bool?
  let closedNext = next.onClose
  next.onClose = {
    shownFirst = latest.panel != nil && presented === latest.panel
    closedNext?()
  }
  confirm(latest)
  try check(next.session.phase == .ended && next.panel == nil && next.previewPanel == nil && next.conversation == nil &&
    snips.sessions.count == 1 && snips.sessions.first === latest && latest.panel != nil,
    "selecting a region in a new snip closes the earlier conversation and preview, ending its session")
  try check(shownFirst == true, "the new conversation is presented before the earlier one closes")
  try check(nextPreviewView.image == nil && nextThread.turn == nil && nextThread.thumbnail.screenshot == nil,
    "closing them releases the screenshot and answer")
  answers.pauses = false
  try check(waitUntil { latest.conversation?.turn?.state == .done } && answers.requests == requested + 1,
    "the new snip is answered with a request of its own")

  // A new snip ends a selection that's still being cropped, which leaves a notice in its
  // conversation. Selecting the new snip's region closes that too.
  guard let cropping = snip() else { throw SessionWindowsTestError.failed("a snip to crop") }
  confirm(cropping)
  try check(latest.panel == nil && latest.session.phase == .ended && snips.sessions.count == 1,
    "each snip's conversation replaces the one before")
  guard let replacing = snip() else { throw SessionWindowsTestError.failed("a snip during cropping") }
  try check(cropping.session.phase == .ended && cropping.panel?.contentView is SessionEndedView && snips.sessions.count == 2,
    "a new snip ends a selection that's being cropped, leaving a notice")
  guard select(replacing) else { throw SessionWindowsTestError.failed("the replacing snip's answer") }
  try check(cropping.panel == nil && snips.sessions.count == 1 && snips.sessions.first === replacing,
    "selecting the new snip's region closes the notice too")
  replacing.panel?.performClose(nil)
  try check(replacing.session.phase == .ended && snips.sessions.isEmpty, "closing the last conversation leaves none")

  // A scroller that comes and goes as the conversation grows changes how wide its thread is, so how
  // its text wraps and how tall its thumbnail is. It still ends up fitting. This conversation opens
  // at the default size, whose height holds its whole thread, rather than the size chosen above.
  let keptSize = snips.chosenSize.size
  snips.chosenSize.size = nil
  answers.text = (1...4).map { "Line \($0) of an answer long enough to wrap at this width, so the thread grows." }
    .joined(separator: "\n")
  let largeContext = CGContext(data: nil, width: 1800, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
  largeContext.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
  largeContext.fill(CGRect(x: 0, y: 0, width: 1800, height: 1000))
  guard let scrolling = snip(FrozenScreen(image: largeContext.makeImage()!, displayID: displayID)) else {
    throw SessionWindowsTestError.failed("a snip of a large display")
  }
  confirm(scrolling)
  scrolling.conversation?.scrollView.scrollerStyle = .legacy
  try check(waitUntil { scrolling.conversation?.turn?.state == .done } && scrolling.conversation.map(fitsThread) == true,
    "a conversation whose scroller came and went still fits its thread")
  scrolling.panel?.performClose(nil)
  snips.chosenSize.size = keptSize
  answers.text = SelfTestAnswers.codeAnswer

  // Notices for snips that fail before they have a window.
  controller.start { throw CaptureError("The display was disconnected.") }
  try check(waitUntil { notices == ["The display was disconnected."] } && snips.sessions.isEmpty &&
    noticeActions.count == 1 && noticeActions[0] == nil, "a capture failure shows its notice, without a button")
  // Each snip's conversation replaces the last, so snipping more often than the session limit
  // never reaches it.
  var answered: [SessionWindows] = []
  for _ in 0...SessionController.maxSessions {
    guard let windows = snip(), select(windows) else { throw SessionWindowsTestError.failed("an answered snip") }
    answered.append(windows)
  }
  try check(snips.sessions.count == 1 && snips.sessions.first === answered.last && notices.count == 1 &&
    answered.dropLast().allSatisfy { $0.panel == nil && $0.session.phase == .ended },
    "snipping more often than the session limit replaces each conversation, without a notice")
  let latestSize = answered.last?.panel.map { $0.contentRect(forFrameRect: $0.frame).size }
  try check(latestSize.map { $0.width == chosen.width && $0.height <= chosen.height } == true &&
    answered.last?.fitsContent == true, "a later conversation opens at the width you chose, and fits its thread up to your height")
  snips.closeAll()
  try check(snips.sessions.isEmpty && answered.allSatisfy { $0.panel == nil && $0.session.phase == .ended },
    "Close All closes the conversation")
  return count
}
