import AppKit

/// SnapScreen's colours.
enum Theme {
  static let accent = NSColor(srgbRed: 108 / 255, green: 92 / 255, blue: 231 / 255, alpha: 1)
  static let pointerSelection = NSColor(srgbRed: 59 / 255, green: 130 / 255, blue: 246 / 255, alpha: 1)
  static let keyboardSelection = NSColor(srgbRed: 167 / 255, green: 139 / 255, blue: 250 / 255, alpha: 1)
  static let keyboardRing = NSColor(srgbRed: 139 / 255, green: 92 / 255, blue: 246 / 255, alpha: 0.75)
  static let backdrop = NSColor(srgbRed: 17 / 255, green: 17 / 255, blue: 17 / 255, alpha: 1)
  static let bubble = dynamic(light: NSColor(srgbRed: 0.937, green: 0.937, blue: 0.945, alpha: 1),
    dark: NSColor(srgbRed: 0.204, green: 0.204, blue: 0.216, alpha: 1))
  static let codeBackground = dynamic(light: NSColor(srgbRed: 0.965, green: 0.969, blue: 0.976, alpha: 1),
    dark: NSColor(srgbRed: 0.102, green: 0.102, blue: 0.11, alpha: 1))
  static let hover = dynamic(light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.white.withAlphaComponent(0.09))
  static let idleControl = dynamic(light: NSColor.black.withAlphaComponent(0.09), dark: NSColor.white.withAlphaComponent(0.12))

  static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
  }

  static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium, color: NSColor? = nil) -> NSImage? {
    var configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    if let color = color { configuration = configuration.applying(.init(paletteColors: [color])) }
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
  }
}

/// Panels never activate SnapScreen, so the app beneath stays active. A key released after its
/// panel closes would therefore reach that app. Escape and Command-W close on release.
final class CompanionPanel: NSPanel {
  private var closingKey: UInt16?
  private var closeFallback: Timer?
  private var releaseMonitor: Any?
  /// Replaces `performClose`, which never reaches the delegate of a window without a close
  /// button, such as the borderless selection overlay.
  var closeAction: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// Closes now for pointer actions; for a key press, closes when that key is released.
  func closeAfterKeyRelease(_ event: NSEvent?) {
    guard closingKey == nil else { return }
    guard let event = event, event.type == .keyDown else { closeNow(nil); return }
    closingKey = event.keyCode
    // NSApplication never dispatches a key-up while Command is held, but local monitors see it.
    releaseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
      guard let self = self, let key = self.closingKey else { return event }
      if event.keyCode == key {
        if event.type == .keyUp { self.finishKeyClose() } else { self.armCloseFallback() }
      }
      // Nothing typed while the key is held goes anywhere.
      return nil
    }
    armCloseFallback()
  }

  /// Only for a release that never arrives; each auto-repeat of the held key restarts it.
  private func armCloseFallback() {
    closeFallback?.invalidate()
    let timer = Timer(timeInterval: 4, repeats: false) { [weak self] _ in self?.finishKeyClose() }
    RunLoop.main.add(timer, forMode: .common)
    closeFallback = timer
  }

  private func endKeyClose() {
    closingKey = nil
    closeFallback?.invalidate()
    closeFallback = nil
    if let monitor = releaseMonitor { NSEvent.removeMonitor(monitor) }
    releaseMonitor = nil
  }

  private func finishKeyClose() {
    guard closingKey != nil else { return }
    endKeyClose()
    closeNow(nil)
  }

  private func closeNow(_ sender: Any?) {
    if let closeAction = closeAction { closeAction() } else { super.performClose(sender) }
  }

  override func sendEvent(_ event: NSEvent) {
    if closingKey != nil, event.type == .keyDown || event.type == .keyUp { return }
    if event.type == .keyDown, event.keyCode == 53,
      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
      !((firstResponder as? NSTextView)?.hasMarkedText() ?? false) {
      // An input method uses Escape to cancel composition; otherwise Escape closes this window.
      closeAfterKeyRelease(event)
      return
    }
    super.sendEvent(event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
      event.charactersIgnoringModifiers?.lowercased() == "w" {
      closeAfterKeyRelease(event)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  /// The File menu's Close (Command-W on any keyboard layout) and Command-period also wait for release.
  override func performClose(_ sender: Any?) { performClose(sender, during: NSApp.currentEvent) }

  func performClose(_ sender: Any?, during event: NSEvent?) {
    if let event = event, event.type == .keyDown, event.window === self || event.window == nil {
      closeAfterKeyRelease(event)
    } else {
      closeNow(sender)
    }
  }

  override func cancelOperation(_ sender: Any?) { performClose(sender) }

  /// Once another window has the keyboard, the release can no longer arrive here.
  override func resignKey() {
    super.resignKey()
    if closingKey != nil { DispatchQueue.main.async { [weak self] in self?.finishKeyClose() } }
  }

  override func close() {
    endKeyClose()
    super.close()
  }
}

/// Keep native actions reachable with Tab even when macOS Full Keyboard Access is off.
class CompanionButton: NSButton {
  override var acceptsFirstResponder: Bool { isEnabled }
  override var canBecomeKeyView: Bool {
    isEnabled && !isHiddenOrHasHiddenAncestor && window != nil
  }
}

/// A borderless symbol button with a hover background. SnapScreen is never the active app, so its
/// tracking area must be active always.
final class ActionButton: CompanionButton {
  private var hovering = false { didSet { if hovering != oldValue { refresh() } } }
  private var tracking: NSTrackingArea?
  private var symbolName: String
  private let idleTitle: String
  private let idleLabel: String
  private var feedbackTimer: Timer?
  var tint: NSColor = .secondaryLabelColor { didSet { refresh() } }
  override var isEnabled: Bool { didSet { refresh() } }

  init(symbol: String, title: String = "", label: String, target: AnyObject?, action: Selector?) {
    symbolName = symbol
    idleTitle = title
    idleLabel = label
    super.init(frame: .zero)
    self.target = target
    self.action = action
    isBordered = false
    setButtonType(.momentaryChange)
    font = .systemFont(ofSize: 12, weight: .medium)
    imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    imageHugsTitle = true
    toolTip = label
    setAccessibilityLabel(label)
    applyContent(symbol: symbol, title: title, color: nil)
  }

  required init?(coder: NSCoder) { nil }

  var buttonSize: NSSize {
    let content = cell?.cellSize ?? .zero
    return NSSize(width: ceil(content.width) + (title.isEmpty ? 10 : 14), height: 24)
  }

  /// Briefly confirms an action, such as Copy, then restores the button.
  func showFeedback(symbol: String, title: String, label: String, color: NSColor) {
    feedbackTimer?.invalidate()
    applyContent(symbol: symbol, title: idleTitle.isEmpty ? "" : title, color: color)
    setAccessibilityLabel(label)
    NSAccessibility.post(element: self, notification: .announcementRequested,
      userInfo: [.announcement: label, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in self?.resetFeedback() }
    RunLoop.main.add(timer, forMode: .common)
    feedbackTimer = timer
  }

  func resetFeedback() {
    feedbackTimer?.invalidate()
    feedbackTimer = nil
    applyContent(symbol: symbolName, title: idleTitle, color: nil)
    setAccessibilityLabel(idleLabel)
  }

  func cancelFeedback() {
    feedbackTimer?.invalidate()
    feedbackTimer = nil
  }

  private var feedbackColor: NSColor?

  private func applyContent(symbol: String, title: String, color: NSColor?) {
    feedbackColor = color
    self.title = title
    image = Theme.symbol(symbol, size: 12)
    image?.isTemplate = true
    refresh()
  }

  private func refresh() {
    let color = !isEnabled ? NSColor.tertiaryLabelColor : (feedbackColor ?? (hovering ? .labelColor : tint))
    contentTintColor = color
    if !title.isEmpty {
      attributedTitle = NSAttributedString(string: title, attributes: [
        .font: font ?? .systemFont(ofSize: 12, weight: .medium), .foregroundColor: color])
    }
    needsDisplay = true
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking = tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { hovering = false }
  }

  override func draw(_ dirtyRect: NSRect) {
    if isEnabled && (hovering || isHighlighted) {
      Theme.hover.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
    super.draw(dirtyRect)
  }
}

/// The composer's circular Send button, which becomes Stop while an answer is in progress.
final class SendButton: CompanionButton {
  enum Mode { case send, stop }
  var mode: Mode = .send { didSet { if mode != oldValue { refresh() } } }
  override var isEnabled: Bool { didSet { refresh() } }

  init(target: AnyObject?, action: Selector?) {
    super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    self.target = target
    self.action = action
    isBordered = false
    title = ""
    setButtonType(.momentaryChange)
    refresh()
  }

  required init?(coder: NSCoder) { nil }

  private func refresh() {
    let label = mode == .send ? "Ask follow-up" : "Stop answer"
    setAccessibilityLabel(label)
    toolTip = label
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
    (isEnabled ? Theme.accent.withAlphaComponent(isHighlighted ? 0.82 : 1) : Theme.idleControl).setFill()
    circle.fill()
    let glyph = mode == .send ? "arrow.up" : "stop.fill"
    let color: NSColor = isEnabled ? .white : .tertiaryLabelColor
    guard let image = Theme.symbol(glyph, size: mode == .send ? 13 : 10, weight: .bold, color: color) else { return }
    let size = image.size
    image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
      width: size.width, height: size.height))
  }

  override func drawFocusRingMask() { NSBezierPath(ovalIn: bounds).fill() }
  override var focusRingMaskBounds: NSRect { bounds }
}
