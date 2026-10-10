import AppKit

extension CompanionPanel {
  /// A floating panel that never activates the app. Media panels (selection and preview) show an
  /// image edge to edge under a transparent title bar. The caller sets the delegate.
  static func make(title: String, contentSize: NSSize, minimumSize: NSSize, media: Bool) -> CompanionPanel {
    var style: NSWindow.StyleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
    if media { style.insert(.fullSizeContentView) }
    let value = CompanionPanel(contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: style, backing: .buffered, defer: false)
    value.title = title
    value.identifier = NSUserInterfaceItemIdentifier(title)
    value.level = .floating
    value.hidesOnDeactivate = false
    value.becomesKeyOnlyIfNeeded = false
    value.isReleasedWhenClosed = false
    value.autorecalculatesKeyViewLoop = true
    value.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    value.acceptsMouseMovedEvents = true
    value.titlebarAppearsTransparent = true
    value.contentMinSize = minimumSize
    if media {
      value.titleVisibility = .hidden
      value.appearance = NSAppearance(named: .darkAqua)
      value.backgroundColor = Theme.backdrop
    }
    return value
  }

  static var titlebarHeight: CGFloat {
    let content = NSRect(x: 0, y: 0, width: 400, height: 300)
    return NSWindow.frameRect(forContentRect: content, styleMask: [.titled]).height - content.height
  }
}

/// Kept below the active panel, click-through except during an edge resize. This preserves
/// Phase 1's tested protection from pointer events falling through a shrinking native panel.
final class PointerShield: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Places the pointer shield beneath each panel as it appears, and lets it take the pointer only
/// while a panel is pressed within 8 points of its edge or is live-resizing.
final class PointerShieldController {
  /// Whether the shield may take the pointer, for example only while a session is active.
  var canRaise: () -> Bool = { true }
  private(set) var shield: PointerShield?
  private var monitor: Any?
  private var pressedWindow: CompanionPanel?
  private var pointerTimer: Timer?
  private var liveResizing = false

  /// Starts watching presses in this process's panels.
  func start() {
    guard monitor == nil else { return }
    // These events control only the resize shield. No input, clipboard, geometry or content logging.
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
      guard let self = self else { return event }
      if event.type == .leftMouseDown {
        self.endPressTracking()
        self.pressedWindow = event.window as? CompanionPanel
        if let panel = self.pressedWindow, panel.styleMask.contains(.resizable),
          isNearFrameEdge(NSEvent.mouseLocation, panel.frame) { self.raise(below: panel) }
      } else {
        self.endPressTracking()
      }
      return event
    }
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      guard let self = self, let window = self.pressedWindow else { return }
      // AppKit's nested tracking loops may consume mouse-up before the local monitor receives it.
      if NSEvent.pressedMouseButtons & 1 == 0 || !window.isVisible { self.endPressTracking() }
    }
    timer.tolerance = 0.02
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .eventTracking)
    pointerTimer = timer
  }

  func stop() {
    if let monitor = monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    pointerTimer?.invalidate()
    pointerTimer = nil
  }

  /// Orders the shield directly beneath a panel, across the panel's screen. Panels call this as
  /// they appear, so the shield is in place before any resize starts. A hidden panel needs none.
  func place(below window: CompanionPanel) {
    guard window.isVisible, let frame = (window.screen ?? NSScreen.main)?.frame else { return }
    let value = shield ?? {
      let panel = PointerShield(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)
      panel.isOpaque = false
      panel.backgroundColor = NSColor(calibratedWhite: 0, alpha: 1 / 255)
      panel.ignoresMouseEvents = true
      panel.hasShadow = false
      panel.level = .floating
      panel.hidesOnDeactivate = false
      panel.isReleasedWhenClosed = false
      panel.animationBehavior = .none
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
      return panel
    }()
    shield = value
    if value.frame != frame { value.setFrame(frame, display: true) }
    value.order(.below, relativeTo: window.windowNumber)
  }

  /// Lets the shield take the pointer beneath a panel that's being reshaped.
  func raise(below window: CompanionPanel) {
    guard canRaise() else { return }
    place(below: window)
    shield?.ignoresMouseEvents = false
  }

  func lower() { shield?.ignoresMouseEvents = true }

  func endPressTracking() {
    pressedWindow = nil
    if !liveResizing { lower() }
  }

  func liveResizeStarted(_ window: NSWindow?) {
    liveResizing = true
    if let window = window as? CompanionPanel { raise(below: window) }
  }

  func liveResizeEnded() {
    liveResizing = false
    lower()
  }

  /// Lowers and hides the shield once the panels it protects have closed.
  func reset() {
    endPressTracking()
    liveResizing = false
    lower()
    shield?.orderOut(nil)
  }
}

/// The only content left after a session ends: no screenshot, answer or draft.
final class SessionEndedView: NSView {
  let messageLabel: NSTextField

  init(message: String) {
    messageLabel = NSTextField(wrappingLabelWithString: message)
    super.init(frame: .zero)
    let icon = NSImageView(image: Theme.symbol("exclamationmark.circle", size: 30, weight: .regular,
      color: .secondaryLabelColor) ?? NSImage())
    icon.setAccessibilityElement(false)
    let title = NSTextField(labelWithString: "Session ended")
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    messageLabel.font = .systemFont(ofSize: 13)
    messageLabel.textColor = .secondaryLabelColor
    messageLabel.alignment = .center
    let stack = NSStackView(views: [icon, title, messageLabel])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 8
    stack.setCustomSpacing(12, after: icon)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
      messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
    ])
  }

  required init?(coder: NSCoder) { nil }
}
