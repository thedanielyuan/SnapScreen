import AppKit

/// A selection as fractions of the image's width and height, from its top-left corner.
struct NormalizedRect {
  let x: Double
  let y: Double
  let width: Double
  let height: Double

  var isValid: Bool {
    [x, y, width, height].allSatisfy { $0.isFinite } &&
      x >= 0 && y >= 0 && width > 0 && height > 0 &&
      x + width <= 1 && y + height <= 1
  }
}

/// Fits an image inside `bounds`, centred, after an equal inset on every side. `maximumScale`
/// prevents enlarging an image beyond the size it was captured at.
func fittedImageRect(_ imageSize: CGSize, in bounds: CGRect, inset: CGFloat = 12,
  maximumScale: CGFloat = .greatestFiniteMagnitude) -> CGRect {
  guard imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0,
    bounds.width > inset * 2, bounds.height > inset * 2 else { return .zero }
  let available = bounds.insetBy(dx: inset, dy: inset)
  let scale = min(available.width / imageSize.width, available.height / imageSize.height, maximumScale)
  let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
  return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
    width: size.width, height: size.height)
}

func selectionMeetsMinimum(_ selection: CGRect, in fitted: CGRect, minimum: CGFloat = 5) -> Bool {
  // Normalizing and rescaling can land a hair under the minimum (for example 5 / 77 * 77).
  let tolerance: CGFloat = 0.000_1
  return [selection.width, selection.height, fitted.width, fitted.height].allSatisfy { $0.isFinite } &&
    selection.width * fitted.width >= minimum - tolerance && selection.height * fitted.height >= minimum - tolerance
}

func isNearFrameEdge(_ point: CGPoint, _ frame: CGRect, margin: CGFloat = 8) -> Bool {
  !frame.insetBy(dx: margin, dy: margin).contains(point)
}

/// Content size for a window that shows an image with `chrome` around it (margins and title bar).
/// The image is never shown larger than captured (its pixels at the display's backing scale), so
/// the window hugs the image instead of letterboxing it.
func imageWindowContentSize(_ imageSize: CGSize, backingScale: CGFloat, maximum: CGSize,
  minimum: CGSize, chrome: CGSize) -> CGSize {
  guard imageSize.width > 0, imageSize.height > 0 else { return minimum }
  let scale = max(1, backingScale)
  let natural = CGSize(width: imageSize.width / scale, height: imageSize.height / scale)
  let available = CGSize(width: max(1, maximum.width - chrome.width), height: max(1, maximum.height - chrome.height))
  let fit = min(1, available.width / natural.width, available.height / natural.height)
  return CGSize(width: max(minimum.width, (natural.width * fit + chrome.width).rounded()),
    height: max(minimum.height, (natural.height * fit + chrome.height).rounded()))
}

/// Places a window beside an on-screen region (screen coordinates, origin bottom-left): to its
/// right, else its left, else below or above it. The frame always stays within `visible`.
func windowFrame(size: CGSize, beside region: CGRect?, in visible: CGRect, gap: CGFloat = 16) -> CGRect {
  let width = min(size.width, visible.width)
  let height = min(size.height, visible.height)
  func frame(_ x: CGFloat, _ y: CGFloat) -> CGRect {
    CGRect(x: min(max(x, visible.minX), visible.maxX - width).rounded(),
      y: min(max(y, visible.minY), visible.maxY - height).rounded(), width: width, height: height)
  }
  guard let region = region, region.width > 0, region.height > 0 else {
    return frame(visible.midX - width / 2, visible.midY - height / 2)
  }
  if region.maxX + gap + width <= visible.maxX { return frame(region.maxX + gap, region.maxY - height) }
  if region.minX - gap - width >= visible.minX { return frame(region.minX - gap - width, region.maxY - height) }
  if region.minY - gap - height >= visible.minY { return frame(region.midX - width / 2, region.minY - gap - height) }
  if region.maxY + gap + height <= visible.maxY { return frame(region.midX - width / 2, region.maxY + gap) }
  // A region that fills the screen leaves no free side; the right edge covers the least of most pages.
  return frame(visible.maxX - gap - width, visible.midY - height / 2)
}

/// Where a window opens while it's only `height` tall, when `largest` is the frame `windowFrame`
/// gave it at its largest size, so it can grow there. Beside the region, it's level with the
/// region's top, as `windowFrame` places a window that tall; above the region, it keeps the bottom
/// edge; otherwise it keeps the top edge.
func openingFrame(_ largest: CGRect, height: CGFloat, beside region: CGRect?, in visible: CGRect) -> CGRect {
  let height = min(height, largest.height)
  let y: CGFloat
  if let region = region, largest.minY >= region.maxY {
    y = largest.minY
  } else if let region = region, largest.maxX <= region.minX || largest.minX >= region.maxX {
    y = min(max(region.maxY - height, visible.minY), visible.maxY - height).rounded()
  } else {
    y = largest.maxY - height
  }
  return CGRect(x: largest.minX, y: y, width: largest.width, height: height)
}

/// Grows a window's frame to `height`, at most `maximumHeight`, and never shrinks it. It grows
/// down from its top edge, or up from its bottom edge, then the other way at the screen's edge.
func grownFrame(_ frame: CGRect, toHeight height: CGFloat, maximumHeight: CGFloat, upward: Bool = false,
  in visible: CGRect) -> CGRect {
  let target = min(height, maximumHeight, visible.height)
  guard target > frame.height else { return frame }
  let y = upward ? frame.minY : frame.maxY - target
  return CGRect(x: frame.minX, y: min(max(y, visible.minY), visible.maxY - target), width: frame.width,
    height: target)
}

/// The screen the user is working on: the one under the pointer that invoked SnapScreen.
func screenUnderPointer() -> NSScreen? {
  let point = NSEvent.mouseLocation
  return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
}
