import AppKit
import SnapScreenCore

private enum SettingsTestError: Error { case failed(String) }

private final class MemoryKeyStore: APIKeyStore {
  var key: String?
  var failure: KeychainError?
  var hasKey: Bool { key != nil }

  func read() throws -> String? {
    if let failure = failure { throw failure }
    return key
  }

  func save(_ key: String) throws {
    if let failure = failure { throw failure }
    self.key = key
  }

  func remove() throws {
    if let failure = failure { throw failure }
    key = nil
  }
}

private final class FakeLoginItem: LoginItem {
  var isEnabled = false
  var needsApproval = false
  var failure: Error?
  var openedSettings = 0

  func setEnabled(_ enabled: Bool) throws {
    if let failure = failure { throw failure }
    isEnabled = enabled
  }

  func openSystemSettings() { openedSettings += 1 }
}

/// Settings against memory instead of the Keychain, UserDefaults suite, network and system settings.
/// The window is never shown.
func runSettingsWindowTests() throws -> Int {
  var count = 0
  func check(_ value: Bool, _ name: String) throws {
    guard value else { throw SettingsTestError.failed(name) }
    count += 1
  }
  func waitUntil(_ condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: 5)
    while !condition() && Date() < deadline { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    return condition()
  }
  _ = NSApplication.shared

  let suite = "com.snapscreen.app.self-test.\(UUID().uuidString)"
  guard let defaults = UserDefaults(suiteName: suite) else { throw SettingsTestError.failed("test defaults") }
  defer { defaults.removePersistentDomain(forName: suite) }
  let keys = MemoryKeyStore()
  let login = FakeLoginItem()
  var tested: [String] = []
  var testFailure: Error?
  var screenRecording = false
  var openedScreenRecording = 0
  let services = SettingsServices(keyStore: keys, defaults: defaults,
    verifyKey: { key in
      tested.append(key)
      if let failure = testFailure { throw failure }
    },
    screenRecordingGranted: { screenRecording }, openScreenRecordingSettings: { openedScreenRecording += 1 },
    loginItem: login, shortcut: .snip)

  var settings = SettingsWindowController(services: services)
  try check(settings.window.title == "SnapScreen Settings" && !settings.window.isVisible, "Settings starts closed")
  try check(settings.enteredKey.isEmpty && settings.keyField.placeholderString == "sk-ant-…" &&
    !settings.removeKeyButton.isEnabled, "with no key saved, the field is empty and Remove key is off")
  try check(settings.promptView.string == "Answer the question shown in this screenshot." &&
    settings.inputCharactersField.stringValue == "4000" && settings.conversationTurnsField.stringValue == "12" &&
    settings.screenshotSizeField.stringValue == "5" && settings.screenshotEdgeField.stringValue == "2576",
    "new settings show the defaults")
  try check(settings.limitsSection.isHidden && settings.advancedButton.state == .off, "Advanced starts collapsed")
  try check(settings.saveButton.keyEquivalent == "\r", "Return saves")
  let link = settings.keyHint.attributedStringValue.attribute(.link, at: 20, effectiveRange: nil) as? URL
  try check(settings.keyHint.stringValue == "Get a key from the Anthropic Console. Stored in your Mac's Keychain." &&
    link == SettingsWindowController.consoleURL, "the hint links to the Anthropic Console")

  settings.keyField.stringValue = "  sk-ant-test-key  "
  settings.save()
  try check(keys.key == "sk-ant-test-key" && settings.statusLabel.stringValue == "Settings saved." &&
    settings.removeKeyButton.isEnabled, "Save stores the trimmed key")
  settings.keyField.stringValue = ""
  settings.save()
  try check(keys.key == "sk-ant-test-key" && settings.statusLabel.stringValue == "Settings saved. Existing API key unchanged.",
    "an empty field keeps the saved key")

  settings.promptView.string = "  Answer in French.  "
  settings.inputCharactersField.stringValue = "6000"
  settings.conversationTurnsField.stringValue = "20"
  settings.screenshotSizeField.stringValue = "8"
  settings.screenshotEdgeField.stringValue = "4000"
  settings.save()
  try check(SessionSettings.load(from: defaults) == SessionSettings(defaultPrompt: "Answer in French.",
    limits: SnapScreenLimits(maxInputCharacters: 6_000, maxScreenshotBytes: 8_000_000, maxScreenshotDimension: 4_000,
      maxConversationTurns: 20)), "Save stores the trimmed prompt and the limits")
  settings.promptView.string = " "
  settings.save()
  try check(SessionSettings.load(from: defaults).defaultPrompt == "Answer the question shown in this screenshot.",
    "a blank prompt saves the default one")

  settings.conversationTurnsField.stringValue = "1"
  settings.save()
  try check(settings.statusLabel.stringValue == "Conversation turn limit must be a whole number from 2 to 50." &&
    settings.statusLabel.textColor == .systemRed && !settings.limitsSection.isHidden &&
    settings.advancedButton.state == .on, "a limit out of range is reported and opens Advanced")
  try check(SessionSettings.load(from: defaults).limits.maxConversationTurns == 20, "nothing saves with a bad limit")
  for value in ["", "2.5", "abc"] {
    settings.conversationTurnsField.stringValue = value
    settings.save()
    try check(settings.statusLabel.stringValue.hasPrefix("Conversation turn limit must"), "\"\(value)\" isn't a limit")
  }
  settings.conversationTurnsField.stringValue = "20"
  settings.inputCharactersField.stringValue = "60000"
  settings.save()
  try check(settings.statusLabel.stringValue == "Question character limit must be a whole number from 100 to 50,000.",
    "limit messages group digits")
  settings.inputCharactersField.stringValue = "100"
  settings.promptView.string = String(repeating: "a", count: 101)
  settings.save()
  try check(settings.statusLabel.stringValue == "Default Prompt exceeds the 100 character limit.",
    "a prompt longer than the question limit isn't saved")
  settings.promptView.string = String(repeating: "😀", count: 100)
  settings.save()
  try check(settings.statusLabel.stringValue == "Settings saved. Existing API key unchanged.",
    "the prompt limit counts code points, as in Chrome")

  keys.failure = KeychainError(operation: .save, status: errSecAuthFailed)
  settings.keyField.stringValue = "sk-ant-other"
  settings.save()
  try check(settings.statusLabel.stringValue == "Couldn't save the API key to your Keychain because access was denied." &&
    keys.key == "sk-ant-test-key", "a Keychain failure is reported and nothing saves")
  keys.failure = nil
  settings.keyField.stringValue = "sk-ant-test-key"

  settings.toggleKeyButton.performClick(nil)
  try check(!settings.visibleKeyField.isHidden && settings.keyField.isHidden &&
    settings.visibleKeyField.stringValue == "sk-ant-test-key" && settings.toggleKeyButton.title == "Hide" &&
    settings.toggleKeyButton.accessibilityLabel() == "Hide API key", "Show reveals the key")
  settings.visibleKeyField.stringValue = "sk-ant-edited"
  settings.toggleKeyButton.performClick(nil)
  try check(settings.visibleKeyField.isHidden && settings.keyField.stringValue == "sk-ant-edited" &&
    settings.toggleKeyButton.title == "Show", "Hide keeps what was typed")
  settings.keyField.stringValue = "sk-ant-test-key"

  settings.testKeyButton.performClick(nil)
  try check(settings.statusLabel.stringValue == "Testing…" && !settings.testKeyButton.isEnabled,
    "Test key shows progress")
  try check(waitUntil { settings.statusLabel.stringValue == "API key works." } && tested == ["sk-ant-test-key"] &&
    settings.testKeyButton.isEnabled, "a working key passes the test")
  testFailure = AnthropicError("auth", "Invalid API key. Check your settings.")
  settings.testKeyButton.performClick(nil)
  try check(waitUntil { settings.statusLabel.stringValue == "Invalid API key. Check your settings." },
    "a failed test shows the API's message")
  testFailure = nil
  settings.keyField.stringValue = " "
  settings.testKeyButton.performClick(nil)
  try check(settings.statusLabel.stringValue == "Enter an API key to test." && tested.count == 2,
    "an empty field isn't tested")
  settings.keyField.stringValue = "sk-ant-test-key"

  settings.removeKeyButton.performClick(nil)
  try check(keys.key == nil && settings.enteredKey.isEmpty && !settings.removeKeyButton.isEnabled &&
    settings.statusLabel.stringValue == "API key removed.", "Remove key deletes the key")
  settings.save()
  try check(settings.statusLabel.stringValue == "Settings saved. Add an API key to analyze screenshots.",
    "saving without any key asks for one")

  keys.key = "sk-ant-stored"
  settings = SettingsWindowController(services: services)
  try check(settings.enteredKey == "sk-ant-stored" && settings.removeKeyButton.isEnabled &&
    settings.promptView.string == String(repeating: "😀", count: 100) && settings.inputCharactersField.stringValue == "100",
    "reopened Settings shows what was saved")
  settings.window.close()
  try check(settings.enteredKey.isEmpty, "closing Settings drops the key from the window")
  keys.failure = KeychainError(operation: .read, status: errSecAuthFailed)
  settings = SettingsWindowController(services: services)
  try check(settings.statusLabel.stringValue == "Couldn't read the API key from your Keychain because access was denied." &&
    settings.removeKeyButton.isEnabled, "an unreadable key is reported and can still be removed")
  keys.failure = nil

  try check(settings.screenRecordingLabel.stringValue == "SnapScreen needs Screen Recording permission to snip.",
    "missing Screen Recording permission is shown")
  settings.screenRecordingButton.performClick(nil)
  try check(openedScreenRecording == 1, "Open System Settings opens Screen Recording")
  screenRecording = true
  settings.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
  try check(settings.screenRecordingLabel.stringValue == "SnapScreen can capture the screen.",
    "returning to Settings rechecks Screen Recording")

  try check(settings.loginSwitch.state == .off && settings.loginNote.isHidden && settings.loginButton.isHidden,
    "Open at login starts off")
  settings.loginSwitch.performClick(nil)
  try check(login.isEnabled && settings.loginSwitch.state == .on, "the switch turns on Open at login")
  login.needsApproval = true
  login.isEnabled = false
  settings.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
  try check(settings.loginSwitch.state == .on && !settings.loginNote.isHidden && !settings.loginButton.isHidden &&
    settings.loginNote.stringValue == "Allow SnapScreen in System Settings > General > Login Items.",
    "a login item waiting for approval says where to allow it")
  settings.loginButton.performClick(nil)
  try check(login.openedSettings == 1, "Open System Settings opens Login Items")
  login.needsApproval = false
  login.failure = NSError(domain: "SMAppServiceErrorDomain", code: 1,
    userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
  settings.loginSwitch.performClick(nil)
  try check(settings.loginNote.stringValue == "Couldn't change Open at login: Operation not permitted" &&
    settings.loginSwitch.state == .off, "a failed change is reported and the switch shows the real state")

  try check(settings.shortcutLabel.stringValue ==
    "Start a snip with ⌃⌥⇧S, or choose Snip from SnapScreen's menu bar icon.", "Settings shows the shortcut")
  var unavailable = services
  unavailable.shortcut = nil
  try check(SettingsWindowController(services: unavailable).shortcutLabel.stringValue ==
    "Another app is using ⌃⌥⇧S, so choose Snip from SnapScreen's menu bar icon.",
    "Settings says when another app has the shortcut")
  return count
}
