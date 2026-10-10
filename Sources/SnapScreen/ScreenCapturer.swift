import AppKit
import ScreenCaptureKit
import SnapScreenCore

/// Freezes one display with ScreenCaptureKit, at full pixel resolution, without the cursor or
/// SnapScreen's own windows. Nothing is written to disk.
enum ScreenCapturer {
  private struct DisplayNotFound: Error {}

  static func capture(displayID: CGDirectDisplayID) async throws -> FrozenScreen {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw DisplayNotFound() }
      let ownProcess = ProcessInfo.processInfo.processIdentifier
      let filter = SCContentFilter(display: display,
        excludingApplications: content.applications.filter { $0.processID == ownProcess }, exceptingWindows: [])
      let configuration = SCStreamConfiguration()
      let scale = CGFloat(filter.pointPixelScale)
      configuration.width = Int((filter.contentRect.width * scale).rounded())
      configuration.height = Int((filter.contentRect.height * scale).rounded())
      configuration.showsCursor = false
      configuration.captureResolution = .best
      let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
      return FrozenScreen(image: image, displayID: displayID)
    } catch let error as SCStreamError where error.code == .userDeclined {
      throw CaptureError("SnapScreen needs Screen Recording permission to snip.")
    }
  }
}

extension NSScreen {
  var displayID: CGDirectDisplayID? {
    deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
  }
}
