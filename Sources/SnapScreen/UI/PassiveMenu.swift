import AppKit

/// Pointer commands that leave the foreground app's key window and typed input alone.
struct PassiveMenuItem {
  let title: String
  let hint: String?
  let isEnabled: Bool
  let separatorBefore: Bool
  let action: () -> Void

  init(title: String, hint: String? = nil, isEnabled: Bool = true, separatorBefore: Bool = false,
    action: @escaping () -> Void) {
    self.title = title
    self.hint = hint
    self.isEnabled = isEnabled
    self.separatorBefore = separatorBefore
    self.action = action
  }
}

/// Native menus temporarily take the foreground window's keyboard. These commands live in the
/// same nonactivating panels as a snip, with no menu tracking loop or keyboard handling.
final class PassiveMenu {
  private(set) var panel: PassivePanel?
  var isVisible: Bool { panel?.isVisible == true }
  private let present: (PassivePanel) -> Void
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var excludedFrame: NSRect?

  /// Tests can inspect the complete panel without putting it on screen.
  init(present: @escaping (PassivePanel) -> Void = { $0.orderFront(nil) }) {
    self.present = present
  }

  deinit { dismiss() }

  /// `topLeft` uses AppKit screen coordinates. The excluded frame lets the menu bar button toggle
  /// its own menu without an earlier mouse-down dismissing it first.
  func show(_ items: [PassiveMenuItem], at topLeft: NSPoint,
    ignoringOutsideClicksIn excludedFrame: NSRect? = nil) {
    dismiss()
    guard !items.isEmpty else { return }
    let content = PassiveMenuView(items: items) { [weak self] action in
      guard let self else { return }
      self.dismiss()
      action()
    }
    let window = PassivePanel(contentRect: NSRect(origin: .zero, size: content.frame.size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.title = "SnapScreen menu"
    window.level = .popUpMenu
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.animationBehavior = .none
    window.contentView = content
    let screen = NSScreen.screens.first(where: { $0.frame.contains(topLeft) }) ?? screenUnderPointer()
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    window.setFrame(Self.frame(size: content.frame.size, at: topLeft, in: visible), display: false)
    panel = window
    self.excludedFrame = excludedFrame
    // Settings hands focus back by hiding the app. canHide=false keeps passive panels visible,
    // but macOS omits a hidden app's windows from accessibility until it is unhidden.
    if NSApp.isHidden { NSApp.unhideWithoutActivation() }
    present(window)
    window.invalidateShadow()
    watchOutsideClicks()
  }

  func dismiss() {
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    globalMonitor = nil
    localMonitor = nil
    excludedFrame = nil
    guard let window = panel else { return }
    panel = nil
    // Release actions immediately, including closures holding a selected answer. Keep the views
    // only until AppKit has finished any button action currently running in this panel.
    (window.contentView as? PassiveMenuView)?.clearActions()
    window.orderOut(nil)
    DispatchQueue.main.async { window.contentView = nil }
  }

  static func frame(size: NSSize, at topLeft: NSPoint, in visible: NSRect) -> NSRect {
    let size = NSSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
    return NSRect(x: min(max(topLeft.x, visible.minX), visible.maxX - size.width),
      y: min(max(topLeft.y - size.height, visible.minY), visible.maxY - size.height),
      width: size.width, height: size.height)
  }

  /// Both monitors only observe mouse presses. The local one returns the original event, so a
  /// click outside still reaches its target, including another passive SnapScreen panel.
  private func watchOutsideClicks() {
    let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
      self?.clickedOutside(at: event.locationInWindow)
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
      guard let self, event.window !== self.panel else { return event }
      let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
      self.clickedOutside(at: point)
      return event
    }
  }

  func clickedOutside(at point: NSPoint) {
    guard let panel, !panel.frame.contains(point), excludedFrame?.contains(point) != true else { return }
    dismiss()
  }
}

/// Each row is a real button, so assistive technologies can invoke it without menu tracking.
final class PassiveMenuView: NSVisualEffectView {
  private(set) var buttons: [PassiveMenuButton] = []
  override var isFlipped: Bool { true }

  init(items: [PassiveMenuItem], perform: @escaping (@escaping () -> Void) -> Void) {
    let font = NSFont.systemFont(ofSize: 13)
    let width = max(220, items.map { item -> CGFloat in
      let titleWidth = (item.title as NSString).size(withAttributes: [.font: font]).width
      let hintWidth = item.hint.map { ($0 as NSString).size(withAttributes: [.font: font]).width + 28 } ?? 0
      return ceil(titleWidth + hintWidth + 32)
    }.max() ?? 0)
    let separators = items.enumerated().filter { $0.offset > 0 && $0.element.separatorBefore }.count
    let height = CGFloat(items.count) * PassiveMenuButton.height + CGFloat(separators) * 9 + 12
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    material = .popover
    blendingMode = .behindWindow
    state = .active
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.masksToBounds = true
    var y: CGFloat = 6
    for (index, item) in items.enumerated() {
      if index > 0 && item.separatorBefore {
        let separator = NSBox(frame: NSRect(x: 8, y: y + 4, width: width - 16, height: 1))
        separator.boxType = .separator
        separator.setAccessibilityElement(false)
        addSubview(separator)
        y += 9
      }
      let button = PassiveMenuButton(item: item) { perform(item.action) }
      button.frame = NSRect(x: 6, y: y, width: width - 12, height: PassiveMenuButton.height)
      addSubview(button)
      buttons.append(button)
      y += PassiveMenuButton.height
    }
  }

  required init?(coder: NSCoder) { nil }

  func clearActions() {
    for button in buttons { button.onPress = nil }
  }
}

final class PassiveMenuButton: NSButton {
  static let height: CGFloat = 28
  var onPress: (() -> Void)?
  private let hint: String?
  private var hovering = false { didSet { needsDisplay = true } }
  private var tracking: NSTrackingArea?
  override var acceptsFirstResponder: Bool { false }
  override var canBecomeKeyView: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  init(item: PassiveMenuItem, onPress: @escaping () -> Void) {
    hint = item.hint
    self.onPress = onPress
    super.init(frame: .zero)
    title = item.title
    isEnabled = item.isEnabled
    isBordered = false
    setButtonType(.momentaryChange)
    setAccessibilityLabel(item.title)
    if let hint = item.hint { setAccessibilityHelp(hint) }
    target = self
    action = #selector(performAction)
  }

  required init?(coder: NSCoder) { nil }

  @objc private func performAction() {
    guard isEnabled else { return }
    onPress?()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }

  override func draw(_ dirtyRect: NSRect) {
    if isEnabled && (hovering || isHighlighted) {
      Theme.hover.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
    let font = NSFont.systemFont(ofSize: 13)
    let titleColor: NSColor = isEnabled ? .labelColor : .disabledControlTextColor
    let textRect = bounds.insetBy(dx: 8, dy: 6)
    (title as NSString).draw(in: textRect, withAttributes: [.font: font, .foregroundColor: titleColor])
    if let hint {
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .right
      (hint as NSString).draw(in: textRect, withAttributes: [.font: font, .paragraphStyle: paragraph,
        .foregroundColor: isEnabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor])
    }
  }
}
