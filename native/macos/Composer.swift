import AppKit

/// Plain-text follow-up input with a placeholder; reports focus so its container can draw a ring.
final class ComposerTextView: NSTextView {
  var placeholder = "Ask a follow-up…" { didSet { needsDisplay = true } }
  var onFocusChange: (() -> Void)?

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    onFocusChange?()
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    onFocusChange?()
    return resigned
  }

  override func didChangeText() {
    super.didChangeText()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !hasMarkedText() else { return }
    let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
    NSAttributedString(string: placeholder, attributes: [
      .font: font ?? AnswerStyle.proseFont, .foregroundColor: NSColor.placeholderTextColor]).draw(at: origin)
  }
}

/// The follow-up composer: a field that grows to six lines, and a Send button that becomes Stop
/// while an answer is in progress. Return asks; Shift-Return or Option-Return adds a line.
final class ComposerView: NSView, NSTextViewDelegate {
  let textView = ComposerTextView(frame: .zero)
  private let scroll = NSScrollView(frame: .zero)
  private(set) lazy var sendButton = SendButton(target: self, action: #selector(sendPressed))
  let hintLabel = NSTextField(labelWithString: "")
  var onSubmit: ((String) -> Void)?
  var onStop: (() -> Void)?
  var onChange: (() -> Void)?
  var maximumCharacters = maxFollowupCharacters { didSet { if maximumCharacters != oldValue { updateHint() } } }
  /// The session accepts a follow-up now.
  var canSubmit = false { didSet { refreshButton() } }
  /// A request is in progress: the button stops it instead of sending.
  var isRunning = false { didSet { refreshButton() } }
  var canStop = false { didSet { refreshButton() } }
  private var rejectedInput = false
  override var isFlipped: Bool { true }

  static let font = NSFont.systemFont(ofSize: 14)
  static let minimumFieldHeight: CGFloat = 40
  static let maximumLines: CGFloat = 6
  private static let buttonSize: CGFloat = 28
  private static let textInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 44)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.drawsBackground = false
    textView.font = Self.font
    textView.textColor = .labelColor
    textView.insertionPointColor = .labelColor
    textView.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor]
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.delegate = self
    textView.setAccessibilityLabel("Follow-up question")
    textView.onFocusChange = { [weak self] in self?.needsDisplay = true }
    scroll.documentView = textView
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.verticalScrollElasticity = .none
    addSubview(scroll)
    addSubview(sendButton)
    hintLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    hintLabel.textColor = .secondaryLabelColor
    hintLabel.setAccessibilityLabel("Follow-up length")
    hintLabel.isHidden = true
    addSubview(hintLabel)
    refreshButton()
  }

  required init?(coder: NSCoder) { nil }

  var draft: String { textView.string }

  func setDraft(_ text: String) {
    textView.string = text
    rejectedInput = false
    textChanged()
    layoutSubtreeIfNeeded()
    textView.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0))
  }

  /// Commits an input method's unfinished text so it is neither sent nor left composing.
  private func commitMarkedText() {
    guard textView.hasMarkedText() else { return }
    textView.unmarkText()
    textView.inputContext?.discardMarkedText()
  }

  func clearDraft() {
    commitMarkedText()
    textView.string = ""
    textView.undoManager?.removeAllActions()
    rejectedInput = false
    textChanged()
  }

  private var lineHeight: CGFloat {
    ceil(textView.layoutManager?.defaultLineHeight(for: Self.font) ?? 17)
  }

  private var textHeight: CGFloat {
    guard let container = textView.textContainer, let manager = textView.layoutManager else { return lineHeight }
    manager.ensureLayout(for: container)
    let used = max(manager.usedRect(for: container).height, manager.extraLineFragmentRect.maxY)
    return min(max(lineHeight, ceil(used)), lineHeight * Self.maximumLines)
  }

  private var fieldHeight: CGFloat {
    max(Self.minimumFieldHeight, textHeight + Self.textInsets.top + Self.textInsets.bottom)
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: fieldHeight + (hintLabel.isHidden ? 0 : 20))
  }

  private var laidOutHeight: CGFloat = 0

  override func layout() {
    super.layout()
    // Wrap at the new width before measuring, so narrowing the window grows the field.
    let textWidth = max(1, bounds.width - Self.textInsets.left - Self.textInsets.right)
    if textView.frame.width != textWidth { textView.frame.size.width = textWidth }
    let height = intrinsicContentSize.height
    if height != laidOutHeight {
      laidOutHeight = height
      invalidateIntrinsicContentSize()
    }
    let field = fieldRect
    let textHeight = self.textHeight
    scroll.frame = NSRect(x: Self.textInsets.left, y: field.midY - textHeight / 2,
      width: max(1, field.width - Self.textInsets.left - Self.textInsets.right), height: textHeight)
    textView.minSize = NSSize(width: 0, height: textHeight)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.frame.size.width = scroll.contentSize.width
    let size = Self.buttonSize
    let inset = (Self.minimumFieldHeight - size) / 2
    sendButton.frame = NSRect(x: field.maxX - inset - size, y: field.maxY - inset - size, width: size, height: size)
    hintLabel.sizeToFit()
    hintLabel.frame = NSRect(x: 6, y: field.maxY + 4, width: max(1, bounds.width - 12), height: hintLabel.frame.height)
  }

  private var fieldRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: fieldHeight) }

  override func draw(_ dirtyRect: NSRect) {
    let field = fieldRect.insetBy(dx: 1, dy: 1)
    let radius = min(20, field.height / 2)
    let shape = NSBezierPath(roundedRect: field, xRadius: radius, yRadius: radius)
    NSColor.textBackgroundColor.setFill()
    shape.fill()
    let focused = window?.firstResponder === textView && (window?.isKeyWindow ?? false)
    if focused {
      Theme.accent.withAlphaComponent(0.25).setStroke()
      let ring = NSBezierPath(roundedRect: field.insetBy(dx: -0.5, dy: -0.5), xRadius: radius, yRadius: radius)
      ring.lineWidth = 3
      ring.stroke()
    }
    (focused ? Theme.accent : NSColor.separatorColor).setStroke()
    shape.lineWidth = 1
    shape.stroke()
  }

  private static let keyNotifications = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // Remove only these observations: the text view registers this view, its delegate, for its own.
    for name in Self.keyNotifications { NotificationCenter.default.removeObserver(self, name: name, object: nil) }
    guard let window = window else { return }
    for name in Self.keyNotifications {
      NotificationCenter.default.addObserver(self, selector: #selector(keyStatusChanged), name: name, object: window)
    }
  }

  @objc private func keyStatusChanged() { needsDisplay = true }

  override func mouseDown(with event: NSEvent) {
    // A click anywhere in the field focuses the text, as in a standard text field.
    window?.makeFirstResponder(textView)
  }

  private var hasSendableDraft: Bool {
    let value = trimProtocolText(draft)
    return !value.isEmpty && inputFitsLimits(value, maximum: maximumCharacters)
  }

  private func refreshButton() {
    sendButton.mode = isRunning ? .stop : .send
    sendButton.isEnabled = isRunning ? canStop : (canSubmit && hasSendableDraft)
  }

  private func updateHint() {
    let count = draft.unicodeScalars.count
    let near = count >= Int(Double(maximumCharacters) * 0.8)
    if rejectedInput {
      hintLabel.stringValue = "Follow-up is too long. The limit is \(maximumCharacters.formatted()) characters."
      hintLabel.textColor = .systemRed
    } else {
      hintLabel.stringValue = "\(count.formatted()) / \(maximumCharacters.formatted())"
      hintLabel.textColor = count > maximumCharacters ? .systemRed : .secondaryLabelColor
    }
    let hidden = !(rejectedInput || near)
    if hintLabel.isHidden != hidden {
      hintLabel.isHidden = hidden
      invalidateIntrinsicContentSize()
    }
    needsLayout = true
  }

  private func textChanged() {
    updateHint()
    refreshButton()
    invalidateIntrinsicContentSize()
    needsLayout = true
    needsDisplay = true
    onChange?()
  }

  func textDidChange(_ notification: Notification) {
    rejectedInput = false
    textChanged()
  }

  func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
    let current = textView.string as NSString
    guard affectedCharRange.location != NSNotFound, affectedCharRange.location <= current.length,
      affectedCharRange.length <= current.length - affectedCharRange.location else { return false }
    let proposed = current.replacingCharacters(in: affectedCharRange, with: replacementString ?? "")
    let fits = inputFitsLimits(proposed, maximum: maximumCharacters)
    if !fits {
      rejectedInput = true
      updateHint()
      NSAccessibility.post(element: hintLabel, notification: .announcementRequested,
        userInfo: [.announcement: hintLabel.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    return fits
  }

  func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      let modifiers = NSApp.currentEvent?.modifierFlags ?? []
      if modifiers.contains(.shift) || modifiers.contains(.option) {
        textView.insertNewlineIgnoringFieldEditor(nil)
      } else {
        submit()
      }
      return true
    case #selector(NSResponder.insertTab(_:)):
      window?.selectNextKeyView(textView)
      return true
    case #selector(NSResponder.insertBacktab(_:)):
      window?.selectPreviousKeyView(textView)
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      (window as? CompanionPanel)?.closeAfterKeyRelease(NSApp.currentEvent)
      return true
    default:
      return false
    }
  }

  /// Asks the draft when the session allows it. The host clears the draft once it is sent.
  func submit() {
    guard !isRunning, canSubmit else { return }
    commitMarkedText()
    guard hasSendableDraft else { return }
    onSubmit?(trimProtocolText(draft))
  }

  @objc private func sendPressed() {
    if isRunning { if canStop { onStop?() } } else { submit() }
    // The button changes role and may disable itself; keep typing in the field.
    window?.makeFirstResponder(textView)
  }

  func clear() {
    for name in Self.keyNotifications { NotificationCenter.default.removeObserver(self, name: name, object: nil) }
    commitMarkedText()
    textView.string = ""
    textView.undoManager?.removeAllActions()
    textView.delegate = nil
    textView.onFocusChange = nil
    onSubmit = nil
    onStop = nil
    onChange = nil
    sendButton.target = nil
    sendButton.action = nil
  }
}
