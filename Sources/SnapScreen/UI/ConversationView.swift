import AppKit

private final class ThreadDocumentView: NSView {
  override var isFlipped: Bool { true }
}

/// The accepted crop at the top of the thread. Pressing it opens the larger preview.
final class ThumbnailButton: CompanionButton {
  var screenshot: NSImage? { didSet { needsDisplay = true } }
  /// The crop's size in pixels, known once the region is selected. The thumbnail takes this size at
  /// once and keeps it, so the thread doesn't shift when the crop arrives.
  var reservedSize: CGSize?

  init(target: AnyObject?, action: Selector?) {
    super.init(frame: .zero)
    self.target = target
    self.action = action
    isBordered = false
    title = ""
    setButtonType(.momentaryChange)
    setAccessibilityLabel("Selected screenshot")
    setAccessibilityHelp("Opens a larger preview.")
    toolTip = "Show screenshot"
  }

  required init?(coder: NSCoder) { nil }

  /// Fits the screenshot within the thread, never wider than 62% of it or taller than 150 points.
  func size(for width: CGFloat) -> NSSize {
    guard let size = reservedSize ?? screenshot?.size, size.width > 0, size.height > 0 else { return .zero }
    let scale = min(min(width * 0.62, 300) / size.width, 150 / size.height, 1)
    return NSSize(width: max(24, (size.width * scale).rounded()), height: max(24, (size.height * scale).rounded()))
  }

  /// A very thin crop keeps a usable button; the image itself keeps its proportions.
  var imageRect: CGRect {
    guard let image = screenshot else { return .zero }
    return fittedImageRect(image.size, in: bounds, inset: 0)
  }

  override func draw(_ dirtyRect: NSRect) {
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    Theme.surface.setFill()
    bounds.fill()
    if let image = screenshot {
      image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: isHighlighted ? 0.8 : 1,
        respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
    NSGraphicsContext.restoreGraphicsState()
    Theme.surfaceBorder.setStroke()
    shape.lineWidth = 1
    shape.stroke()
  }

  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
  }

  override var focusRingMaskBounds: NSRect { bounds }
}

/// Spinner first; after five seconds, a label and the elapsed time.
final class PendingView: NSView {
  private let spinner = NSProgressIndicator()
  let label = NSTextField(labelWithString: "")
  private let time = NSTextField(labelWithString: "")
  var thinking = false { didSet { if thinking != oldValue { update() } } }
  var since = Date() { didSet { update() } }
  static let labelDelay: TimeInterval = 5
  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.setAccessibilityLabel("Loading")
    label.font = .systemFont(ofSize: 12)
    label.textColor = .secondaryLabelColor
    time.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    time.textColor = .tertiaryLabelColor
    time.setAccessibilityElement(false)
    [spinner, label, time].forEach(addSubview)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil && !isHidden { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
  }

  override var isHidden: Bool {
    didSet {
      if isHidden { spinner.stopAnimation(nil) } else if window != nil { spinner.startAnimation(nil) }
    }
  }

  func update(now: Date = Date()) {
    let elapsed = max(0, now.timeIntervalSince(since))
    guard elapsed >= Self.labelDelay else {
      label.stringValue = ""
      time.stringValue = ""
      return
    }
    let text = thinking ? "Thinking…" : "Waiting for the answer…"
    if label.stringValue != text {
      label.stringValue = text
      // Announce each new label once, never the timer.
      NSAccessibility.post(element: label, notification: .announcementRequested,
        userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.low.rawValue])
    }
    let seconds = Int(elapsed)
    time.stringValue = "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    layoutContent()
  }

  func layoutContent() {
    spinner.frame = NSRect(x: 0, y: 2, width: 16, height: 16)
    label.sizeToFit()
    label.frame.origin = NSPoint(x: 24, y: (20 - label.frame.height) / 2)
    time.sizeToFit()
    time.frame.origin = NSPoint(x: label.frame.maxX + 6, y: (20 - time.frame.height) / 2)
  }
}

/// A failed request, with Retry.
final class FailureView: NSView {
  let message = NSTextField(wrappingLabelWithString: "")
  private let icon = NSImageView()
  let retryButton: ActionButton
  override var isFlipped: Bool { true }

  init(target: AnyObject?, retry: Selector) {
    retryButton = ActionButton(symbol: "arrow.clockwise", title: "Retry", label: "Retry", target: target, action: retry)
    super.init(frame: .zero)
    retryButton.tint = .labelColor
    message.font = .systemFont(ofSize: 13)
    message.textColor = .systemRed
    message.isSelectable = true
    icon.image = Theme.symbol("exclamationmark.triangle.fill", size: 13, color: .systemRed)
    icon.setAccessibilityElement(false)
    [icon, message, retryButton].forEach(addSubview)
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { nil }

  func height(for width: CGFloat) -> CGFloat {
    let textWidth = max(40, width - 46)
    let textHeight = ceil(message.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth,
      height: .greatestFiniteMagnitude)).height ?? 18)
    icon.frame = NSRect(x: 12, y: 11, width: 16, height: 16)
    message.frame = NSRect(x: 34, y: 10, width: textWidth, height: textHeight)
    var height = 10 + textHeight + 10
    if !retryButton.isHidden {
      let size = retryButton.buttonSize
      retryButton.frame = NSRect(x: 28, y: height - 4, width: size.width, height: size.height)
      height += size.height + 2
    }
    return height
  }

  override func draw(_ dirtyRect: NSRect) {
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
    NSColor.systemRed.withAlphaComponent(0.08).setFill()
    shape.fill()
    NSColor.systemRed.withAlphaComponent(0.4).setStroke()
    shape.lineWidth = 1
    shape.stroke()
  }
}

enum AnswerStatus: String { case streaming, done, stopped }

enum TurnState: Equatable { case waiting, thinking, streaming, done, stopped, failed(String) }

/// The snip's answer, with its progress, failure and actions.
final class TurnView: NSView {
  private(set) var state: TurnState = .waiting
  let answer = AnswerView()
  let pending = PendingView()
  let failure: FailureView
  let copyButton: ActionButton
  let retryButton: ActionButton
  private let stoppedLabel = NSTextField(labelWithString: "Stopped")
  var canRetry = false { didSet { updateVisibility() } }
  var actionsEnabled = true {
    didSet {
      copyButton.isEnabled = actionsEnabled
      answer.copyEnabled = actionsEnabled
    }
  }
  /// The shortcut that copies this answer, while it offers Copy.
  var copyShortcut: String? {
    didSet { copyButton.toolTip = "Copy answer" + (copyShortcut.map { " (\($0))" } ?? "") }
  }
  override var isFlipped: Bool { true }

  init(target: AnyObject?, copy: Selector, retry: Selector) {
    failure = FailureView(target: target, retry: retry)
    copyButton = ActionButton(symbol: "doc.on.doc", label: "Copy answer", target: target, action: copy)
    retryButton = ActionButton(symbol: "arrow.clockwise", title: "Retry", label: "Retry", target: target, action: retry)
    super.init(frame: .zero)
    copyButton.hoverTint = Theme.accent
    stoppedLabel.font = .systemFont(ofSize: 12)
    stoppedLabel.textColor = .secondaryLabelColor
    [answer, pending, failure, copyButton, stoppedLabel, retryButton].forEach(addSubview)
    updateVisibility()
  }

  required init?(coder: NSCoder) { nil }

  var isPending: Bool {
    switch state {
    case .waiting, .thinking: return true
    case .streaming: return answer.renderedText.isEmpty
    default: return false
    }
  }

  private var hasAnswerText: Bool { !trimProtocolText(answer.renderedText).isEmpty }

  /// Returns whether views were added or removed.
  @discardableResult
  func apply(_ newState: TurnState, text: String? = nil) -> Bool {
    let wasPending = isPending
    state = newState
    var changed = false
    if let text = text {
      let final: Bool
      switch newState {
      case .waiting, .thinking, .streaming: final = false
      default: final = true
      }
      changed = answer.render(text, final: final)
    } else if case .failed = newState {
      answer.render(answer.renderedText, final: true)
    }
    if case .failed(let message) = newState { failure.message.stringValue = message }
    pending.thinking = newState == .thinking
    if isPending && !wasPending { pending.since = Date() }
    updateVisibility()
    return changed
  }

  func restart() {
    answer.clear()
    failure.message.stringValue = ""
    state = .waiting
    pending.thinking = false
    pending.since = Date()
    updateVisibility()
  }

  private func updateVisibility() {
    pending.isHidden = !isPending
    if case .failed = state { failure.isHidden = false } else { failure.isHidden = true }
    failure.retryButton.isHidden = !canRetry
    let settled = state == .done || state == .stopped || { if case .failed = state { return true } else { return false } }()
    copyButton.isHidden = !(settled && hasAnswerText)
    stoppedLabel.isHidden = state != .stopped
    retryButton.isHidden = !(state == .stopped && canRetry)
    needsLayout = true
  }

  func height(for width: CGFloat) -> CGFloat {
    var y: CGFloat = 0
    func gap(_ value: CGFloat) { if y > 0 { y += value } }
    if !answer.segmentViews.isEmpty {
      gap(14)
      let height = answer.height(for: width)
      answer.frame = NSRect(x: 0, y: y, width: width, height: height)
      y += height
    } else {
      answer.frame = NSRect(x: 0, y: y, width: width, height: 0)
    }
    // Actions belong to the answer text, so they sit directly beneath it.
    let rowViews: [NSView] = [copyButton, stoppedLabel, retryButton].filter { !$0.isHidden }
    if !rowViews.isEmpty {
      gap(6)
      var x: CGFloat = -5
      for view in rowViews {
        if let button = view as? ActionButton {
          let size = button.buttonSize
          button.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
          x += size.width + 4
        } else if let label = view as? NSTextField {
          label.sizeToFit()
          label.frame.origin = NSPoint(x: x + 4, y: y + (24 - label.frame.height) / 2)
          x = label.frame.maxX + 6
        }
      }
      y += 24
    }
    if !pending.isHidden {
      gap(14)
      pending.frame = NSRect(x: 0, y: y, width: width, height: 20)
      pending.layoutContent()
      y += 20
    }
    if !failure.isHidden {
      gap(10)
      let height = failure.height(for: width)
      failure.frame = NSRect(x: 0, y: y, width: width, height: height)
      y += height
    }
    return y
  }

  func clear() {
    answer.clear()
    failure.message.stringValue = ""
    for button in [copyButton, retryButton, failure.retryButton] {
      button.cancelFeedback()
      button.target = nil
      button.action = nil
    }
  }
}

/// The scrolling thread: the screenshot, then its answer, progress and failure. Streaming text is
/// followed until the answer's start reaches the top, which then stays in view as the rest arrives
/// below; scrolling to the bottom follows again. Reading elsewhere keeps its position.
final class ConversationView: NSView {
  let scrollView = NSScrollView(frame: .zero)
  private let document = ThreadDocumentView(frame: .zero)
  private(set) lazy var thumbnail = ThumbnailButton(target: self, action: #selector(previewPressed))
  private(set) var turn: TurnView?
  /// A hairline under the title bar, shown only while the thread is scrolled beneath it.
  private let topSeparator = NSBox()
  private var pendingTimer: Timer?
  private var layingOut = false
  var onPreview: (() -> Void)?
  var onRetry: (() -> Void)?
  /// Passive panels cannot receive shortcuts, so their Copy buttons must not advertise them.
  var showsCopyShortcuts = true { didSet { updateCopyShortcuts() } }
  var canRetry = false { didSet { turn?.canRetry = canRetry; relayout() } }
  var actionsEnabled = true {
    didSet {
      turn?.actionsEnabled = actionsEnabled
      thumbnail.isEnabled = actionsEnabled && thumbnail.screenshot != nil
    }
  }
  /// The thread's height when nothing is scrolled out of view, as last laid out.
  private(set) var contentHeight: CGFloat = 0
  static let horizontalPadding: CGFloat = 18
  /// Above the first item and below the last, and above the answer when it's held at the top.
  static let verticalPadding: CGFloat = 16
  static let followThreshold: CGFloat = 24

  /// The answer while it offers Copy, which Copy Answer (⇧⌘C) copies.
  var answerToCopy: TurnView? { turn.flatMap { $0.copyButton.isHidden ? nil : $0 } }

  /// The answer's last code block that offers Copy, which Copy Code (⌥⌘C) copies.
  var codeToCopy: AnswerSegmentView? { turn?.answer.segmentViews.last { $0.copyButton?.isHidden == false } }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    scrollView.frame = bounds
    scrollView.autoresizingMask = [.width, .height]
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.documentView = document
    scrollView.setAccessibilityLabel("Conversation")
    addSubview(scrollView)
    topSeparator.boxType = .separator
    topSeparator.autoresizingMask = [.width, .maxYMargin]
    topSeparator.isHidden = true
    addSubview(topSeparator)
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
      name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    thumbnail.isHidden = true
    document.addSubview(thumbnail)
  }

  override var isFlipped: Bool { true }

  @objc private func scrolled() {
    topSeparator.isHidden = scrollView.contentView.bounds.minY <= 1
  }

  required init?(coder: NSCoder) { nil }

  /// Holds the thumbnail's place at the crop's size, in pixels, until `setScreenshot` fills it.
  func reserveScreenshot(size: CGSize) {
    thumbnail.reservedSize = size
    thumbnail.isHidden = false
    thumbnail.isEnabled = false
    relayout(followBottom: false)
  }

  func setScreenshot(_ image: NSImage?) {
    thumbnail.screenshot = image
    if image == nil { thumbnail.reservedSize = nil }
    thumbnail.isHidden = image == nil
    thumbnail.isEnabled = actionsEnabled && image != nil
    relayout(followBottom: false)
  }

  /// Starts the answer, waiting for its first text.
  func beginTurn() {
    guard turn == nil else { return }
    let turn = TurnView(target: self, copy: #selector(copyPressed(_:)), retry: #selector(retryPressed))
    turn.canRetry = canRetry
    turn.actionsEnabled = actionsEnabled
    self.turn = turn
    document.addSubview(turn)
    updatePendingTimer()
    relayout(scrollToBottom: true)
    window?.recalculateKeyViewLoop()
  }

  /// Retry starts the answer again.
  func restartTurn() {
    turn?.restart()
    updatePendingTimer()
    relayout(scrollToBottom: true)
  }

  func setThinking() {
    guard let turn = turn, turn.isPending else { return }
    turn.apply(.thinking)
    turn.pending.update()
  }

  func updateAnswer(_ text: String, status: AnswerStatus) {
    guard let turn = turn else { return }
    let state: TurnState = status == .streaming ? .streaming : (status == .done ? .done : .stopped)
    let changed = turn.apply(state, text: text)
    updatePendingTimer()
    relayout()
    if changed { window?.recalculateKeyViewLoop() }
  }

  func fail(_ message: String, clearAnswer: Bool) {
    guard let turn = turn else { return }
    let changed = turn.apply(.failed(message), text: clearAnswer ? "" : turn.answer.renderedText)
    updatePendingTimer()
    relayout()
    if changed { window?.recalculateKeyViewLoop() }
    NSAccessibility.post(element: turn.failure.message, notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }

  /// Following pauses only while the reader is selecting text in the thread; text views keep an
  /// inactive selection after focus moves on, which must not stop following.
  var hasSelection: Bool {
    guard let text = window?.firstResponder as? NSTextView, text.isDescendant(of: document) else { return false }
    return text.selectedRange().length > 0
  }

  private var isAtBottom: Bool {
    document.frame.height - scrollView.contentView.bounds.maxY <= Self.followThreshold
  }

  override func layout() {
    super.layout()
    topSeparator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    relayout()
  }

  private func relayout(followBottom: Bool? = nil, scrollToBottom: Bool = false) {
    guard !layingOut else { return }
    layingOut = true
    defer { layingOut = false }
    let position = scrollView.contentView.bounds.origin
    let follow = scrollToBottom || (followBottom ?? (isAtBottom && !hasSelection))
    // Showing or hiding the scroller changes the width the thread wraps to, and the scroll view can
    // do either once the thread's new height is in place. So it lays out again at the new width
    // until the width holds, a pass or two at most.
    var width: CGFloat = 0
    for _ in 0..<3 {
      scrollView.tile()
      let available = max(1, scrollView.contentSize.width)
      guard available != width else { break }
      width = available
      let inner = max(1, width - Self.horizontalPadding * 2)
      var y = Self.verticalPadding
      if !thumbnail.isHidden {
        let size = thumbnail.size(for: inner)
        thumbnail.frame = NSRect(x: width - Self.horizontalPadding - size.width, y: y, width: size.width,
          height: size.height)
        y += size.height + 18
      }
      if let turn = turn {
        let height = turn.height(for: inner)
        turn.frame = NSRect(x: Self.horizontalPadding, y: y, width: inner, height: height)
        y += height
      }
      y += Self.verticalPadding
      contentHeight = y
      document.frame = NSRect(x: 0, y: 0, width: width, height: max(scrollView.contentSize.height, y))
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    let maximum = max(0, document.frame.height - scrollView.contentSize.height)
    // Following stops where the answer starts at the top, so its first lines stay in view while the
    // rest streams in below. A reader who scrolls on past that is followed to the bottom.
    let start = turn.map { max(0, $0.frame.minY - Self.verticalPadding) } ?? maximum
    let target: CGFloat
    if scrollToBottom {
      target = min(maximum, start)
    } else if follow {
      target = position.y > start + 1 ? maximum : min(maximum, start)
    } else {
      target = min(position.y, maximum)
    }
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    updateCopyShortcuts()
  }

  /// Names the copy shortcuts in the tooltips of the Copy buttons they press.
  private func updateCopyShortcuts() {
    guard let turn = turn else { return }
    let code = codeToCopy
    turn.copyShortcut = showsCopyShortcuts && turn === answerToCopy ? "⇧⌘C" : nil
    for block in turn.answer.segmentViews where block.segment.isCode {
      block.copyShortcut = showsCopyShortcuts && block === code ? "⌥⌘C" : nil
    }
  }

  /// Copies the answer, as its Copy button does. Returns false when it doesn't offer Copy.
  @discardableResult
  func copyLatestAnswer() -> Bool {
    guard actionsEnabled, let button = answerToCopy?.copyButton, button.isEnabled else { return false }
    button.performClick(nil)
    return true
  }

  /// Copies the last code block, as its Copy button does. Returns false when none offers Copy.
  @discardableResult
  func copyLatestCode() -> Bool {
    guard actionsEnabled, let button = codeToCopy?.copyButton, button.isEnabled else { return false }
    button.performClick(nil)
    return true
  }

  private func updatePendingTimer() {
    let pending = turn?.isPending == true
    if pending && pendingTimer == nil {
      let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
        guard let turn = self?.turn, turn.isPending else { return }
        turn.pending.update()
      }
      RunLoop.main.add(timer, forMode: .common)
      pendingTimer = timer
    } else if !pending {
      pendingTimer?.invalidate()
      pendingTimer = nil
    }
  }

  @objc private func previewPressed() { onPreview?() }

  @objc private func retryPressed() { onRetry?() }

  /// Copies exactly the answer text that was streamed, including code fences.
  @objc private func copyPressed(_ sender: ActionButton) {
    guard actionsEnabled, let turn = turn, turn.copyButton === sender else { return }
    let text = turn.answer.renderedText
    guard !trimProtocolText(text).isEmpty else { return }
    Clipboard.copy(text)
    sender.showFeedback(symbol: "checkmark", title: "", label: "Copied", color: Theme.accent)
  }

  func clear() {
    NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
    pendingTimer?.invalidate()
    pendingTimer = nil
    if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) {
      window?.makeFirstResponder(nil)
    }
    turn?.clear()
    turn?.removeFromSuperview()
    turn = nil
    thumbnail.screenshot = nil
    thumbnail.reservedSize = nil
    thumbnail.isHidden = true
    thumbnail.target = nil
    thumbnail.action = nil
    onPreview = nil
    onRetry = nil
    document.frame = NSRect(origin: .zero, size: scrollView.contentSize)
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }
}
