import AppKit

/// The screenshot is fitted inside this view. All selection coordinates stay relative to
/// that image, including when the window is resized or the screenshot is letterboxed.
final class SelectionView: NSView {
  var image: NSImage? { didSet { selectionChanged() } }
  var selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) {
    didSet { selectionChanged() }
  }
  var onConfirm: ((NormalizedRect) -> Void)?
  var onCancel: (() -> Void)?
  var onSelectionChange: ((String) -> Void)? { didSet { onSelectionChange?(selectionSummary) } }
  private var anchor: CGPoint?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureAccessibility()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureAccessibility()
  }

  var imageRect: CGRect {
    guard let image = image else { return .zero }
    return fittedImageRect(image.size, in: bounds)
  }

  private var normalizedSelection: NormalizedRect? {
    guard [selection.origin.x, selection.origin.y, selection.width, selection.height]
      .allSatisfy({ $0.isFinite }), selection.width > 0, selection.height > 0 else { return nil }
    let x = max(0, min(1, selection.origin.x))
    let y = max(0, min(1, selection.origin.y))
    let rect = NormalizedRect(x: x, y: y,
      width: min(1 - x, selection.width), height: min(1 - y, selection.height))
    return rect.isValid ? rect : nil
  }

  var selectionSummary: String {
    guard let image = image else { return "No screenshot available." }
    guard let rect = normalizedSelection else { return "Choose a region at least 5 by 5 display points." }
    // decodeImage sets the NSImage size to the PNG's pixel dimensions. Round both edges,
    // matching cropImage in the extension, rather than rounding width independently.
    let left = Int((rect.x * image.size.width).rounded())
    let top = Int((rect.y * image.size.height).rounded())
    let right = Int(((rect.x + rect.width) * image.size.width).rounded())
    let bottom = Int(((rect.y + rect.height) * image.size.height).rounded())
    let geometry = "\(right - left) × \(bottom - top) pixels, \(left) from left, \(top) from top."
    return canConfirm ? geometry : geometry + " Enlarge the selection to at least 5 by 5 display points."
  }

  private var canConfirm: Bool {
    guard let rect = normalizedSelection, image != nil else { return false }
    return selectionMeetsMinimum(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
      in: imageRect)
  }

  private func configureAccessibility() {
    setAccessibilityElement(true)
    setAccessibilityRole(.layoutArea)
    setAccessibilityRoleDescription("screenshot region selector")
    setAccessibilityLabel("Frozen screenshot region selection")
    setAccessibilityHelp("Drag a region and release to ask. Arrow keys move the selection one display point. " +
      "Shift and arrow keys resize it. Return asks about the selection. Escape cancels. Tab moves to the controls.")
    var actions = [("Move left", UInt16(123), false), ("Move right", UInt16(124), false),
      ("Move up", UInt16(126), false), ("Move down", UInt16(125), false),
      ("Reduce width", UInt16(123), true), ("Increase width", UInt16(124), true),
      ("Reduce height", UInt16(126), true), ("Increase height", UInt16(125), true)]
      .map { name, keyCode, resize in
        NSAccessibilityCustomAction(name: name) { [weak self] in
          self?.adjustSelection(keyCode: keyCode, resize: resize) ?? false
        }
      }
    actions.append(NSAccessibilityCustomAction(name: "Ask about selection") { [weak self] in
      self?.accessibilityPerformPress() ?? false
    })
    actions.append(NSAccessibilityCustomAction(name: "Cancel selection") { [weak self] in
      guard let cancel = self?.onCancel else { return false }
      cancel()
      return true
    })
    setAccessibilityCustomActions(actions)
    selectionChanged()
  }

  override func accessibilityPerformPress() -> Bool {
    guard canConfirm, onConfirm != nil else { return false }
    confirm()
    return true
  }

  private func selectionChanged() {
    needsDisplay = true
    let summary = selectionSummary
    setAccessibilityValue(summary)
    onSelectionChange?(summary)
    if window != nil { NSAccessibility.post(element: self, notification: .valueChanged) }
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    selectionChanged()
  }

  override func setBoundsSize(_ newSize: NSSize) {
    super.setBoundsSize(newSize)
    selectionChanged()
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
    let fitted = imageRect
    guard fitted.width > 0, fitted.height > 0 else { return }
    image?.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    let selected = CGRect(x: fitted.minX + selection.minX * fitted.width,
      y: fitted.minY + selection.minY * fitted.height,
      width: selection.width * fitted.width, height: selection.height * fitted.height)
    let shade = NSBezierPath(rect: fitted)
    shade.appendRect(selected)
    shade.windingRule = .evenOdd
    NSColor.black.withAlphaComponent(0.42).setFill()
    shade.fill()
    NSColor.systemYellow.setStroke()
    let outline = NSBezierPath(rect: selected)
    outline.lineWidth = 3
    outline.stroke()
  }

  private func normalizedPoint(_ event: NSEvent) -> CGPoint {
    let point = convert(event.locationInWindow, from: nil)
    let fitted = imageRect
    return CGPoint(x: max(0, min(1, (point.x - fitted.minX) / max(1, fitted.width))),
      y: max(0, min(1, (point.y - fitted.minY) / max(1, fitted.height))))
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
    anchor = normalizedPoint(event)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let anchor = anchor else { return }
    let point = normalizedPoint(event)
    selection = CGRect(x: min(point.x, anchor.x), y: min(point.y, anchor.y),
      width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
  }

  override func mouseUp(with event: NSEvent) {
    guard anchor != nil else { return }
    mouseDragged(with: event)
    anchor = nil
    // Preserve release-to-submit and click/tiny-drag cancellation from the tested prototype.
    if canConfirm { confirm() } else { onCancel?() }
  }

  /// Kept separate from event dispatch so accessibility actions use exactly the same bounds
  /// and one-display-point increments as keyboard selection.
  @discardableResult
  func adjustSelection(keyCode: UInt16, resize: Bool) -> Bool {
    let fitted = imageRect
    guard [123, 124, 125, 126].contains(keyCode), fitted.width > 0, fitted.height > 0,
      normalizedSelection != nil else { return false }
    let dx: CGFloat = keyCode == 123 ? -1 / max(1, fitted.width) :
      (keyCode == 124 ? 1 / max(1, fitted.width) : 0)
    let dy: CGFloat = keyCode == 126 ? -1 / max(1, fitted.height) :
      (keyCode == 125 ? 1 / max(1, fitted.height) : 0)
    var updated = selection
    if resize {
      updated.size.width = max(1 / max(1, fitted.width), min(1 - selection.minX, selection.width + dx))
      updated.size.height = max(1 / max(1, fitted.height), min(1 - selection.minY, selection.height + dy))
    } else {
      updated.origin.x = max(0, min(1 - selection.width, selection.minX + dx))
      updated.origin.y = max(0, min(1 - selection.height, selection.minY + dy))
    }
    guard updated != selection else { return false }
    selection = updated
    return true
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 76: confirm()
    case 53: onCancel?()
    case 48:
      if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
      else { window?.selectNextKeyView(self) }
    case 123, 124, 125, 126:
      adjustSelection(keyCode: event.keyCode, resize: event.modifierFlags.contains(.shift))
    default:
      // Selection owns keyboard input. Do not forward unknown keys to Chrome.
      break
    }
  }

  @objc func confirm() {
    guard canConfirm, let rect = normalizedSelection else { return }
    onConfirm?(rect)
  }
}

/// A preview has its own explicit close control. It only holds the extension-accepted crop.
final class PreviewView: NSView {
  private let imageView = NSImageView()
  var image: NSImage? {
    get { imageView.image }
    set { imageView.image = newValue }
  }
  var onClose: (() -> Void)?
  override var acceptsFirstResponder: Bool { true }

  init(image: NSImage) {
    super.init(frame: .zero)
    configure()
    self.image = image
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  private func configure() {
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.setAccessibilityElement(true)
    imageView.setAccessibilityRole(.image)
    imageView.setAccessibilityLabel("Selected screenshot preview")
    imageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(imageView)
    let close = CompanionButton(title: "Close preview", target: self, action: #selector(closePreview))
    close.bezelStyle = .rounded
    close.keyEquivalent = "\u{1b}"
    close.keyEquivalentModifierMask = []
    close.translatesAutoresizingMaskIntoConstraints = false
    addSubview(close)
    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      imageView.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -10),
      close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      close.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
    ])
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 53: closePreview()
    case 48:
      if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
      else { window?.selectNextKeyView(self) }
    default: break
    }
  }

  @objc private func closePreview() { onClose?() }
}
