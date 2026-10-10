import AppKit
import SnapScreenCore

/// What Settings uses outside its window, so the self-test can replace each part.
struct SettingsServices {
  var keyStore: APIKeyStore
  var defaults: UserDefaults = .standard
  var verifyKey: (String) async throws -> Void = { try await AnthropicClient().verifyAPIKey($0) }
  var screenRecordingGranted: () -> Bool = { ScreenRecordingAccess.isGranted }
  var openScreenRecordingSettings: () -> Void = { ScreenRecordingAccess.openSystemSettings() }
  var loginItem: LoginItem = MainAppLoginItem()
  /// Nil when another app has the shortcut.
  var shortcut: Hotkey.Combination?
}

/// The Settings window: the extension's options page (the key, the Default Prompt and the
/// advanced limits), plus Screen Recording status and Open at login. Saving works as it does there.
final class SettingsWindowController: NSObject, NSWindowDelegate {
  static let contentWidth: CGFloat = 440
  static let consoleURL = URL(string: "https://console.anthropic.com/")!

  let window: NSWindow
  let keyField = NSSecureTextField()
  /// Shows the key in place of `keyField` after Show.
  let visibleKeyField = NSTextField()
  let keyHint = NSTextField(labelWithString: "")
  let promptView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 64))
  let inputCharactersField = NSTextField()
  let conversationTurnsField = NSTextField()
  let screenshotSizeField = NSTextField()
  let screenshotEdgeField = NSTextField()
  let limitsSection = NSStackView()
  let statusLabel = NSTextField(wrappingLabelWithString: "")
  let screenRecordingLabel = NSTextField(wrappingLabelWithString: "")
  let loginSwitch = NSSwitch()
  let loginNote = NSTextField(wrappingLabelWithString: "")
  let shortcutLabel = NSTextField(wrappingLabelWithString: "")
  private(set) lazy var toggleKeyButton = NSButton(title: "Show", target: self, action: #selector(toggleKeyVisibility))
  private(set) lazy var advancedButton = NSButton(title: "", target: self, action: #selector(toggleAdvanced))
  private(set) lazy var advancedTitle = NSButton(title: "Advanced", target: self, action: #selector(toggleAdvancedTitle))
  private(set) lazy var saveButton = NSButton(title: "Save", target: self, action: #selector(save))
  private(set) lazy var testKeyButton = NSButton(title: "Test key", target: self, action: #selector(testKey))
  private(set) lazy var removeKeyButton = NSButton(title: "Remove key", target: self, action: #selector(removeKey))
  private(set) lazy var screenRecordingButton = NSButton(title: "Open System Settings", target: self,
    action: #selector(openScreenRecordingSettings))
  private(set) lazy var loginButton = NSButton(title: "Open System Settings", target: self,
    action: #selector(openLoginItems))
  var onClose: (() -> Void)?

  private let services: SettingsServices
  private var hasStoredKey = false
  private var testPending = false
  private var removalEpoch = 0
  private var testTask: Task<Void, Never>?
  private var statusTimer: Timer?
  private var loginError: String?

  init(services: SettingsServices) {
    self.services = services
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth + 40, height: 400),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    super.init()
    window.title = "SnapScreen Settings"
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.moveToActiveSpace]
    window.delegate = self
    buildContent()
    load()
    refreshSystemStatus()
    window.center()
  }

  // MARK: Layout

  private func buildContent() {
    let intro = Self.wrappingLabel("Configure your Anthropic API key and default analysis prompt.", size: 13,
      color: .secondaryLabelColor)

    for field in [keyField, visibleKeyField] {
      field.placeholderString = "sk-ant-…"
      field.setAccessibilityLabel("Anthropic API Key")
      field.usesSingleLineMode = true
      field.cell?.isScrollable = true
      field.cell?.wraps = false
      field.isAutomaticTextCompletionEnabled = false
      field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    visibleKeyField.isHidden = true
    toggleKeyButton.setAccessibilityLabel("Show API key")
    let keyRow = row([keyField, visibleKeyField, toggleKeyButton])
    keyHint.attributedStringValue = Self.consoleHint()
    // Selectable, so the link opens on click.
    keyHint.isSelectable = true
    keyHint.allowsEditingTextAttributes = true

    promptView.isRichText = false
    promptView.importsGraphics = false
    promptView.allowsUndo = true
    promptView.font = .systemFont(ofSize: 13)
    promptView.textColor = .labelColor
    promptView.isAutomaticQuoteSubstitutionEnabled = false
    promptView.isAutomaticDashSubstitutionEnabled = false
    promptView.isAutomaticTextReplacementEnabled = false
    promptView.textContainerInset = NSSize(width: 2, height: 5)
    promptView.minSize = .zero
    promptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    promptView.isVerticallyResizable = true
    promptView.isHorizontallyResizable = false
    promptView.autoresizingMask = [.width]
    promptView.textContainer?.widthTracksTextView = true
    promptView.placeholder = SessionSettings.defaults.defaultPrompt
    promptView.setAccessibilityLabel("Default Prompt")
    let promptScroll = NSScrollView()
    promptScroll.documentView = promptView
    promptScroll.borderType = .bezelBorder
    promptScroll.hasVerticalScroller = true
    promptScroll.autohidesScrollers = true
    promptScroll.heightAnchor.constraint(equalToConstant: 64).isActive = true

    advancedButton.bezelStyle = .disclosure
    advancedButton.setButtonType(.pushOnPushOff)
    advancedButton.state = .off
    advancedButton.setAccessibilityLabel("Advanced")
    advancedTitle.isBordered = false
    // The disclosure triangle already names the section.
    advancedTitle.setAccessibilityElement(false)
    let limitsGrid = NSGridView(views: [
      [limitColumn(inputCharactersField, "Question characters"), limitColumn(conversationTurnsField, "Conversation turns")],
      [limitColumn(screenshotSizeField, "Screenshot size (MB)"), limitColumn(screenshotEdgeField, "Screenshot edge (px)")],
    ])
    limitsGrid.rowSpacing = 10
    limitsGrid.columnSpacing = 24
    // Fixed columns, so the grid doesn't stretch to an arbitrary width.
    for index in 0..<limitsGrid.numberOfColumns { limitsGrid.column(at: index).width = 150 }
    for view in [
      Self.label("Request limits", size: 13, weight: .semibold),
      Self.wrappingLabel("Keep requests predictable and within Anthropic's image and request limits.", size: 11,
        color: .secondaryLabelColor, width: Self.contentWidth - 20),
      limitsGrid,
      Self.wrappingLabel("Defaults: 4,000 characters, 12 turns, 5 MB, and 2,576 px. The API ceilings are 10 MB and " +
        "8,000 px.", size: 11, color: .secondaryLabelColor, width: Self.contentWidth - 20),
    ] { limitsSection.addArrangedSubview(view) }
    limitsSection.orientation = .vertical
    limitsSection.alignment = .leading
    limitsSection.spacing = 8
    limitsSection.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
    limitsSection.isHidden = true

    saveButton.keyEquivalent = "\r"
    removeKeyButton.hasDestructiveAction = true
    statusLabel.font = .systemFont(ofSize: 12)
    statusLabel.preferredMaxLayoutWidth = Self.contentWidth
    // An empty status keeps its line, so messages don't resize the window.
    statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true

    screenRecordingLabel.font = .systemFont(ofSize: 13)
    screenRecordingLabel.preferredMaxLayoutWidth = Self.contentWidth - 170
    screenRecordingLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let screenRecordingRow = row([screenRecordingLabel, screenRecordingButton])
    loginSwitch.target = self
    loginSwitch.action = #selector(loginSwitchChanged)
    loginSwitch.setAccessibilityLabel("Open at login")
    loginNote.font = .systemFont(ofSize: 11)
    loginNote.textColor = .secondaryLabelColor
    loginNote.preferredMaxLayoutWidth = Self.contentWidth
    shortcutLabel.font = .systemFont(ofSize: 13)
    shortcutLabel.preferredMaxLayoutWidth = Self.contentWidth
    let separator = NSBox()
    separator.boxType = .separator
    for view in [intro, keyRow, keyHint, promptScroll, statusLabel, separator, screenRecordingRow, loginNote,
      shortcutLabel] {
      view.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
    }

    let stack = NSStackView(views: [
      intro,
      section([Self.label("Anthropic API Key", size: 13, weight: .semibold), keyRow, keyHint]),
      section([Self.label("Default Prompt", size: 13, weight: .semibold), promptScroll]),
      section([row([advancedButton, advancedTitle], spacing: 2), limitsSection]),
      section([row([saveButton, testKeyButton, removeKeyButton]), statusLabel]),
      separator,
      section([Self.label("Screen Recording", size: 13, weight: .semibold), screenRecordingRow]),
      section([row([loginSwitch, Self.label("Open at login", size: 13)]), loginNote, loginButton]),
      section([Self.label("Keyboard shortcut", size: 13, weight: .semibold), shortcutLabel]),
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 20, right: 20)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let content = NSView()
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      stack.topAnchor.constraint(equalTo: content.topAnchor),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
    window.contentView = content
    window.initialFirstResponder = keyField
  }

  private func section(_ views: [NSView]) -> NSStackView {
    let section = NSStackView(views: views)
    section.orientation = .vertical
    section.alignment = .leading
    section.spacing = 6
    return section
  }

  private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = spacing
    return row
  }

  private func limitColumn(_ field: NSTextField, _ title: String) -> NSView {
    field.setAccessibilityLabel(title)
    field.widthAnchor.constraint(equalToConstant: 110).isActive = true
    let column = NSStackView(views: [Self.label(title, size: 12), field])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 4
    return column
  }

  private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    return label
  }

  private static func wrappingLabel(_ text: String, size: CGFloat, color: NSColor,
    width: CGFloat = contentWidth) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: size)
    label.textColor = color
    label.preferredMaxLayoutWidth = width
    return label
  }

  private static func consoleHint() -> NSAttributedString {
    let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
      .foregroundColor: NSColor.secondaryLabelColor]
    let hint = NSMutableAttributedString(string: "Get a key from the ", attributes: plain)
    hint.append(NSAttributedString(string: "Anthropic Console",
      attributes: [.font: NSFont.systemFont(ofSize: 11), .link: consoleURL]))
    hint.append(NSAttributedString(string: ". Stored in your Mac's Keychain.", attributes: plain))
    return hint
  }

  private func fitWindow() {
    guard let content = window.contentView else { return }
    content.layoutSubtreeIfNeeded()
    let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize)).size
    // Grow or shrink downwards, keeping the title bar in place.
    window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width,
      height: size.height), display: window.isVisible)
  }

  // MARK: Settings

  /// The key as typed, in whichever field shows it.
  var enteredKey: String { visibleKeyField.isHidden ? keyField.stringValue : visibleKeyField.stringValue }

  private func load() {
    let settings = SessionSettings.load(from: services.defaults)
    promptView.string = settings.defaultPrompt
    setLimits(settings.limits)
    hasStoredKey = services.keyStore.hasKey
    if hasStoredKey {
      do {
        keyField.stringValue = try services.keyStore.read() ?? ""
      } catch {
        showStatus(Self.message(for: error), isError: true, sticky: true)
      }
    }
    updateControls()
  }

  private func setLimits(_ limits: SnapScreenLimits) {
    inputCharactersField.stringValue = String(limits.maxInputCharacters)
    conversationTurnsField.stringValue = String(limits.maxConversationTurns)
    screenshotSizeField.stringValue = limits.maxScreenshotBytes % megabyte == 0
      ? String(limits.maxScreenshotBytes / megabyte) : String(Double(limits.maxScreenshotBytes) / Double(megabyte))
    screenshotEdgeField.stringValue = String(limits.maxScreenshotDimension)
  }

  private struct LimitInput {
    let field: NSTextField
    let name: String
    let range: ClosedRange<Int>
  }

  private var limitInputs: [LimitInput] {
    let bytes = SnapScreenLimits.screenshotBytes
    return [
      LimitInput(field: inputCharactersField, name: "Question character limit",
        range: SnapScreenLimits.inputCharacters.min...SnapScreenLimits.inputCharacters.max),
      LimitInput(field: conversationTurnsField, name: "Conversation turn limit",
        range: SnapScreenLimits.conversationTurns.min...SnapScreenLimits.conversationTurns.max),
      LimitInput(field: screenshotSizeField, name: "Screenshot size limit", range: bytes.min / megabyte...bytes.max / megabyte),
      LimitInput(field: screenshotEdgeField, name: "Screenshot edge limit",
        range: SnapScreenLimits.screenshotDimension.min...SnapScreenLimits.screenshotDimension.max),
    ]
  }

  /// The limits as entered, or nil after reporting the first one that isn't allowed.
  private func readLimits() -> SnapScreenLimits? {
    var values: [Int] = []
    for input in limitInputs {
      let number = Double(input.field.stringValue.jsTrimmed)
      guard let number = number, number.isFinite, number.rounded() == number, abs(number) < 1e12,
        input.range.contains(Int(number)) else {
        showStatus("\(input.name) must be a whole number from \(groupedDigits(input.range.lowerBound)) to " +
          "\(groupedDigits(input.range.upperBound)).", isError: true)
        setAdvancedVisible(true)
        window.makeFirstResponder(input.field)
        return nil
      }
      values.append(Int(number))
    }
    return SnapScreenLimits(maxInputCharacters: values[0], maxScreenshotBytes: values[2] * megabyte,
      maxScreenshotDimension: values[3], maxConversationTurns: values[1])
  }

  @objc func save() {
    guard let limits = readLimits() else { return }
    let typedPrompt = promptView.string.jsTrimmed
    let prompt = typedPrompt.isEmpty ? SessionSettings.defaults.defaultPrompt : typedPrompt
    guard countTextCharacters(prompt) <= limits.maxInputCharacters else {
      showStatus("Default Prompt exceeds the \(groupedDigits(limits.maxInputCharacters)) character limit.", isError: true)
      return
    }
    let apiKey = enteredKey.jsTrimmed
    if !apiKey.isEmpty {
      do {
        try services.keyStore.save(apiKey)
      } catch {
        showStatus(Self.message(for: error), isError: true)
        return
      }
      hasStoredKey = true
    }
    SessionSettings.save(defaultPrompt: prompt, to: services.defaults)
    SessionSettings.save(limits: limits, to: services.defaults)
    updateControls()
    if !apiKey.isEmpty {
      showStatus("Settings saved.")
    } else {
      showStatus(hasStoredKey ? "Settings saved. Existing API key unchanged."
        : "Settings saved. Add an API key to analyze screenshots.")
    }
  }

  @objc func testKey() {
    guard !testPending else { return }
    let apiKey = enteredKey.jsTrimmed
    guard !apiKey.isEmpty else {
      showStatus("Enter an API key to test.", isError: true)
      return
    }
    let epoch = removalEpoch
    let verify = services.verifyKey
    testPending = true
    updateControls()
    showStatus("Testing…", sticky: true)
    testTask = Task { @MainActor [weak self] in
      let failure: String?
      do {
        try await verify(apiKey)
        failure = nil
      } catch is CancellationError {
        return
      } catch let error as AnthropicError {
        failure = error.message
      } catch {
        failure = "Test failed."
      }
      guard let self = self else { return }
      self.testPending = false
      self.updateControls()
      // A key removed during the test makes its result stale.
      if epoch == self.removalEpoch { self.showStatus(failure ?? "API key works.", isError: failure != nil) }
    }
  }

  @objc func removeKey() {
    guard hasStoredKey else { return }
    removalEpoch += 1
    do {
      try services.keyStore.remove()
    } catch {
      showStatus(Self.message(for: error), isError: true)
      return
    }
    hasStoredKey = false
    keyField.stringValue = ""
    visibleKeyField.stringValue = ""
    setKeyVisible(false)
    updateControls()
    showStatus("API key removed.")
  }

  @objc func toggleKeyVisibility() { setKeyVisible(visibleKeyField.isHidden) }

  private func setKeyVisible(_ visible: Bool) {
    guard visible == visibleKeyField.isHidden else { return }
    let editing = (window.firstResponder as? NSText)?.delegate === (visible ? keyField : visibleKeyField)
    if visible { visibleKeyField.stringValue = keyField.stringValue } else { keyField.stringValue = visibleKeyField.stringValue }
    keyField.isHidden = visible
    visibleKeyField.isHidden = !visible
    toggleKeyButton.title = visible ? "Hide" : "Show"
    toggleKeyButton.setAccessibilityLabel(visible ? "Hide API key" : "Show API key")
    if editing { window.makeFirstResponder(visible ? visibleKeyField : keyField) }
  }

  @objc private func toggleAdvanced() { setAdvancedVisible(advancedButton.state == .on) }
  @objc private func toggleAdvancedTitle() { setAdvancedVisible(limitsSection.isHidden) }

  func setAdvancedVisible(_ visible: Bool) {
    advancedButton.state = visible ? .on : .off
    guard limitsSection.isHidden == visible else { return }
    limitsSection.isHidden = !visible
    fitWindow()
  }

  private func updateControls() {
    removeKeyButton.isEnabled = hasStoredKey
    testKeyButton.isEnabled = !testPending
  }

  private func showStatus(_ message: String, isError: Bool = false, sticky: Bool = false) {
    statusTimer?.invalidate()
    statusTimer = nil
    statusLabel.stringValue = message
    statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    fitWindow()
    NSAccessibility.post(element: statusLabel, notification: .announcementRequested, userInfo: [.announcement: message,
      .priority: (isError ? NSAccessibilityPriorityLevel.high : .medium).rawValue])
    guard !sticky else { return }
    let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
      self?.statusLabel.stringValue = ""
      self?.fitWindow()
    }
    RunLoop.main.add(timer, forMode: .common)
    statusTimer = timer
  }

  private static func message(for error: Error) -> String {
    (error as? KeychainError)?.message ?? error.localizedDescription
  }

  // MARK: Screen Recording, Open at login and the shortcut

  private func refreshSystemStatus() {
    screenRecordingLabel.stringValue = services.screenRecordingGranted()
      ? "SnapScreen can capture the screen." : "SnapScreen needs Screen Recording permission to snip."
    let login = services.loginItem
    loginSwitch.state = login.isEnabled || login.needsApproval ? .on : .off
    loginNote.stringValue = loginError
      ?? (login.needsApproval ? "Allow SnapScreen in System Settings > General > Login Items." : "")
    loginNote.isHidden = loginNote.stringValue.isEmpty
    loginButton.isHidden = !login.needsApproval
    shortcutLabel.stringValue = services.shortcut.map {
      "Start a snip with \($0.display), or choose Snip from SnapScreen's menu bar icon."
    } ?? "Another app is using \(Hotkey.Combination.snip.display), so choose Snip from SnapScreen's menu bar icon."
    fitWindow()
  }

  @objc func openScreenRecordingSettings() { services.openScreenRecordingSettings() }

  @objc func openLoginItems() { services.loginItem.openSystemSettings() }

  @objc func loginSwitchChanged() {
    do {
      try services.loginItem.setEnabled(loginSwitch.state == .on)
      loginError = nil
    } catch {
      loginError = "Couldn't change Open at login: \(error.localizedDescription)"
    }
    refreshSystemStatus()
  }

  /// Returning from System Settings may have changed either.
  func windowDidBecomeKey(_ notification: Notification) { refreshSystemStatus() }

  func windowWillClose(_ notification: Notification) {
    testTask?.cancel()
    testTask = nil
    statusTimer?.invalidate()
    statusTimer = nil
    // The key stays in memory only while Settings is open.
    keyField.stringValue = ""
    visibleKeyField.stringValue = ""
    onClose?()
  }
}
