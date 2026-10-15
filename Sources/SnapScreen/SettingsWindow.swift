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

/// Plain-text input that shows a placeholder while it's empty, laid out as typed text would be.
/// Tab and Shift-Tab move to the next and previous field, as in a text field; Option-Tab types a
/// tab.
final class PromptTextView: NSTextView {
  var placeholder = "" { didSet { needsDisplay = true } }
  /// Called with whether it now has the keyboard.
  var onFocusChange: ((Bool) -> Void)?

  override func didChangeText() {
    super.didChangeText()
    needsDisplay = true
  }

  override func insertTab(_ sender: Any?) { window?.selectNextKeyView(self) }
  override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(self) }

  override func becomeFirstResponder() -> Bool {
    guard super.becomeFirstResponder() else { return false }
    onFocusChange?(true)
    return true
  }

  override func resignFirstResponder() -> Bool {
    guard super.resignFirstResponder() else { return false }
    onFocusChange?(false)
    return true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !hasMarkedText() else { return }
    // Laid out as the text is, so the placeholder sits exactly where typing starts. String drawing
    // places a line's extra space differently.
    var attributes = typingAttributes
    attributes[.foregroundColor] = NSColor.placeholderTextColor
    let storage = NSTextStorage(string: placeholder, attributes: attributes)
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: textContainer?.containerSize.width ?? bounds.width,
      height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: textContainerOrigin)
  }
}

/// The Default Prompt's box: a `PromptTextView` drawn like the key field, which grows with its text
/// from `minLines` to `maxLines` lines and then scrolls.
final class PromptEditor: NSView {
  static let minLines: CGFloat = 4
  static let maxLines: CGFloat = 10
  /// Between the bezel and the text's scroll view, so scrolled text clears the rounded corners.
  private static let margin = NSSize(width: 1, height: 3)

  let textView: PromptTextView
  let scrollView: NSScrollView
  /// Shown while the text has the keyboard. The text view's own ring would be clipped by the
  /// scroll view, so the box draws one like the key field's.
  let focusRing = FocusRingView()
  private var height: NSLayoutConstraint!
  private var hasFocus = false
  /// An empty text field behind the text, so the box looks just like the key field.
  private let bezel = BezelField()

  init(width: CGFloat) {
    scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width - 2 * Self.margin.width, height: 100))
    textView = PromptTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: 100))
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.font = .systemFont(ofSize: 13)
    textView.textColor = .labelColor
    textView.drawsBackground = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = true
    // Text starts where the key field's does.
    textView.textContainerInset = NSSize(width: 0, height: 3)
    textView.minSize = .zero
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.focusRingType = .none
    textView.onFocusChange = { [weak self] focused in
      self?.hasFocus = focused
      self?.updateFocusRing()
    }
    scrollView.documentView = textView
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    bezel.isEditable = false
    bezel.isSelectable = false
    bezel.refusesFirstResponder = true
    bezel.setAccessibilityElement(false)
    bezel.translatesAutoresizingMaskIntoConstraints = false
    focusRing.isHidden = true
    focusRing.translatesAutoresizingMaskIntoConstraints = false
    addSubview(bezel)
    addSubview(scrollView)
    addSubview(focusRing)
    for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(updateFocusRing), name: name, object: nil)
    }
    height = heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: width),
      height,
      bezel.leadingAnchor.constraint(equalTo: leadingAnchor),
      bezel.trailingAnchor.constraint(equalTo: trailingAnchor),
      bezel.topAnchor.constraint(equalTo: topAnchor),
      bezel.bottomAnchor.constraint(equalTo: bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin.width),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.margin.width),
      scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.margin.height),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.margin.height),
      focusRing.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -FocusRingView.outset),
      focusRing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: FocusRingView.outset),
      focusRing.topAnchor.constraint(equalTo: topAnchor, constant: -FocusRingView.outset),
      focusRing.bottomAnchor.constraint(equalTo: bottomAnchor, constant: FocusRingView.outset),
    ])
    fitToText()
  }

  required init?(coder: NSCoder) { nil }

  /// A click in the margin edits the text too, as in a text field.
  override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(textView) }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      NotificationCenter.default.removeObserver(self, name: name, object: nil)
      if let window = window {
        NotificationCenter.default.addObserver(self, selector: #selector(updateFocusRing), name: name, object: window)
      }
    }
    updateFocusRing()
  }

  /// Shows the ring when the text has the keyboard, as AppKit does for a text field.
  @objc private func updateFocusRing() {
    focusRing.isHidden = !(hasFocus && NSApp.isActive && window?.isKeyWindow == true)
  }

  /// Fits the box to its text, and returns whether its height changed.
  @discardableResult func fitToText() -> Bool {
    guard let manager = textView.layoutManager, let container = textView.textContainer,
      let font = textView.font else { return false }
    manager.ensureLayout(for: container)
    let line = manager.defaultLineHeight(for: font)
    let text = max(manager.usedRect(for: container).height, manager.extraLineFragmentRect.maxY)
    let fitted = ceil(min(max(text, Self.minLines * line), Self.maxLines * line) +
      2 * (textView.textContainerInset.height + Self.margin.height))
    guard fitted != height.constant else { return false }
    height.constant = fitted
    return true
  }
}

/// A text field that only shows its bezel. Clicks pass through it to the view behind.
private final class BezelField: NSTextField {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A ring like a text field's focus ring, around a box `outset` points inside its bounds. Clicks
/// pass through it.
final class FocusRingView: NSView {
  /// How far the ring reaches outside the box. It also covers the box's outer half point.
  static let outset: CGFloat = 3
  /// A text field's corner radius, as macOS 27 draws it.
  private static let radius: CGFloat = 6

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    let outer = Self.radius + Self.outset
    let ring = NSBezierPath(roundedRect: bounds, xRadius: outer, yRadius: outer)
    let inner = bounds.insetBy(dx: Self.outset + 0.5, dy: Self.outset + 0.5)
    ring.append(NSBezierPath(roundedRect: inner, xRadius: Self.radius - 0.5, yRadius: Self.radius - 0.5))
    ring.windingRule = .evenOdd
    NSColor.keyboardFocusIndicatorColor.setFill()
    ring.fill()
  }
}

/// The Settings window: the key, the Default Prompt and the advanced limits, plus Screen
/// Recording status and Open at login. Closing it saves what you changed.
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
  static let contentWidth: CGFloat = 440
  static let consoleURL = URL(string: "https://console.anthropic.com/")!

  let window: NSWindow
  let keyField = NSSecureTextField()
  /// Shows the key in place of `keyField` after Show.
  let visibleKeyField = NSTextField()
  let keyHint = NSTextField(labelWithString: "")
  let promptEditor = PromptEditor(width: contentWidth)
  var promptView: PromptTextView { promptEditor.textView }
  /// The prompt's length against the Prompt characters limit.
  let promptCount = NSTextField(labelWithString: "")
  let inputCharactersField = NSTextField()
  let screenshotSizeField = NSTextField()
  let screenshotEdgeField = NSTextField()
  let limitsSection = NSStackView()
  let statusLabel = NSTextField(wrappingLabelWithString: "")
  let screenRecordingLabel = NSTextField(wrappingLabelWithString: "")
  let loginSwitch = NSSwitch()
  let loginNote = NSTextField(wrappingLabelWithString: "")
  let shortcutLabel = NSTextField(wrappingLabelWithString: "")
  private(set) lazy var toggleKeyButton = NSButton(title: "Show", target: self, action: #selector(toggleKeyVisibility))
  private(set) lazy var restorePromptButton = NSButton(title: "Restore Default", target: self,
    action: #selector(restoreDefaultPrompt))
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
  /// The key as last read or saved, so closing knows whether a typed one is new. Like the field,
  /// it's held only while Settings is open.
  private var savedKey = ""
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

    promptView.placeholder = SessionSettings.defaults.defaultPrompt
    promptView.setAccessibilityLabel("Default Prompt")
    promptView.delegate = self
    restorePromptButton.controlSize = .small
    restorePromptButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
    restorePromptButton.toolTip = "Replace the prompt with SnapScreen's default. Undo brings yours back."
    let promptHeader = edgeRow(Self.label("Default Prompt", size: 13, weight: .semibold), restorePromptButton)
    let promptHint = Self.label("Sent with every snip. Leave it empty to use the default.", size: 11)
    promptHint.textColor = .secondaryLabelColor
    promptCount.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    let promptFooter = edgeRow(promptHint, promptCount)
    // The count follows the limit as it's typed.
    inputCharactersField.delegate = self

    advancedButton.bezelStyle = .disclosure
    advancedButton.setButtonType(.pushOnPushOff)
    advancedButton.state = .off
    advancedButton.setAccessibilityLabel("Advanced")
    advancedTitle.isBordered = false
    // The disclosure triangle already names the section.
    advancedTitle.setAccessibilityElement(false)
    let limitsGrid = NSGridView(views: [
      [limitColumn(inputCharactersField, "Prompt characters"), NSGridCell.emptyContentView],
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
      Self.wrappingLabel("Defaults: 4,000 characters, 5 MB, and 2,576 px. The API ceilings are 10 MB and " +
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
    for view in [intro, keyRow, keyHint, promptHeader, promptFooter, statusLabel, separator, screenRecordingRow,
      loginNote, shortcutLabel] {
      view.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
    }

    let stack = NSStackView(views: [
      intro,
      section([Self.label("Anthropic API Key", size: 13, weight: .semibold), keyRow, keyHint]),
      section([promptHeader, promptEditor, promptFooter]),
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
    // Tab moves through the fields in the order they appear.
    window.recalculateKeyViewLoop()
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

  /// A row with `leading` at its start and `trailing` at its end.
  private func edgeRow(_ leading: NSView, _ trailing: NSView) -> NSStackView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.addView(leading, in: .leading)
    row.addView(trailing, in: .trailing)
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
    promptView.setSelectedRange(NSRange(location: (promptView.string as NSString).length, length: 0))
    setLimits(settings.limits)
    promptChanged()
    hasStoredKey = services.keyStore.hasKey
    if hasStoredKey {
      do {
        keyField.stringValue = try services.keyStore.read() ?? ""
        savedKey = keyField.stringValue
      } catch {
        showStatus(Self.message(for: error), isError: true, sticky: true)
      }
    }
    // Typing starts in the key field until there's a key, then at the end of the prompt.
    window.initialFirstResponder = keyField.stringValue.isEmpty ? keyField : promptView
    updateControls()
  }

  private func setLimits(_ limits: SnapScreenLimits) {
    for (input, value) in zip(limitInputs, limitStrings(limits)) { input.field.stringValue = value }
  }

  /// The limits as their fields show them, in `limitInputs` order.
  private func limitStrings(_ limits: SnapScreenLimits) -> [String] {
    [String(limits.maxInputCharacters),
      limits.maxScreenshotBytes % megabyte == 0
        ? String(limits.maxScreenshotBytes / megabyte) : String(Double(limits.maxScreenshotBytes) / Double(megabyte)),
      String(limits.maxScreenshotDimension)]
  }

  /// Whether the fields differ from what's saved: the Default Prompt, a limit, or a new typed key.
  var hasUnsavedChanges: Bool {
    let saved = SessionSettings.load(from: services.defaults)
    let typedPrompt = promptView.string.jsTrimmed
    let apiKey = enteredKey.jsTrimmed
    return (typedPrompt.isEmpty ? SessionSettings.defaults.defaultPrompt : typedPrompt) != saved.defaultPrompt ||
      limitInputs.map { $0.field.stringValue.jsTrimmed } != limitStrings(saved.limits) ||
      (!apiKey.isEmpty && apiKey != savedKey)
  }

  private struct LimitInput {
    let field: NSTextField
    let name: String
    let range: ClosedRange<Int>
  }

  private var limitInputs: [LimitInput] {
    let bytes = SnapScreenLimits.screenshotBytes
    return [
      LimitInput(field: inputCharactersField, name: "Prompt character limit",
        range: SnapScreenLimits.inputCharacters.min...SnapScreenLimits.inputCharacters.max),
      LimitInput(field: screenshotSizeField, name: "Screenshot size limit", range: bytes.min / megabyte...bytes.max / megabyte),
      LimitInput(field: screenshotEdgeField, name: "Screenshot edge limit",
        range: SnapScreenLimits.screenshotDimension.min...SnapScreenLimits.screenshotDimension.max),
    ]
  }

  /// The field's value, or nil when it isn't a whole number in its range.
  private func value(of input: LimitInput) -> Int? {
    guard let number = Double(input.field.stringValue.jsTrimmed), number.isFinite, number.rounded() == number,
      abs(number) < 1e12, input.range.contains(Int(number)) else { return nil }
    return Int(number)
  }

  /// The limits as entered, or nil after reporting the first one that isn't allowed.
  private func readLimits() -> SnapScreenLimits? {
    var values: [Int] = []
    for input in limitInputs {
      guard let value = value(of: input) else {
        showStatus("\(input.name) must be a whole number from \(groupedDigits(input.range.lowerBound)) to " +
          "\(groupedDigits(input.range.upperBound)).", isError: true)
        setAdvancedVisible(true)
        window.makeFirstResponder(input.field)
        return nil
      }
      values.append(value)
    }
    return SnapScreenLimits(maxInputCharacters: values[0], maxScreenshotBytes: values[1] * megabyte,
      maxScreenshotDimension: values[2])
  }

  /// Saves the key, Default Prompt and limits, or reports the first that can't be saved and saves
  /// nothing more. Returns whether it saved.
  @objc @discardableResult func save() -> Bool {
    guard let limits = readLimits() else { return false }
    let typedPrompt = promptView.string.jsTrimmed
    let prompt = typedPrompt.isEmpty ? SessionSettings.defaults.defaultPrompt : typedPrompt
    guard countTextCharacters(prompt) <= limits.maxInputCharacters else {
      showStatus("Default Prompt exceeds the \(groupedDigits(limits.maxInputCharacters)) character limit.", isError: true)
      window.makeFirstResponder(promptView)
      return false
    }
    let apiKey = enteredKey.jsTrimmed
    if !apiKey.isEmpty {
      do {
        try services.keyStore.save(apiKey)
      } catch {
        showStatus(Self.message(for: error), isError: true)
        return false
      }
      hasStoredKey = true
      savedKey = apiKey
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
    return true
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
    savedKey = ""
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

  // MARK: Default Prompt

  func textDidChange(_ notification: Notification) { promptChanged() }

  func controlTextDidChange(_ notification: Notification) {
    if (notification.object as? NSTextField) === inputCharactersField { updatePromptCount() }
  }

  /// Updates what follows the prompt: its count, Restore Default and the box's height.
  private func promptChanged() {
    let typed = promptView.string.jsTrimmed
    restorePromptButton.isEnabled = !typed.isEmpty && typed != SessionSettings.defaults.defaultPrompt
    updatePromptCount()
    if promptEditor.fitToText() { fitWindow() }
  }

  /// Counts what Save checks against the Prompt characters limit, in red when it's over.
  private func updatePromptCount() {
    let count = countTextCharacters(promptView.string.jsTrimmed)
    guard let limit = value(of: limitInputs[0]) else {
      promptCount.stringValue = count == 1 ? "1 character" : "\(groupedDigits(count)) characters"
      promptCount.textColor = .secondaryLabelColor
      promptCount.setAccessibilityLabel(nil)
      return
    }
    promptCount.stringValue = "\(groupedDigits(count)) / \(groupedDigits(limit))"
    promptCount.textColor = count > limit ? .systemRed : .secondaryLabelColor
    promptCount.setAccessibilityLabel("\(groupedDigits(count)) of \(groupedDigits(limit)) characters")
  }

  /// Replaces the prompt with the default one, as an edit that Undo reverses.
  @objc func restoreDefaultPrompt() {
    let text = SessionSettings.defaults.defaultPrompt
    let range = NSRange(location: 0, length: (promptView.string as NSString).length)
    guard promptView.shouldChangeText(in: range, replacementString: text) else { return }
    promptView.replaceCharacters(in: range, with: text)
    promptView.didChangeText()
    promptView.undoManager?.setActionName("Restore Default")
    promptView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    window.makeFirstResponder(promptView)
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

  /// Closing saves what you changed, as Save does. If something can't be saved, Settings stays open
  /// showing why.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    !hasUnsavedChanges || save()
  }

  func windowWillClose(_ notification: Notification) {
    testTask?.cancel()
    testTask = nil
    statusTimer?.invalidate()
    statusTimer = nil
    // The key stays in memory only while Settings is open.
    keyField.stringValue = ""
    visibleKeyField.stringValue = ""
    savedKey = ""
    onClose?()
  }
}
