#if SNAPSCREEN_TEST_HOOKS
import AppKit
import Security
import SnapScreenCore

/// The real client maps these fixture failures, then the real controller and windows display them.
/// No scenario reads a saved API key, makes a network request or changes the general pasteboard.
private enum FocusFailureFixture: String, CaseIterable {
  case authentication, rateLimit, server, provider, streamError, network
  case malformedStream, incompleteStream, refusal, headerTimeout, bodyTimeout, missingKey, keychain
  /// The real Keychain store reading from a locked keychain, where macOS would ask to unlock it.
  case lockedKeychain

  var failure: AnthropicError {
    switch self {
    case .authentication: return AnthropicError("auth", "Invalid API key. Check your settings.")
    case .rateLimit: return AnthropicError("rate_limit", "Rate limit reached. Try again in ~7s.")
    case .server: return AnthropicError("server", "Service unavailable. Please try again.")
    case .provider: return AnthropicError("api", "API error (422): Fixture provider error")
    case .streamError: return AnthropicError("api", "Fixture stream error")
    case .network: return AnthropicError("network", "Network error. Check your connection and try again.")
    case .malformedStream:
      return AnthropicError("stream", "The API returned malformed streaming data. Please try again.")
    case .incompleteStream:
      return AnthropicError("stream", "The API response ended before it was complete. Please try again.")
    case .refusal: return AnthropicError("refusal", "Claude declined to answer this question.")
    case .headerTimeout, .bodyTimeout:
      return AnthropicError("timeout", "Request timed out. Please try again.")
    case .missingKey:
      return AnthropicError("no_api_key", "Add your Anthropic API key in SnapScreen Settings, then Retry.")
    case .keychain, .lockedKeychain:
      return AnthropicError("keychain",
        KeychainError(operation: .readWithoutPrompt, status: errSecInteractionNotAllowed).message)
    }
  }

  var failsBeforeRequest: Bool { self == .missingKey || self == .keychain || self == .lockedKeychain }
  var hasPartialAnswer: Bool { self == .refusal || self == .bodyTimeout }
}

private final class FocusFailureAPI: HTTPTransport, @unchecked Sendable {
  static let partialAnswer = "SNAPSCREEN_PARTIAL_FAILURE_ANSWER"
  static let recoveredAnswer = "SNAPSCREEN_FAILURE_RETRY_ANSWER"
  private let fixture: FocusFailureFixture
  private let lock = NSLock()
  private var bodies: [Data] = []
  private var pending: AsyncThrowingStream<Data, any Error>.Continuation?

  init(_ fixture: FocusFailureFixture) { self.fixture = fixture }

  var requests: [Data] { lock.withLock { bodies } }

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    let first = lock.withLock {
      bodies.append(request.httpBody ?? Data())
      return bodies.count == 1
    }
    if !first || fixture.failsBeforeRequest {
      return response(body: try Self.answer(Self.recoveredAnswer, stopReason: "end_turn"))
    }
    switch fixture {
    case .authentication: return response(status: 401)
    case .rateLimit: return response(status: 429, headers: ["retry-after": "7"])
    case .server: return response(status: 503)
    case .provider:
      return response(status: 422, body: try JSONSerialization.data(withJSONObject:
        ["error": ["message": "Fixture\nprovider\u{0000} error"]]))
    case .streamError:
      return response(body: try Self.events([
        ["type": "error", "error": ["message": "Fixture\nstream\u{0000} error"]],
      ]))
    case .network: throw URLError(.notConnectedToInternet)
    case .headerTimeout: throw URLError(.timedOut)
    case .malformedStream: return response(body: Data("data: {broken\n\n".utf8))
    case .incompleteStream: return response(body: try Self.text(Self.partialAnswer))
    case .refusal, .bodyTimeout:
      let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
      lock.withLock { pending = continuation }
      continuation.yield(try Self.text(Self.partialAnswer))
      return HTTPResponse(status: 200, headers: ["content-type": "text/event-stream"],
        body: body, cancel: { [weak self] in self?.cancelPending() })
    case .missingKey, .keychain, .lockedKeychain:
      preconditionFailure("key failures occur before transport.send")
    }
  }

  /// The test first observes the partial text, then causes the terminal failure, without a race
  /// against a short timer. This also proves refusal removes text that really reached the window.
  func finishPartialAnswer() throws -> Bool {
    let continuation = takePending()
    guard let continuation else { return false }
    if fixture == .bodyTimeout {
      continuation.finish(throwing: URLError(.timedOut))
    } else {
      continuation.yield(try Self.ending("refusal"))
      continuation.finish()
    }
    return true
  }

  func cancelPending() { takePending()?.finish(throwing: CancellationError()) }

  private func takePending() -> AsyncThrowingStream<Data, any Error>.Continuation? {
    lock.withLock {
      defer { pending = nil }
      return pending
    }
  }

  private func response(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) -> HTTPResponse {
    HTTPResponse(status: status, headers: headers, body: AsyncThrowingStream { continuation in
      if !body.isEmpty { continuation.yield(body) }
      continuation.finish()
    }, cancel: {})
  }

  private static func text(_ text: String) throws -> Data {
    try events([
      ["type": "message_start", "message": ["id": "msg_focus_failure", "role": "assistant"]],
      ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
      ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]],
    ])
  }

  private static func ending(_ reason: String) throws -> Data {
    try events([
      ["type": "content_block_stop", "index": 0],
      ["type": "message_delta", "delta": ["stop_reason": reason]],
      ["type": "message_stop"],
    ])
  }

  private static func answer(_ text: String, stopReason: String) throws -> Data {
    try Self.text(text) + ending(stopReason)
  }

  private static func events(_ events: [[String: Any]]) throws -> Data {
    try events.reduce(into: Data()) { result, event in
      result.append(Data("data: ".utf8))
      result.append(try JSONSerialization.data(withJSONObject: event))
      result.append(Data("\n\n".utf8))
    }
  }
}

@MainActor
private final class FocusFailureWindows: SessionControllerDelegate {
  let snips: SnipWindows
  private(set) var failure: AnthropicError?
  private(set) var notices: [String] = []

  init(controller: SessionController) {
    snips = SnipWindows(controller: controller, showNotice: { _, _ in })
    controller.delegate = self
  }

  func session(_ session: SnipSession, didReport event: SessionEvent) {
    if case .failed(let failure) = event { self.failure = failure }
    snips.session(session, didReport: event)
  }

  func sessionController(_ controller: SessionController, showNotice message: String) {
    notices.append(message)
  }
}

private struct FocusFailureTestError: Error, CustomStringConvertible {
  let description: String
}

@MainActor
private final class FocusFailureKeyAccess {
  /// Recovery unlocks the locked keychain, as Settings would after asking for its password.
  var recovered = false { didSet { if recovered { _ = lockedKeychain?.keychain.unlock() } } }
  private(set) var reads = 0
  /// The real store and its locked temporary keychain, for `lockedKeychain`.
  let lockedKeychain: (keychain: TemporaryKeychain, store: KeychainStore)?

  init(for fixture: FocusFailureFixture) throws {
    guard fixture == .lockedKeychain else {
      lockedKeychain = nil
      return
    }
    let keychain = try TemporaryKeychain()
    let store = KeychainStore(service: "com.snapscreen.app.focus-test", account: UUID().uuidString,
      keychains: [keychain.reference])
    try store.save("sk-ant-focus-fixture")
    guard keychain.lock() else { throw FocusFailureTestError(description: "the temporary keychain locks") }
    lockedKeychain = (keychain, store)
  }

  func read(for fixture: FocusFailureFixture) throws -> String? {
    reads += 1
    if let store = lockedKeychain?.store { return try store.readForRequest() }
    if !recovered {
      if fixture == .missingKey { return nil }
      if fixture == .keychain { throw fixture.failure }
    }
    return "sk-ant-focus-fixture"
  }
}

/// A keychain file of the test's own, outside the user's keychain list, that the test can lock and
/// unlock with its own password. The SecKeychain calls are deprecated, so they're looked up.
final class TemporaryKeychain {
  private typealias Create = @convention(c) (UnsafePointer<CChar>, UInt32, UnsafeRawPointer?, DarwinBoolean,
    UnsafeRawPointer?, UnsafeMutablePointer<UnsafeRawPointer?>) -> OSStatus
  private typealias Unlock = @convention(c) (UnsafeRawPointer, UInt32, UnsafeRawPointer?, DarwinBoolean) -> OSStatus
  private typealias Change = @convention(c) (UnsafeRawPointer) -> OSStatus
  private static let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)

  let reference: SecKeychain
  private let password = Array(UUID().uuidString.utf8)

  init() throws {
    guard let security = Self.security, let create = dlsym(security, "SecKeychainCreate") else {
      throw FocusFailureTestError(description: "SecKeychainCreate is available")
    }
    let path = NSTemporaryDirectory() + "snapscreen-focus-\(UUID().uuidString).keychain-db"
    var keychain: UnsafeRawPointer?
    let status = password.withUnsafeBytes {
      unsafeBitCast(create, to: Create.self)(path, UInt32($0.count), $0.baseAddress, false, nil, &keychain)
    }
    guard status == errSecSuccess, let keychain else {
      throw FocusFailureTestError(description: "a temporary keychain is created: \(status)")
    }
    reference = Unmanaged<SecKeychain>.fromOpaque(keychain).takeRetainedValue()
  }

  private func call(_ name: String) -> OSStatus {
    guard let security = Self.security, let function = dlsym(security, name) else { return errSecUnimplemented }
    return unsafeBitCast(function, to: Change.self)(Unmanaged.passUnretained(reference).toOpaque())
  }

  func lock() -> Bool { call("SecKeychainLock") == errSecSuccess }

  func unlock() -> Bool {
    guard let security = Self.security, let function = dlsym(security, "SecKeychainUnlock") else { return false }
    return password.withUnsafeBytes {
      unsafeBitCast(function, to: Unlock.self)(Unmanaged.passUnretained(reference).toOpaque(), UInt32($0.count),
        $0.baseAddress, true)
    } == errSecSuccess
  }

  /// Removes the file and any item in it.
  func delete() { _ = call("SecKeychainDelete") }
}

/// Fails the run, after cancelling it, if a password dialog appears, rather than letting it take the
/// keyboard. It polls WindowServer off the main thread, which a dialog's read would block, and gives
/// up after half a minute in case a read blocks without one.
final class PasswordDialogWatchdog: @unchecked Sendable {
  private let lock = NSLock()
  private var running = true

  init() {
    let started = Date()
    Thread.detachNewThread { [self] in
      while lock.withLock({ running }) {
        let dialogs = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
          .filter { $0[kCGWindowOwnerName as String] as? String == "SecurityAgent" }
        if !dialogs.isEmpty || Date().timeIntervalSince(started) > 30 {
          let cancelled = dialogs.isEmpty ? false : Self.cancelDialog()
          let mode = CommandLine.arguments.contains("--focus-test") ? "focus" : "live"
          FileHandle.standardError.write(Data(("SnapScreen \(mode) test failed: " + (dialogs.isEmpty ?
            "a Keychain read was still blocked after 30 seconds\n" :
            "a Keychain password dialog appeared (cancelled: \(cancelled))\n")).utf8))
          exit(1)
        }
        usleep(50_000)
      }
    }
  }

  func stop() { lock.withLock { running = false } }

  /// Presses the dialog's own Cancel or Deny button, which refuses without entering anything.
  private static func cancelDialog() -> Bool {
    guard AXIsProcessTrusted(),
      let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.SecurityAgent").first
    else { return false }
    var queue = [AXUIElementCreateApplication(agent.processIdentifier)]
    while !queue.isEmpty {
      let element = queue.removeFirst()
      var title: AnyObject?
      AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
      if ["Cancel", "Deny"].contains(title as? String ?? "") {
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
      }
      var children: AnyObject?
      AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
      queue += children as? [AXUIElement] ?? []
    }
    return false
  }
}

@MainActor
func runFailureFocusTests(using driver: FocusTestDriver) async throws {
  for fixture in FocusFailureFixture.allCases {
    try await checkRequestFailure(fixture, using: driver)
  }
  try await checkRequestFailure(.authentication, retry: false, using: driver)
  try await checkSelectionTimeout(whileCropping: false, using: driver)
  try await checkSelectionTimeout(whileCropping: true, using: driver)
}

@MainActor
private func checkRequestFailure(_ fixture: FocusFailureFixture, retry: Bool = true,
  using driver: FocusTestDriver) async throws {
  let api = FocusFailureAPI(fixture)
  let key = try FocusFailureKeyAccess(for: fixture)
  // A locked keychain must fail the read before macOS can ask for its password.
  let watchdog = key.lockedKeychain.map { _ in PasswordDialogWatchdog() }
  defer {
    watchdog?.stop()
    key.lockedKeychain?.keychain.delete()
  }
  if let locked = key.lockedKeychain {
    let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: locked.store.service, kSecAttrAccount as String: locked.store.account,
      kSecMatchSearchList as String: [locked.keychain.reference]]
    try driver.require(KeychainLock.state(of: item) == .locked, "the key's temporary keychain is locked before the snip")
  }
  let controller = SessionController(answers: AnthropicClient(transport: api),
    apiKey: { try key.read(for: fixture) }, settings: { .defaults })
  let observer = FocusFailureWindows(controller: controller)
  defer {
    observer.snips.closeAll()
    observer.snips.shields.stop()
    api.cancelPending()
  }
  let capture = driver.capture
  guard let session = controller.start(capture: { capture }) else {
    throw FocusFailureTestError(description: "the \(fixture.rawValue) session starts")
  }
  try await driver.wait("the \(fixture.rawValue) selection opens") {
    observer.snips.sessions.first?.overlay?.isVisible == true
  }
  guard let windows = observer.snips.sessions.first else {
    throw FocusFailureTestError(description: "the \(fixture.rawValue) session has windows")
  }
  try await driver.select(windows)
  if fixture.hasPartialAnswer {
    try await driver.wait("the \(fixture.rawValue) partial answer is visible before failure") {
      windows.conversation?.turn?.answer.renderedText == FocusFailureAPI.partialAnswer
    }
    try await driver.probe("while \(fixture.rawValue) waits with partial text")
    try driver.require(try api.finishPartialAnswer(), "the fixture releases its pending \(fixture.rawValue)")
  }
  try await driver.wait("the \(fixture.rawValue) request reports its failure") { session.phase == .failed }
  guard let panel = windows.panel, let turn = windows.conversation?.turn else {
    throw FocusFailureTestError(description: "the \(fixture.rawValue) failure keeps its conversation")
  }
  try driver.require(observer.failure == fixture.failure && turn.state == .failed(fixture.failure.message) &&
    turn.failure.message.string == fixture.failure.message && !turn.failure.isHidden,
    "the real client/controller displays the mapped \(fixture.rawValue) error")
  try driver.require(session.canRetry && !session.canStop && windows.stopButton?.isHidden == true &&
    !turn.failure.retryButton.isHidden && turn.failure.retryButton.isEnabled && !windows.dismissesOnOutsideClick,
    "the \(fixture.rawValue) failure exposes passive Retry and keeps its window")
  try driver.require(observer.notices.isEmpty && key.reads == 1 &&
    api.requests.count == (fixture.failsBeforeRequest ? 0 : 1),
    "\(fixture.rawValue) follows the request path without a notice or an extra request")
  if fixture == .refusal {
    try driver.require(turn.answer.renderedText.isEmpty && turn.copyButton.isHidden,
      "refusal clears the previously displayed answer and removes its Copy action")
  } else if fixture == .bodyTimeout {
    try driver.require(turn.answer.renderedText == FocusFailureAPI.partialAnswer && !turn.copyButton.isHidden,
      "a timeout during the body keeps the previously displayed partial answer")
  }
  try driver.checkPanel(panel, "\(fixture.rawValue) failure")
  try await driver.probe("with the \(fixture.rawValue) error displayed")
  if fixture == .provider {
    try await driver.checkContextMenu(turn.failure.message)
    try driver.require(session.phase == .failed && !turn.failure.isHidden,
      "the error's Select All and Copy actions leave its failed session open")
  }
  if !retry {
    guard let close = panel.standardWindowButton(.closeButton) else {
      throw FocusFailureTestError(description: "the failed conversation has a close button")
    }
    try await driver.click(close)
    try await driver.wait("a failed conversation closes without Retry") { observer.snips.sessions.isEmpty }
    try driver.require(session.phase == .ended && !panel.isVisible && windows.conversation == nil &&
      windows.previewPanel == nil && api.requests.count == 1,
      "closing a failed conversation releases its content without another request")
    try await driver.probe("after closing a failed conversation without Retry")
    return
  }
  key.recovered = true
  try await driver.click(turn.failure.retryButton)
  try await driver.wait("Retry recovers from \(fixture.rawValue)") { session.phase == .ready }
  try driver.require(turn.answer.renderedText == FocusFailureAPI.recoveredAnswer &&
    turn.failure.isHidden && turn.failure.message.string.isEmpty && windows.dismissesOnOutsideClick,
    "Retry replaces the \(fixture.rawValue) error with the finished answer")
  let requests = api.requests
  let requestBodies = try requests.map {
    try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: $0), options: .sortedKeys)
  }
  try driver.require(key.reads == 2 && requests.count == (fixture.failsBeforeRequest ? 1 : 2) &&
    requestBodies.allSatisfy { $0 == requestBodies.first },
    "Retry rereads the key and sends the unchanged crop and request after \(fixture.rawValue)")
  try driver.checkPanel(panel, "\(fixture.rawValue) recovered conversation")
  try await driver.probe("after Retry recovers from \(fixture.rawValue)")
  guard let close = panel.standardWindowButton(.closeButton) else {
    throw FocusFailureTestError(description: "the recovered \(fixture.rawValue) panel has a close button")
  }
  try await driver.click(close)
  try await driver.wait("the recovered \(fixture.rawValue) conversation closes") { observer.snips.sessions.isEmpty }
  try driver.require(session.phase == .ended && !panel.isVisible,
    "closing the recovered \(fixture.rawValue) panel ends its session")
  try await driver.probe("after closing the recovered \(fixture.rawValue) conversation")
}

@MainActor
private func checkSelectionTimeout(whileCropping: Bool, using driver: FocusTestDriver) async throws {
  let stage = whileCropping ? "while cropping" : "with the overlay open"
  let hooks = SessionFocusTestHooks(holdCrop: whileCropping)
  let api = FocusFailureAPI(.missingKey)
  let controller = SessionController(answers: AnthropicClient(transport: api),
    apiKey: { "sk-ant-focus-fixture" }, focusTestHooks: hooks)
  let observer = FocusFailureWindows(controller: controller)
  defer {
    observer.snips.closeAll()
    observer.snips.shields.stop()
    hooks.releaseCrop()
  }
  let capture = driver.capture
  guard let session = controller.start(capture: { capture }) else {
    throw FocusFailureTestError(description: "the selection-timeout session starts \(stage)")
  }
  try await driver.wait("the timeout-test overlay opens") { observer.snips.sessions.first?.overlay?.isVisible == true }
  guard let windows = observer.snips.sessions.first, let overlay = windows.overlay else {
    throw FocusFailureTestError(description: "the timeout test has an overlay")
  }
  try driver.checkPanel(overlay, "before selection timeout")
  if whileCropping {
    try await driver.select(windows)
    try await driver.wait("cropping suspends before accepting the screenshot") { hooks.isCropSuspended }
    try driver.require(session.phase == .cropping && windows.panel?.isVisible == true &&
      windows.stopButton?.isEnabled == false, "the cropping timeout starts with a waiting conversation")
  }
  try await driver.probe("before selection timeout \(stage)")
  try driver.require(hooks.expireSelection(), "the real scheduled selection-expiry callback fires \(stage)")
  try await driver.wait("selection expiry ends the session \(stage)") { session.phase == .ended }
  try driver.require(!overlay.isVisible && windows.overlay == nil && windows.selectionView == nil &&
    api.requests.isEmpty && observer.notices.isEmpty,
    "selection expiry releases the frozen overlay without starting a request \(stage)")
  if whileCropping {
    guard let panel = windows.panel, let ended = panel.contentView as? SessionEndedView else {
      throw FocusFailureTestError(description: "expiry during cropping replaces the conversation with its ended notice")
    }
    try driver.require(ended.messageLabel.stringValue == SessionWindows.endedMessage &&
      windows.conversation == nil && windows.stopButton == nil && windows.previewPanel == nil &&
      !windows.dismissesOnOutsideClick,
      "expiry during cropping releases the thread and leaves only the session-ended notice")
    try driver.checkPanel(panel, "session-ended notice after cropping timeout")
    try await driver.probe("with the session-ended notice after cropping timeout")
    try driver.require(!ended.messageLabel.isSelectable, "the Session ended message isn't selectable text")
    try await driver.checkNoNativeMenu(on: ended.messageLabel, "the Session ended message")
    hooks.releaseCrop()
    try await driver.wait("the cancelled crop finishes after expiry") { hooks.hasFinishedCrop }
    try await driver.probe("after the expired crop completes")
    try driver.require(api.requests.isEmpty && session.phase == .ended &&
      panel.contentView === ended && windows.conversation == nil,
      "late crop completion cannot revive the ended session or make a request")
    guard let close = panel.standardWindowButton(.closeButton) else {
      throw FocusFailureTestError(description: "the session-ended panel has a close button")
    }
    try await driver.click(close)
    try await driver.wait("the session-ended close button dismisses its window") { observer.snips.sessions.isEmpty }
    try driver.require(!panel.isVisible, "closing the session-ended notice hides its panel")
  } else {
    try driver.require(observer.snips.sessions.isEmpty && windows.panel == nil,
      "expiry with the overlay open closes every window for that snip")
  }
  try await driver.probe("after selection timeout cleanup \(stage)")
}
#endif
