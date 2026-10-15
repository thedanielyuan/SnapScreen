import AppKit
import Carbon.HIToolbox
import SnapScreenCore

private enum AppShellTestError: Error { case failed(String) }

/// Shared by the shell and session checks, which never show these panels.
func hasPassivePanelConfiguration(_ panel: NSPanel) -> Bool {
  !panel.canBecomeKey && !panel.canBecomeMain && panel.styleMask.contains(.nonactivatingPanel) &&
    panel.isFloatingPanel && panel.becomesKeyOnlyIfNeeded && !panel.hidesOnDeactivate && !panel.canHide &&
    panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle])
}

/// Text in a passive panel that could open the native text menu or a dragging session, each of
/// which takes the foreground window's key status: a selectable or editable label, or a text view
/// other than the read-only one with a passive menu.
func nativeTextViews(in view: NSView?) -> [NSView] {
  guard let view else { return [] }
  let native = (view as? NSTextField).map { $0.isSelectable || $0.isEditable } ??
    (view as? NSTextView).map { !($0 is ReadOnlyTextView) || $0.isEditable } ?? false
  return (native ? [view] : []) + view.subviews.flatMap { nativeTextViews(in: $0) }
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
  try check(PassivePanel.refusedEvents == [.quickLook, .pressure],
    "passive panels refuse the force click and three-finger tap that show Look Up")

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

  let menu = PassiveMenu(present: { _ in })
  var menuActions: [String] = []
  var dismissedBeforeAction = true
  func menuAction(_ name: String) {
    dismissedBeforeAction = dismissedBeforeAction && menu.panel == nil
    menuActions.append(name)
  }
  let items = StatusMenu.make(snip: { menuAction("snip") }, closeAll: { menuAction("close") },
    settings: { menuAction("settings") }, quit: { menuAction("quit") }, canCloseAll: true, shortcut: .snip)
  try check(items.map(\.title) == ["Snip", "Close All Conversations", "Settings…", "Quit SnapScreen"] &&
    items[3].separatorBefore, "the menu has Snip, Close All Conversations, Settings… and Quit")
  try check(items[0].hint == "⌥⇧S", "Snip shows its Carbon shortcut without taking keyboard input")
  menu.show(items, at: NSPoint(x: 100, y: 500))
  let menuPanel = menu.panel!
  let menuContent = menuPanel.contentView as! PassiveMenuView
  try check(hasPassivePanelConfiguration(menuPanel) && menuPanel.level == .popUpMenu,
    "pointer menus use passive panels without native menu tracking")
  try check(menuContent.buttons.allSatisfy {
    $0.acceptsFirstMouse(for: nil) && !$0.acceptsFirstResponder && !$0.canBecomeKeyView
  }, "menu commands act on the first click without accepting the keyboard")
  menuContent.buttons[0].updateTrackingAreas()
  try check(menuContent.buttons[0].trackingAreas.contains { $0.options.contains(.activeAlways) },
    "menu hover tracking works while the original app stays active")
  for index in items.indices {
    menu.show(items, at: NSPoint(x: 100, y: 500))
    (menu.panel?.contentView as? PassiveMenuView)?.buttons[index].performClick(nil)
  }
  try check(menuActions == ["snip", "close", "settings", "quit"] && dismissedBeforeAction,
    "every menu command dismisses its panel before dispatching to the app")
  menuContent.buttons[0].performClick(nil)
  try check(menuActions.count == 4, "dismissed menu rows release their actions immediately")
  let taken = StatusMenu.make(snip: {}, closeAll: { menuAction("disabled") }, settings: {}, quit: {},
    canCloseAll: false, shortcut: nil)
  try check(taken[0].hint == nil, "a shortcut another app has isn't shown")
  let anchor = NSRect(x: 40, y: 700, width: 24, height: 24)
  menu.show(taken, at: NSPoint(x: 100, y: 500), ignoringOutsideClicksIn: anchor)
  let disabled = (menu.panel?.contentView as? PassiveMenuView)?.buttons[1]
  disabled?.performClick(nil)
  try check(disabled?.isEnabled == false && menuActions.count == 4 && menu.panel != nil,
    "Close All Conversations cannot dispatch or dismiss the menu when none is open")
  menu.clickedOutside(at: NSPoint(x: anchor.midX, y: anchor.midY))
  try check(menu.panel != nil, "the menu bar button's frame is excluded so it can toggle its menu")
  menu.clickedOutside(at: NSPoint(x: -10_000, y: -10_000))
  try check(menu.panel == nil, "an outside press dismisses the menu")
  let visible = NSRect(x: -1440, y: -120, width: 1440, height: 900)
  let edgeFrame = PassiveMenu.frame(size: NSSize(width: 240, height: 120),
    at: NSPoint(x: -10, y: -100), in: visible)
  try check(visible.contains(edgeFrame), "a pointer menu stays inside a negative-origin display near its edge")
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
  // AppKit answers a request to open a file or URL that no delegate method takes, such as `open -a`
  // and Open With send, with a modal alert that activates SnapScreen and takes the keyboard.
  let delegate = AppDelegate()
  let windows = NSApp.windows.count
  delegate.application(NSApp, open: [URL(fileURLWithPath: "/tmp/snapscreen-self-test.txt"),
    URL(string: "https://example.com/snapscreen-self-test")!])
  try check(delegate.responds(to: #selector(NSApplicationDelegate.application(_:open:))) && NSApp.windows.count == windows,
    "a request from another app to open a file or URL is taken and ignored")

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
  try check(nativeTextViews(in: notice).isEmpty && nativeTextViews(in: menuContent).isEmpty &&
    nativeTextViews(in: SessionEndedView(message: "Snip again.")).isEmpty,
    "notices, menus and the Session ended message have no text that opens a native menu")
  try check([NSApp.effectiveAppearance, menuPanel.effectiveAppearance, panel.effectiveAppearance].allSatisfy {
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
  // With prompts off, a locked keychain still shows its unlock dialog, so an answer's read first
  // checks the item's keychain. The self-test's item is in the unlocked login keychain.
  let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service,
    kSecAttrAccount as String: store.account]
  try check(KeychainLock.state(of: item) == .unlocked, "the saved key's keychain reports that it's unlocked")
  func inspection(keychain: Bool = true, status: UInt32?) -> KeychainLock.Inspection {
    KeychainLock.Inspection(keychain: { keychain ? $0 : nil }, status: { _ in status })
  }
  try check(KeychainLock.state(of: item, using: inspection(status: 0)) == .locked &&
    KeychainLock.state(of: item, using: inspection(status: 7)) == .unlocked &&
    KeychainLock.state(of: item, using: inspection(status: 6)) == .locked,
    "the lock state follows the keychain's unlock flag")
  try check(KeychainLock.state(of: item, using: nil) == .unknown &&
    KeychainLock.state(of: item, using: inspection(status: nil)) == .unknown &&
    KeychainLock.state(of: item, using: inspection(keychain: false, status: 1)) == .unknown,
    "missing lock-status symbols or an unreadable status leave the state unknown")
  for state in [KeychainLock.State.locked, .unknown] {
    var checks = 0
    let guarded = KeychainStore(service: store.service, account: store.account, lockState: { _ in
      checks += 1
      return state
    })
    do {
      _ = try guarded.readForRequest()
      throw AppShellTestError.failed("an answer reads the key despite a \(state) keychain")
    } catch let error as AnthropicError {
      try check(checks == 1 && error == AnthropicError("keychain",
        KeychainError(operation: .readWithoutPrompt, status: errSecInteractionNotAllowed).message),
        "a \(state) keychain fails an answer's read before the key is read, sending you to Settings")
    }
    try check((try guarded.read()) == "sk-ant-self-test-second" && checks == 1,
      "Settings reads a \(state) keychain's key itself, where macOS may ask for the password")
  }
  try check((try KeychainStore(service: store.service, account: store.account, lockState: { _ in .missing })
    .readWithoutPrompt()) == nil, "an item that isn't found is a missing key, not a Keychain failure")
  try store.remove()
  try check(!store.hasKey && (try store.read()) == nil && (try store.readWithoutPrompt()) == nil &&
    KeychainLock.state(of: item) == .missing, "Remove key deletes the Keychain item")
  try store.remove()
  try check(KeychainError(operation: .read, status: errSecAuthFailed).message ==
    "Couldn't read the API key from your Keychain because access was denied.", "a denied Keychain read is explained")
  try check([errSecAuthFailed, errSecInteractionNotAllowed].allSatisfy {
    KeychainError(operation: .readWithoutPrompt, status: $0).message ==
      "Open SnapScreen Settings to allow access to your API key in the Keychain, then Retry."
  }, "an answer that would need a Keychain prompt sends you to Settings instead")
  return count
}
