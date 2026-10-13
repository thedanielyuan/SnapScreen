import AppKit

/// The panel that covers a display with its frozen image, for selecting a region. It stays
/// non-opaque: the native prototype and Phase 4's acceptance round found that a screen-sized
/// non-opaque panel caused no visibility change in Chrome, and an opaque one could make Chrome
/// mark the page as hidden. It never takes the keyboard or activates the app.
enum SelectionOverlay {
  static let title = "SnapScreen — Select region"

  static func make(covering screen: NSScreen) -> CompanionPanel {
    let panel = CompanionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.title = title
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    // Above the menu bar, the Dock and SnapScreen's own floating panels.
    panel.level = .screenSaver
    panel.animationBehavior = .none
    panel.acceptsMouseMovedEvents = true
    panel.setFrame(screen.frame, display: false)
    return panel
  }
}

/// macOS shows only the frontmost app's cursor changes, and SnapScreen never activates, so on its
/// own the overlay's crosshair shows only when SnapScreen happens to be frontmost, such as after
/// Settings. The window server's private SetsCursorInBackground connection property lets an app
/// set the cursor from the background, so the overlay turns it on while it's up.
enum BackgroundCursor {
  private typealias MainConnection = @convention(c) () -> Int32
  private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

  private static let functions: (MainConnection, SetProperty)? = {
    guard let graphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
      let connection = dlsym(graphics, "CGSMainConnectionID"),
      let setProperty = dlsym(graphics, "CGSSetConnectionProperty") else { return nil }
    return (unsafeBitCast(connection, to: MainConnection.self), unsafeBitCast(setProperty, to: SetProperty.self))
  }()

  static var isAvailable: Bool { functions != nil }

  static func setEnabled(_ enabled: Bool) {
    guard let (connection, setProperty) = functions else { return }
    let id = connection()
    _ = setProperty(id, id, "SetsCursorInBackground" as CFString, (enabled ? kCFBooleanTrue : kCFBooleanFalse)!)
  }
}
