import AppKit

private final class ThreadDocumentView: NSView {
  override var isFlipped: Bool { true }
}

/// The accepted crop at the top of the thread. Pressing it opens the larger preview.
final class ThumbnailButton: CompanionButton {
  var screenshot: NSImage? { didSet { needsDisplay = true } }

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
    guard let image = screenshot, image.size.width > 0, image.size.height > 0 else { return .zero }
    let scale = min(min(width * 0.62, 300) / image.size.width, 150 / image.size.height, 1)
    return NSSize(width: max(24, (image.size.width * scale).rounded()), height: max(24, (image.size.height * scale).rounded()))
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
    Theme.codeBackground.setFill()
    bounds.fill()
    if let image = screenshot {
      image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: isHighlighted ? 0.8 : 1,
        respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
    NSGraphicsContext.restoreGraphicsState()
    NSColor.separatorColor.setStroke()
    shape.lineWidth = 1
    shape.stroke()
  }

  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
  }

  override var focusRingMaskBounds: NSRect { bounds }
}

/// A follow-up question, right-aligned.
final class QuestionBubbleView: NSView {
  let textView = ReadOnlyTextView(frame: .zero)
  private static let padding = NSSize(width: 12, height: 8)
  override var isFlipped: Bool { true }

  init(text: String) {
    super.init(frame: .zero)
    textView.configureReadOnly(font: AnswerStyle.proseFont)
    textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
      .font: AnswerStyle.proseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: AnswerStyle.proseParagraph]))
    textView.setAccessibilityLabel("Your follow-up")
    addSubview(textView)
  }

  required init?(coder: NSCoder) { nil }

  /// Lays out the bubble for the widest allowed size and returns its frame size.
  func size(maximumWidth: CGFloat) -> NSSize {
    let available = max(40, maximumWidth - Self.padding.width * 2)
    let natural = textView.textStorage?.boundingRect(with: NSSize(width: available, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]).width ?? available
    let width = min(available, ceil(natural) + 1)
    let height = max(18, textView.measuredHeight(for: width))
    textView.frame = NSRect(x: Self.padding.width, y: Self.padding.height, width: width, height: height)
    return NSSize(width: width + Self.padding.width * 2, height: height + Self.padding.height * 2)
  }

  override func draw(_ dirtyRect: NSRect) {
    Theme.bubble.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
  }

  func clear() {
    textView.string = ""
    textView.undoManager?.removeAllActions()
  }
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

/// A failed request, with Retry on the newest one.
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

/// A conversation-level notice, such as older turns removed to stay within the limit.
final class NoticeView: NSView {
  let label = NSTextField(wrappingLabelWithString: "")
  override var isFlipped: Bool { true }

  init(message: String) {
    super.init(frame: .zero)
    label.stringValue = message
    label.font = .systemFont(ofSize: 11.5)
    label.textColor = .secondaryLabelColor
    label.alignment = .center
    addSubview(label)
  }

  required init?(coder: NSCoder) { nil }

  func height(for width: CGFloat) -> CGFloat {
    let textWidth = max(40, width - 48)
    let height = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth,
      height: .greatestFiniteMagnitude)).height ?? 16)
    label.frame = NSRect(x: 24, y: 0, width: textWidth, height: height)
    return height
  }
}

enum AnswerStatus: String { case streaming, done, stopped }

enum TurnState: Equatable { case waiting, thinking, streaming, done, stopped, failed(String) }

/// One exchange: an optional follow-up question, then its answer, progress, failure and actions.
final class TurnView: NSView {
  let question: String?
  private(set) var state: TurnState = .waiting
  private let bubble: QuestionBubbleView?
  let answer = AnswerView()
  let pending = PendingView()
  let failure: FailureView
  let copyButton: ActionButton
  let retryButton: ActionButton
  private let stoppedLabel = NSTextField(labelWithString: "Stopped")
  /// A notice about this request, such as older turns removed to make room for it.
  private(set) var noticeView: NoticeView?
  var isLatest = true { didSet { updateVisibility() } }
  var canRetry = false { didSet { updateVisibility() } }
  var actionsEnabled = true {
    didSet {
      copyButton.isEnabled = actionsEnabled
      answer.copyEnabled = actionsEnabled
    }
  }
  override var isFlipped: Bool { true }

  init(question: String?, target: AnyObject?, copy: Selector, retry: Selector) {
    self.question = question
    bubble = question.map { QuestionBubbleView(text: $0) }
    failure = FailureView(target: target, retry: retry)
    copyButton = ActionButton(symbol: "doc.on.doc", label: "Copy answer", target: target, action: copy)
    retryButton = ActionButton(symbol: "arrow.clockwise", title: "Retry", label: "Retry", target: target, action: retry)
    super.init(frame: .zero)
    stoppedLabel.font = .systemFont(ofSize: 12)
    stoppedLabel.textColor = .secondaryLabelColor
    if let bubble = bubble { addSubview(bubble) }
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

  func setNotice(_ message: String) {
    if let notice = noticeView { notice.label.stringValue = message; return }
    let notice = NoticeView(message: message)
    addSubview(notice)
    noticeView = notice
  }

  /// Whether the session keeps this exchange in its conversation, mirroring its settle rules:
  /// a first answer that failed without text is cleared (the next request becomes the first),
  /// a stopped first answer is kept, and a follow-up stopped before any text is dropped.
  func isHeld(asFirst first: Bool) -> Bool {
    switch state {
    case .done: return true
    case .stopped: return first || hasAnswerText
    case .failed: return !first || hasAnswerText
    case .waiting, .thinking, .streaming: return false
    }
  }

  private func updateVisibility() {
    pending.isHidden = !isPending
    if case .failed = state { failure.isHidden = false } else { failure.isHidden = true }
    failure.retryButton.isHidden = !(isLatest && canRetry)
    let settled = state == .done || state == .stopped || { if case .failed = state { return true } else { return false } }()
    copyButton.isHidden = !(settled && hasAnswerText)
    stoppedLabel.isHidden = state != .stopped
    retryButton.isHidden = !(state == .stopped && isLatest && canRetry)
    needsLayout = true
  }

  func height(for width: CGFloat) -> CGFloat {
    var y: CGFloat = 0
    func gap(_ value: CGFloat) { if y > 0 { y += value } }
    if let notice = noticeView {
      let height = notice.height(for: width)
      notice.frame = NSRect(x: 0, y: y, width: width, height: height)
      y += height
    }
    if let bubble = bubble {
      gap(16)
      let size = bubble.size(maximumWidth: (width * 0.82).rounded())
      bubble.frame = NSRect(x: width - size.width, y: y, width: size.width, height: size.height)
      y += size.height
    }
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
    bubble?.clear()
    answer.clear()
    noticeView?.label.stringValue = ""
    failure.message.stringValue = ""
    for button in [copyButton, retryButton, failure.retryButton] {
      button.cancelFeedback()
      button.target = nil
      button.action = nil
    }
  }
}

/// The scrolling thread: screenshot, answers, follow-ups, progress and failures. Reading above the
/// bottom keeps its position while text streams in; asking a question scrolls it into view.
final class ConversationView: NSView {
  let scrollView = NSScrollView(frame: .zero)
  private let document = ThreadDocumentView(frame: .zero)
  private(set) lazy var thumbnail = ThumbnailButton(target: self, action: #selector(previewPressed))
  private(set) var turns: [TurnView] = []
  /// A hairline under the title bar, shown only while the thread is scrolled beneath it.
  private let topSeparator = NSBox()
  private var pendingTimer: Timer?
  private var layingOut = false
  var onPreview: (() -> Void)?
  var onRetry: (() -> Void)?
  /// Where keyboard focus goes when the view holding it is removed, usually the composer.
  var focusFallback: (() -> NSView?)?
  var canRetry = false { didSet { turns.forEach { $0.canRetry = canRetry }; relayout() } }
  var actionsEnabled = true {
    didSet {
      turns.forEach { $0.actionsEnabled = actionsEnabled }
      thumbnail.isEnabled = actionsEnabled
    }
  }
  static let horizontalPadding: CGFloat = 18
  static let followThreshold: CGFloat = 24

  var latestTurn: TurnView? { turns.last }

  /// The earlier exchanges the session still holds, oldest first. The newest exchange is the
  /// request in progress, so the session prunes only these.
  var heldTurns: [TurnView] {
    var held: [TurnView] = []
    for turn in turns.dropLast() where turn.isHeld(asFirst: held.isEmpty) { held.append(turn) }
    return held
  }

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

  func setScreenshot(_ image: NSImage?) {
    thumbnail.screenshot = image
    thumbnail.isHidden = image == nil
    relayout(followBottom: false)
  }

  /// Starts an exchange: the first answer (no question) or a follow-up.
  func beginTurn(question: String?) {
    turns.forEach { $0.isLatest = false }
    let turn = TurnView(question: question, target: self, copy: #selector(copyPressed(_:)), retry: #selector(retryPressed))
    turn.canRetry = canRetry
    turn.actionsEnabled = actionsEnabled
    turns.append(turn)
    document.addSubview(turn)
    updatePendingTimer()
    relayout(scrollToBottom: true)
    window?.recalculateKeyViewLoop()
  }

  func restartLatestTurn() {
    preservingFocus { latestTurn?.restart() }
    updatePendingTimer()
    relayout(scrollToBottom: true)
  }

  func setThinking() {
    guard let turn = latestTurn, turn.isPending else { return }
    turn.apply(.thinking)
    turn.pending.update()
  }

  func updateAnswer(_ text: String, status: AnswerStatus) {
    guard let turn = latestTurn else { return }
    let state: TurnState = status == .streaming ? .streaming : (status == .done ? .done : .stopped)
    var changed = false
    preservingFocus { changed = turn.apply(state, text: text) }
    updatePendingTimer()
    relayout()
    if changed { window?.recalculateKeyViewLoop() }
  }

  func fail(_ message: String, clearAnswer: Bool) {
    guard let turn = latestTurn else { return }
    var changed = false
    preservingFocus {
      changed = turn.apply(.failed(message), text: clearAnswer ? "" : turn.answer.renderedText)
    }
    updatePendingTimer()
    relayout()
    if changed { window?.recalculateKeyViewLoop() }
    NSAccessibility.post(element: turn.failure.message, notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }

  /// A notice concerns the newest request, so it appears above that exchange. When the session
  /// removed older turns to make room, the same turns leave this thread: it keeps the first
  /// answer and drops the oldest follow-ups after it.
  func addNotice(_ message: String, removedTurns: Int) {
    guard let latest = latestTurn else { return }
    if removedTurns > 0 {
      let removed = Array(heldTurns.dropFirst().prefix(removedTurns))
      preservingFocus {
        for turn in removed {
          turn.clear()
          turn.removeFromSuperview()
        }
      }
      turns.removeAll { turn in removed.contains { $0 === turn } }
      window?.recalculateKeyViewLoop()
    }
    latest.setNotice(message)
    relayout()
  }

  /// A follow-up stopped before any text is not part of the conversation; drop it before the next.
  func removeAbandonedTurn() {
    guard let turn = latestTurn, turn.question != nil, turn.state == .stopped else { return }
    var held: [TurnView] = []
    for earlier in turns.dropLast() where earlier.isHeld(asFirst: held.isEmpty) { held.append(earlier) }
    guard !turn.isHeld(asFirst: held.isEmpty) else { return }
    preservingFocus {
      turn.clear()
      turn.removeFromSuperview()
    }
    turns.removeLast()
    latestTurn?.isLatest = true
  }

  /// Following the bottom pauses only while the reader is selecting text in the thread; text
  /// views keep an inactive selection after focus moves on, which must not stop following.
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
    scrollView.tile()
    let width = max(1, scrollView.contentSize.width)
    let inner = max(1, width - Self.horizontalPadding * 2)
    var y: CGFloat = 16
    if !thumbnail.isHidden {
      let size = thumbnail.size(for: inner)
      thumbnail.frame = NSRect(x: width - Self.horizontalPadding - size.width, y: y, width: size.width, height: size.height)
      y += size.height + 18
    }
    for (index, turn) in turns.enumerated() {
      let height = turn.height(for: inner)
      turn.frame = NSRect(x: Self.horizontalPadding, y: y, width: inner, height: height)
      y += height + (index == turns.count - 1 ? 0 : 22)
    }
    y += 16
    document.frame = NSRect(x: 0, y: 0, width: width, height: max(scrollView.contentSize.height, y))
    let maximum = max(0, document.frame.height - scrollView.contentSize.height)
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: follow ? maximum : min(position.y, maximum)))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  /// Removing a view that holds keyboard focus must not leave the panel without a responder.
  private func preservingFocus(_ change: () -> Void) {
    change()
    if let window = window, window.firstResponder === window || window.firstResponder == nil,
      let fallback = focusFallback?() {
      window.makeFirstResponder(fallback)
    }
  }

  private func updatePendingTimer() {
    let pending = turns.contains { $0.isPending }
    if pending && pendingTimer == nil {
      let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
        self?.turns.filter { $0.isPending }.forEach { $0.pending.update() }
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
    guard actionsEnabled, let turn = turns.first(where: { $0.copyButton === sender }) else { return }
    let text = turn.answer.renderedText
    guard !trimProtocolText(text).isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    sender.showFeedback(symbol: "checkmark", title: "", label: "Copied", color: .systemGreen)
  }

  func clear() {
    NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
    pendingTimer?.invalidate()
    pendingTimer = nil
    if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) {
      window?.makeFirstResponder(nil)
    }
    for turn in turns {
      turn.clear()
      turn.removeFromSuperview()
    }
    turns.removeAll()
    thumbnail.screenshot = nil
    thumbnail.isHidden = true
    thumbnail.target = nil
    thumbnail.action = nil
    onPreview = nil
    onRetry = nil
    focusFallback = nil
    document.frame = NSRect(origin: .zero, size: scrollView.contentSize)
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }
}
