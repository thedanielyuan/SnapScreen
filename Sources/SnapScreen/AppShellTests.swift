import AppKit
import Carbon.HIToolbox

private enum AppShellTestError: Error { case failed(String) }

/// The shortcut, menus, notices and Keychain store. Windows stay offscreen. The Keychain checks use
/// their own service and remove what they add.
func runAppShellTests() throws -> Int {
  var count = 0
  func check(_ value: Bool, _ name: String) throws {
    guard value else { throw AppShellTestError.failed(name) }
    count += 1
  }
  _ = NSApplication.shared

  let snip = Hotkey.Combination.snip
  try check(snip.keyCode == UInt32(kVK_ANSI_S) && snip.modifiers == UInt32(optionKey | shiftKey) && snip.display == "⌥⇧S",
    "the shortcut is ⌥⇧S")
  // A combination nobody uses, so the check never takes a real shortcut.
  let unused = Hotkey.Combination(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
    display: "⌃⌥⇧⌘F19", menuKey: "", menuModifiers: [])
  let first = Hotkey(unused)
  let second = Hotkey(unused)
  try check(first.register(), "a free shortcut registers")
  try check(!second.register(), "a shortcut that's already registered is reported as taken")
  first.unregister()
  try check(second.register(), "an unregistered shortcut is free again")
  second.unregister()

  final class MenuTarget: NSObject {
    var snips = 0
    var settings = 0
    @objc func snip() { snips += 1 }
    @objc func showSettings() { settings += 1 }
  }
  let target = MenuTarget()
  let menu = StatusMenu.make(target: target, snip: #selector(MenuTarget.snip), settings: #selector(MenuTarget.showSettings),
    shortcut: .snip)
  try check(menu.items.map(\.title) == ["Snip", "Settings…", "", "Quit SnapScreen"] && menu.items[2].isSeparatorItem,
    "the menu has Snip, Settings… and Quit")
  try check(menu.items[0].keyEquivalent == "s" && menu.items[0].keyEquivalentModifierMask == [.option, .shift],
    "Snip shows its shortcut")
  try check(menu.items[3].action == #selector(NSApplication.terminate(_:)) && menu.items[3].keyEquivalent == "q",
    "Quit terminates the app")
  menu.performActionForItem(at: 0)
  menu.performActionForItem(at: 1)
  try check(target.snips == 1 && target.settings == 1, "Snip and Settings… reach the app")
  let taken = StatusMenu.make(target: target, snip: #selector(MenuTarget.snip), settings: #selector(MenuTarget.showSettings),
    shortcut: nil)
  try check(taken.items[0].keyEquivalent.isEmpty, "a shortcut another app has isn't shown")
  try check(StatusMenu.icon?.isTemplate == true, "the menu bar icon adapts to the menu bar")

  installEditingMenu(applicationName: "SnapScreen")
  let edit = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu
  try check(edit?.item(withTitle: "Copy")?.action == #selector(NSText.copy(_:)) &&
    edit?.item(withTitle: "Paste")?.keyEquivalent == "v" && edit?.item(withTitle: "Select All")?.keyEquivalent == "a",
    "the Edit menu gives Settings' fields copy and paste")
  try check(NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Close window")?.keyEquivalent == "w",
    "Command-W closes a window")

  var performed = 0
  var closed = 0
  let notice = NoticePanelView(message: "SnapScreen needs Screen Recording permission to snip.",
    action: NoticeAction(title: "Open System Settings") { performed += 1 }, onClose: { closed += 1 })
  try check(notice.messageLabel.stringValue == "SnapScreen needs Screen Recording permission to snip." &&
    notice.actionButton?.title == "Open System Settings", "a notice shows its message and action")
  notice.actionButton?.performClick(nil)
  try check(performed == 1 && closed == 1, "a notice's action runs, then closes the notice")
  notice.closeButton.performClick(nil)
  try check(performed == 1 && closed == 2 && notice.closeButton.accessibilityLabel() == "Close",
    "the close button closes the notice")
  try check(NoticePanelView(message: "Plain", action: nil, onClose: {}).actionButton == nil, "a notice may have no action")
  let panel = NoticePanel(content: NoticePanelView(message: "Plain", action: nil, onClose: {}))
  try check(!panel.canBecomeKey && !panel.canBecomeMain && panel.styleMask.contains(.nonactivatingPanel) &&
    !panel.hidesOnDeactivate, "a notice never activates SnapScreen or takes the keyboard")
  try check(notice.actionButton?.acceptsFirstMouse(for: nil) == true, "a notice's buttons act on the first click")

  let store = KeychainStore(service: "com.snapscreen.app.self-test", account: UUID().uuidString)
  defer { try? store.remove() }
  try check(!store.hasKey && (try store.read()) == nil, "no key before saving")
  try store.save("sk-ant-self-test-first")
  try check(store.hasKey && (try store.read()) == "sk-ant-self-test-first", "a saved key reads back from the Keychain")
  try store.save("sk-ant-self-test-second")
  try check((try store.read()) == "sk-ant-self-test-second", "saving again replaces the key")
  try store.remove()
  try check(!store.hasKey && (try store.read()) == nil, "Remove key deletes the Keychain item")
  try store.remove()
  try check(KeychainError(operation: .read, status: errSecAuthFailed).message ==
    "Couldn't read the API key from your Keychain because access was denied.", "a denied Keychain read is explained")
  return count
}
