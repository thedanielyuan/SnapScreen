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

  func readWithoutPrompt() throws -> String? { try read() }

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
    settings.inputCharactersField.stringValue == "4000" && settings.screenshotSizeField.stringValue == "5" &&
    settings.screenshotEdgeField.stringValue == "2576",
    "new settings show the defaults")
  try check(settings.limitsSection.isHidden && settings.advancedButton.state == .off, "Advanced starts collapsed")
  try check(settings.saveButton.keyEquivalent == "\r", "Return saves")
  let link = settings.keyHint.attributedStringValue.attribute(.link, at: 20, effectiveRange: nil) as? URL
  try check(settings.keyHint.stringValue == "Get a key from the Anthropic Console. Stored in your Mac's Keychain." &&
    link == SettingsWindowController.consoleURL, "the hint links to the Anthropic Console")
  try check(settings.window.initialFirstResponder === settings.keyField, "with no key, typing starts in the key field")

  // The Default Prompt's box, edited as typing does.
  func edit(_ text: String) {
    settings.promptView.insertText(text,
      replacementRange: NSRange(location: 0, length: (settings.promptView.string as NSString).length))
    // Ends the edit's undo group, as the end of an event does.
    RunLoop.main.run(mode: .default, before: Date())
  }
  func setCharacterLimit(_ value: String) {
    settings.inputCharactersField.stringValue = value
    NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: settings.inputCharactersField)
  }
  func boxHeight() -> CGFloat {
    settings.window.contentView?.layoutSubtreeIfNeeded()
    return settings.promptEditor.frame.height
  }
  try check(settings.promptCount.stringValue == "45 / 4,000" && settings.promptCount.textColor == .secondaryLabelColor &&
    !settings.restorePromptButton.isEnabled, "the default prompt shows its count, with Restore Default off")
  let line = NSLayoutManager().defaultLineHeight(for: settings.promptView.font!)
  let shortBox = boxHeight()
  let shortWindow = settings.window.frame.height
  edit("  Answer in French.  \n")
  try check(settings.promptCount.stringValue == "17 / 4,000" && settings.restorePromptButton.isEnabled &&
    settings.promptCount.accessibilityLabel() == "17 of 4,000 characters",
    "typing updates the count of what's saved, and turns on Restore Default")
  try check(boxHeight() == shortBox, "a short prompt keeps the four-line box")
  edit(Array(repeating: "Answer in French.", count: 6).joined(separator: "\n"))
  let grown = boxHeight() - shortBox
  try check(abs(grown - (6 - PromptEditor.minLines) * line) < 1 && settings.window.frame.height == shortWindow + grown,
    "the box and window grow with the prompt")
  edit(Array(repeating: "Answer in French.", count: 30).joined(separator: "\n"))
  try check(abs(boxHeight() - shortBox - (PromptEditor.maxLines - PromptEditor.minLines) * line) < 1 &&
    settings.promptEditor.scrollView.documentView!.frame.height > settings.promptEditor.scrollView.contentSize.height,
    "a long prompt stops growing the box at ten lines and scrolls")
  settings.window.makeFirstResponder(settings.promptView)
  try check(settings.promptEditor.focusRing.frame == settings.promptEditor.bounds.insetBy(dx: -FocusRingView.outset,
    dy: -FocusRingView.outset) && settings.promptEditor.focusRing.isHidden && settings.promptView.focusRingType == .none,
    "the focus ring goes around the whole box, and only while Settings has the keyboard")
  edit("Answer in French.")
  try check(boxHeight() == shortBox && settings.window.frame.height == shortWindow, "the box shrinks back")

  setCharacterLimit("100")
  try check(settings.promptCount.stringValue == "17 / 100", "the count follows the limit as it's typed")
  edit(String(repeating: "a", count: 101))
  try check(settings.promptCount.stringValue == "101 / 100" && settings.promptCount.textColor == .systemRed,
    "a prompt over the limit shows its count in red")
  setCharacterLimit("abc")
  try check(settings.promptCount.stringValue == "101 characters" && settings.promptCount.textColor == .secondaryLabelColor,
    "without a valid limit, the count stands alone")
  setCharacterLimit("4000")

  edit("Answer in French.")
  settings.restorePromptButton.performClick(nil)
  try check(settings.promptView.string == "Answer the question shown in this screenshot." &&
    !settings.restorePromptButton.isEnabled && settings.promptCount.stringValue == "45 / 4,000" &&
    settings.window.firstResponder === settings.promptView, "Restore Default puts back the default prompt")
  try check(settings.promptView.undoManager?.undoActionName == "Restore Default", "Restore Default can be undone")
  settings.promptView.undoManager?.undo()
  try check(settings.promptView.string == "Answer in French." && settings.restorePromptButton.isEnabled,
    "Undo brings back the prompt Restore Default replaced")
  edit("")
  try check(!settings.restorePromptButton.isEnabled && settings.promptCount.stringValue == "0 / 4,000",
    "an empty prompt, which saves the default, leaves Restore Default off")

  edit("Answer in French.")
  settings.window.makeFirstResponder(settings.promptView)
  settings.promptView.insertTab(nil)
  try check(settings.promptView.string == "Answer in French." && settings.window.firstResponder !== settings.promptView,
    "Tab moves to the next field instead of typing a tab")
  settings.window.makeFirstResponder(settings.promptView)
  settings.promptView.insertBacktab(nil)
  try check(settings.window.firstResponder !== settings.promptView, "Shift-Tab moves to the previous field")
  settings.window.makeFirstResponder(settings.promptView)
  settings.promptView.setSelectedRange(NSRange(location: 6, length: 0))
  settings.promptView.insertTabIgnoringFieldEditor(nil)
  try check(settings.promptView.string == "Answer\t in French.", "Option-Tab still types a tab")
  edit("Answer the question shown in this screenshot.")

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
  settings.screenshotSizeField.stringValue = "8"
  settings.screenshotEdgeField.stringValue = "4000"
  settings.save()
  try check(SessionSettings.load(from: defaults) == SessionSettings(defaultPrompt: "Answer in French.",
    limits: SnapScreenLimits(maxInputCharacters: 6_000, maxScreenshotBytes: 8_000_000, maxScreenshotDimension: 4_000)),
    "Save stores the trimmed prompt and the limits")
  settings.promptView.string = " "
  settings.save()
  try check(SessionSettings.load(from: defaults).defaultPrompt == "Answer the question shown in this screenshot.",
    "a blank prompt saves the default one")

  settings.screenshotEdgeField.stringValue = "100"
  settings.save()
  try check(settings.statusLabel.stringValue == "Screenshot edge limit must be a whole number from 512 to 8,000." &&
    settings.statusLabel.textColor == .systemRed && !settings.limitsSection.isHidden &&
    settings.advancedButton.state == .on, "a limit out of range is reported and opens Advanced")
  try check(SessionSettings.load(from: defaults).limits.maxScreenshotDimension == 4_000, "nothing saves with a bad limit")
  for value in ["", "2.5", "abc"] {
    settings.screenshotEdgeField.stringValue = value
    settings.save()
    try check(settings.statusLabel.stringValue.hasPrefix("Screenshot edge limit must"), "\"\(value)\" isn't a limit")
  }
  settings.screenshotEdgeField.stringValue = "4000"
  settings.inputCharactersField.stringValue = "60000"
  settings.save()
  try check(settings.statusLabel.stringValue == "Prompt character limit must be a whole number from 100 to 50,000.",
    "limit messages group digits")
  settings.inputCharactersField.stringValue = "100"
  settings.promptView.string = String(repeating: "a", count: 101)
  settings.save()
  try check(settings.statusLabel.stringValue == "Default Prompt exceeds the 100 character limit." &&
    settings.window.firstResponder === settings.promptView, "a prompt longer than its limit isn't saved")
  settings.promptView.string = String(repeating: "😀", count: 100)
  settings.save()
  try check(settings.statusLabel.stringValue == "Settings saved. Existing API key unchanged.",
    "the prompt limit counts code points")

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
    settings.promptView.string == String(repeating: "😀", count: 100) && settings.inputCharactersField.stringValue == "100" &&
    settings.promptCount.stringValue == "100 / 100", "reopened Settings shows what was saved")
  try check(settings.window.initialFirstResponder === settings.promptView &&
    settings.promptView.selectedRange() == NSRange(location: (settings.promptView.string as NSString).length, length: 0),
    "with a key saved, typing starts at the end of the prompt")
  settings.window.close()
  try check(settings.enteredKey.isEmpty, "closing Settings drops the key from the window")
  keys.failure = KeychainError(operation: .read, status: errSecAuthFailed)
  settings = SettingsWindowController(services: services)
  try check(settings.statusLabel.stringValue == "Couldn't read the API key from your Keychain because access was denied." &&
    settings.removeKeyButton.isEnabled && settings.window.initialFirstResponder === settings.keyField,
    "an unreadable key is reported, can still be removed, and can be typed again")
  keys.failure = nil

  // Closing saves what you changed, as Save does, and stays open to show what can't be saved.
  let closing = SettingsWindowController(services: services)
  let stored = { SessionSettings.load(from: defaults) }
  let before = stored()
  try check(!closing.hasUnsavedChanges && closing.windowShouldClose(closing.window) && closing.statusLabel.stringValue.isEmpty,
    "unchanged Settings close without saving")
  closing.promptView.string = "Answer briefly."
  closing.inputCharactersField.stringValue = "500"
  try check(closing.hasUnsavedChanges && closing.windowShouldClose(closing.window) &&
    stored() == SessionSettings(defaultPrompt: "Answer briefly.",
      limits: SnapScreenLimits(maxInputCharacters: 500, maxScreenshotBytes: before.limits.maxScreenshotBytes,
        maxScreenshotDimension: before.limits.maxScreenshotDimension)),
    "closing saves an edited prompt and limit")
  let saved = stored()
  closing.screenshotEdgeField.stringValue = "9999"
  try check(!closing.windowShouldClose(closing.window) && closing.statusLabel.stringValue.hasPrefix("Screenshot edge limit must") &&
    !closing.limitsSection.isHidden && stored() == saved, "a limit that isn't allowed keeps Settings open, saving nothing")
  closing.screenshotEdgeField.stringValue = String(saved.limits.maxScreenshotDimension)
  closing.keyField.stringValue = "sk-ant-typed"
  try check(closing.windowShouldClose(closing.window) && keys.key == "sk-ant-typed", "closing saves a newly typed key")
  closing.keyField.stringValue = ""
  try check(!closing.hasUnsavedChanges, "an emptied key field isn't a change, since Save keeps the saved key")
  closing.window.close()

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
    "Start a snip with ⌥⇧S, or choose Snip from SnapScreen's menu bar icon.", "Settings shows the shortcut")
  var unavailable = services
  unavailable.shortcut = nil
  try check(SettingsWindowController(services: unavailable).shortcutLabel.stringValue ==
    "Another app is using ⌥⇧S, so choose Snip from SnapScreen's menu bar icon.",
    "Settings says when another app has the shortcut")
  return count
}
