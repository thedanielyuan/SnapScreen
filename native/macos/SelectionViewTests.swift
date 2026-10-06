import AppKit

private enum SelectionTestError: Error { case failed(String) }

func runSelectionViewTests() throws -> Int {
  var count = 0
  func check(_ value: Bool, _ name: String) throws {
    guard value else { throw SelectionTestError.failed(name) }
    count += 1
  }
  func near(_ left: CGFloat, _ right: CGFloat) -> Bool { abs(left - right) < 0.000_001 }
  func key(_ code: UInt16, shift: Bool = false) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
      timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: code)!
  }
  let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
  func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }
  view.image = NSImage(size: NSSize(width: 2000, height: 1000))
  let fitted = view.imageRect
  try check(fitted == CGRect(x: 12, y: 156, width: 976, height: 488), "landscape is fitted with letterboxing")
  try check(view.selectionSummary == "1000 × 500 pixels, 500 from left, 250 from top.",
    "selection feedback uses screenshot pixels and top-left origin")
  try check(view.isAccessibilityElement() && view.accessibilityRole() == .layoutArea,
    "selection is exposed as an accessible selection area")
  try check(view.accessibilityValue() as? String == view.selectionSummary,
    "accessible selection value contains the visible geometry")
  try check(view.accessibilityHelp()?.contains("Shift and arrow keys") == true,
    "selection exposes keyboard help")

  var reported = ""
  view.onSelectionChange = { reported = $0 }
  try check(reported == view.selectionSummary, "summary callback supplies initial selection")
  view.keyDown(with: key(124))
  try check(near(view.selection.minX, 0.25 + 1 / fitted.width) && view.selection.minY == 0.25,
    "right arrow moves one fitted display point without moving down")
  view.keyDown(with: key(125))
  try check(near(view.selection.minY, 0.25 + 1 / fitted.height),
    "down arrow moves one fitted display point toward screenshot bottom")
  try check(reported == view.selectionSummary && reported != "1000 × 500 pixels, 500 from left, 250 from top.",
    "keyboard movement updates the summary and accessibility value")
  let origin = view.selection.origin
  view.keyDown(with: key(123, shift: true))
  view.keyDown(with: key(126, shift: true))
  try check(view.selection.origin == origin && near(view.selection.width, 0.5 - 1 / fitted.width) &&
    near(view.selection.height, 0.5 - 1 / fitted.height), "shift arrows resize without moving the top-left corner")

  view.selection = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
  view.keyDown(with: key(123))
  view.keyDown(with: key(126))
  try check(view.selection.origin == .zero, "moving is clamped at top-left image edges")
  view.selection = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
  view.keyDown(with: key(124))
  view.keyDown(with: key(125))
  view.keyDown(with: key(124, shift: true))
  view.keyDown(with: key(125, shift: true))
  try check(view.selection == CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
    "moving and resizing are clamped at bottom-right image edges")
  view.selection = CGRect(x: 0, y: 0, width: 1 / fitted.width, height: 1 / fitted.height)
  view.keyDown(with: key(123, shift: true))
  view.keyDown(with: key(126, shift: true))
  try check(near(view.selection.width * fitted.width, 1) && near(view.selection.height * fitted.height, 1),
    "keyboard shrinking retains a positive one-point selection")

  var confirmations = [NormalizedRect]()
  var cancellations = 0
  view.onConfirm = { confirmations.append($0) }
  view.onCancel = { cancellations += 1 }
  view.keyDown(with: key(36))
  try check(confirmations.isEmpty && cancellations == 0 && view.selectionSummary.contains("Enlarge"),
    "Return refuses tiny selection with feedback and permits continued adjustment")
  try check(!view.accessibilityPerformPress(), "accessible confirmation enforces the same minimum")
  view.selection = CGRect(x: 0.25, y: 0.25, width: 5 / fitted.width, height: 5 / fitted.height)
  view.keyDown(with: key(76))
  try check(confirmations.count == 1 && near(confirmations[0].width * fitted.width, 5),
    "keypad Enter accepts the five-point minimum")
  try check(view.accessibilityPerformPress() && confirmations.count == 2,
    "accessible confirmation submits a valid selection")

  let previous = view.selection
  view.keyDown(with: key(0))
  try check(view.selection == previous && confirmations.count == 2 && cancellations == 0,
    "unknown keyboard input is consumed without selection actions")
  view.keyDown(with: key(53))
  try check(cancellations == 1, "Escape cancels selection")

  let actions = view.accessibilityCustomActions() ?? []
  let right = actions.first { $0.name == "Move right" }
  try check(right?.handler?() == true && view.selection.minX > previous.minX,
    "VoiceOver movement applies the same keyboard selection operation")
  let cancel = actions.first { $0.name == "Cancel selection" }
  try check(cancel?.handler?() == true && cancellations == 2, "VoiceOver can cancel without pointer input")

  // Letterbox clicks must not submit the existing default selection or start a drag.
  let outside = CGPoint(x: fitted.midX, y: fitted.minY - 1)
  view.mouseDown(with: mouse(.leftMouseDown, outside))
  view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: fitted.midX, y: fitted.midY)))
  try check(confirmations.count == 2 && cancellations == 2, "letterbox clicks do not start selection")
  let inside = CGPoint(x: fitted.minX + 10, y: fitted.minY + 10)
  view.mouseDown(with: mouse(.leftMouseDown, inside))
  view.mouseUp(with: mouse(.leftMouseUp, inside))
  try check(confirmations.count == 2 && cancellations == 3, "click without dragging cancels")
  view.mouseDown(with: mouse(.leftMouseDown, inside))
  view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: fitted.maxX + 30, y: fitted.maxY + 30)))
  try check(confirmations.count == 3 && near(confirmations[2].x, 10 / fitted.width) &&
    near(confirmations[2].y, 10 / fitted.height) && near(confirmations[2].x + confirmations[2].width, 1) &&
    near(confirmations[2].y + confirmations[2].height, 1), "release submits a drag clamped to fitted image edges")

  view.selection = CGRect(x: 0.1004, y: 0.1004, width: 0.1004, height: 0.1004)
  try check(view.selectionSummary == "201 × 101 pixels, 201 from left, 100 from top.",
    "pixel summary rounds crop edges rather than width independently")
  let beforeResize = view.selection
  view.setFrameSize(NSSize(width: 500, height: 900))
  try check(view.selection == beforeResize, "window resizing preserves normalized selection")
  view.keyDown(with: key(124))
  try check(near(view.selection.minX - beforeResize.minX, 1 / view.imageRect.width),
    "keyboard increments follow the newly fitted image after window resizing")
  view.image = NSImage(size: NSSize(width: 1000, height: 2000))
  view.selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
  try check(view.selectionSummary == "500 × 1000 pixels, 250 from left, 500 from top.",
    "portrait summary uses screenshot dimensions rather than view dimensions")
  view.image = nil
  view.confirm()
  try check(view.imageRect == .zero && view.selectionSummary == "No screenshot available." && confirmations.count == 3,
    "cleared screenshots cannot be confirmed or exposed in feedback")
  return count
}
