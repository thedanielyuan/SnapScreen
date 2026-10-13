import AppKit

/// The frozen screenshot, fitted inside its window, for selecting a region: drag and release to
/// ask, or click to cancel. Accessibility actions can place, move and confirm a selection without
/// taking the keyboard from the app beneath. All coordinates
/// stay normalized to the fitted image, including while the window is resized.
final class SelectionView: NSView {
  static let instruction = "Drag to select a region. Click to cancel"
  /// The keyboard selection's step and the smallest selection, in display points.
  static let keyboardStep: CGFloat = 10
  static let minimumSize: CGFloat = 5
  static let dim = NSColor.black.withAlphaComponent(0.35)

  var image: NSImage? {
    didSet {
      dimmedImage = image.flatMap(Self.dimmed)
      selectionChanged()
    }
  }
  /// The image under the dim, made once, so a redraw while dragging copies two images instead of
  /// blending the whole view.
  private var dimmedImage: NSImage?
  /// Fills the view with the image, for the overlay that covers its display: no margin, title bar
  /// inset or backdrop.
  var fillsBounds = false { didSet { selectionChanged() } }
  /// Normalized to the image. Nil until a drag starts or an accessibility action places a keyboard
  /// selection.
  var selection: CGRect? { didSet { selectionChanged() } }
  private(set) var isKeyboardSelection = false
  private(set) var isDragging = false
  var onConfirm: ((NormalizedRect) -> Void)?
  var onCancel: (() -> Void)?
  private var anchor: CGPoint?
  private var cursorTracking: NSTrackingArea?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  // The overlay never becomes key; the first press must still start a drag.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureAccessibility()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureAccessibility()
  }

  /// The image avoids the transparent title bar, so a drag never starts beneath it.
  var imageRect: CGRect {
    guard let image = image else { return .zero }
    if fillsBounds { return bounds }
    let insets = safeAreaInsets
    let area = CGRect(x: insets.left, y: insets.top, width: bounds.width - insets.left - insets.right,
      height: bounds.height - insets.top - insets.bottom)
    return fittedImageRect(image.size, in: area, inset: 8)
  }

  private var normalizedSelection: NormalizedRect? {
    guard let selection = selection, [selection.origin.x, selection.origin.y, selection.width, selection.height]
      .allSatisfy({ $0.isFinite }), selection.width > 0, selection.height > 0 else { return nil }
    let x = max(0, min(1, selection.origin.x))
    let y = max(0, min(1, selection.origin.y))
    let rect = NormalizedRect(x: x, y: y,
      width: min(1 - x, selection.width), height: min(1 - y, selection.height))
    return rect.isValid ? rect : nil
  }

  /// Screenshot pixels, rounded at both edges as the crop is.
  private var pixelBounds: (left: Int, top: Int, width: Int, height: Int)? {
    guard let image = image, let rect = normalizedSelection else { return nil }
    let left = Int((rect.x * image.size.width).rounded())
    let top = Int((rect.y * image.size.height).rounded())
    let right = Int(((rect.x + rect.width) * image.size.width).rounded())
    let bottom = Int(((rect.y + rect.height) * image.size.height).rounded())
    return (left, top, right - left, bottom - top)
  }

  /// The selection's size in screenshot pixels: the crop's size before any limit shrinks it.
  var selectedPixelSize: CGSize? { pixelBounds.map { CGSize(width: $0.width, height: $0.height) } }

  var selectionSummary: String {
    guard image != nil else { return "No screenshot available." }
    guard let pixels = pixelBounds else { return "No region selected." }
    let geometry = "\(pixels.width) × \(pixels.height) pixels, \(pixels.left) from left, \(pixels.top) from top."
    return canConfirm ? geometry : geometry + " Enlarge the selection to at least 5 by 5 display points."
  }

  var canConfirm: Bool {
    guard let rect = normalizedSelection, image != nil else { return false }
    return selectionMeetsMinimum(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
      in: imageRect, minimum: Self.minimumSize)
  }

  private func configureAccessibility() {
    setAccessibilityElement(true)
    setAccessibilityRole(.layoutArea)
    setAccessibilityRoleDescription("screenshot region selector")
    setAccessibilityLabel("Select a screen region")
    setAccessibilityHelp("Drag a region and release to ask about it, or click without dragging to cancel. " +
      "Use the selection's accessibility actions to move, resize, ask or cancel. " +
      "Keyboard input stays in the app beneath.")
    var actions = [("Move left", UInt16(123), false), ("Move right", UInt16(124), false),
      ("Move up", UInt16(126), false), ("Move down", UInt16(125), false),
      ("Reduce width", UInt16(123), true), ("Increase width", UInt16(124), true),
      ("Reduce height", UInt16(126), true), ("Increase height", UInt16(125), true)]
      .map { name, keyCode, resize in
        NSAccessibilityCustomAction(name: name) { [weak self] in
          guard let self = self else { return false }
          if self.selection == nil { return self.placeKeyboardSelection() }
          return self.adjustSelection(keyCode: keyCode, resize: resize)
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
    guard onConfirm != nil else { return false }
    if selection == nil { return placeKeyboardSelection() }
    guard canConfirm else { return false }
    confirm()
    return true
  }

  private func selectionChanged() {
    needsDisplay = true
    setAccessibilityValue(selectionSummary)
    if window != nil { NSAccessibility.post(element: self, notification: .valueChanged) }
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    selectionChanged()
    window?.invalidateCursorRects(for: self)
  }

  override func resetCursorRects() {
    addCursorRect(imageRect, cursor: .crosshair)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking = cursorTracking { removeTrackingArea(tracking) }
    // Cursor rects alone need an active app, and SnapScreen never activates.
    let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    cursorTracking = area
  }

  override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
  override func mouseEntered(with event: NSEvent) { holdCrosshair() }
  override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
  override func mouseMoved(with event: NSEvent) { showCrosshair() }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { holdCrosshair() }
  }

  /// The app the pointer leaves resets the cursor as the overlay covers it, sometimes just after
  /// this view set the crosshair, so it's set again over the next second, and on each move and press.
  private func holdCrosshair() {
    showCrosshair()
    for delay in [0.02, 0.05, 0.1, 0.3, 1] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.showCrosshair() }
    }
  }

  /// Only while the pointer is over the image: the key window also gets moves over other displays.
  private func showCrosshair() {
    guard let window = window, window.isVisible,
      imageRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
    NSCursor.crosshair.set()
  }

  private func displayRect(_ selection: CGRect, in fitted: CGRect) -> CGRect {
    CGRect(x: fitted.minX + selection.minX * fitted.width, y: fitted.minY + selection.minY * fitted.height,
      width: selection.width * fitted.width, height: selection.height * fitted.height)
  }

  /// The selected region in this view's coordinates, used to place the answer window beside it.
  var selectionDisplayRect: CGRect? {
    guard let selection = selection else { return nil }
    return displayRect(selection, in: imageRect)
  }

  override func draw(_ dirtyRect: NSRect) {
    if !fillsBounds {
      Theme.backdrop.setFill()
      bounds.fill()
    }
    let fitted = imageRect
    guard let image = image, fitted.width > 0, fitted.height > 0 else { return }
    let selected = selection.map { displayRect($0, in: fitted) }
    if let dimmed = dimmedImage {
      drawImage(dimmed, in: fitted)
      if let selected = selected {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selected).addClip()
        drawImage(image, in: fitted)
        NSGraphicsContext.restoreGraphicsState()
      }
    } else {
      drawImage(image, in: fitted)
      let shade = NSBezierPath(rect: fitted)
      if let selected = selected {
        shade.appendRect(selected)
        shade.windingRule = .evenOdd
      }
      Self.dim.setFill()
      shade.fill()
    }
    if let selected = selected { drawSelection(selected) }
    if !isDragging { drawHint(in: fitted) }
  }

  private func drawImage(_ image: NSImage, in rect: CGRect) {
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high.rawValue])
  }

  /// The image with the dim applied, at its full pixel size. Nil when it has no bitmap.
  private static func dimmed(_ image: NSImage) -> NSImage? {
    guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let space = source.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
      ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
      bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
      return nil
    }
    let rect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
    context.draw(source, in: rect)
    context.setFillColor(dim.cgColor)
    context.fill(rect)
    return context.makeImage().map { NSImage(cgImage: $0, size: image.size) }
  }

  private func drawSelection(_ rect: CGRect) {
    if isKeyboardSelection {
      Theme.keyboardRing.setStroke()
      let ring = NSBezierPath(rect: rect.insetBy(dx: -3.5, dy: -3.5))
      ring.lineWidth = 3
      ring.stroke()
      NSColor.white.withAlphaComponent(0.9).setStroke()
      let inner = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
      inner.lineWidth = 2
      inner.stroke()
    }
    let color = isKeyboardSelection ? Theme.keyboardSelection : Theme.pointerSelection
    // A dragged region shows its true colours, as it's sent; the undimmed area and border mark it.
    if isKeyboardSelection {
      color.withAlphaComponent(0.16).setFill()
      rect.fill()
    }
    color.setStroke()
    let border = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
    border.lineWidth = 2
    border.stroke()
    guard let pixels = pixelBounds else { return }
    let badge = NSAttributedString(string: "\(pixels.width) × \(pixels.height)", attributes: [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
    let size = badge.size()
    let box = NSSize(width: ceil(size.width) + 16, height: ceil(size.height) + 6)
    let origin = CGPoint(x: max(4, min(rect.maxX + 8, bounds.width - box.width - 4)),
      y: max(4, min(rect.maxY + 8, bounds.height - box.height - 4)))
    drawPill(badge, in: CGRect(origin: origin, size: box), radius: 6)
  }

  private func drawHint(in fitted: CGRect) {
    let hint = NSAttributedString(string: Self.instruction, attributes: [
      .font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.white])
    let size = hint.size()
    let box = NSSize(width: min(ceil(size.width) + 32, max(0, fitted.width - 16)), height: ceil(size.height) + 16)
    guard box.width > 32 else { return }
    drawPill(hint, in: CGRect(x: fitted.midX - box.width / 2, y: fitted.maxY - 24 - box.height,
      width: box.width, height: box.height), radius: 8)
  }

  private func drawPill(_ text: NSAttributedString, in box: CGRect, radius: CGFloat) {
    NSColor.black.withAlphaComponent(0.75).setFill()
    NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
    let size = text.size()
    text.draw(with: CGRect(x: box.midX - min(size.width, box.width - 16) / 2, y: box.midY - size.height / 2,
      width: min(size.width, box.width - 16) + 1, height: size.height + 1),
      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
  }

  private func normalizedPoint(_ event: NSEvent) -> CGPoint {
    let point = convert(event.locationInWindow, from: nil)
    let fitted = imageRect
    return CGPoint(x: max(0, min(1, (point.x - fitted.minX) / max(1, fitted.width))),
      y: max(0, min(1, (point.y - fitted.minY) / max(1, fitted.height))))
  }

  override func mouseDown(with event: NSEvent) {
    showCrosshair()
    guard image != nil, imageRect.width > 0 else { return }
    // A drag that starts in the margin is clamped to the image edge.
    let point = normalizedPoint(event)
    anchor = point
    isDragging = true
    isKeyboardSelection = false
    selection = CGRect(origin: point, size: .zero)
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
    isDragging = false
    // Release asks; a click or a drag under the minimum cancels, as in the tested prototype.
    if canConfirm { confirm() } else { selection = nil; onCancel?() }
  }

  /// Places the keyboard selection: centred, half the image but at most 320 × 180 points.
  @discardableResult
  func placeKeyboardSelection() -> Bool {
    let fitted = imageRect
    guard image != nil, fitted.width >= Self.minimumSize, fitted.height >= Self.minimumSize else { return false }
    let width = min(max((fitted.width / 2).rounded(), Self.minimumSize), min(320, fitted.width))
    let height = min(max((fitted.height / 2).rounded(), Self.minimumSize), min(180, fitted.height))
    isKeyboardSelection = true
    selection = CGRect(x: (fitted.width - width) / 2 / fitted.width, y: (fitted.height - height) / 2 / fitted.height,
      width: width / fitted.width, height: height / fitted.height)
    return true
  }

  /// The accessibility actions' moves and resizes, each direction named by its arrow key's code.
  @discardableResult
  func adjustSelection(keyCode: UInt16, resize: Bool) -> Bool {
    let fitted = imageRect
    guard [123, 124, 125, 126].contains(keyCode), fitted.width > 0, fitted.height > 0,
      let current = selection, normalizedSelection != nil else { return false }
    let step = Self.keyboardStep
    let dx: CGFloat = keyCode == 123 ? -step : (keyCode == 124 ? step : 0)
    let dy: CGFloat = keyCode == 126 ? -step : (keyCode == 125 ? step : 0)
    let minimumWidth = min(1, Self.minimumSize / fitted.width)
    let minimumHeight = min(1, Self.minimumSize / fitted.height)
    var updated = current
    if resize {
      updated.size.width = max(minimumWidth, min(1 - current.minX, current.width + dx / fitted.width))
      updated.size.height = max(minimumHeight, min(1 - current.minY, current.height + dy / fitted.height))
    } else {
      updated.origin.x = max(0, min(1 - current.width, current.minX + dx / fitted.width))
      updated.origin.y = max(0, min(1 - current.height, current.minY + dy / fitted.height))
    }
    isKeyboardSelection = true
    guard updated != current else { return false }
    selection = updated
    return true
  }

  @objc func confirm() {
    guard canConfirm, let rect = normalizedSelection else { return }
    onConfirm?(rect)
  }
}

/// Shows only the accepted crop, fitted and never enlarged beyond its pixel size.
final class PreviewView: NSView {
  var image: NSImage? {
    didSet {
      needsDisplay = true
      setAccessibilityElement(image != nil)
    }
  }
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  init(image: NSImage) {
    super.init(frame: .zero)
    setAccessibilityRole(.image)
    setAccessibilityLabel("Selected screenshot")
    // Property observers do not run from this class's own initializer.
    self.image = image
    setAccessibilityElement(true)
  }

  required init?(coder: NSCoder) { nil }

  var imageRect: CGRect {
    guard let image = image else { return .zero }
    let insets = safeAreaInsets
    let area = CGRect(x: insets.left, y: insets.top, width: bounds.width - insets.left - insets.right,
      height: bounds.height - insets.top - insets.bottom)
    return fittedImageRect(image.size, in: area, inset: 12, maximumScale: 1)
  }

  override func draw(_ dirtyRect: NSRect) {
    Theme.backdrop.setFill()
    bounds.fill()
    let fitted = imageRect
    guard let image = image, fitted.width > 0, fitted.height > 0 else { return }
    image.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high.rawValue])
    NSColor.white.withAlphaComponent(0.12).setStroke()
    let border = NSBezierPath(rect: fitted.insetBy(dx: -0.5, dy: -0.5))
    border.lineWidth = 1
    border.stroke()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsDisplay = true
  }
}
