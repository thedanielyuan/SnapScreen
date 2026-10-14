#if SNAPSCREEN_TEST_HOOKS
import AppKit
import SnapScreenCore

struct FocusTestFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// The same failure scenarios run through CI's window driver and the opt-in WindowServer driver.
/// Only the latter posts real input; both preserve the foreground app and use fixture data.
@MainActor
struct FocusTestDriver {
  let screen: NSScreen
  let capture: FrozenScreen
  let require: (Bool, String) throws -> Void
  let wait: (String, @escaping @MainActor () -> Bool) async throws -> Void
  let probe: (String) async throws -> Void
  let select: (SessionWindows) async throws -> Void
  let click: (NSView) async throws -> Void
  /// A right-click at a view's center, or a control-click when the flag is set.
  let contextClick: (NSView, Bool) async throws -> Void
  let movePointer: (NSPoint) async throws -> Void
  let checkPanel: (PassivePanel, String) throws -> Void
  let checkContextMenu: (NSTextView) async throws -> Void

  /// Right-clicks, then control-clicks, text that must open no native menu: its tracking would take
  /// the foreground window's key status and keystrokes. Typing follows each click.
  func checkNoNativeMenu(on view: NSView, _ stage: String) async throws {
    for control in [false, true] {
      let gesture = control ? "control-click" : "right-click"
      let watch = NativeMenuWatch()
      defer { watch.stop() }
      try await contextClick(view, control)
      try await probe("after a \(gesture) on \(stage)")
      try require(watch.menus.isEmpty, "a \(gesture) on \(stage) opens no native menu: \(watch.menus)")
    }
  }
}

/// Records each native menu that begins tracking in this process, and ends it at once, so a
/// regression fails a check instead of leaving a menu holding the keyboard.
@MainActor
final class NativeMenuWatch {
  private(set) var menus: [String] = []
  private var observer: NSObjectProtocol?

  init() {
    observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
      queue: nil) { [weak self] note in
      guard let menu = note.object as? NSMenu else { return }
      let title = menu.items.first?.title ?? "untitled"
      MainActor.assumeIsolated { self?.menus.append(title) }
      menu.perform(#selector(NSMenu.cancelTracking), with: nil, afterDelay: 0.2, inModes: [.common])
    }
  }

  func stop() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }
}
#endif
