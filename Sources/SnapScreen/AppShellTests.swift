import AppKit
import Carbon.HIToolbox

private enum AppShellTestError: Error { case failed(String) }

/// Shared by the shell and session checks, which never show these panels.
func hasPassivePanelConfiguration(_ panel: NSPanel) -> Bool {
  !panel.canBecomeKey && !panel.canBecomeMain && panel.styleMask.contains(.nonactivatingPanel) &&
    panel.isFloatingPanel && panel.becomesKeyOnlyIfNeeded && !panel.hidesOnDeactivate && !panel.canHide &&
    panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle])
}

/// The shortcut, menus, quit requests, notices and Keychain store. Windows stay offscreen. The
/// Keychain checks use their own service and remove what they add.
func runAppShellTests() throws -> Int {
  var count = 0
  func check(_ value: Bool, _ name: String) throws {
    guard value else { throw AppShellTestError.failed(name) }
    count += 1
  }
  _ = NSApplication.shared
  try check(NSApp.activationPolicy() == .accessory, "SnapScreen launches as an accessory app")
  // The bare binary also supports --self-test, but only the app bundle has an Info.plist.
  if Bundle.main.bundleIdentifier != nil {
    try check(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true,
      "the bundle is an agent with no Dock or App Switcher entry")
  }
  let passive = PassivePanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 80),
    styleMask: [.titled], backing: .buffered, defer: false)
  try check(hasPassivePanelConfiguration(passive) && passive.styleMask.contains(.titled) && passive.level == .floating,
    "passive panels preserve the requested style and install nonactivating behavior at creation")

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
    var closes = 0
    var settings = 0
    @objc func snip() { snips += 1 }
    @objc func closeAll() { closes += 1 }
    @objc func showSettings() { settings += 1 }
  }
  let target = MenuTarget()
  let menu = StatusMenu.make(target: target, snip: #selector(MenuTarget.snip), closeAll: #selector(MenuTarget.closeAll),
    settings: #selector(MenuTarget.showSettings), shortcut: .snip)
  try check(menu.items.map(\.title) == ["Snip", "Close All Conversations", "Settings…", "", "Quit SnapScreen"] &&
    menu.items[3].isSeparatorItem, "the menu has Snip, Close All Conversations, Settings… and Quit")
  try check(menu.items[0].keyEquivalent == "s" && menu.items[0].keyEquivalentModifierMask == [.option, .shift],
    "Snip shows its shortcut")
  try check(menu.items[4].action == #selector(NSApplication.terminate(_:)) && menu.items[4].keyEquivalent == "q",
    "Quit terminates the app")
  menu.performActionForItem(at: 0)
  menu.performActionForItem(at: 1)
  menu.performActionForItem(at: 2)
  try check(target.snips == 1 && target.closes == 1 && target.settings == 1,
    "Snip, Close All Conversations and Settings… reach the app")
  let taken = StatusMenu.make(target: target, snip: #selector(MenuTarget.snip), closeAll: #selector(MenuTarget.closeAll),
    settings: #selector(MenuTarget.showSettings), shortcut: nil)
  try check(taken.items[0].keyEquivalent.isEmpty, "a shortcut another app has isn't shown")
  try check(StatusMenu.icon?.isTemplate == true, "the menu bar icon adapts to the menu bar")

  try check(QuitRequest.isAccepted(nil), "Quit SnapScreen, which sends no Apple event, quits")
  func quitEvent() -> NSAppleEventDescriptor {
    NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
      targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
  }
  try check(!QuitRequest.isAccepted(quitEvent()), "a quit event from an unknown sender is refused")
  let loggingOut = quitEvent()
  loggingOut.setParam(NSAppleEventDescriptor(typeCode: OSType(kAEReallyLogOut)), forKeyword: AEKeyword(kAEQuitReason))
  try check(QuitRequest.isAccepted(loggingOut), "logging out, restarting or shutting down quits")
  try check([
    "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
    "/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor",
    "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/MacOS/SecurityPrivacyExtension",
    "/Applications/Raycast.app/Contents/MacOS/Raycast",
  ].allSatisfy { QuitRequest.isAccepted(senderPath: $0) }, "macOS and apps can quit SnapScreen")
  try check(![
    "/usr/bin/osascript", "/Applications/Xcode.app/Contents/Developer/usr/bin/python3",
    "/Users/me/build/audit/input", "/Applications/Tool.app/Contents/Resources/helper",
    "/System/Volumes/Data/Users/me/input", nil,
  ].contains { QuitRequest.isAccepted(senderPath: $0) }, "command-line tools and scripts can't quit SnapScreen")
  try check(QuitRequest.executablePath(of: 1) == "/sbin/launchd", "a quit event's sender is found from its process ID")

  installEditingMenu(applicationName: "SnapScreen")
  let edit = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu
  try check(edit?.item(withTitle: "Copy")?.action == #selector(NSText.copy(_:)) &&
    edit?.item(withTitle: "Paste")?.keyEquivalent == "v" && edit?.item(withTitle: "Select All")?.keyEquivalent == "a",
    "the Edit menu gives Settings' fields copy and paste")
  try check(NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Close window")?.keyEquivalent == "w",
    "Command-W closes Settings")

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
  try check(hasPassivePanelConfiguration(panel) && panel.level == .floating,
    "a notice floats in every Space without activating SnapScreen or taking the keyboard")
  try check(notice.actionButton?.acceptsFirstMouse(for: nil) == true, "a notice's buttons act on the first click")
  try check([NSApp.effectiveAppearance, menu.effectiveAppearance, panel.effectiveAppearance].allSatisfy {
    $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  }, "SnapScreen's windows and menus are dark whatever the system's appearance")

  let store = KeychainStore(service: "com.snapscreen.app.self-test", account: UUID().uuidString)
  defer { try? store.remove() }
  try check(!store.hasKey && (try store.read()) == nil, "no key before saving")
  try store.save("sk-ant-self-test-first")
  try check(store.hasKey && (try store.read()) == "sk-ant-self-test-first", "a saved key reads back from the Keychain")
  try store.save("sk-ant-self-test-second")
  try check((try store.read()) == "sk-ant-self-test-second", "saving again replaces the key")
  // The item trusts the binary that saved it, so it reads without asking.
  try check(KeychainPrompts.canDisallow && KeychainPrompts.areAllowed == true &&
    (try store.readWithoutPrompt()) == "sk-ant-self-test-second" && KeychainPrompts.areAllowed == true,
    "answers read the key with Keychain prompts turned off, then turn them back on")
  try check(KeychainPrompts.disallowed { KeychainPrompts.areAllowed } == false,
    "Keychain prompts are off while an answer reads the key")
  func checkBlockedRead(_ control: KeychainPrompts.InteractionControl?, _ name: String) throws {
    var readAttempted = false
    do {
      try KeychainPrompts.disallowed(using: control) { readAttempted = true }
    } catch let error as KeychainError {
      try check(!readAttempted && error == KeychainError(operation: .readWithoutPrompt,
        status: errSecInteractionNotAllowed), name)
      return
    }
    throw AppShellTestError.failed(name)
  }
  try checkBlockedRead(nil, "missing prompt-control symbols refuse the read instead of risking a password prompt")
  var promptChanges: [Bool] = []
  try checkBlockedRead(KeychainPrompts.InteractionControl(getAllowed: { nil }, setAllowed: {
    promptChanges.append($0)
    return errSecSuccess
  }), "an unreadable prompt setting refuses the read instead of guessing the prior setting")
  try check(promptChanges.isEmpty, "an unreadable prompt setting is left unchanged")
  try checkBlockedRead(KeychainPrompts.InteractionControl(getAllowed: { true }, setAllowed: {
    promptChanges.append($0)
    return errSecAuthFailed
  }), "a failure to disable prompts refuses the read instead of risking a password prompt")
  try check(promptChanges == [false], "a failed attempt to disable prompts never enables them")
  for original in [true, false] {
    var allowed = original
    var changes: [Bool] = []
    let control = KeychainPrompts.InteractionControl(getAllowed: { allowed }, setAllowed: {
      allowed = $0
      changes.append($0)
      return errSecSuccess
    })
    let duringRead = try KeychainPrompts.disallowed(using: control) { allowed }
    try check(!duringRead && allowed == original && changes == [false, original],
      "a nonprompting read restores prompts to their original setting: \(original)")
  }
  try store.remove()
  try check(!store.hasKey && (try store.read()) == nil && (try store.readWithoutPrompt()) == nil,
    "Remove key deletes the Keychain item")
  try store.remove()
  try check(KeychainError(operation: .read, status: errSecAuthFailed).message ==
    "Couldn't read the API key from your Keychain because access was denied.", "a denied Keychain read is explained")
  try check([errSecAuthFailed, errSecInteractionNotAllowed].allSatisfy {
    KeychainError(operation: .readWithoutPrompt, status: $0).message ==
      "Open SnapScreen Settings to allow access to your API key in the Keychain, then Retry."
  }, "an answer that would need a Keychain prompt sends you to Settings instead")
  return count
}
