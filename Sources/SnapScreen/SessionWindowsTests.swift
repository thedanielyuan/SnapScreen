import AppKit
import SnapScreenCore

private enum SessionWindowsTestError: Error { case failed(String) }

/// Answers each question at once, after a moment, or holds the answer until it's stopped.
private final class SelfTestAnswers: AnswerClient, @unchecked Sendable {
  private let lock = NSLock()
  private var holding = false
  private var delaying = false
  private var pausing = false
  private var asked: [String] = []

  var holds: Bool {
    get { lock.withLock { holding } }
    set { lock.withLock { holding = newValue } }
  }

  /// Each answer streams for a moment before it finishes.
  var delays: Bool {
    get { lock.withLock { delaying } }
    set { lock.withLock { delaying = newValue } }
  }

  /// Answers stream until this is turned off, then finish.
  var pauses: Bool {
    get { lock.withLock { pausing } }
    set { lock.withLock { pausing = newValue } }
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
    let (holds, delays) = lock.withLock { () -> (Bool, Bool) in
      asked.append(question)
      return (holding, delaying)
    }
    let text = "Answer to \(question)"
    handlers.onThinking()
    handlers.onDelta(text)
    while pauses { try await Task.sleep(for: .milliseconds(10)) }
    if holds { try await Task.sleep(for: .seconds(60)) }
    if delays { try await Task.sleep(for: .milliseconds(300)) }
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
  func select(_ windows: SessionWindows) -> Bool {
    windows.selectionView?.selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    windows.selectionView?.confirm()
    return waitUntil { windows.conversation?.latestTurn?.state == .done }
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
    "the session retains follow-up state within the limit")
  try check(windows.composer?.isReadOnly == true && windows.composer?.textView.isEditable == false &&
    windows.composer?.textView.isSelectable == false && windows.composer?.sendButton.isHidden == true,
    "the capture flow offers no editable or selectable field or idle Send button")

  // The conversation opens only as tall as its answer needs, and grows down with its thread.
  guard let panel = windows.panel, let thread = windows.conversation else {
    throw SessionWindowsTestError.failed("the conversation stays open")
  }
  try check(hasPassivePanelConfiguration(panel) && panel.level == .floating,
    "the conversation is a floating panel that cannot take keyboard focus")
  func fitsThread() -> Bool { thread.scrollView.documentView!.frame.height <= thread.scrollView.contentSize.height + 1 }
  let largest = panel.frameRect(forContentRect: NSRect(origin: .zero, size: SessionWindows.defaultConversationSize))
  let top = panel.frame.maxY
  try check(panel.frame.height < largest.height && fitsThread() && windows.fitsContent,
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
  try check(waitUntil { windows.conversation?.latestTurn?.state == .streaming } && windows.composer?.canStop == true &&
    windows.composer?.sendButton.isHidden == false && windows.composer?.sendButton.isEnabled == true,
    "streaming text shows while the passive composer's Stop button is available")
  windows.composer?.sendButton.performClick(nil)
  try check(windows.conversation?.latestTurn?.state == .stopped && windows.conversation?.canRetry == true &&
    windows.composer?.isRunning == false, "Stop keeps the text so far and offers Retry")
  answers.holds = false
  windows.conversation?.onRetry?()
  try check(waitUntil { windows.conversation?.latestTurn?.state == .done } &&
    windows.conversation?.latestTurn?.answer.renderedText == "Answer to Hold on", "Retry asks again")
  try check(answers.questions == ["(first)", "Why?", longQuestion, longQuestion, "Hold on", "Hold on"],
    "each request asks its own question")

  // Programmatic submissions retain the controller's queue behavior even though the passive
  // capture UI no longer accepts typed follow-ups. A stopped answer keeps its draft unsent.
  answers.delays = true
  windows.composer?.setDraft("Slowly")
  windows.composer?.submit()
  try check(waitUntil { windows.conversation?.latestTurn?.state == .streaming }, "a slow answer streams")
  windows.composer?.setDraft("Queued")
  windows.composer?.submit()
  try check(windows.composer?.isQueued == true && windows.composer?.hintLabel.stringValue == ComposerView.queuedMessage &&
    windows.composer?.draft == "Queued" && windows.conversation?.latestTurn?.question == "Slowly",
    "submitting while an answer streams queues the draft")
  answers.delays = false
  try check(waitUntil { windows.conversation?.latestTurn?.question == "Queued" && windows.conversation?.latestTurn?.state == .done } &&
    windows.composer?.draft.isEmpty == true && windows.composer?.isQueued == false, "the queued draft goes once the answer finishes")
  answers.holds = true
  windows.composer?.setDraft("Held")
  windows.composer?.submit()
  try check(waitUntil { windows.conversation?.latestTurn?.state == .streaming }, "a held answer streams")
  windows.composer?.setDraft("Not sent")
  windows.composer?.submit()
  windows.composer?.onStop?()
  answers.holds = false
  try check(windows.composer?.isQueued == false && windows.composer?.draft == "Not sent" &&
    !answers.questions.contains("Not sent"), "stopping the answer leaves its queued draft in the field, unsent")

  // Copy actions still find the newest answer and code block without a key window. These checks
  // write to a private pasteboard, never the clipboard.
  let general = Clipboard.pasteboard
  let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.snapscreen.self-test.\(UUID().uuidString)"))
  Clipboard.pasteboard = pasteboard
  windows.composer?.setDraft("Code:\n```py\nprint(1)\n```")
  windows.composer?.submit()
  try check(waitUntil { windows.conversation?.latestTurn?.state == .done }, "an answer with code arrives")
  func enables(_ action: Selector) -> Bool { windows.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")) }
  try check(enables(#selector(SessionWindows.copyAnswer(_:))) && enables(#selector(SessionWindows.copyLastCode(_:))),
    "Copy Answer and Copy Code are available")
  windows.copyAnswer(nil)
  try check(pasteboard.string(forType: .string) == "Answer to Code:\n```py\nprint(1)\n```", "Copy Answer copies the newest answer")
  windows.copyLastCode(nil)
  try check(pasteboard.string(forType: .string) == "print(1)", "Copy Code copies the newest code block")
  Clipboard.pasteboard = general
  pasteboard.releaseGlobally()

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
  try check(!enables(#selector(SessionWindows.copyAnswer(_:))) && !enables(#selector(SessionWindows.copyLastCode(_:))),
    "an ended session has nothing to copy")
  windows.panel?.performClose(nil)
  try check(windows.session.phase == .ended && windows.panel == nil && snips.sessions.isEmpty,
    "closing the conversation ends the session")

  // Once its answer has finished, a click in another app closes the conversation and its preview,
  // as the close button does. The global monitor never fires here, so these checks pass each
  // click's position as it would.
  answers.pauses = true
  guard let finished = snip() else { throw SessionWindowsTestError.failed("a snip to dismiss") }
  finished.selectionView?.selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
  finished.selectionView?.confirm()
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
  try check(finished.composer?.isRunning == true && !finished.dismissesOnOutsideClick && stillOpen(.cropping),
    "a click in another app doesn't close a conversation waiting for its first answer")
  try check(waitUntil { finished.conversation?.latestTurn?.state == .streaming } && !finished.dismissesOnOutsideClick &&
    stillOpen(.running), "a click in another app doesn't close or stop an answer as it streams")
  answers.pauses = false
  try check(waitUntil { finished.conversation?.latestTurn?.state == .done } && finished.dismissesOnOutsideClick,
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

  // Follow-ups and Retry turn it off while they run, as do a stopped or failed answer.
  answers.pauses = true
  finished.composer?.setDraft("And this?")
  finished.composer?.submit()
  try check(waitUntil { finished.conversation?.latestTurn?.state == .streaming } && !finished.dismissesOnOutsideClick &&
    stillOpen(.running), "a click in another app doesn't close or stop a follow-up as it streams")
  finished.composer?.onStop?()
  try check(!finished.dismissesOnOutsideClick && stillOpen(.stopped), "a stopped answer stays open until you close it")
  finished.conversation?.onRetry?()
  try check(!finished.dismissesOnOutsideClick && stillOpen(.running), "a click in another app doesn't close or stop a Retry")
  answers.pauses = false
  try check(waitUntil { finished.conversation?.latestTurn?.state == .done } && finished.dismissesOnOutsideClick,
    "once the Retry finishes, a click in another app can close the conversation")
  slot.key = nil
  finished.composer?.setDraft("No key")
  finished.composer?.submit()
  try check(waitUntil { finished.session.phase == .failed } && !finished.dismissesOnOutsideClick && stillOpen(.failed),
    "a failed answer stays open until you close it")
  slot.key = "sk-ant-self-test"
  finished.conversation?.onRetry?()
  try check(waitUntil { finished.conversation?.latestTurn?.state == .done } && finished.dismissesOnOutsideClick,
    "a successful Retry makes the conversation dismissible again")

  // A new snip leaves it open and dismissible while you select. Selecting happens in SnapScreen's
  // overlay, which the monitor never sees.
  guard let selecting = snip() else { throw SessionWindowsTestError.failed("another snip") }
  try check(selecting.overlay != nil && finished.panel === finishedPanel && finished.dismissesOnOutsideClick &&
    snips.sessions.count == 2, "a new snip leaves a finished conversation open and dismissible while you select")
  selecting.overlay?.closeAction?()
  try check(snips.sessions.count == 1 && finished.panel === finishedPanel && finished.dismissesOnOutsideClick,
    "cancelling the new snip leaves it as it was")

  // The click closes both windows through the close button's path, which ends the session, releases
  // the screenshot, answers and draft, and stops watching. Meanwhile no other panel, such as a new
  // snip's overlay, can take the keyboard, which AppKit would otherwise hand it from the closing
  // ones.
  guard let finishedThread = finished.conversation, let finishedComposer = finished.composer,
    let finishedPreview = finished.previewPanel, let finishedPreviewView = finishedPreview.contentView as? PreviewView else {
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
  finishedComposer.setDraft("Not sent")
  finished.clickedOutside(at: elsewhere())
  try check(finished.session.phase == .ended && finished.panel == nil && finished.previewPanel == nil &&
    finished.conversation == nil && finished.composer == nil && !finished.dismissesOnOutsideClick &&
    !finishedPanel.isVisible && !finishedPreview.isVisible && !snips.shields.isTrackingPanel,
    "a click in another app ends the session and closes the conversation and preview")
  try check(finishedPreviewView.image == nil && finishedThread.turns.isEmpty && finishedThread.thumbnail.screenshot == nil &&
    finishedComposer.draft.isEmpty, "closing them releases the screenshot, answers and unsent draft")
  try check(keyableWhileClosing == false && !nextOverlay.canBecomeKey && snips.sessions.count == 1 && next.overlay === nextOverlay,
    "a new snip's overlay cannot take the keyboard during or after another conversation closes")
  finished.clickedOutside(at: elsewhere())
  try check(finished.session.phase == .ended && snips.sessions.count == 1, "a later click finds nothing more to close")

  // Selecting a region in a new snip closes the earlier conversation and preview through the close
  // button's path, even while it answers, which ends its session and releases its screenshot,
  // answers and draft. The new conversation is presented before the earlier one closes.
  guard select(next), let nextPanel = next.panel, let nextThread = next.conversation, let nextComposer = next.composer else {
    throw SessionWindowsTestError.failed("the new snip's conversation")
  }
  next.conversation?.onPreview?()
  guard let nextPreview = next.previewPanel, let nextPreviewView = nextPreview.contentView as? PreviewView else {
    throw SessionWindowsTestError.failed("the new snip's preview")
  }
  answers.pauses = true
  nextComposer.setDraft("Still answering")
  nextComposer.submit()
  try check(waitUntil { nextThread.latestTurn?.state == .streaming }, "the conversation answers a follow-up")
  nextComposer.setDraft("Not sent")
  guard let latest = snip() else { throw SessionWindowsTestError.failed("a snip while the answer streams") }
  try check(next.panel === nextPanel && next.previewPanel === nextPreview && next.session.phase == .running &&
    snips.sessions.count == 2, "a new snip leaves a streaming conversation open while you select")
  var shownFirst: Bool?
  let closedNext = next.onClose
  next.onClose = {
    shownFirst = latest.panel != nil && presented === latest.panel
    closedNext?()
  }
  latest.selectionView?.selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
  latest.selectionView?.confirm()
  try check(next.session.phase == .ended && next.panel == nil && next.previewPanel == nil && next.conversation == nil &&
    snips.sessions.count == 1 && snips.sessions.first === latest && latest.panel != nil,
    "selecting a region in a new snip closes the earlier conversation and preview, ending its session")
  try check(shownFirst == true, "the new conversation is presented before the earlier one closes")
  try check(nextPreviewView.image == nil && nextThread.turns.isEmpty && nextThread.thumbnail.screenshot == nil &&
    nextComposer.draft.isEmpty, "closing them releases the screenshot, answers and unsent draft")
  answers.pauses = false
  try check(waitUntil { latest.conversation?.latestTurn?.state == .done } &&
    answers.questions.suffix(2) == ["Still answering", "(first)"], "the new snip is answered, and the stopped one isn't")

  // A new snip ends a selection that's still being cropped, which leaves a notice in its
  // conversation. Selecting the new snip's region closes that too.
  guard let cropping = snip() else { throw SessionWindowsTestError.failed("a snip to crop") }
  cropping.selectionView?.selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
  cropping.selectionView?.confirm()
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
