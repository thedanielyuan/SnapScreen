import AppKit

/// What a notice's button does, such as opening System Settings.
struct NoticeAction {
  let title: String
  let perform: () -> Void
}

/// A small panel for failures before a conversation window
/// exists. It never activates SnapScreen or takes the keyboard, so the app you were using keeps
/// focus.
final class NoticePanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(content: NoticePanelView) {
    super.init(contentRect: NSRect(origin: .zero, size: content.fittingSize),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .floating
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    contentView = content
  }
}

/// SnapScreen is never the active app, so a click must act at once rather than only bringing the
/// panel forward.
final class NoticeButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A notice's message, with an optional action and a close button.
final class NoticePanelView: NSVisualEffectView {
  static let messageWidth: CGFloat = 260
  let messageLabel: NSTextField
  private(set) var actionButton: NoticeButton?
  private(set) var closeButton = NoticeButton(frame: .zero)
  /// Reports the pointer entering (true) and leaving (false).
  var onHoverChange: ((Bool) -> Void)?
  private let action: NoticeAction?
  private let onClose: () -> Void
  private var tracking: NSTrackingArea?

  init(message: String, action: NoticeAction?, onClose: @escaping () -> Void) {
    messageLabel = NSTextField(wrappingLabelWithString: message)
    self.action = action
    self.onClose = onClose
    super.init(frame: .zero)
    material = .popover
    blendingMode = .behindWindow
    // The app is never active, so follow nothing and always draw the active material.
    state = .active
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.masksToBounds = true

    let icon = NSImageView(image: Theme.symbol("exclamationmark.circle", size: 16, weight: .regular,
      color: .secondaryLabelColor) ?? NSImage())
    icon.setAccessibilityElement(false)
    messageLabel.font = .systemFont(ofSize: 13)
    // A fixed width lets the panel's fitting size include every wrapped line.
    messageLabel.preferredMaxLayoutWidth = Self.messageWidth
    messageLabel.widthAnchor.constraint(equalToConstant: Self.messageWidth).isActive = true
    let text = NSStackView(views: [messageLabel])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 10
    if let action = action {
      let button = NoticeButton(title: action.title, target: self, action: #selector(performAction))
      text.addArrangedSubview(button)
      actionButton = button
    }
    closeButton.image = Theme.symbol("xmark", size: 10, weight: .semibold)
    closeButton.image?.isTemplate = true
    closeButton.contentTintColor = .secondaryLabelColor
    closeButton.isBordered = false
    closeButton.target = self
    closeButton.action = #selector(close)
    closeButton.setAccessibilityLabel("Close")
    closeButton.toolTip = "Close"
    let row = NSStackView(views: [icon, text, closeButton])
    row.orientation = .horizontal
    row.alignment = .top
    row.spacing = 10
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    // Margins as constraints: a horizontal stack's bottom inset doesn't count toward its fitting size.
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
      closeButton.widthAnchor.constraint(equalToConstant: 16),
      closeButton.heightAnchor.constraint(equalToConstant: 16),
    ])
  }

  required init?(coder: NSCoder) { nil }

  @objc private func performAction() {
    action?.perform()
    onClose()
  }

  @objc private func close() { onClose() }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking = tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
  override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

/// Shows one notice at a time, in the top-right corner of the screen under the pointer. A new
/// notice replaces the last, and each closes itself after a few seconds unless the pointer is on it.
final class NoticeCenter {
  static let duration: TimeInterval = 8
  private(set) var panel: NoticePanel?
  private var timer: Timer?

  func show(_ message: String, action: NoticeAction? = nil) {
    dismiss()
    let view = NoticePanelView(message: message, action: action) { [weak self] in self?.dismiss() }
    view.onHoverChange = { [weak self] hovering in
      if hovering { self?.timer?.invalidate() } else { self?.scheduleDismissal(after: 3) }
    }
    let notice = NoticePanel(content: view)
    let visible = screenUnderPointer()?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let size = view.fittingSize
    notice.setFrame(NSRect(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 12,
      width: size.width, height: size.height), display: false)
    notice.orderFrontRegardless()
    notice.invalidateShadow()
    panel = notice
    NSAccessibility.post(element: view, notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    scheduleDismissal(after: Self.duration)
  }

  func dismiss() {
    timer?.invalidate()
    timer = nil
    guard let notice = panel else { return }
    panel = nil
    notice.orderOut(nil)
    // A button in the panel may still be running the action that closed it.
    DispatchQueue.main.async { notice.contentView = nil }
  }

  private func scheduleDismissal(after seconds: TimeInterval) {
    timer?.invalidate()
    let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.dismiss() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }
}
