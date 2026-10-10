import AppKit

/// The menu bar app: its icon and menu, the global shortcut, Settings and notices.
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let keyStore = KeychainStore()
  private let notices = NoticeCenter()
  private let hotkey = Hotkey(.snip)
  private var shortcutAvailable = false
  private var statusItem: NSStatusItem?
  private var settings: SettingsWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    installEditingMenu(applicationName: "SnapScreen")
    hotkey.onPress = { [weak self] in self?.snip() }
    shortcutAvailable = hotkey.register()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = StatusMenu.icon
    item.button?.toolTip = "SnapScreen"
    item.menu = StatusMenu.make(target: self, snip: #selector(snip), settings: #selector(showSettings),
      shortcut: shortcutAvailable ? hotkey.combination : nil)
    statusItem = item
    if !shortcutAvailable {
      notices.show("Another app is using \(hotkey.combination.display), so choose Snip from SnapScreen's menu bar icon.")
    }
    // As the extension does on install, open Settings while there's no key to use.
    if !keyStore.hasKey { showSettings() }
  }

  /// Opening the app again while it runs, from Finder or Spotlight, shows Settings.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showSettings()
    return false
  }

  @objc func snip() {
    guard ScreenRecordingAccess.isGranted else {
      notices.show("SnapScreen needs Screen Recording permission to snip.",
        action: NoticeAction(title: "Open System Settings") { ScreenRecordingAccess.openSystemSettings() })
      return
    }
    // Phase 3 of docs/standalone-app-plan.md replaces this with the selection overlay.
    notices.show("Snipping isn't built yet. It arrives in the next phase of the standalone app.")
  }

  @objc func showSettings() {
    if settings == nil {
      let controller = SettingsWindowController(services: SettingsServices(keyStore: keyStore,
        shortcut: shortcutAvailable ? hotkey.combination : nil))
      controller.onClose = { [weak self] in self?.settingsClosed() }
      settings = controller
    }
    NSApp.activate()
    settings?.window.makeKeyAndOrderFront(nil)
  }

  private func settingsClosed() {
    guard let closing = settings else { return }
    settings = nil
    closing.window.delegate = nil
    // The window is still closing, so release it afterwards.
    DispatchQueue.main.async { _ = closing }
    // Return the keyboard to the app you were using, unless another SnapScreen window is open.
    if !NSApp.windows.contains(where: { $0 !== closing.window && $0.isVisible && $0.styleMask.contains(.titled) }) {
      NSApp.hide(nil)
    }
  }
}
