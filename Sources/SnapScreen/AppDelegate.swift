import AppKit
import SnapScreenCore

/// What the app uses beyond its own windows, so the live focus test can run the real app with a key
/// kept in memory, a made-up capture and scripted answers.
struct AppServices {
  var keyStore: APIKeyStore = KeychainStore()
  var answers: any AnswerClient = AnthropicClient()
  var screenRecordingGranted: () -> Bool = { ScreenRecordingAccess.isGranted }
  var capture: @Sendable (CGDirectDisplayID) async throws -> FrozenScreen = {
    try await ScreenCapturer.capture(displayID: $0)
  }
  /// Settings' services, given the key store and the shortcut, nil when another app has it.
  var settings: (APIKeyStore, Hotkey.Combination?) -> SettingsServices = {
    SettingsServices(keyStore: $0, shortcut: $1)
  }
}

/// The menu bar app: its icon and menu, the global shortcut, snips, Settings and notices.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  private let services: AppServices
  private let notices = NoticeCenter()
  private let hotkey = Hotkey(.snip)
  private var shortcutAvailable = false
  private var statusItem: NSStatusItem?
  private var settings: SettingsWindowController?
  private var snips: SnipWindows?

  init(services: AppServices = AppServices()) {
    self.services = services
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    installEditingMenu(applicationName: "SnapScreen")
    // The key is read for each request, so a key saved in Settings applies to open conversations.
    // A request never lets macOS ask for your password; Settings, which you open yourself, may.
    let keyStore = services.keyStore
    let controller = SessionController(answers: services.answers, apiKey: {
      do {
        return try keyStore.readWithoutPrompt()
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

  /// How long an activation waits for Settings before SnapScreen hands it back. Opening the
  /// running app again activates it about a millisecond before the reopen event that opens Settings.
  static let handbackDelay: DispatchTimeInterval = .milliseconds(150)

  /// Only Settings, which you open yourself, keeps SnapScreen active. Anything else that activates
  /// it, such as a script, a launcher or another app asking it to, finds no window for the
  /// keyboard, so it hands activation back to the app you were using.
  func applicationDidBecomeActive(_ notification: Notification) {
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.handbackDelay) { [weak self] in
      guard let self, self.settings == nil else { return }
      ForegroundFocus.returnToPreviousApp()
    }
  }

  /// Opening the app again while it runs, from Finder or Spotlight, shows Settings.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showSettings()
    return false
  }

  /// SnapScreen quits only when you mean it to, so a script or a test can't quit the copy you use.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    QuitRequest.isAccepted(NSAppleEventManager.shared().currentAppleEvent) ? .terminateNow : .terminateCancel
  }

  @MainActor @objc func snip() {
    guard services.screenRecordingGranted() else {
      notices.show("SnapScreen needs Screen Recording permission to snip.",
        action: NoticeAction(title: "Open System Settings") { ScreenRecordingAccess.openSystemSettings() })
      return
    }
    // The display under the pointer, as the shortcut or the menu leaves it.
    let displayID = screenUnderPointer()?.displayID ?? CGMainDisplayID()
    let capture = services.capture
    snips?.controller.start { try await capture(displayID) }
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
      let controller = SettingsWindowController(services: services.settings(services.keyStore,
        shortcutAvailable ? hotkey.combination : nil))
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
    DispatchQueue.main.async {
      ForegroundFocus.returnToPreviousApp(ignoring: closing.window)
    }
  }
}

/// SnapScreen takes the keyboard only for Settings. Whenever it's active with no other window that
/// could have the keyboard, as once Settings closes, it hides, and AppKit activates the app you were
/// using. Passive panels set `canHide` to false, so an open snip stays visible through the handoff.
/// If another app is already active, this leaves it alone.
enum ForegroundFocus {
  /// `closing` is a window that's closing, so it doesn't count.
  static func returnToPreviousApp(ignoring closing: NSWindow? = nil) {
    guard NSApp.isActive, !NSApp.windows.contains(where: {
      $0 !== closing && $0.isVisible && $0.canBecomeKey
    }) else { return }
    NSApp.hide(nil)
  }
}

/// Which requests to quit SnapScreen it accepts. Quit SnapScreen sends no Apple event. A quit event
/// is accepted when it gives a reason, as logging out, restarting and shutting down do, or comes from
/// macOS or an app, such as Activity Monitor, and refused from a command-line tool or script.
enum QuitRequest {
  static func isAccepted(_ event: NSAppleEventDescriptor?) -> Bool {
    guard let event, event.eventClass == AEEventClass(kCoreEventClass),
      event.eventID == AEEventID(kAEQuitApplication) else { return true }
    let reason = AEKeyword(kAEQuitReason)
    if event.paramDescriptor(forKeyword: reason) != nil || event.attributeDescriptor(forKeyword: reason) != nil {
      return true
    }
    let sender = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value ?? 0
    return isAccepted(senderPath: sender > 0 ? executablePath(of: sender) : nil)
  }

  /// macOS's own processes and the main executables of apps and app extensions. /System/Volumes
  /// holds the data volume, not macOS.
  static func isAccepted(senderPath path: String?) -> Bool {
    guard let path else { return false }
    if path.hasPrefix("/System/") && !path.hasPrefix("/System/Volumes/") { return true }
    let parts = URL(fileURLWithPath: path).pathComponents
    guard parts.count >= 4, parts[parts.count - 3] == "Contents", parts[parts.count - 2] == "MacOS" else {
      return false
    }
    let bundle = parts[parts.count - 4]
    return bundle.hasSuffix(".app") || bundle.hasSuffix(".appex")
  }

  static func executablePath(of pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
  }
}
