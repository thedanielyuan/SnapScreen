import AppKit

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

/// The screen the user is working on: the one under the pointer that invoked SnapScreen.
func screenUnderPointer() -> NSScreen? {
  let point = NSEvent.mouseLocation
  return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
}
