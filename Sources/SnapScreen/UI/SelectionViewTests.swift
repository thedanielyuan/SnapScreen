import AppKit

private enum SelectionTestError: Error { case failed(String) }

func runSelectionViewTests() throws -> Int {
  var count = 0
  func check(_ value: Bool, _ name: String) throws {
    guard value else { throw SelectionTestError.failed(name) }
    count += 1
  }
  func near(_ left: CGFloat, _ right: CGFloat) -> Bool { abs(left - right) < 0.000_001 }
  func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: isRepeat, keyCode: code)!
  }
  let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
  func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }
  view.image = NSImage(size: NSSize(width: 2000, height: 1000))
  let fitted = view.imageRect
  try check(fitted == CGRect(x: 8, y: 154, width: 984, height: 492), "landscape is fitted with letterboxing")
  try check(view.selection == nil && view.selectionSummary == "No region selected.",
    "no region is preselected")
  try check(SelectionView.instruction == "Drag to select a region. Click to cancel",
    "the visible instruction says how to select and cancel")
  try check(view.isAccessibilityElement() && view.accessibilityRole() == .layoutArea,
    "selection is exposed as an accessible selection area")
  try check(view.accessibilityHelp()?.contains("Shift with arrow keys") == true,
    "keyboard selection is described to assistive technology")

  var confirmations = [NormalizedRect]()
  var cancellations = 0
  view.onConfirm = { confirmations.append($0) }
  view.onCancel = { cancellations += 1 }

  view.keyDown(with: key(124))
  try check(view.selection == nil, "arrow keys wait for a keyboard selection")
  view.keyDown(with: key(36))
  let placed = view.selection!
  try check(view.isKeyboardSelection && confirmations.isEmpty, "Return first places a keyboard selection")
  try check(near(placed.width * fitted.width, 320) && near(placed.height * fitted.height, 180) &&
    near(placed.midX, 0.5) && near(placed.midY, 0.5), "keyboard selection is centred at 320 × 180 points")
  try check(view.accessibilityValue() as? String == view.selectionSummary &&
    view.selectionSummary.hasSuffix("from top."), "accessible value reports the screenshot pixels")
  view.keyDown(with: key(124))
  try check(near(view.selection!.minX, placed.minX + 10 / fitted.width) && near(view.selection!.minY, placed.minY),
    "right arrow moves ten display points")
  view.keyDown(with: key(125, .option))
  try check(near(view.selection!.minY, placed.minY + 1 / fitted.height), "Option makes a one-point adjustment")
  let origin = view.selection!.origin
  view.keyDown(with: key(123, .shift))
  view.keyDown(with: key(126, .shift))
  try check(view.selection!.origin == origin && near(view.selection!.width * fitted.width, 310) &&
    near(view.selection!.height * fitted.height, 170), "Shift + arrows resize without moving the corner")

  view.selection = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
  view.keyDown(with: key(123))
  view.keyDown(with: key(126))
  try check(view.selection!.origin == .zero, "moving is clamped at the top-left image edges")
  view.selection = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
  view.keyDown(with: key(124))
  view.keyDown(with: key(125))
  view.keyDown(with: key(124, .shift))
  view.keyDown(with: key(125, .shift))
  try check(view.selection == CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
    "moving and resizing are clamped at the bottom-right image edges")
  view.selection = CGRect(x: 0, y: 0, width: 12 / fitted.width, height: 12 / fitted.height)
  view.keyDown(with: key(123, .shift))
  view.keyDown(with: key(126, .shift))
  try check(near(view.selection!.width * fitted.width, 5) && near(view.selection!.height * fitted.height, 5),
    "keyboard shrinking stops at the five-point minimum")
  view.keyDown(with: key(36, repeat: true))
  try check(confirmations.isEmpty, "a held Return does not ask")
  view.keyDown(with: key(76))
  try check(confirmations.count == 1 && near(confirmations[0].width * fitted.width, 5),
    "keypad Enter asks about the five-point minimum")
  try check(view.accessibilityPerformPress() && confirmations.count == 2,
    "accessible press asks about a valid selection")
  view.selection = CGRect(x: 0.25, y: 0.25, width: 1 / fitted.width, height: 1 / fitted.height)
  view.keyDown(with: key(36))
  try check(confirmations.count == 2 && view.selectionSummary.contains("Enlarge"),
    "a tiny selection is refused with feedback")
  try check(!view.accessibilityPerformPress(), "accessible press enforces the same minimum")

  let previous = view.selection
  view.keyDown(with: key(0))
  view.keyDown(with: key(48))
  try check(view.selection == previous && confirmations.count == 2 && cancellations == 0,
    "other keys are consumed without selection actions")

  let actions = view.accessibilityCustomActions() ?? []
  view.selection = nil
  let right = actions.first { $0.name == "Move right" }
  try check(right?.handler?() == true && view.isKeyboardSelection && view.selection != nil,
    "VoiceOver movement first places the keyboard selection")
  try check(right?.handler?() == true, "VoiceOver movement applies the keyboard operation")
  let cancel = actions.first { $0.name == "Cancel selection" }
  try check(cancel?.handler?() == true && cancellations == 1, "VoiceOver can cancel without pointer input")

  // Pointer: drag and release asks; a click cancels; a drag from the margin starts at the edge.
  let inside = CGPoint(x: fitted.minX + 10, y: fitted.minY + 10)
  view.mouseDown(with: mouse(.leftMouseDown, inside))
  try check(view.isDragging && !view.isKeyboardSelection, "a drag replaces the keyboard selection")
  view.mouseUp(with: mouse(.leftMouseUp, inside))
  try check(confirmations.count == 2 && cancellations == 2 && view.selection == nil && !view.isDragging,
    "click without dragging cancels")
  view.mouseDown(with: mouse(.leftMouseDown, inside))
  view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: fitted.midX, y: fitted.midY)))
  try check(view.selectionDisplayRect.map { near($0.minX, inside.x) && near($0.maxX, fitted.midX) } == true,
    "the dragged region is reported in view coordinates")
  view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: fitted.maxX + 30, y: fitted.maxY + 30)))
  try check(confirmations.count == 3 && near(confirmations[2].x, 10 / fitted.width) &&
    near(confirmations[2].y, 10 / fitted.height) && near(confirmations[2].x + confirmations[2].width, 1) &&
    near(confirmations[2].y + confirmations[2].height, 1), "release asks about a drag clamped to the image")
  view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: fitted.minX - 6, y: fitted.minY - 6)))
  view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: fitted.minX + 100, y: fitted.minY + 50)))
  try check(confirmations.count == 4 && confirmations[3].x == 0 && confirmations[3].y == 0,
    "a drag starting in the margin begins at the image edge")

  view.selection = CGRect(x: 0.1004, y: 0.1004, width: 0.1004, height: 0.1004)
  try check(view.selectionSummary == "201 × 101 pixels, 201 from left, 100 from top.",
    "pixel summary rounds crop edges rather than width independently")
  let beforeResize = view.selection
  view.setFrameSize(NSSize(width: 500, height: 900))
  try check(view.selection == beforeResize, "window resizing preserves the normalized selection")
  view.keyDown(with: key(124))
  try check(near(view.selection!.minX - beforeResize!.minX, 10 / view.imageRect.width),
    "keyboard steps follow the newly fitted image after resizing")
  view.image = NSImage(size: NSSize(width: 1000, height: 2000))
  view.selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
  try check(view.selectionSummary == "500 × 1000 pixels, 250 from left, 500 from top.",
    "portrait summary uses screenshot dimensions rather than view dimensions")
  view.image = nil
  view.confirm()
  try check(view.imageRect == .zero && view.selectionSummary == "No screenshot available." && confirmations.count == 4,
    "cleared screenshots cannot be confirmed or exposed in feedback")

  // Normalizing and rescaling can land a hair under the minimum at some widths, such as 77 points.
  let narrow = SelectionView(frame: CGRect(x: 0, y: 0, width: 93, height: 400))
  narrow.image = NSImage(size: NSSize(width: 77, height: 77))
  try check(narrow.imageRect.width == 77, "the rounding fixture fits a 77-point image")
  narrow.selection = CGRect(x: 0, y: 0, width: 5.0 / 77, height: 5.0 / 77)
  try check(5.0 / 77 * 77 < 5 && narrow.canConfirm, "a five-point selection is accepted despite rounding")

  let preview = PreviewView(image: NSImage(size: NSSize(width: 200, height: 100)))
  preview.setFrameSize(NSSize(width: 1000, height: 800))
  try check(preview.imageRect.size == CGSize(width: 200, height: 100), "preview never enlarges a small crop")
  preview.setFrameSize(NSSize(width: 124, height: 400))
  try check(preview.imageRect.width == 100 && preview.imageRect.height == 50, "preview fits a large crop")
  preview.image = nil
  try check(preview.imageRect == .zero && !preview.isAccessibilityElement(), "a cleared preview exposes nothing")

  // The standalone app's overlay fills its view with the frozen display.
  let overlay = SelectionView(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
  overlay.fillsBounds = true
  try check(overlay.imageRect == .zero, "an overlay without a screenshot has nothing to select")
  overlay.image = NSImage(size: NSSize(width: 2880, height: 1800))
  try check(overlay.imageRect == overlay.bounds, "the overlay's screenshot fills it, with no margin or title bar inset")
  var overlayConfirmations = [NormalizedRect]()
  overlay.onConfirm = { overlayConfirmations.append($0) }
  func overlayMouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: overlay.convert(point, to: nil), modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }
  overlay.mouseDown(with: overlayMouse(.leftMouseDown, CGPoint(x: 144, y: 90)))
  overlay.mouseUp(with: overlayMouse(.leftMouseUp, CGPoint(x: 720, y: 450)))
  try check(overlayConfirmations.count == 1 && near(overlayConfirmations[0].x, 0.1) && near(overlayConfirmations[0].y, 0.1) &&
    near(overlayConfirmations[0].width, 0.4) && near(overlayConfirmations[0].height, 0.4),
    "an overlay drag selects the same fraction of the display")
  try check(overlay.selectionDisplayRect == CGRect(x: 144, y: 90, width: 576, height: 360),
    "the overlay reports the selection where it is on the display")
  overlay.selection = nil
  overlay.placeKeyboardSelection()
  try check(overlay.selectionDisplayRect == CGRect(x: 560, y: 360, width: 320, height: 180),
    "the overlay's keyboard selection is centred at 320 × 180 points")

  // Outside the selection the screenshot is dimmed by 35%; inside it isn't, whether fitted or filled.
  func red(_ view: NSView, _ point: CGPoint) -> CGFloat? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)?.redComponent
  }
  let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
  context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
  let solidRed = NSImage(cgImage: context.makeImage()!, size: NSSize(width: 40, height: 20))
  for fills in [false, true] {
    let dimmed = SelectionView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
    dimmed.fillsBounds = fills
    dimmed.image = solidRed
    dimmed.selection = CGRect(x: 0, y: 0, width: 0.5, height: 1)
    let fitted = dimmed.imageRect
    let inside = red(dimmed, CGPoint(x: fitted.minX + fitted.width * 0.25, y: fitted.midY)) ?? 0
    let outside = red(dimmed, CGPoint(x: fitted.minX + fitted.width * 0.9, y: fitted.midY)) ?? 0
    // Inside, only the selection's light tint changes the colour.
    try check(inside > 0.85 && abs(outside - 0.65) < 0.03,
      fills ? "the overlay dims only outside the selection" : "the selection window dims only outside the selection")
  }
  return count
}
