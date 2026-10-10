import AppKit

/// The panel that covers a display with its frozen image, for selecting a region. It stays
/// non-opaque: the native prototype found that a screen-sized non-opaque panel caused no
/// visibility change in Chrome (docs/native-phase1-results.md), and an opaque one could make
/// Chrome mark the page as hidden. Like every SnapScreen panel, it takes the keyboard without
/// activating the app.
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
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.acceptsMouseMovedEvents = true
    panel.setFrame(screen.frame, display: false)
    return panel
  }
}
