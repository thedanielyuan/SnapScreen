import AppKit

/// Installs the main menu. An accessory app never shows a menu bar, but text fields only receive
/// Command-C, Command-V and the other editing shortcuts through the main menu's Edit items.
func installEditingMenu(applicationName: String) {
  let mainMenu = NSMenu(title: "Main")
  // AppKit reserves the first menu for the application. Keep File and Edit separate.
  let appItem = NSMenuItem(title: applicationName, action: nil, keyEquivalent: "")
  appItem.submenu = NSMenu(title: applicationName)
  mainMenu.addItem(appItem)
  let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
  let fileMenu = NSMenu(title: "File")
  // CompanionPanel closes on the key's release; this item documents the shortcut.
  fileMenu.addItem(withTitle: "Close window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
  fileItem.submenu = fileMenu
  mainMenu.addItem(fileItem)
  let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
  let editMenu = NSMenu(title: "Edit")
  editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
  let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
  redo.keyEquivalentModifierMask = [.command, .shift]
  editMenu.addItem(.separator())
  editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
  editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
  editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
  editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
  editItem.submenu = editMenu
  mainMenu.addItem(editItem)
  NSApp.mainMenu = mainMenu
}
