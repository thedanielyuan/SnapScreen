import AppKit
import SnapScreenCore

/// Gives each snip its windows, and shows a notice when a snip fails before it has any. Each snip's
/// conversation replaces the earlier snips' windows, so only one is open at a time.
@MainActor
final class SnipWindows: SessionControllerDelegate {
  let controller: SessionController
  let shields = PointerShieldController()
  let chosenSize = ChosenConversationSize()
  private(set) var sessions: [SessionWindows] = []
  private let showNotice: (String, NoticeAction?) -> Void
  private let present: @MainActor (CompanionPanel) -> Void

  /// `showNotice` shows a message, with a button when it has an action. `present` shows a window;
  /// the self-test leaves windows offscreen.
  init(controller: SessionController, showNotice: @escaping (String, NoticeAction?) -> Void,
    present: @escaping @MainActor (CompanionPanel) -> Void = { $0.orderFront(nil) }) {
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
      windows.onOpenConversation = { [weak self, weak windows] in self?.closeEarlier(than: windows) }
      sessions.append(windows)
      windows.handle(event)
    }
  }

  func sessionController(_ controller: SessionController, showNotice message: String) {
    showNotice(message, nil)
  }

  /// Closes every conversation, ending their sessions.
  func closeAll() {
    for windows in sessions { windows.closeConversation() }
  }

  /// Once a snip's conversation has opened, closes the earlier snips' conversations, previews and
  /// ended notices through their close button's path, ending their sessions. Cancelling a snip
  /// leaves them open. All capture panels refuse the keyboard, so replacing them cannot hand it
  /// to another SnapScreen panel, and no app is activated.
  private func closeEarlier(than windows: SessionWindows?) {
    for earlier in sessions where earlier !== windows { earlier.closeConversation() }
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
/// selection and the screenshot preview. None activates SnapScreen or takes the keyboard.
/// Select and cancel with the pointer; close panels with their buttons. The conversation opens small and
/// grows to fit its thread until you resize it. Once its answer has finished, a click in another
/// app closes the conversation and preview. Selecting a region in a new snip closes them too.
@MainActor
final class SessionWindows: NSObject, NSWindowDelegate {
  static let endedMessage = "Snip again to start a new capture."
  /// A conversation's largest content size, until you choose one by resizing a conversation.
  static let defaultConversationSize = NSSize(width: 460, height: 560)
  /// The smallest content size, which a conversation opens at and can be resized to.
  static let minimumConversationSize = NSSize(width: 340, height: 280)
  /// From Stop to the panel's bottom and right edges, and the band it takes beneath the thread
  /// while a request is in progress.
  private static let stopMargin: CGFloat = 14
  static let stopBandHeight: CGFloat = 8 + StopButton.size + stopMargin
  /// A click in another app this close to a panel, where macOS resizes it, was probably aimed at
  /// the panel, so it doesn't close it.
  static let outsideClickMargin: CGFloat = 8

  let session: SnipSession
  /// Called once every window has closed.
  var onClose: (() -> Void)?
  /// Called once the conversation has replaced the overlay without taking the keyboard.
  var onOpenConversation: (() -> Void)?
  private(set) var overlay: CompanionPanel?
  private(set) var selectionView: SelectionView?
  private(set) var panel: CompanionPanel?
  private(set) var previewPanel: CompanionPanel?
  private(set) var conversation: ConversationView?
  /// Shown beneath the thread while a request is in progress.
  private(set) var stopButton: StopButton?
  /// The thread's bottom edge, raised above Stop while it shows.
  private var threadBottom: NSLayoutConstraint?
  private var screenshot: NSImage?
  private let shields: PointerShieldController
  private let chosenSize: ChosenConversationSize
  private let present: @MainActor (CompanionPanel) -> Void
  /// The conversation grows to fit its thread until you resize it yourself.
  private(set) var fitsContent = true
  /// How tall the conversation may grow: its frame at its largest, where it was placed.
  private var largestHeight: CGFloat = 0
  /// Whether it opened above the selection, so it grows upward, away from it.
  private var growsUpward = false
  /// The visible frame of the display it opens on, which fitting uses until it's on screen.
  private var openingVisibleFrame = NSRect.zero
  /// Watches clicks in other apps while the answer has finished, and only then.
  private var outsideClickMonitor: Any?

  init(session: SnipSession, shields: PointerShieldController, chosenSize: ChosenConversationSize,
    present: @escaping @MainActor (CompanionPanel) -> Void) {
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
    case .answer(let text, let status):
      conversation?.updateAnswer(text, status: AnswerStatus(status))
      if status != .streaming { announce(status == .done ? "Answer complete" : "Answer stopped") }
    case .failed(let error):
      // Refused text is never kept, so the window clears it.
      conversation?.fail(error.message, clearAnswer: error.code == "refusal")
    case .ended:
      end()
      return
    }
    updateControls()
    fitPanel()
  }

  private func showOverlay(_ frozen: FrozenScreen) {
    guard let screen = NSScreen.screens.first(where: { $0.displayID == frozen.displayID }) else {
      // The display went away after it was captured.
      session.close()
      close()
      return
    }
    let window = SelectionOverlay.make(covering: screen)
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
  }

  private func select(_ rect: NormalizedRect) {
    guard let window = overlay, let view = selectionView,
      session.select(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)) else { return }
    let anchor = view.selectionDisplayRect.map { window.convertToScreen(view.convert($0, to: nil)) }
    let cropSize = view.selectedPixelSize
    let screen = window.screen
    releaseOverlay()
    showConversation(beside: anchor, on: screen, cropSize: cropSize)
    onOpenConversation?()
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
    // Pinned to the panel's corner rather than placed after the answer, so a long answer can't
    // scroll it out of view.
    let stop = StopButton(target: self, action: #selector(stopPressed))
    stop.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(thread)
    root.addSubview(stop)
    let bottom = thread.bottomAnchor.constraint(equalTo: root.bottomAnchor)
    NSLayoutConstraint.activate([
      thread.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      thread.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      thread.topAnchor.constraint(equalTo: root.topAnchor),
      bottom,
      stop.widthAnchor.constraint(equalToConstant: StopButton.size),
      stop.heightAnchor.constraint(equalToConstant: StopButton.size),
      stop.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.stopMargin),
      stop.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.stopMargin),
    ])
    panel = window
    conversation = thread
    stopButton = stop
    threadBottom = bottom
    if let size = cropSize { thread.reserveScreenshot(size: size) }
    thread.beginTurn()
    updateControls()
    fitPanel()
    present(window)
    shields.place(below: window)
  }

  private func updateControls() {
    conversation?.canRetry = session.canRetry
    conversation?.actionsEnabled = session.phase != .ended
    // Not while the answer or a Retry is running, or after one failed or stopped.
    watchOutsideClicks(panel != nil && session.phase == .ready)
    guard let stop = stopButton else { return }
    // Stop shows from the moment the region is selected, and can act once the request starts.
    stop.isHidden = !(session.phase == .cropping || session.phase == .running)
    stop.isEnabled = session.canStop
    threadBottom?.constant = stop.isHidden ? 0 : -Self.stopBandHeight
  }

  /// Grows the conversation to show its whole thread, and Stop while it shows, up to its largest
  /// size, until you resize it yourself. It never shrinks, so a Retry doesn't make it jump.
  private func fitPanel() {
    guard fitsContent, let window = panel, let root = window.contentView, let thread = conversation,
      let stop = stopButton else { return }
    let visible = window.isVisible ? (window.screen?.visibleFrame ?? openingVisibleFrame) : openingVisibleFrame
    // Growing can hide the thread's scroller, which widens the thread: its text rewraps and its
    // thumbnail grows. So it measures again until the panel holds still, a pass or two at most.
    for _ in 0..<4 {
      root.layoutSubtreeIfNeeded()
      let content = thread.contentHeight + (stop.isHidden ? 0 : Self.stopBandHeight)
      let height = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1, height: ceil(content))).height
      let frame = grownFrame(window.frame, toHeight: height, maximumHeight: largestHeight, upward: growsUpward,
        in: visible)
      guard frame != window.frame else { return }
      window.setFrame(frame, display: false)
    }
    root.layoutSubtreeIfNeeded()
  }

  @objc private func stopPressed() {
    guard session.stop() else { return }
    updateControls()
  }

  private func retryAnswer() {
    guard session.retry() else { return }
    conversation?.restartTurn()
    updateControls()
    fitPanel()
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
      // Restore the conversation's ordering without changing the browser's keyboard focus.
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

  /// Whether a click in another app closes the conversation now.
  var dismissesOnOutsideClick: Bool { outsideClickMonitor != nil }

  /// A global monitor gets a copy of each press that goes to another app. It can't change or stop
  /// the press, so the click still reaches that app, and for mouse events it needs no permission.
  /// It reads only where the press was, and nothing is kept or logged.
  private func watchOutsideClicks(_ watching: Bool) {
    if watching, outsideClickMonitor == nil {
      outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown,
        .otherMouseDown]) { [weak self] event in
        // A press in another app has no window here, so its location is on the screen.
        self?.clickedOutside(at: event.locationInWindow)
      }
    } else if !watching, let monitor = outsideClickMonitor {
      NSEvent.removeMonitor(monitor)
      outsideClickMonitor = nil
    }
  }

  /// A click in another app, at a point on the screen, closes a finished conversation and its
  /// preview as the close button does. Clicks in SnapScreen's own windows never arrive here. One
  /// just outside either panel, or while one is pressed or resized, leaves them open.
  func clickedOutside(at point: NSPoint) {
    guard dismissesOnOutsideClick, session.phase == .ready, !shields.isTrackingPanel else { return }
    let margin = Self.outsideClickMargin
    guard ![panel, previewPanel].contains(where: { $0?.frame.insetBy(dx: -margin, dy: -margin).contains(point) == true })
    else { return }
    // Every capture panel permanently refuses the keyboard, including during this close.
    closeConversation()
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

  /// Releases the frozen display, screenshot and conversation. The session releases its own.
  private func clearContent() {
    watchOutsideClicks(false)
    releaseOverlay()
    (previewPanel?.contentView as? PreviewView)?.image = nil
    previewPanel?.contentView = nil
    previewPanel?.delegate = nil
    previewPanel?.close()
    previewPanel = nil
    screenshot = nil
    conversation?.clear()
    conversation = nil
    stopButton?.target = nil
    stopButton?.action = nil
    stopButton = nil
    threadBottom = nil
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
