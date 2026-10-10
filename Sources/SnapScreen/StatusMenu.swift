import AppKit

/// The menu bar icon and its menu: Snip, Close All Conversations, Settings… and Quit.
enum StatusMenu {
  /// `shortcut` is nil when another app has the combination, so the menu doesn't promise it. The
  /// target enables Close All Conversations only while one is open.
  static func make(target: AnyObject, snip: Selector, closeAll: Selector, settings: Selector,
    shortcut: Hotkey.Combination?) -> NSMenu {
    let menu = NSMenu(title: "SnapScreen")
    let snipItem = menu.addItem(withTitle: "Snip", action: snip, keyEquivalent: shortcut?.menuKey ?? "")
    snipItem.keyEquivalentModifierMask = shortcut?.menuModifiers ?? []
    snipItem.target = target
    let closeAllItem = menu.addItem(withTitle: "Close All Conversations", action: closeAll, keyEquivalent: "")
    closeAllItem.target = target
    let settingsItem = menu.addItem(withTitle: "Settings…", action: settings, keyEquivalent: ",")
    settingsItem.target = target
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit SnapScreen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    return menu
  }

  static var icon: NSImage? {
    let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "SnapScreen")
    image?.isTemplate = true
    return image
  }
}
