import AppKit
import CoreGraphics
import ServiceManagement

/// Screen Recording, which capturing the screen needs.
enum ScreenRecordingAccess {
  /// Checks without asking. macOS applies a change only after SnapScreen restarts, and offers to
  /// quit and reopen it.
  static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

  private static let settingsURL =
    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

  /// Opens Screen Recording in System Settings. Asking first lists SnapScreen there; macOS shows
  /// its own prompt the first time only.
  static func openSystemSettings() {
    if !isGranted { CGRequestScreenCaptureAccess() }
    NSWorkspace.shared.open(settingsURL)
  }
}

/// Open at login, so the self-test can replace the system's login items.
protocol LoginItem: AnyObject {
  var isEnabled: Bool { get }
  /// Registered, but waiting for the user to allow it in System Settings.
  var needsApproval: Bool { get }
  func setEnabled(_ enabled: Bool) throws
  func openSystemSettings()
}

/// The app itself as a login item, through SMAppService.
final class MainAppLoginItem: LoginItem {
  var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
  var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

  func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else if SMAppService.mainApp.status != .notRegistered {
      try SMAppService.mainApp.unregister()
    }
  }

  func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
