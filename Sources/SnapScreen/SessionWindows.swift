import AppKit
import SnapScreenCore

/// Gives each snip its windows, and shows a notice when a snip fails before it has any.
@MainActor
final class SnipWindows: SessionControllerDelegate {
  let controller: SessionController
  let shields = PointerShieldController()
  let chosenSize = ChosenConversationSize()
  private(set) var sessions: [SessionWindows] = []
  private let showNotice: (String, NoticeAction?) -> Void
  private let present: @MainActor (NSWindow) -> Void

  /// `showNotice` shows a message, with a button when it has an action. `present` shows a window;
  /// the self-test leaves windows offscreen.
  init(controller: SessionController, showNotice: @escaping (String, NoticeAction?) -> Void,
    present: @escaping @MainActor (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }) {
    self.controller = controller
    self.showNotice = showNotice
    self.present = present
    controller.delegate = self
    shields.start()
  }

  func session(_ session: SnipSession, didReport event: SessionEvent) {
    if let windows = sessions.first(where: { $0.session === session }) {
      windows.handle(event)
    } else if case .captured = event {
      let windows = SessionWindows(session: session, shields: shields, chosenSize: chosenSize, present: present)
      windows.onClose = { [weak self, weak windows] in self?.closed(windows) }
      sessions.append(windows)
      windows.handle(event)
    }
  }

  func sessionController(_ controller: SessionController, showNotice message: String) {
    showNotice(message, nil)
  }

  /// With every session open, the notice offers to close the oldest conversation.
  func sessionControllerIsFull(_ controller: SessionController) {
    showNotice(SessionController.fullMessage, NoticeAction(title: "Close Oldest") { [weak self] in self?.closeOldest() })
  }

  /// Closes the conversation that opened first, ending its session.
  func closeOldest() {
    sessions.first?.closeConversation()
  }

  /// Closes every conversation, ending their sessions.
  func closeAll() {
    for windows in sessions { windows.closeConversation() }
  }

  private func closed(_ windows: SessionWindows?) {
    sessions.removeAll { $0 === windows }
    // The shield stays beneath a conversation that's still open.
    if let panel = sessions.last(where: { $0.panel?.isVisible == true })?.panel {
      shields.place(below: panel)
    } else {
      shields.reset()
    }
  }
}

/// The size you last gave a conversation by resizing it. Later conversations open at its width and
/// grow no taller than its height. It's kept in memory only, so it lasts until SnapScreen quits.
final class ChosenConversationSize {
  var size: NSSize?
}

/// One session's windows: the overlay over its frozen display, then its conversation beside the
/// selection and the screenshot preview. None of them activates SnapScreen, so the app you snip
/// keeps focus, and Escape and Command-W close on key release. The conversation opens small and
/// grows to fit its thread until you resize it.
@MainActor
final class SessionWindows: NSObject, NSWindowDelegate, NSMenuItemValidation {
  static let endedMessage = "Snip again to start a new capture."
  /// A conversation's largest content size, until you choose one by resizing a conversation.
  static let defaultConversationSize = NSSize(width: 460, height: 560)
  /// The smallest content size, which a conversation opens at and can be resized to.
  static let minimumConversationSize = NSSize(width: 340, height: 280)
  /// Between the thread and the follow-up field, and from the field to the panel's edges.
  private static let composerGap: CGFloat = 8
  private static let composerMargin: CGFloat = 14

  let session: SnipSession
  /// Called once every window has closed.
  var onClose: (() -> Void)?
  private(set) var overlay: CompanionPanel?
  private(set) var selectionView: SelectionView?
  private(set) var panel: CompanionPanel?
  private(set) var previewPanel: CompanionPanel?
  private(set) var conversation: ConversationView?
  private(set) var composer: ComposerView?
  private var screenshot: NSImage?
  private let shields: PointerShieldController
  private let chosenSize: ChosenConversationSize
  private let present: @MainActor (NSWindow) -> Void
  /// The conversation grows to fit its thread and draft until you resize it yourself.
  private(set) var fitsContent = true
  /// How tall the conversation may grow: its frame at its largest, where it was placed.
  private var largestHeight: CGFloat = 0
  /// Whether it opened above the selection, so it grows upward, away from it.
  private var growsUpward = false
  /// The visible frame of the display it opens on, which fitting uses until it's on screen.
  private var openingVisibleFrame = NSRect.zero

  init(session: SnipSession, shields: PointerShieldController, chosenSize: ChosenConversationSize,
    present: @escaping @MainActor (NSWindow) -> Void) {
    self.session = session
    self.shields = shields
    self.chosenSize = chosenSize
    self.present = present
  }

  func handle(_ event: SessionEvent) {
    switch event {
    case .captured(let frozen):
      showOverlay(frozen)
    case .accepted(let png):
      screenshot = NSImage(data: png)
      conversation?.setScreenshot(screenshot)
    case .started:
      break
    case .thinking:
      conversation?.setThinking()
    case .notice(let message, let removedTurns):
      conversation?.addNotice(message, removedTurns: removedTurns)
    case .answer(let text, let status):
      conversation?.updateAnswer(text, status: AnswerStatus(status))
      if status != .streaming { announce(status == .done ? "Answer complete" : "Answer stopped") }
      // A draft queued behind a stopped answer stays in the field, unsent.
      if status == .stopped { composer?.cancelQueue() }
    case .failed(let error):
      // The session drops refused text from the conversation, so the window does too.
      conversation?.fail(error.message, clearAnswer: error.code == "refusal")
      composer?.cancelQueue()
    case .ended:
      end()
      return
    }
    updateControls()
    fitPanel()
    // The answer a queued draft waited for has finished, so it goes now.
    if case .answer(_, .done) = event { composer?.sendQueued() }
  }

  private func showOverlay(_ frozen: FrozenScreen) {
    guard let screen = NSScreen.screens.first(where: { $0.displayID == frozen.displayID }) else {
      // The display went away after it was captured.
      session.close()
      close()
      return
    }
    let window = SelectionOverlay.make(covering: screen)
    window.closeAction = { [weak self] in self?.cancelSelection() }
    window.delegate = self
    let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
    view.fillsBounds = true
    // Sized in pixels, so the selection's size badge shows the pixels that are sent.
    view.image = NSImage(cgImage: frozen.image, size: NSSize(width: frozen.image.width, height: frozen.image.height))
    view.onCancel = { [weak self] in self?.cancelSelection() }
    view.onConfirm = { [weak self] rect in self?.select(rect) }
    window.contentView = view
    overlay = window
    selectionView = view
    BackgroundCursor.setEnabled(true)
    present(window)
    window.makeFirstResponder(view)
  }

  private func select(_ rect: NormalizedRect) {
    guard let window = overlay, let view = selectionView,
      session.select(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)) else { return }
    let anchor = view.selectionDisplayRect.map { window.convertToScreen(view.convert($0, to: nil)) }
    let cropSize = view.selectedPixelSize
    let screen = window.screen
    releaseOverlay()
    showConversation(beside: anchor, on: screen, cropSize: cropSize)
  }

  private func cancelSelection() {
    session.close()
    close()
  }

  /// Drops every reference to the frozen display.
  private func releaseOverlay() {
    // A new snip releases the previous overlay before it shows its own.
    if overlay != nil { BackgroundCursor.setEnabled(false) }
    selectionView?.image = nil
    selectionView?.onCancel = nil
    selectionView?.onConfirm = nil
    selectionView = nil
    overlay?.closeAction = nil
    overlay?.delegate = nil
    overlay?.contentView = nil
    overlay?.close()
    overlay = nil
  }

  /// `cropSize`, the selection in pixels, holds the thumbnail's place until the crop arrives.
  private func showConversation(beside anchor: CGRect?, on screen: NSScreen?, cropSize: CGSize?) {
    let screen = screen ?? screenUnderPointer()
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let window = CompanionPanel.make(title: "SnapScreen", contentSize: chosenSize.size ?? Self.defaultConversationSize,
      minimumSize: Self.minimumConversationSize, media: false)
    window.delegate = self
    // Placed at its largest, so it has room to grow, but opened at its smallest.
    let largest = windowFrame(size: window.frame.size, beside: anchor, in: visible)
    let smallest = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumConversationSize)).height
    window.setFrame(openingFrame(largest, height: smallest, beside: anchor, in: visible), display: false)
    largestHeight = largest.height
    growsUpward = anchor.map { largest.minY >= $0.maxY } ?? false
    openingVisibleFrame = visible
    let root = NSView()
    window.contentView = root
    let thread = ConversationView()
    thread.translatesAutoresizingMaskIntoConstraints = false
    thread.onPreview = { [weak self] in self?.showPreview() }
    thread.onRetry = { [weak self] in self?.retryAnswer() }
    let input = ComposerView()
    input.translatesAutoresizingMaskIntoConstraints = false
    input.onSubmit = { [weak self] text in self?.ask(text) }
    input.onStop = { [weak self] in self?.stopAnswer() }
    input.onChange = { [weak self] in
      self?.updateControls()
      self?.fitPanel()
    }
    thread.focusFallback = { [weak input] in input?.textView }
    root.addSubview(thread)
    root.addSubview(input)
    NSLayoutConstraint.activate([
      thread.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      thread.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      thread.topAnchor.constraint(equalTo: root.topAnchor),
      thread.bottomAnchor.constraint(equalTo: input.topAnchor, constant: -Self.composerGap),
      input.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.composerMargin),
      input.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.composerMargin),
      input.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.composerMargin),
    ])
    panel = window
    conversation = thread
    composer = input
    if let size = cropSize { thread.reserveScreenshot(size: size) }
    thread.beginTurn(question: nil)
    updateControls()
    fitPanel()
    present(window)
    shields.place(below: window)
    window.makeFirstResponder(input.textView)
  }

  private func updateControls() {
    conversation?.canRetry = session.canRetry
    conversation?.actionsEnabled = session.phase != .ended
    guard let composer = composer else { return }
    composer.maximumCharacters = session.maxInputCharacters
    composer.isRunning = session.phase == .cropping || session.phase == .running
    composer.canStop = session.canStop
    composer.canSubmit = session.canAsk
  }

  /// Grows the conversation to show its whole thread and draft, up to its largest size, until you
  /// resize it yourself. It never shrinks, so a Retry or a sent draft doesn't make it jump.
  private func fitPanel() {
    guard fitsContent, let window = panel, let root = window.contentView, let thread = conversation,
      let input = composer else { return }
    let visible = window.isVisible ? (window.screen?.visibleFrame ?? openingVisibleFrame) : openingVisibleFrame
    // Growing can hide the thread's scroller, which widens the thread: its text rewraps and its
    // thumbnail grows. So it measures again until the panel holds still, a pass or two at most.
    for _ in 0..<4 {
      root.layoutSubtreeIfNeeded()
      let content = thread.contentHeight + Self.composerGap + input.intrinsicContentSize.height + Self.composerMargin
      let height = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1, height: ceil(content))).height
      let frame = grownFrame(window.frame, toHeight: height, maximumHeight: largestHeight, upward: growsUpward,
        in: visible)
      guard frame != window.frame else { return }
      window.setFrame(frame, display: false)
    }
    root.layoutSubtreeIfNeeded()
  }

  private func ask(_ text: String) {
    guard session.ask(text) else { return }
    conversation?.removeAbandonedTurn()
    conversation?.beginTurn(question: text)
    composer?.clearDraft()
    updateControls()
    fitPanel()
  }

  private func stopAnswer() {
    guard session.stop() else { return }
    updateControls()
  }

  private func retryAnswer() {
    guard session.retry() else { return }
    conversation?.restartLatestTurn()
    updateControls()
  }

  private func showPreview() {
    guard session.phase != .ended, let image = screenshot else { return }
    if let existing = previewPanel {
      present(existing)
      return
    }
    let screen = panel?.screen ?? screenUnderPointer()
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let size = imageWindowContentSize(image.size, backingScale: 1,
      maximum: NSSize(width: visible.width * 0.8, height: visible.height * 0.8),
      minimum: NSSize(width: 320, height: 220),
      chrome: NSSize(width: 24, height: CompanionPanel.titlebarHeight + 24))
    let window = CompanionPanel.make(title: "Screenshot", contentSize: size, minimumSize: NSSize(width: 240, height: 180),
      media: true)
    window.delegate = self
    // Beside the conversation, so the preview covers neither it nor the middle of the screen.
    window.setFrame(windowFrame(size: size, beside: panel?.frame, in: visible), display: false)
    let preview = PreviewView(image: image)
    window.contentView = preview
    previewPanel = window
    present(window)
    shields.place(below: window)
    window.makeFirstResponder(preview)
  }

  private func announce(_ text: String) {
    guard let element = conversation else { return }
    NSAccessibility.post(element: element, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if sender === previewPanel {
      (previewPanel?.contentView as? PreviewView)?.image = nil
      previewPanel?.delegate = nil
      previewPanel = nil
      // Keep typing in the conversation rather than returning keys to the app beneath.
      DispatchQueue.main.async { [weak self] in
        guard let self = self, let window = self.panel, window.isVisible else { return }
        self.present(window)
        self.shields.place(below: window)
      }
      return true
    }
    // Closing the conversation ends its session, or dismisses one that already ended.
    closeConversation()
    return false
  }

  /// Ends the session and closes its windows, as the conversation's close button does.
  func closeConversation() {
    session.close()
    close()
  }

  /// Edit > Copy Answer (⇧⌘C): the newest answer, as its Copy button copies it.
  @objc func copyAnswer(_ sender: Any?) {
    conversation?.copyLatestAnswer()
  }

  /// Edit > Copy Code (⌥⌘C): the newest code block, as its Copy button copies it.
  @objc func copyLastCode(_ sender: Any?) {
    conversation?.copyLatestCode()
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(copyAnswer(_:)): return conversation?.answerToCopy != nil
    case #selector(copyLastCode(_:)): return conversation?.codeToCopy != nil
    default: return true
    }
  }

  func windowWillStartLiveResize(_ notification: Notification) {
    // Resizing the conversation yourself stops it fitting its thread.
    if (notification.object as? NSWindow) === panel { fitsContent = false }
    shields.liveResizeStarted(notification.object as? NSWindow)
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    if let window = notification.object as? NSWindow, window === panel {
      chosenSize.size = window.contentRect(forFrameRect: window.frame).size
    }
    shields.liveResizeEnded()
  }

  /// Zooming the conversation is resizing it too, but it doesn't choose the next one's size.
  func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
    if window === panel { fitsContent = false }
    return true
  }

  /// The session ended on its own, so an open conversation keeps only a notice.
  private func end() {
    clearContent()
    guard let window = panel else {
      close()
      return
    }
    window.title = "SnapScreen — Session ended"
    window.contentView = SessionEndedView(message: Self.endedMessage)
  }

  /// Releases the frozen display, screenshot, conversation and draft. The session releases its own.
  private func clearContent() {
    releaseOverlay()
    (previewPanel?.contentView as? PreviewView)?.image = nil
    previewPanel?.contentView = nil
    previewPanel?.delegate = nil
    previewPanel?.close()
    previewPanel = nil
    screenshot = nil
    conversation?.clear()
    conversation = nil
    composer?.clear()
    composer = nil
    panel?.makeFirstResponder(nil)
    panel?.contentView = nil
  }

  private func close() {
    clearContent()
    panel?.delegate = nil
    panel?.close()
    panel = nil
    let onClose = onClose
    self.onClose = nil
    onClose?()
  }
}

private extension AnswerStatus {
  init(_ status: SessionEvent.AnswerStatus) {
    switch status {
    case .streaming: self = .streaming
    case .done: self = .done
    case .stopped: self = .stopped
    }
  }
}
