#if SNAPSCREEN_TEST_HOOKS
import AppKit
import Carbon.HIToolbox

/// The opt-in focus test's real browser, for `--focus --chrome`: an isolated instance of the
/// installed Google Chrome, with a temporary profile, showing scripts/fixtures/focus-recorder.html.
/// A debugger, extension or automation switch would change how Chrome handles focus, so none is
/// attached. This process reads the page through its title and Chrome's focused window and element
/// through Accessibility, and answers the focus test's commands as `LiveFocusTarget` does. It has
/// no windows and never activates. Reports describe that fixture only and travel through pipes.
@MainActor
final class ChromeFocusTarget: NSObject, NSApplicationDelegate {
  /// How the page's title starts. The rest is its state as JSON, then Chrome's " - Google Chrome".
  private static let titlePrefix = "SnapScreen focus recorder {"
  private var chrome: NSRunningApplication?
  private var app: AXUIElement?
  private var window: AXUIElement?
  /// The field's element, which must stay Chrome's focused element.
  private var field: AXUIElement?
  private var observer: AXObserver?
  private var monitor: Timer?
  private var measuring = false
  private var quitting = false
  private var nativeFailures = 0
  private var nativeFailureReasons: [String: Int] = [:]
  private var samples = 0
  private var fullscreen = false
  private var fullscreenExitEvents = 0
  /// The page's totals at the last reset, so that a report counts only what happened since.
  private var baseline: [String: Int] = [:]
  private var pending = Data()
  private var terminations: DispatchSourceSignal?

  private struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  /// What the page's title last said. Its totals count since the page loaded.
  private struct Page {
    let time: Double
    let focused: Bool
    let activeElement: Bool
    let visible: Bool
    let totals: [String: Int]
    let text: String

    func total(_ name: String) -> Int { totals[name] ?? 0 }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // The focus test ends this process with SIGTERM, or by exiting, which closes its pipes.
    signal(SIGPIPE, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let terminations = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    terminations.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.quit() } }
    terminations.resume()
    self.terminations = terminations
    FileHandle.standardInput.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      Task { @MainActor in
        if data.isEmpty { self?.quit() } else { self?.receive(data) }
      }
    }
    Task { @MainActor in
      do {
        try await start()
      } catch {
        report(["error": String(describing: error)])
      }
    }
  }

  private func start() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let profile = environment["SNAPSCREEN_FOCUS_CHROME_PROFILE"], let path = environment["SNAPSCREEN_FOCUS_PAGE"] else {
      throw Failure(description: "run the Chrome focus test through scripts/test-app-live.sh --focus --chrome")
    }
    guard AXIsProcessTrusted() && CGPreflightPostEventAccess() else {
      throw Failure(description: "Accessibility isn't approved for the terminal running --focus --chrome")
    }
    guard let location = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
      throw Failure(description: "Google Chrome isn't installed")
    }
    var page = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)!
    page.queryItems = [URLQueryItem(name: "automated", value: nil)]
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.addsToRecentItems = false
    // Its own profile keeps the user's Chrome, its windows and its data out of the test. The
    // switches only skip first-run screens, the Keychain, extensions and background downloads.
    configuration.arguments = ["--user-data-dir=\(profile)", "--no-first-run", "--no-default-browser-check",
      "--use-mock-keychain", "--disable-sync", "--disable-background-networking", "--disable-component-update",
      "--disable-default-apps", "--disable-extensions", "--disable-search-engine-choice-screen", "--new-window",
      page.url!.absoluteString]
    let chrome = try await NSWorkspace.shared.openApplication(at: location, configuration: configuration)
    self.chrome = chrome
    let app = AXUIElementCreateApplication(chrome.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 1)
    self.app = app
    try await until("Chrome opens the recorder page", seconds: 30) {
      self.window = self.recorderWindow()
      return self.window != nil
    }
    // Where the WKWebView target puts its window.
    let screen = screenUnderPointer() ?? NSScreen.main!
    try setFrame(screen.visibleFrame.insetBy(dx: 20, dy: 20))
    try await until("Chrome comes to the front", seconds: 10) {
      NSWorkspace.shared.frontmostApplication?.processIdentifier == chrome.processIdentifier
    }
    if CommandLine.arguments.contains("--fullscreen") {
      try set(window, "AXFullScreen", kCFBooleanTrue)
      // A fullscreen window spans the display's width; on a display with a camera housing, macOS
      // keeps it below the menu bar's height.
      guard await poll(seconds: 10, {
        self.isFullscreen && self.frame(of: self.window).map { abs($0.width - screen.frame.width) < 1 } == true
      }) else {
        throw Failure(description: "Chrome's window enters a fullscreen Space: fullscreen \(isFullscreen), " +
          "frame \(frame(of: window).map { NSStringFromRect($0) } ?? "none"), display \(NSStringFromRect(screen.frame))")
      }
      // The Space's animation ends after the window reaches its fullscreen frame.
      try await Task.sleep(for: .seconds(1.5))
    }
    fullscreen = isFullscreen
    // Chrome builds its pages' accessibility trees once a client reads its role, as assistive
    // apps do, and that takes a moment.
    _ = axValue(app, kAXRoleAttribute)
    try await focusField(within: 8)
    observe(chrome, app)
    let monitor = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.sample() }
    }
    RunLoop.main.add(monitor, forMode: .common)
    self.monitor = monitor
    let controls = try await positiveControls()
    guard let center = frame(of: field).map({ NSPoint(x: $0.midX, y: $0.midY) }), let number = windowNumber() else {
      throw Failure(description: "the recorder's field and window can be found")
    }
    measuring = true
    let version = Bundle(url: location)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    report(["ready": true, "pid": Int(chrome.processIdentifier), "window": number, "x": center.x, "y": center.y,
      "positiveControl": controls.values.allSatisfy { $0 }, "positiveControls": controls,
      "browser": "Google Chrome \(version ?? "of unknown version")"])
  }

  /// Each observer must first see a deliberate change of the kind it watches for, or the run is
  /// invalid: the address bar takes the keyboard from the page and its field, and a temporary tab
  /// hides the page. A native menu from another process, as SnapScreen's menus once were, takes
  /// Chrome's key window without Chrome or the page noticing, so only the probe can see it: a key
  /// typed while the menu is open must not reach the page.
  private func positiveControls() async throws -> [String: Bool] {
    var results: [String: Bool] = [:]
    resetNative()
    measuring = true
    guard let typed = await freshPage() else { throw Failure(description: "the page reports its state") }
    try postKey(CGKeyCode(kVK_ANSI_L), flags: .maskCommand)
    // In a fullscreen Space the window's title is empty while the address bar is focused, so the
    // page's blurs are read once the field has the keyboard again.
    let left = await poll(seconds: 3) { self.nativeFailureReasons["responderSamples", default: 0] > 0 }
    try await focusField()
    let returned = await freshPage()
    results["addressBar"] = left && returned.map {
      $0.total("window blur") > typed.total("window blur") && $0.total("field blur") > typed.total("field blur")
    } == true
    guard let shown = await freshPage() else { throw Failure(description: "the page reports its state") }
    try postKey(CGKeyCode(kVK_ANSI_T), flags: .maskCommand)
    var hidden = await poll(seconds: 3) { self.recorderWindow() == nil }
    if hidden {
      // Only the temporary tab may close: the window's title is no longer the recorder's.
      try postKey(CGKeyCode(kVK_ANSI_W), flags: .maskCommand) {
        self.axString(self.window, kAXTitleAttribute)?.hasPrefix(Self.titlePrefix) == false
      }
      hidden = await poll(seconds: 3) {
        guard let page = self.page() else { return false }
        return page.total("visibility hidden") > shown.total("visibility hidden") &&
          page.total("visibility visible") > shown.total("visibility visible")
      }
    }
    results["temporaryTab"] = hidden
    try await focusField()
    guard let quiet = await freshPage() else { throw Failure(description: "the page reports its state") }
    let menu = NSMenu()
    menu.addItem(withTitle: "SnapScreen focus test", action: nil, keyEquivalent: "")
    // Both run inside the menu's tracking loop.
    let typing = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { try? self?.postKey(CGKeyCode(kVK_ANSI_X), flags: []) }
    }
    RunLoop.main.add(typing, forMode: .common)
    menu.perform(#selector(NSMenu.cancelTracking), with: nil, afterDelay: 0.5, inModes: [.common])
    let point = frame(of: window).map { NSPoint(x: $0.midX, y: $0.midY) } ?? .zero
    _ = menu.popUp(positioning: nil, at: point, in: nil)
    try await Task.sleep(for: .milliseconds(200))
    results["nativeMenu"] = await freshPage().map { $0.text == quiet.text && $0.total("key") == quiet.total("key") } == true
    try await focusField()
    measuring = false
    resetNative()
    return results
  }

  /// Gives the page's field the keyboard with a click, as a person would, unless it has it within
  /// `seconds`, and keeps its element as the one that must stay focused.
  private func focusField(within seconds: Double = 1) async throws {
    if !(await poll(seconds: seconds, fieldHasKeyboard)) {
      guard let window = frame(of: window) else { throw Failure(description: "the recorder's window has a frame") }
      // Where the page puts its field: centered 150 by 85 points from the bottom left.
      try await click(at: NSPoint(x: window.minX + 150, y: window.minY + 85))
      guard await poll(seconds: 5, fieldHasKeyboard) else {
        throw Failure(description: "a click gives the page's field the keyboard: \(focusState())")
      }
    }
    field = axElement(app, kAXFocusedUIElementAttribute)
  }

  /// Chrome is in front with the recorder's window focused, and its focused element is the field,
  /// which the page also reports has the keyboard.
  private func fieldHasKeyboard() -> Bool {
    guard let chrome, let window, NSWorkspace.shared.frontmostApplication?.processIdentifier == chrome.processIdentifier,
      axElement(app, kAXFocusedWindowAttribute).map({ CFEqual($0, window) }) == true,
      let focused = axElement(app, kAXFocusedUIElementAttribute), axString(focused, kAXRoleAttribute) == kAXTextAreaRole,
      axString(focused, kAXDescriptionAttribute) == "Focus probe", let page = page() else { return false }
    return page.focused && page.activeElement && page.visible
  }

  /// What Chrome and the page report, for a failure's message.
  private func focusState() -> String {
    let focusedWindow = axElement(app, kAXFocusedWindowAttribute)
    let focused = axElement(app, kAXFocusedUIElementAttribute)
    return "frontmost PID \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0), Chrome's " +
      "\(chrome?.processIdentifier ?? 0); the recorder's window focused " +
      "\(focusedWindow.flatMap { focusedWindow in window.map { CFEqual(focusedWindow, $0) } } ?? false); " +
      "focused element \(axString(focused, kAXRoleAttribute) ?? "none") \(axString(focused, kAXDescriptionAttribute) ?? ""); " +
      "title \(axString(window, kAXTitleAttribute) ?? "none")"
  }

  /// Notifications keep a loss shorter than the sampling interval.
  private func observe(_ chrome: NSRunningApplication, _ app: AXUIElement) {
    var observer: AXObserver?
    guard AXObserverCreate(chrome.processIdentifier, { _, element, notification, context in
      guard let context else { return }
      let target = Unmanaged<ChromeFocusTarget>.fromOpaque(context).takeUnretainedValue()
      MainActor.assumeIsolated { target.notice(notification as String, element) }
    }, &observer) == .success, let observer else { return }
    let context = Unmanaged.passUnretained(self).toOpaque()
    for name in [kAXApplicationDeactivatedNotification, kAXFocusedWindowChangedNotification,
      kAXFocusedUIElementChangedNotification] {
      AXObserverAddNotification(observer, app, name as CFString, context)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    self.observer = observer
  }

  private func notice(_ name: String, _ element: AXUIElement) {
    guard measuring else { return }
    let reason: String
    switch name {
    case kAXApplicationDeactivatedNotification: reason = "resignActiveEvents"
    case kAXFocusedWindowChangedNotification where window.map({ !CFEqual(element, $0) }) ?? true: reason = "resignKeyEvents"
    case kAXFocusedUIElementChangedNotification where field.map({ !CFEqual(element, $0) }) ?? true: reason = "responderEvents"
    default: return
    }
    nativeFailures += 1
    nativeFailureReasons[reason, default: 0] += 1
  }

  private func sample() {
    guard measuring, let chrome, let window, let field else { return }
    var reasons: [String] = []
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != chrome.processIdentifier {
      reasons.append("inactiveSamples")
    }
    if axElement(app, kAXFocusedWindowAttribute).map({ CFEqual($0, window) }) != true { reasons.append("nonKeySamples") }
    if axElement(app, kAXFocusedUIElementAttribute).map({ CFEqual($0, field) }) != true { reasons.append("responderSamples") }
    if !reasons.isEmpty {
      nativeFailures += 1
      for reason in reasons { nativeFailureReasons[reason, default: 0] += 1 }
    }
    samples += 1
    if samples % 10 == 0 {
      let now = isFullscreen
      if fullscreen && !now { fullscreenExitEvents += 1 }
      fullscreen = now
    }
  }

  private func resetNative() {
    nativeFailures = 0
    nativeFailureReasons = [:]
  }

  private func receive(_ data: Data) {
    pending.append(data)
    while let newline = pending.firstIndex(of: 10) {
      let command = String(decoding: pending.prefix(upTo: newline), as: UTF8.self).split(separator: " ")
      pending.removeSubrange(...newline)
      switch command.first {
      case "launch": LiveFocusTarget.openAppShell { [weak self] in self?.report($0) }
      case "open": LiveFocusTarget.openFileInAppShell { [weak self] in self?.report($0) }
      case "yield": activate(command.dropFirst().first.flatMap { pid_t($0) })
      default:
        let reset = command.first == "reset"
        Task { @MainActor in await reportState(reset: reset) }
      }
    }
  }

  /// The same report as `LiveFocusTarget`'s. `reset` also starts counting again from now.
  private func reportState(reset: Bool) async {
    guard let page = await freshPage() else {
      return report(["error": "the recorder's title stopped updating", "nativeFailures": nativeFailures,
        "nativeFailureReasons": nativeFailureReasons, "title": axString(window, kAXTitleAttribute) ?? "none"])
    }
    let since = { (name: String) in page.total(name) - (self.baseline[name] ?? 0) }
    var result: [String: Any] = ["focused": page.focused, "activeElement": page.activeElement,
      "blurCount": since("window blur") + since("field blur"), "visible": page.visible,
      "hiddenCount": since("visibility hidden"), "text": page.text,
      "focusEvents": ["windowBlur": since("window blur"), "windowFocus": since("window focus"),
        "fieldBlur": since("field blur"), "fieldFocus": since("field focus")],
      "fieldPointerDownCount": page.total("field pointerdown"), "nativeFailures": nativeFailures,
      "nativeFailureReasons": nativeFailureReasons, "fullscreen": isFullscreen,
      "fullscreenExitEvents": fullscreenExitEvents]
    if reset {
      result["restored"] = fieldHasKeyboard() &&
        axElement(app, kAXFocusedUIElementAttribute).flatMap { focused in field.map { CFEqual(focused, $0) } } == true
      baseline = page.totals
      resetNative()
    }
    report(result)
  }

  /// Chrome can't be asked to yield activation, so a script activates SnapScreen, as another app
  /// or a launcher can.
  private func activate(_ pid: pid_t?) {
    guard let pid, let identifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
      return report(["yielded": false])
    }
    let script = Process()
    script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    script.arguments = ["-e", "tell application id \"\(identifier)\" to activate"]
    script.terminationHandler = { [weak self] process in
      let activated = process.terminationStatus == 0
      Task { @MainActor in self?.report(["yielded": activated]) }
    }
    do { try script.run() } catch { report(["yielded": false]) }
  }

  /// Quits this test's Chrome, then exits. The script also stops anything left with its profile.
  private func quit() {
    guard !quitting else { return }
    quitting = true
    FileHandle.standardInput.readabilityHandler = nil
    measuring = false
    monitor?.invalidate()
    guard let chrome, !chrome.isTerminated else { exit(0) }
    chrome.terminate()
    let deadline = Date().addingTimeInterval(3)
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
      guard chrome.isTerminated || Date() > deadline else { return }
      if !chrome.isTerminated { chrome.forceTerminate() }
      exit(0)
    }
  }

  // MARK: Chrome through Accessibility

  private func recorderWindow() -> AXUIElement? {
    (axValue(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).first {
      axString($0, kAXTitleAttribute)?.hasPrefix(Self.titlePrefix) == true
    }
  }

  private func page() -> Page? {
    guard let title = axString(window, kAXTitleAttribute), title.hasPrefix(Self.titlePrefix),
      let end = title.range(of: "}", options: .backwards) else { return nil }
    let json = title[title.index(title.startIndex, offsetBy: Self.titlePrefix.count - 1)..<end.upperBound]
    guard let state = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
      let time = state["time"] as? Double, let focused = state["focused"] as? Bool,
      let activeElement = state["activeElement"] as? Bool, let visible = state["visible"] as? Bool,
      let totals = state["totals"] as? [String: Int], let text = state["text"] as? String else { return nil }
    return Page(time: time, focused: focused, activeElement: activeElement, visible: visible, totals: totals, text: text)
  }

  /// The page's state from a title it wrote after this call; it writes one every 25 ms.
  private func freshPage() async -> Page? {
    let requested = Date().timeIntervalSince1970 * 1000
    for _ in 0..<400 {
      if let page = page(), page.time >= requested { return page }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return nil
  }

  private var isFullscreen: Bool { axValue(window, "AXFullScreen") as? Bool == true }

  /// The recorder's window in WindowServer's list, which the focus test orders panels against.
  private func windowNumber() -> Int? {
    guard let chrome, let frame = frame(of: window) else { return nil }
    let height = CGDisplayBounds(CGMainDisplayID()).height
    return (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []).first { info in
        guard info[kCGWindowOwnerPID as String] as? Int == Int(chrome.processIdentifier),
          info[kCGWindowLayer as String] as? Int == 0,
          let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
        else { return false }
        return abs(bounds.minX - frame.minX) < 1 && abs(height - bounds.maxY - frame.minY) < 1 &&
          abs(bounds.width - frame.width) < 1 && abs(bounds.height - frame.height) < 1
      }?[kCGWindowNumber as String] as? Int
  }

  private func axValue(_ element: AXUIElement?, _ name: String) -> AnyObject? {
    guard let element else { return nil }
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
  }

  private func axElement(_ element: AXUIElement?, _ name: String) -> AXUIElement? {
    guard let value = axValue(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
  }

  private func axString(_ element: AXUIElement?, _ name: String) -> String? { axValue(element, name) as? String }

  /// An element's frame in AppKit's screen coordinates.
  private func frame(of element: AXUIElement?) -> NSRect? {
    guard let position = axValue(element, kAXPositionAttribute), let size = axValue(element, kAXSizeAttribute),
      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else {
      return nil
    }
    return NSRect(x: origin.x, y: CGDisplayBounds(CGMainDisplayID()).height - origin.y - extent.height,
      width: extent.width, height: extent.height)
  }

  private func setFrame(_ frame: NSRect) throws {
    var origin = CGPoint(x: frame.minX, y: CGDisplayBounds(CGMainDisplayID()).height - frame.maxY)
    var size = frame.size
    try set(window, kAXPositionAttribute, AXValueCreate(.cgPoint, &origin)!)
    try set(window, kAXSizeAttribute, AXValueCreate(.cgSize, &size)!)
  }

  private func set(_ element: AXUIElement?, _ name: String, _ value: AnyObject) throws {
    guard let element, AXUIElementSetAttributeValue(element, name as CFString, value) == .success else {
      throw Failure(description: "Chrome accepts its window's \(name)")
    }
  }

  // MARK: Input, only to this test's Chrome while it's in front

  /// `allowed` adds a condition checked just before posting.
  private func postKey(_ code: CGKeyCode, flags: CGEventFlags, allowed: () -> Bool = { true }) throws {
    try requireChromeInFront()
    guard allowed() else { throw Failure(description: "Chrome is in the expected state before a shortcut is posted") }
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
      event?.flags = flags
      event?.post(tap: .cghidEventTap)
    }
  }

  private func click(at point: NSPoint) async throws {
    try requireChromeInFront()
    let location = CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
      CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)?
        .post(tap: .cghidEventTap)
      try await Task.sleep(for: .milliseconds(60))
    }
  }

  private func requireChromeInFront() throws {
    guard let chrome, NSWorkspace.shared.frontmostApplication?.processIdentifier == chrome.processIdentifier else {
      throw Failure(description: "the test's Chrome is in front before any input is posted")
    }
  }

  private func poll(seconds: Double, _ predicate: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !predicate() {
      guard Date() < deadline else { return false }
      try? await Task.sleep(for: .milliseconds(25))
    }
    return true
  }

  private func until(_ message: String, seconds: Double, _ predicate: () -> Bool) async throws {
    guard await poll(seconds: seconds, predicate) else { throw Failure(description: message) }
  }

  private func report(_ value: [String: Any]) {
    guard !quitting, var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    data.append(10)
    try? FileHandle.standardOutput.write(contentsOf: data)
  }
}
#endif
