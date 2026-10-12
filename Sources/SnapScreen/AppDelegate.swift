import AppKit
import SnapScreenCore

/// The menu bar app: its icon and menu, the global shortcut, snips, Settings and notices.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  private let keyStore = KeychainStore()
  private let notices = NoticeCenter()
  private let hotkey = Hotkey(.snip)
  private var shortcutAvailable = false
  private var statusItem: NSStatusItem?
  private var settings: SettingsWindowController?
  private var snips: SnipWindows?

  func applicationDidFinishLaunching(_ notification: Notification) {
    installEditingMenu(applicationName: "SnapScreen")
    // The key is read for each request, so a key saved in Settings applies to open conversations.
    let keyStore = keyStore
    let controller = SessionController(apiKey: {
      do {
        return try keyStore.read()
      } catch let error as KeychainError {
        throw AnthropicError("keychain", error.message)
      }
    })
    snips = SnipWindows(controller: controller, showNotice: { [notices] in notices.show($0, action: $1) })
    hotkey.onPress = { [weak self] in self?.snip() }
    shortcutAvailable = hotkey.register()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = StatusMenu.icon
    item.button?.toolTip = "SnapScreen"
    item.menu = StatusMenu.make(target: self, snip: #selector(snip), closeAll: #selector(closeAllConversations),
      settings: #selector(showSettings), shortcut: shortcutAvailable ? hotkey.combination : nil)
    statusItem = item
    if !shortcutAvailable {
      notices.show("Another app is using \(hotkey.combination.display), so choose Snip from SnapScreen's menu bar icon.")
    }
    // Setup is an explicit foreground action, never an automatic activation at login.
    if !keyStore.hasKey {
      notices.show("Add your Anthropic API key in SnapScreen Settings to start snipping.",
        action: NoticeAction(title: "Open Settings") { [weak self] in self?.showSettings() })
    }
  }

  /// Opening the app again while it runs, from Finder or Spotlight, shows Settings.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showSettings()
    return false
  }

  @MainActor @objc func snip() {
    guard ScreenRecordingAccess.isGranted else {
      notices.show("SnapScreen needs Screen Recording permission to snip.",
        action: NoticeAction(title: "Open System Settings") { ScreenRecordingAccess.openSystemSettings() })
      return
    }
    // The display under the pointer, as the shortcut or the menu leaves it.
    let displayID = screenUnderPointer()?.displayID ?? CGMainDisplayID()
    snips?.controller.start { try await ScreenCapturer.capture(displayID: displayID) }
  }

  @MainActor @objc func closeAllConversations() {
    snips?.closeAll()
  }

  /// Close All Conversations is enabled only while there's one to close.
  @MainActor func validateMenuItem(_ item: NSMenuItem) -> Bool {
    item.action != #selector(closeAllConversations) || snips?.sessions.isEmpty == false
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
