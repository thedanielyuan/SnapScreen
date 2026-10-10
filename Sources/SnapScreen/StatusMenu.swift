import AppKit

/// The menu bar icon and its menu: Snip, Settings… and Quit.
enum StatusMenu {
  /// `shortcut` is nil when another app has the combination, so the menu doesn't promise it.
  static func make(target: AnyObject, snip: Selector, settings: Selector, shortcut: Hotkey.Combination?) -> NSMenu {
    let menu = NSMenu(title: "SnapScreen")
    let snipItem = menu.addItem(withTitle: "Snip", action: snip, keyEquivalent: shortcut?.menuKey ?? "")
    snipItem.keyEquivalentModifierMask = shortcut?.menuModifiers ?? []
    snipItem.target = target
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
