import AppKit
import Foundation

#if SNAPSCREEN_TEST_HOOKS
/// Live integration builds only; `npm run build:native` never compiles this. The test writes the
/// scenario to a file so one browser run can drive an unattended exchange and then a held selection.
enum TestScenario: String { case exchange, hold }
let testScenario: TestScenario? = ProcessInfo.processInfo.environment["SNAPSCREEN_TEST_SCENARIO_FILE"]
  .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
  .flatMap { TestScenario(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
#endif

final class CompanionPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// Kept below the active panel, click-through except during an edge resize. This preserves
/// Phase 1's tested protection from pointer events falling through a shrinking native panel.
final class PointerShield: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

final class Host: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
  private var session = NativeSession()
  private var panel: CompanionPanel?
  private var previewPanel: CompanionPanel?
  private var selectionView: SelectionView?
  private var cropImage: NSImage?
  private var answerView: AnswerView?
  private var followupField: NSTextField?
  private var followupEditor: NSTextView?
  private var statusLabel: NSTextField?
  private var noticeLabel: NSTextField?
  private var inputHintLabel: NSTextField?
  private var askButton: NSButton?
  private var stopButton: NSButton?
  private var retryButton: NSButton?
  private var copyButton: NSButton?
  private var previewButton: NSButton?
  private var answerText = ""
  private var monitor: Any?
  private var pressedWindow: CompanionPanel?
  private var pointerTimer: Timer?
  private var responseTimer: Timer?
  private var shield: PointerShield?
  private var liveResizing = false
  private var transportOpen = true
  #if SNAPSCREEN_TEST_HOOKS
  private var testFollowupSent = false
  #endif

  func applicationDidFinishLaunching(_ notification: Notification) {
    installEditingMenu()
    // These events control only the resize shield. No input, clipboard, geometry or content logging.
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
      guard let self = self else { return event }
      if event.type == .leftMouseDown {
        self.endPressTracking()
        self.pressedWindow = event.window as? CompanionPanel
        if let panel = self.pressedWindow, panel.styleMask.contains(.resizable),
          isNearFrameEdge(NSEvent.mouseLocation, panel.frame) { self.raiseShield(below: panel) }
      } else {
        self.endPressTracking()
      }
      return event
    }
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      guard let self = self, let window = self.pressedWindow else { return }
      // AppKit's nested tracking loops may consume mouse-up before the local monitor receives it.
      if NSEvent.pressedMouseButtons & 1 == 0 || !window.isVisible { self.endPressTracking() }
    }
    timer.tolerance = 0.02
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .eventTracking)
    pointerTimer = timer
    armTimeout(seconds: 10)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        while let data = try readFrame(FileHandle.standardInput) {
          let command = try parseCommand(data)
          // Synchronous delivery bounds the queue to one message, including large image frames.
          DispatchQueue.main.sync { autoreleasepool { self?.receive(command) } }
        }
      } catch {
        // Protocol and transport failures expose no payloads, including on stderr.
      }
      DispatchQueue.main.async { self?.expire() }
    }
  }

  private func installEditingMenu() {
    let mainMenu = NSMenu(title: "Main")
    // AppKit reserves the first menu for the application. Keep File and Edit separate.
    let appItem = NSMenuItem(title: "SnapScreen Companion", action: nil, keyEquivalent: "")
    appItem.submenu = NSMenu(title: "SnapScreen Companion")
    mainMenu.addItem(appItem)
    let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    let fileMenu = NSMenu(title: "File")
    fileMenu.addItem(withTitle: "Close window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    fileItem.submenu = fileMenu
    mainMenu.addItem(fileItem)
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)
    NSApp.mainMenu = mainMenu
  }

  private func armTimeout(seconds: TimeInterval) {
    responseTimer?.invalidate()
    let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.expire() }
    RunLoop.main.add(timer, forMode: .common)
    responseTimer = timer
  }

  private func receive(_ command: HostCommand) {
    guard transportOpen, session.receive(command) else { return }
    switch command.payload {
    case .hello:
      responseTimer?.invalidate()
      if let ready = session.readyMessage() { send(ready) }
      // A handshaken host must receive its one capture promptly.
      armTimeout(seconds: 30)
    case .capture(let bytes):
      responseTimer?.invalidate()
      guard let image = decodeImage(bytes) else { expire(); return }
      showSelection(image)
    case .accepted(let bytes, _):
      guard let image = decodeImage(bytes) else { expire(); return }
      cropImage = image
      statusLabel?.stringValue = "Preparing answer…"
      armTimeout(seconds: 30)
    case .started:
      answerText = ""
      answerView?.clear()
      showNotice("")
      statusLabel?.stringValue = "Thinking…"
      // The extension's API timeout is 240 seconds. This only handles a lost authoritative worker.
      armTimeout(seconds: 270)
    case .thinking:
      statusLabel?.stringValue = "Thinking…"
    case .notice(let message):
      showNotice(message)
    case .answer(let text, let status):
      answerText = text
      answerView?.render(text)
      switch status {
      case .streaming: statusLabel?.stringValue = "Answering…"
      case .done:
        responseTimer?.invalidate()
        statusLabel?.stringValue = "Answer complete"
        #if SNAPSCREEN_TEST_HOOKS
        if testScenario == .exchange { DispatchQueue.main.async { [weak self] in self?.continueTestExchange() } }
        #endif
      case .stopped:
        responseTimer?.invalidate()
        statusLabel?.stringValue = "Answer stopped"
      }
    case .error(let code, let message):
      responseTimer?.invalidate()
      // The extension drops refused text from the conversation, so the window does too.
      if code == "refusal" {
        answerText = ""
        answerView?.clear()
      }
      // The extension sanitizes provider messages before crossing this boundary.
      if selectionView != nil {
        releaseSelection()
        showAnswer()
      }
      statusLabel?.stringValue = message
    case .expired:
      expire()
    }
    updateControls()
  }

  private func send(_ message: [String: Any]) {
    guard transportOpen else { return }
    do { try FileHandle.standardOutput.write(contentsOf: framed(message)) }
    catch { expire() }
  }

  private func makePanel(title: String, size: NSSize, answer: Bool = false) -> CompanionPanel {
    let value = CompanionPanel(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
    value.title = title
    value.identifier = NSUserInterfaceItemIdentifier(title)
    value.level = .floating
    value.hidesOnDeactivate = false
    value.becomesKeyOnlyIfNeeded = false
    value.isReleasedWhenClosed = false
    value.autorecalculatesKeyViewLoop = true
    value.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    value.acceptsMouseMovedEvents = true
    value.minSize = NSSize(width: answer ? 560 : 450, height: answer ? 440 : 350)
    value.center()
    value.delegate = self
    return value
  }

  private func showSelection(_ image: NSImage) {
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
    let window = makePanel(title: "SnapScreen — Select region",
      size: NSSize(width: min(1100, screen.width - 60), height: min(760, screen.height - 80)))
    let root = NSView()
    window.contentView = root
    let view = SelectionView()
    view.image = image
    view.translatesAutoresizingMaskIntoConstraints = false
    view.onCancel = { [weak self] in self?.cancel() }
    view.onConfirm = { [weak self] rect in self?.selected(rect) }
    root.addSubview(view)
    let hint = NSTextField(labelWithString: "Drag a region; releasing it asks. Arrows move, Shift + arrows resize, Enter selects. Escape cancels.")
    hint.font = .systemFont(ofSize: 12)
    hint.maximumNumberOfLines = 3
    hint.lineBreakMode = .byWordWrapping
    hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let summary = NSTextField(labelWithString: view.selectionSummary)
    summary.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    summary.setAccessibilityLabel("Selected region")
    view.onSelectionChange = { [weak summary] value in summary?.stringValue = value }
    let guidance = NSStackView(views: [summary, hint])
    guidance.orientation = .vertical
    guidance.alignment = .leading
    guidance.spacing = 4
    let confirm = button("Use selection", #selector(confirmSelection))
    let actions = NSStackView(views: [confirm, button("Cancel selection", #selector(cancel))])
    actions.spacing = 8
    let footer = NSStackView(views: [guidance, actions])
    footer.orientation = .vertical
    footer.alignment = .leading
    footer.spacing = 10
    footer.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(footer)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: root.leadingAnchor), view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      view.topAnchor.constraint(equalTo: root.topAnchor), view.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
      footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
      footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
      footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
      guidance.widthAnchor.constraint(equalTo: footer.widthAnchor),
      hint.widthAnchor.constraint(equalTo: guidance.widthAnchor),
    ])
    panel = window
    selectionView = view
    window.makeKeyAndOrderFront(nil)
    placeShield(below: window)
    window.makeFirstResponder(view)
    #if SNAPSCREEN_TEST_HOOKS
    if testScenario == .exchange {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak view] in view?.confirm() }
    }
    #endif
  }

  private func selected(_ rect: NormalizedRect) {
    guard let message = session.command("selected", rect: rect) else { return }
    // Do not create a CGImage crop here: it could retain the full backing pixels. The extension
    // owns cropping and returns the accepted region. Drop every full-image reference before send.
    releaseSelection()
    showAnswer()
    send(message)
    armTimeout(seconds: 30)
  }

  @objc private func confirmSelection() { selectionView?.confirm() }

  private func releaseSelection() {
    selectionView?.image = nil
    selectionView?.onSelectionChange = nil
    selectionView?.onCancel = nil
    selectionView?.onConfirm = nil
    selectionView = nil
    panel?.delegate = nil
    panel?.contentView = nil
    panel?.close()
    panel = nil
    endPressTracking()
  }

  private func button(_ title: String, _ selector: Selector) -> NSButton {
    let value = CompanionButton(title: title, target: self, action: selector)
    value.bezelStyle = .rounded
    value.setAccessibilityLabel(title)
    return value
  }

  private func showAnswer() {
    let window = makePanel(title: "SnapScreen — Answer", size: NSSize(width: 680, height: 520), answer: true)
    let root = NSView()
    window.contentView = root
    let status = NSTextField(wrappingLabelWithString: "Waiting for the selected region…")
    status.font = .systemFont(ofSize: 12)
    let notice = NSTextField(wrappingLabelWithString: "")
    notice.font = .systemFont(ofSize: 12)
    notice.textColor = .secondaryLabelColor
    notice.isHidden = true
    let answer = AnswerView()
    let field = NSTextField()
    field.placeholderString = "Ask a follow-up"
    field.setAccessibilityLabel("Follow-up question")
    field.target = self
    field.action = #selector(submitFollowup)
    field.delegate = self
    let inputHint = NSTextField(labelWithString: "")
    inputHint.font = .systemFont(ofSize: 11)
    inputHint.textColor = .secondaryLabelColor
    inputHint.setAccessibilityLabel("Follow-up length")
    let ask = button("Ask", #selector(submitFollowup))
    let entry = NSStackView(views: [field, ask])
    entry.spacing = 8
    entry.orientation = .horizontal
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let copy = button("Copy answer", #selector(copyAnswer))
    let preview = button("Preview", #selector(showPreview))
    let stop = button("Stop", #selector(stopAnswer))
    let retry = button("Retry", #selector(retryAnswer))
    let controls = NSStackView(views: [copy, preview, stop, retry, button("Close", #selector(closeAnswer))])
    controls.spacing = 8
    controls.orientation = .horizontal
    let stack = NSStackView(views: [status, notice, answer, entry, inputHint, controls])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
      status.widthAnchor.constraint(equalTo: stack.widthAnchor),
      notice.widthAnchor.constraint(equalTo: stack.widthAnchor),
      answer.widthAnchor.constraint(equalTo: stack.widthAnchor),
      entry.widthAnchor.constraint(equalTo: stack.widthAnchor),
      controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
      answer.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
    ])
    panel = window
    answerView = answer
    followupField = field
    statusLabel = status
    noticeLabel = notice
    inputHintLabel = inputHint
    askButton = ask
    stopButton = stop
    retryButton = retry
    copyButton = copy
    previewButton = preview
    updateControls()
    window.makeKeyAndOrderFront(nil)
    placeShield(below: window)
    window.makeFirstResponder(answer.focusTarget)
  }

  private func showNotice(_ message: String) {
    noticeLabel?.stringValue = message
    noticeLabel?.isHidden = message.isEmpty
  }

  #if SNAPSCREEN_TEST_HOOKS
  /// Asks one follow-up after the first answer, then closes after the follow-up's answer.
  private func continueTestExchange() {
    if testFollowupSent { closeAnswer(); return }
    testFollowupSent = true
    followupField?.stringValue = "SNAPSCREEN_LIVE_FOLLOW_UP"
    submitFollowup()
  }
  #endif

  private func updateControls() {
    let draft = trimProtocolText(followupField?.stringValue ?? "")
    askButton?.isEnabled = session.canFollowup && !draft.isEmpty
      && inputFitsLimits(draft, maximum: session.maxInputCharacters)
    let characters = (followupField?.stringValue ?? "").unicodeScalars.count
    inputHintLabel?.stringValue = "\(characters) / \(session.maxInputCharacters) characters · Return to ask"
    answerView?.copyEnabled = session.active
    followupField?.isEnabled = session.canFollowup
    stopButton?.isEnabled = session.canStop
    retryButton?.isEnabled = session.canRetry
    copyButton?.isEnabled = session.active && !answerText.isEmpty
    previewButton?.isEnabled = session.active && cropImage != nil
    panel?.recalculateKeyViewLoop()
  }

  func controlTextDidChange(_ notification: Notification) { updateControls() }

  func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
    guard let field = followupField, (client as? NSTextField) === field else { return nil }
    if let editor = followupEditor { return editor }
    let editor = NSTextView()
    editor.isFieldEditor = true
    editor.isRichText = false
    editor.importsGraphics = false
    editor.delegate = self
    followupEditor = editor
    return editor
  }

  func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
    guard textView === followupEditor else { return true }
    let current = textView.string as NSString
    guard affectedCharRange.location != NSNotFound, affectedCharRange.location <= current.length,
      affectedCharRange.length <= current.length - affectedCharRange.location else { return false }
    let proposed = current.replacingCharacters(in: affectedCharRange, with: replacementString ?? "")
    let fits = inputFitsLimits(proposed, maximum: session.maxInputCharacters)
    if !fits {
      inputHintLabel?.stringValue = "Follow-up is too long (limit: \(session.maxInputCharacters) characters)."
    }
    return fits
  }

  @objc private func submitFollowup() {
    guard let field = followupField else { return }
    let value = trimProtocolText(field.stringValue)
    guard let message = session.command("followup", text: value) else { return }
    field.stringValue = ""
    statusLabel?.stringValue = "Preparing follow-up…"
    updateControls()
    send(message)
    armTimeout(seconds: 30)
  }

  @objc private func stopAnswer() {
    guard let message = session.command("stop") else { return }
    statusLabel?.stringValue = "Stopping…"
    updateControls()
    send(message)
  }

  @objc private func retryAnswer() {
    guard let message = session.command("retry") else { return }
    statusLabel?.stringValue = "Preparing retry…"
    updateControls()
    send(message)
    armTimeout(seconds: 30)
  }

  @objc private func copyAnswer() {
    guard session.active, !answerText.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(answerText, forType: .string)
    copyButton?.title = "Copied"
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      self?.copyButton?.title = "Copy answer"
    }
  }

  @objc private func showPreview() {
    guard session.active, let image = cropImage else { return }
    if let existing = previewPanel { existing.makeKeyAndOrderFront(nil); return }
    let window = makePanel(title: "SnapScreen — Screenshot preview", size: NSSize(width: 580, height: 420))
    let preview = PreviewView(image: image)
    preview.onClose = { [weak self] in self?.previewPanel?.performClose(nil) }
    window.contentView = preview
    previewPanel = window
    window.makeKeyAndOrderFront(nil)
    placeShield(below: window)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if sender === previewPanel {
      (previewPanel?.contentView as? PreviewView)?.image = nil
      previewPanel?.delegate = nil
      previewPanel = nil
      return true
    }
    if session.phase == .expired { terminate(); return false }
    if session.phase == .selecting { cancel() } else { closeAnswer() }
    return false
  }

  @objc private func cancel() {
    guard let message = session.command("cancelled") else { return }
    send(message)
    terminate()
  }

  @objc private func closeAnswer() {
    guard let message = session.command("close") else { return }
    send(message)
    terminate()
  }

  private func clearContent() {
    responseTimer?.invalidate()
    responseTimer = nil
    endPressTracking()
    liveResizing = false
    lowerShield()
    shield?.orderOut(nil)
    selectionView?.image = nil
    selectionView?.onConfirm = nil
    selectionView?.onSelectionChange = nil
    selectionView?.onCancel = nil
    selectionView = nil
    (previewPanel?.contentView as? PreviewView)?.image = nil
    previewPanel?.contentView = nil
    previewPanel?.delegate = nil
    previewPanel?.close()
    previewPanel = nil
    cropImage = nil
    answerText = ""
    answerView?.clear()
    answerView = nil
    followupField?.stringValue = ""
    followupEditor?.string = ""
    followupEditor?.undoManager?.removeAllActions()
    followupEditor?.delegate = nil
    followupEditor = nil
    followupField?.delegate = nil
    followupField = nil
    inputHintLabel?.stringValue = ""
    inputHintLabel = nil
    statusLabel?.stringValue = ""
    statusLabel = nil
    noticeLabel?.stringValue = ""
    noticeLabel = nil
    askButton = nil
    stopButton = nil
    retryButton = nil
    copyButton = nil
    previewButton = nil
    panel?.makeFirstResponder(nil)
    panel?.contentView = nil
  }

  private func expire() {
    guard transportOpen else { return }
    transportOpen = false
    session.expire()
    try? FileHandle.standardInput.close()
    try? FileHandle.standardOutput.close()
    clearContent()
    guard let window = panel else { terminate(); return }
    // Retain only a notice in an already-visible panel. There are no retry/reconnect commands,
    // and no screenshot, answer or draft is retained or replayed after connection loss.
    window.title = "SnapScreen — Session interrupted"
    let root = NSView()
    let label = NSTextField(wrappingLabelWithString: "This session was interrupted. Invoke SnapScreen in Chrome again to start a new capture.")
    label.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
      label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
      label.centerYAnchor.constraint(equalTo: root.centerYAnchor),
    ])
    window.contentView = root
  }

  private func terminate() {
    clearContent()
    panel?.delegate = nil
    panel?.close()
    panel = nil
    if let monitor = monitor { NSEvent.removeMonitor(monitor) }
    pointerTimer?.invalidate()
    NSApp.terminate(nil)
  }

  func windowWillStartLiveResize(_ notification: Notification) {
    liveResizing = true
    if let window = notification.object as? CompanionPanel { raiseShield(below: window) }
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    liveResizing = false
    lowerShield()
  }

  private func endPressTracking() {
    pressedWindow = nil
    if !liveResizing { lowerShield() }
  }

  private func placeShield(below window: CompanionPanel) {
    guard let frame = (window.screen ?? NSScreen.main)?.frame else { return }
    let value = shield ?? {
      let panel = PointerShield(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)
      panel.isOpaque = false
      panel.backgroundColor = NSColor(calibratedWhite: 0, alpha: 1 / 255)
      panel.ignoresMouseEvents = true
      panel.hasShadow = false
      panel.level = .floating
      panel.hidesOnDeactivate = false
      panel.isReleasedWhenClosed = false
      panel.animationBehavior = .none
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
      return panel
    }()
    shield = value
    if value.frame != frame { value.setFrame(frame, display: true) }
    value.order(.below, relativeTo: window.windowNumber)
  }

  private func raiseShield(below window: CompanionPanel) {
    guard session.phase != .expired else { return }
    placeShield(below: window)
    shield?.ignoresMouseEvents = false
  }

  private func lowerShield() { shield?.ignoresMouseEvents = true }
}

if CommandLine.arguments.contains("--self-test") {
  do {
    _ = NSApplication.shared
    let count = try runProtocolSelfTests() + runAnswerViewTests() + runSelectionViewTests()
    #if SNAPSCREEN_TEST_HOOKS
    print("Native companion self-test: \(count) checks passed (test hooks build)")
    #else
    print("Native companion self-test: \(count) checks passed")
    #endif
    exit(0)
  } catch {
    fputs("Native companion self-test failed: \(error)\n", stderr)
    exit(1)
  }
}

// Chrome launches this window-owning process. No app relay, IPC socket or activation call.
signal(SIGPIPE, SIG_IGN)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let host = Host()
application.delegate = host
application.run()
