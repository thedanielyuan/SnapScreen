import AppKit

/// The menu bar icon and its menu: Snip, Close All Conversations, Settings… and Quit.
enum StatusMenu {
  /// `shortcut` is nil when another app has the combination, so the menu doesn't promise it.
  /// Its hint describes the Carbon hot key; the menu itself never takes keyboard input.
  static func make(snip: @escaping () -> Void, closeAll: @escaping () -> Void,
    settings: @escaping () -> Void, quit: @escaping () -> Void, canCloseAll: Bool,
    shortcut: Hotkey.Combination?) -> [PassiveMenuItem] {
    [
      PassiveMenuItem(title: "Snip", hint: shortcut?.display, action: snip),
      PassiveMenuItem(title: "Close All Conversations", isEnabled: canCloseAll, action: closeAll),
      PassiveMenuItem(title: "Settings…", action: settings),
      PassiveMenuItem(title: "Quit SnapScreen", separatorBefore: true, action: quit),
    ]
  }

  static var icon: NSImage? {
    let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "SnapScreen")
    image?.isTemplate = true
    return image
  }
}
