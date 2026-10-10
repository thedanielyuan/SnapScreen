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

/// Kept below the active panel, click-through except during an edge resize. This preserves
/// Phase 1's tested protection from pointer events falling through a shrinking native panel.
final class PointerShield: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

final class Host: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var session = NativeSession()
  private var panel: CompanionPanel?
  private var previewPanel: CompanionPanel?
  private var selectionView: SelectionView?
  private var cropImage: NSImage?
  private var conversation: ConversationView?
  private var composer: ComposerView?
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
    // CompanionPanel closes on the key's release; this item documents the shortcut.
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
      conversation?.setScreenshot(image)
      armTimeout(seconds: 30)
    case .started:
      // The extension's API timeout is 240 seconds. This only handles a lost authoritative worker.
      armTimeout(seconds: 270)
    case .thinking:
      conversation?.setThinking()
    case .notice(let message, let removedTurns):
      conversation?.addNotice(message, removedTurns: removedTurns)
    case .answer(let text, let status):
      conversation?.updateAnswer(text, status: status)
      if status != .streaming {
        responseTimer?.invalidate()
        announce(status == .done ? "Answer complete" : "Answer stopped")
      }
      #if SNAPSCREEN_TEST_HOOKS
      if status == .done && testScenario == .exchange {
        DispatchQueue.main.async { [weak self] in self?.continueTestExchange() }
      }
      #endif
    case .error(let code, let message):
      responseTimer?.invalidate()
      if selectionView != nil {
        releaseSelection()
        showAnswer(beside: nil, on: nil)
      }
      // The extension sanitizes provider messages before crossing this boundary. It drops refused
      // text from the conversation, so the window does too.
      conversation?.fail(message, clearAnswer: code == "refusal")
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

  private func announce(_ text: String) {
    guard let element = conversation else { return }
    NSAccessibility.post(element: element, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
  }

  /// Media panels (selection and preview) show an image edge to edge under a transparent title bar.
  private func makePanel(title: String, contentSize: NSSize, minimumSize: NSSize, media: Bool) -> CompanionPanel {
    var style: NSWindow.StyleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
    if media { style.insert(.fullSizeContentView) }
    let value = CompanionPanel(contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: style, backing: .buffered, defer: false)
    value.title = title
    value.identifier = NSUserInterfaceItemIdentifier(title)
    value.level = .floating
    value.hidesOnDeactivate = false
    value.becomesKeyOnlyIfNeeded = false
    value.isReleasedWhenClosed = false
    value.autorecalculatesKeyViewLoop = true
    value.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    value.acceptsMouseMovedEvents = true
    value.titlebarAppearsTransparent = true
    value.contentMinSize = minimumSize
    if media {
      value.titleVisibility = .hidden
      value.appearance = NSAppearance(named: .darkAqua)
      value.backgroundColor = Theme.backdrop
    }
    value.delegate = self
    return value
  }

  private static var titlebarHeight: CGFloat {
    let content = NSRect(x: 0, y: 0, width: 400, height: 300)
    return NSWindow.frameRect(forContentRect: content, styleMask: [.titled]).height - content.height
  }

  private func showSelection(_ image: NSImage) {
    let screen = screenUnderPointer()
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    // Shown at captured size when it fits, otherwise fitted within most of the screen.
    let size = imageWindowContentSize(image.size, backingScale: screen?.backingScaleFactor ?? 2,
      maximum: NSSize(width: visible.width * 0.92, height: visible.height * 0.92),
      minimum: NSSize(width: 480, height: 320), chrome: NSSize(width: 16, height: Self.titlebarHeight + 16))
    let window = makePanel(title: "SnapScreen — Select region", contentSize: size,
      minimumSize: NSSize(width: 360, height: 260), media: true)
    window.setFrame(windowFrame(size: size, beside: nil, in: visible), display: false)
    let view = SelectionView()
    view.image = image
    view.onCancel = { [weak self] in self?.cancel() }
    view.onConfirm = { [weak self] rect in self?.selected(rect) }
    window.contentView = view
    panel = window
    selectionView = view
    window.makeKeyAndOrderFront(nil)
    placeShield(below: window)
    window.makeFirstResponder(view)
    #if SNAPSCREEN_TEST_HOOKS
    if testScenario == .exchange {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak view] in
        view?.placeKeyboardSelection()
        view?.confirm()
      }
    }
    #endif
  }

  private func selected(_ rect: NormalizedRect) {
    guard let message = session.command("selected", rect: rect) else { return }
    let screen = panel?.screen
    var anchor: CGRect?
    if let view = selectionView, let window = view.window, let region = view.selectionDisplayRect {
      anchor = window.convertToScreen(view.convert(region, to: nil))
    }
    // Do not create a CGImage crop here: it could retain the full backing pixels. The extension
    // owns cropping and returns the accepted region. Drop every full-image reference before send.
    releaseSelection()
    showAnswer(beside: anchor, on: screen)
    send(message)
    armTimeout(seconds: 30)
  }

  private func releaseSelection() {
    selectionView?.image = nil
    selectionView?.onCancel = nil
    selectionView?.onConfirm = nil
    selectionView = nil
    panel?.delegate = nil
    panel?.contentView = nil
    panel?.close()
    panel = nil
    endPressTracking()
  }

  private func showAnswer(beside anchor: CGRect?, on screen: NSScreen?) {
    let screen = screen ?? screenUnderPointer()
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let window = makePanel(title: "SnapScreen", contentSize: NSSize(width: 460, height: 560),
      minimumSize: NSSize(width: 340, height: 280), media: false)
    window.setFrame(windowFrame(size: window.frame.size, beside: anchor, in: visible), display: false)
    let root = NSView()
    window.contentView = root
    let thread = ConversationView()
    thread.translatesAutoresizingMaskIntoConstraints = false
    thread.onPreview = { [weak self] in self?.showPreview() }
    thread.onRetry = { [weak self] in self?.retryAnswer() }
    let input = ComposerView()
    input.translatesAutoresizingMaskIntoConstraints = false
    input.onSubmit = { [weak self] text in self?.submitFollowup(text) }
    input.onStop = { [weak self] in self?.stopAnswer() }
    input.onChange = { [weak self] in self?.updateControls() }
    thread.focusFallback = { [weak input] in input?.textView }
    root.addSubview(thread)
    root.addSubview(input)
    NSLayoutConstraint.activate([
      thread.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      thread.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      thread.topAnchor.constraint(equalTo: root.topAnchor),
      thread.bottomAnchor.constraint(equalTo: input.topAnchor, constant: -8),
      input.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      input.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      input.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
    ])
    panel = window
    conversation = thread
    composer = input
    thread.beginTurn(question: nil)
    updateControls()
    window.makeKeyAndOrderFront(nil)
    placeShield(below: window)
    window.makeFirstResponder(input.textView)
  }

  #if SNAPSCREEN_TEST_HOOKS
  /// Asks one follow-up after the first answer, then closes after the follow-up's answer.
  private func continueTestExchange() {
    if testFollowupSent { closeAnswer(); return }
    testFollowupSent = true
    composer?.setDraft("SNAPSCREEN_LIVE_FOLLOW_UP")
    composer?.submit()
  }
  #endif

  private func updateControls() {
    conversation?.canRetry = session.canRetry
    conversation?.actionsEnabled = session.active
    guard let composer = composer else { return }
    composer.maximumCharacters = session.maxInputCharacters
    composer.isRunning = [.accepting, .waiting, .streaming].contains(session.phase)
    composer.canStop = session.canStop
    composer.canSubmit = session.canFollowup
  }

  private func submitFollowup(_ text: String) {
    guard let message = session.command("followup", text: text) else { return }
    conversation?.removeAbandonedTurn()
    conversation?.beginTurn(question: text)
    composer?.clearDraft()
    updateControls()
    send(message)
    armTimeout(seconds: 30)
  }

  private func stopAnswer() {
    guard let message = session.command("stop") else { return }
    updateControls()
    send(message)
  }

  private func retryAnswer() {
    guard let message = session.command("retry") else { return }
    conversation?.restartLatestTurn()
    updateControls()
    send(message)
    armTimeout(seconds: 30)
  }

  private func showPreview() {
    guard session.active, let image = cropImage else { return }
    if let existing = previewPanel { existing.makeKeyAndOrderFront(nil); return }
    let screen = panel?.screen ?? screenUnderPointer()
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let size = imageWindowContentSize(image.size, backingScale: 1,
      maximum: NSSize(width: visible.width * 0.8, height: visible.height * 0.8),
      minimum: NSSize(width: 320, height: 220), chrome: NSSize(width: 24, height: Self.titlebarHeight + 24))
    let window = makePanel(title: "Screenshot", contentSize: size, minimumSize: NSSize(width: 240, height: 180), media: true)
    window.setFrame(windowFrame(size: size, beside: nil, in: visible), display: false)
    let preview = PreviewView(image: image)
    window.contentView = preview
    previewPanel = window
    window.makeKeyAndOrderFront(nil)
    placeShield(below: window)
    window.makeFirstResponder(preview)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if sender === previewPanel {
      (previewPanel?.contentView as? PreviewView)?.image = nil
      previewPanel?.delegate = nil
      previewPanel = nil
      // Keep typing in the conversation rather than returning keys to Chrome.
      DispatchQueue.main.async { [weak self] in
        guard let window = self?.panel, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
        if let shield = self?.shield, let panel = self?.panel { shield.order(.below, relativeTo: panel.windowNumber) }
      }
      return true
    }
    if session.phase == .expired { terminate(); return false }
    if session.phase == .selecting { cancel() } else { closeAnswer() }
    return false
  }

  private func cancel() {
    guard let message = session.command("cancelled") else { return }
    send(message)
    terminate()
  }

  private func closeAnswer() {
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
    selectionView?.onCancel = nil
    selectionView = nil
    (previewPanel?.contentView as? PreviewView)?.image = nil
    previewPanel?.contentView = nil
    previewPanel?.delegate = nil
    previewPanel?.close()
    previewPanel = nil
    cropImage = nil
    conversation?.clear()
    conversation = nil
    composer?.clear()
    composer = nil
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
    window.title = "SnapScreen — Session ended"
    window.contentView = SessionEndedView()
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

/// The only content left after the connection ends: no screenshot, answer or draft.
final class SessionEndedView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    let icon = NSImageView(image: Theme.symbol("exclamationmark.circle", size: 30, weight: .regular,
      color: .secondaryLabelColor) ?? NSImage())
    icon.setAccessibilityElement(false)
    let title = NSTextField(labelWithString: "Session ended")
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    let body = NSTextField(wrappingLabelWithString: "Invoke SnapScreen in Chrome to start a new capture.")
    body.font = .systemFont(ofSize: 13)
    body.textColor = .secondaryLabelColor
    body.alignment = .center
    let stack = NSStackView(views: [icon, title, body])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 8
    stack.setCustomSpacing(12, after: icon)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
      body.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

if CommandLine.arguments.contains("--self-test") {
  do {
    _ = NSApplication.shared
    let count = try runProtocolSelfTests() + runGeometryTests() + runAnswerViewTests() + runSelectionViewTests() +
      runConversationViewTests()
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
