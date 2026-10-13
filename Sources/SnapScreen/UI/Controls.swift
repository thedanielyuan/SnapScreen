import AppKit

/// SnapScreen's colours. It has no light mode (main.swift makes the app dark): the conversation is
/// near-black, code sits on it a shade lighter, and cyan marks what's live.
enum Theme {
  /// Stop when it can act, and Copy under the pointer or once it copies.
  static let accent = NSColor(srgbRed: 34 / 255, green: 211 / 255, blue: 238 / 255, alpha: 1)
  /// Stop's square, drawn on the accent.
  static let onAccent = gray(0x0D)
  static let pointerSelection = NSColor(srgbRed: 59 / 255, green: 130 / 255, blue: 246 / 255, alpha: 1)
  static let keyboardSelection = NSColor(srgbRed: 167 / 255, green: 139 / 255, blue: 250 / 255, alpha: 1)
  static let keyboardRing = NSColor(srgbRed: 139 / 255, green: 92 / 255, blue: 246 / 255, alpha: 0.75)
  static let backdrop = NSColor(srgbRed: 17 / 255, green: 17 / 255, blue: 17 / 255, alpha: 1)
  /// The conversation window.
  static let background = gray(0x0D)
  /// Code blocks and the screenshot's thumbnail, each outlined.
  static let surface = gray(0x17)
  static let surfaceBorder = gray(0x2A)
  static let hover = NSColor.white.withAlphaComponent(0.09)
  static let idleControl = NSColor.white.withAlphaComponent(0.12)
  /// Stop's square on `idleControl`, faint until it can act.
  static let idleIcon = NSColor.white.withAlphaComponent(0.06)

  /// An opaque sRGB grey from its 8-bit level, so 0x0D is #0D0D0D.
  private static func gray(_ level: CGFloat) -> NSColor {
    NSColor(srgbRed: level / 255, green: level / 255, blue: level / 255, alpha: 1)
  }

  static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium, color: NSColor? = nil) -> NSImage? {
    var configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    if let color = color { configuration = configuration.applying(.init(paletteColors: [color])) }
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
  }
}

/// Where Copy writes: the general pasteboard. The self-test swaps in a private one, so it never
/// touches your clipboard.
enum Clipboard {
  static var pasteboard = NSPasteboard.general

  static func copy(_ text: String) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }
}

/// A snip's panels: the selection overlay, the conversation and the screenshot preview. Like every
/// capture panel, they never activate SnapScreen or take the keyboard, including when clicked, so
/// they close only from the pointer. Settings uses a separate foreground NSWindow.
final class CompanionPanel: PassivePanel {}

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
  var hoverTint: NSColor = .labelColor { didSet { refresh() } }
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
    let color = !isEnabled ? NSColor.tertiaryLabelColor : (feedbackColor ?? (hovering ? hoverTint : tint))
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

/// The conversation's circular Stop button, shown while an answer is in progress. It fills with the
/// accent only while it can act, once the request has started.
final class StopButton: CompanionButton {
  static let size: CGFloat = 32
  override var isEnabled: Bool { didSet { needsDisplay = true } }

  init(target: AnyObject?, action: Selector?) {
    super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
    self.target = target
    self.action = action
    isBordered = false
    title = ""
    setButtonType(.momentaryChange)
    setAccessibilityLabel("Stop answer")
    toolTip = "Stop answer"
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
    (isEnabled ? Theme.accent.withAlphaComponent(isHighlighted ? 0.82 : 1) : Theme.idleControl).setFill()
    circle.fill()
    (isEnabled ? Theme.onAccent : Theme.idleIcon).set()
    // A path rather than an SF Symbol, whose image sits on a text baseline, so its ink is off centre:
    // a square centred in the circle, 10 points on a side of a 32-point circle.
    let side = 10 * bounds.height / 32
    NSBezierPath(roundedRect: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side),
      xRadius: side / 5, yRadius: side / 5).fill()
  }

  override func drawFocusRingMask() { NSBezierPath(ovalIn: bounds).fill() }
  override var focusRingMaskBounds: NSRect { bounds }
}
