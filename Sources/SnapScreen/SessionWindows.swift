import AppKit
import SnapScreenCore

/// Gives each snip its windows, and shows a notice when a snip fails before it has any.
@MainActor
final class SnipWindows: SessionControllerDelegate {
  let controller: SessionController
  let shields = PointerShieldController()
  private(set) var sessions: [SessionWindows] = []
  private let showNotice: (String) -> Void
  private let present: @MainActor (NSWindow) -> Void

  /// `present` shows a window. The self-test leaves windows offscreen.
  init(controller: SessionController, showNotice: @escaping (String) -> Void,
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
      let windows = SessionWindows(session: session, shields: shields, present: present)
      windows.onClose = { [weak self, weak windows] in self?.closed(windows) }
      sessions.append(windows)
      windows.handle(event)
    }
  }

  func sessionController(_ controller: SessionController, showNotice message: String) {
    showNotice(message)
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

/// One session's windows: the overlay over its frozen display, then its conversation beside the
/// selection and the screenshot preview. None of them activates SnapScreen, so the app you snip
/// keeps focus, and Escape and Command-W close on key release, as in the companion.
@MainActor
final class SessionWindows: NSObject, NSWindowDelegate {
  static let endedMessage = "Snip again to start a new capture."

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
  private let present: @MainActor (NSWindow) -> Void

  init(session: SnipSession, shields: PointerShieldController, present: @escaping @MainActor (NSWindow) -> Void) {
    self.session = session
    self.shields = shields
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
    case .failed(let error):
      // The session drops refused text from the conversation, so the window does too.
      conversation?.fail(error.message, clearAnswer: error.code == "refusal")
    case .ended:
      end()
      return
    }
    updateControls()
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
    present(window)
    window.makeFirstResponder(view)
  }

  private func select(_ rect: NormalizedRect) {
    guard let window = overlay, let view = selectionView,
      session.select(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)) else { return }
    let anchor = view.selectionDisplayRect.map { window.convertToScreen(view.convert($0, to: nil)) }
    let screen = window.screen
    releaseOverlay()
    showConversation(beside: anchor, on: screen)
  }

  private func cancelSelection() {
    session.close()
    close()
  }

  /// Drops every reference to the frozen display.
  private func releaseOverlay() {
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

  private func showConversation(beside anchor: CGRect?, on screen: NSScreen?) {
    let screen = screen ?? screenUnderPointer()
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let window = CompanionPanel.make(title: "SnapScreen", contentSize: NSSize(width: 460, height: 560),
      minimumSize: NSSize(width: 340, height: 280), media: false)
    window.delegate = self
    window.setFrame(windowFrame(size: window.frame.size, beside: anchor, in: visible), display: false)
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
    input.onChange = { [weak self] in self?.updateControls() }
    thread.focusFallback = { [weak input] in input?.textView }
    root.addSubview(thread)
    root.addSubview(input)
    NSLayoutConstraint.activate([
      thread.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      thread.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      thread.topAnchor.constraint(equalTo: root.topAnchor),
      thread.bottomAnchor.constraint(equalTo: input.topAnchor, constant: -8),
      input.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      input.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      input.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
    ])
    panel = window
    conversation = thread
    composer = input
    thread.beginTurn(question: nil)
    updateControls()
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

  private func ask(_ text: String) {
    guard session.ask(text) else { return }
    conversation?.removeAbandonedTurn()
    conversation?.beginTurn(question: text)
    composer?.clearDraft()
    updateControls()
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
    window.setFrame(windowFrame(size: size, beside: nil, in: visible), display: false)
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
    session.close()
    close()
    return false
  }

  func windowWillStartLiveResize(_ notification: Notification) {
    shields.liveResizeStarted(notification.object as? NSWindow)
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    shields.liveResizeEnded()
  }

  /// The session ended on its own. As in the companion, an open conversation keeps only a notice.
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
