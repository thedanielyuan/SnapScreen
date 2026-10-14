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
  let movePointer: (NSPoint) async throws -> Void
  let checkPanel: (PassivePanel, String) throws -> Void
  let checkContextMenu: (NSTextView) async throws -> Void
}
#endif
