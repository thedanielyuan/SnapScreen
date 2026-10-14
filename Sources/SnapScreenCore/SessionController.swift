import CoreGraphics
import Foundation

// Snips and their answers. The app calls a session's methods as you select, stop, retry and
// close, and its delegate receives the session's events.

/// A display's contents, frozen when the shortcut was pressed.
public struct FrozenScreen: Equatable, Sendable {
  public let image: CGImage
  /// The display it shows, which the selection overlay covers.
  public let displayID: CGDirectDisplayID

  public init(image: CGImage, displayID: CGDirectDisplayID) {
    self.image = image
    self.displayID = displayID
  }
}

/// A capture failure with a message written for the user. Other failures get a generic message.
public struct CaptureError: Error, Equatable, Sendable {
  public let message: String

  public init(_ message: String) { self.message = message }
}

/// What a session reports to the app's windows.
public enum SessionEvent: Equatable, Sendable {
  public enum AnswerStatus: Sendable {
    case streaming
    case done
    case stopped
  }

  /// Show the frozen screen over its display, for the user to select a region.
  case captured(FrozenScreen)
  /// The selection, cropped and fitted to the limits. The answer and each Retry send this PNG.
  case accepted(Data)
  /// A request started: the answer or a Retry.
  case started
  case thinking
  /// The answer so far, at most ten times a second while it streams, then once when it's done or
  /// stopped.
  case answer(String, AnswerStatus)
  /// The request failed, with a message written for the user.
  case failed(AnthropicError)
  /// The session ended without the app closing it: a new snip replaced its selection, the
  /// selection timed out, or cropping failed. Its windows should close.
  case ended
}

/// The app's windows. Calls arrive on the main actor. `select` and `retry` report nothing before
/// they return, so the app can update its windows after calling them.
@MainActor
public protocol SessionControllerDelegate: AnyObject {
  func session(_ session: SnipSession, didReport event: SessionEvent)
  /// A snip failed before it showed anything, so a notice should say why.
  func sessionController(_ controller: SessionController, showNotice message: String)
  /// A snip was refused because `SessionController.maxSessions` sessions are open. Unless the
  /// delegate offers more, a notice says so with `SessionController.fullMessage`.
  func sessionControllerIsFull(_ controller: SessionController)
}

extension SessionControllerDelegate {
  public func sessionControllerIsFull(_ controller: SessionController) {
    sessionController(controller, showNotice: SessionController.fullMessage)
  }
}

/// What a session needs from `AnthropicClient`, so tests can script answers.
public protocol AnswerClient: Sendable {
  func analyzeImage(apiKey: String, image: Data, hiddenInstruction: String?, userQuestion: String?,
    limits: SnapScreenLimits, handlers: StreamHandlers) async throws -> String
}

extension AnthropicClient: AnswerClient {}

/// Runs main-actor work after a delay. Tests replace it to fire timers when they choose.
struct SessionScheduler: Sendable {
  let after: @Sendable (Duration, @escaping @MainActor @Sendable () -> Void) -> Void

  static let live = SessionScheduler { delay, action in
    Task { @MainActor in
      try? await Task.sleep(for: delay)
      action()
    }
  }
}

/// Starts snips and holds up to four sessions at once.
@MainActor
public final class SessionController {
  public static let maxSessions = 4
  /// What a snip refused at `maxSessions` says.
  public nonisolated static let fullMessage = "Close a SnapScreen window before starting another snip."
  /// An unfinished selection ends after this long.
  static let selectionTimeout: Duration = .seconds(120)
  /// Streaming answer text reaches the windows at most this often.
  static let updateInterval: Duration = .milliseconds(100)

  public weak var delegate: (any SessionControllerDelegate)?
  private(set) var sessions: [SnipSession] = []

  let answers: any AnswerClient
  let apiKey: @MainActor () throws -> String?
  let settings: @MainActor () -> SessionSettings
  let scheduler: SessionScheduler
  let cropSelection: @Sendable (CGImage, CGRect, SnapScreenLimits) async throws -> Data

  /// `apiKey` is read for each request, so a key saved in Settings applies to a Retry in an open
  /// conversation. An `AnthropicError` it throws, such as for a Keychain that denied access, fails
  /// that request with its message. `settings` is read once per snip and kept for its Retries.
  public convenience init(answers: any AnswerClient = AnthropicClient(),
    apiKey: @escaping @MainActor () throws -> String?,
    settings: @escaping @MainActor () -> SessionSettings = { SessionSettings.load() }) {
    self.init(answers: answers, apiKey: apiKey, settings: settings, scheduler: .live, cropSelection: cropAndFit)
  }

  init(answers: any AnswerClient, apiKey: @escaping @MainActor () throws -> String?,
    settings: @escaping @MainActor () -> SessionSettings, scheduler: SessionScheduler,
    cropSelection: @escaping @Sendable (CGImage, CGRect, SnapScreenLimits) async throws -> Data) {
    self.answers = answers
    self.apiKey = apiKey
    self.settings = settings
    self.scheduler = scheduler
    self.cropSelection = cropSelection
  }

  /// Starts a snip. `capture` freezes the display to snip. A selection that hasn't been accepted
  /// yet ends, reporting `ended`. With four sessions open, it tells the delegate and returns nil.
  @discardableResult
  public func start(capture: @escaping @Sendable () async throws -> FrozenScreen) -> SnipSession? {
    for session in sessions where !session.isAccepted { session.expire() }
    guard sessions.count < Self.maxSessions else {
      delegate?.sessionControllerIsFull(self)
      return nil
    }
    let session = SnipSession(controller: self, settings: settings())
    sessions.append(session)
    scheduler.after(Self.selectionTimeout) { [weak session] in
      if let session, !session.isAccepted { session.expire() }
    }
    session.capture(with: capture)
    return session
  }

  func remove(_ session: SnipSession) {
    sessions.removeAll { $0 === session }
  }
}

/// Crops a frozen screen to the selection and fits it to the limits, off the main actor.
private func cropAndFit(_ image: CGImage, _ rect: CGRect, _ limits: SnapScreenLimits) async throws -> Data {
  try await Task.detached(priority: .userInitiated) {
    fitScreenshotToLimits(try cropImage(image, normalizedRect: rect), limits: limits)
  }.value
}

#if SNAPSCREEN_TEST_HOOKS
/// Controls the real selection-expiry callback and crop completion in the live focus tests.
/// Production builds have neither this API nor a way to shorten their selection timeout.
public final class SessionFocusTestHooks: @unchecked Sendable {
  private let lock = NSLock()
  private var expiry: (@MainActor @Sendable () -> Void)?
  private var cropContinuation: CheckedContinuation<Void, Never>?
  private var holdCrop: Bool
  private var cropFinished = false

  public init(holdCrop: Bool = false) { self.holdCrop = holdCrop }

  public var isCropSuspended: Bool { lock.withLock { cropContinuation != nil } }
  public var hasFinishedCrop: Bool { lock.withLock { cropFinished } }

  /// Fires the callback installed by `start`, without changing the production timer or expiry.
  @MainActor
  public func expireSelection() -> Bool {
    let action = lock.withLock { () -> (@MainActor @Sendable () -> Void)? in
      defer { expiry = nil }
      return expiry
    }
    action?()
    return action != nil
  }

  /// A cancelled crop may still finish. Tests release it after expiry to check that it is ignored.
  public func releaseCrop() {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      holdCrop = false
      defer { cropContinuation = nil }
      return cropContinuation
    }
    continuation?.resume()
  }

  fileprivate func waitForCrop() async {
    await withCheckedContinuation { continuation in
      let held = lock.withLock {
        guard holdCrop else { return false }
        cropContinuation = continuation
        return true
      }
      if !held { continuation.resume() }
    }
  }

  fileprivate func scheduleExpiry(_ action: @escaping @MainActor @Sendable () -> Void) {
    lock.withLock { expiry = action }
  }

  fileprivate func finishedCrop() { lock.withLock { cropFinished = true } }
}

extension SessionController {
  /// Uses the usual client, cropping and expiry paths, with deterministic test-only timing.
  public convenience init(answers: any AnswerClient,
    apiKey: @escaping @MainActor () throws -> String?, focusTestHooks: SessionFocusTestHooks) {
    let timeout = Self.selectionTimeout
    let scheduler = SessionScheduler { delay, action in
      if delay == timeout { focusTestHooks.scheduleExpiry(action) }
      else { SessionScheduler.live.after(delay, action) }
    }
    self.init(answers: answers, apiKey: apiKey, settings: { .defaults }, scheduler: scheduler,
      cropSelection: { image, rect, limits in
        await focusTestHooks.waitForCrop()
        defer { focusTestHooks.finishedCrop() }
        return try await cropAndFit(image, rect, limits)
      })
  }
}
#endif

/// One snip: its frozen screen, then its screenshot and answer. The app calls these methods from
/// its windows, and the session reports through the controller's delegate. When it ends, it stops
/// any request and releases every image and all text.
@MainActor
public final class SnipSession {
  public enum Phase: Sendable {
    case capturing
    case selecting
    case cropping
    /// Answered.
    case ready
    case running
    case failed
    case stopped
    case ended
  }

  public private(set) var phase = Phase.capturing
  private weak var controller: SessionController?
  /// The Default Prompt and limits when the snip started.
  private(set) var settings: SessionSettings?
  private(set) var frozen: FrozenScreen?
  /// The accepted selection, which the answer and each Retry send.
  private(set) var crop: Data?
  /// The request in progress.
  private(set) var generation: Generation?
  /// The capture, then the crop.
  private var setup: Task<Void, Never>?

  init(controller: SessionController, settings: SessionSettings) {
    self.controller = controller
    self.settings = settings
  }

  public var canRetry: Bool { phase == .failed || phase == .stopped }
  public var canStop: Bool { phase == .running }

  var isAccepted: Bool { crop != nil }

  /// Crops the frozen screen to `rect`, given as fractions of its width and height from its
  /// top-left corner, then asks for the answer. Returns false unless the session is selecting.
  @discardableResult
  public func select(_ rect: CGRect) -> Bool {
    guard phase == .selecting, let frozen, let settings, let controller else { return false }
    phase = .cropping
    let cropSelection = controller.cropSelection
    setup = Task {
      let fitted: Data
      do {
        fitted = try await cropSelection(frozen.image, rect, settings.limits)
      } catch {
        if phase == .cropping { expire() }
        return
      }
      guard phase == .cropping else { return }
      // Accept, and start the answer, before reporting it. From here, a new snip leaves this
      // conversation alone.
      crop = fitted
      self.frozen = nil
      generate()
      report(.accepted(fitted))
    }
    return true
  }

  /// Sends the failed or stopped request again, unchanged.
  @discardableResult
  public func retry() -> Bool {
    guard canRetry else { return false }
    generate()
    return true
  }

  /// Stops the request and reports the answer so far before returning.
  @discardableResult
  public func stop() -> Bool {
    guard phase == .running, let generation else { return false }
    self.generation = nil
    generation.task?.cancel()
    phase = .stopped
    report(.answer(generation.relay.text, .stopped))
    return true
  }

  /// Cancels the selection or closes the conversation. The session reports nothing more.
  public func close() { end() }

  func capture(with capture: @escaping @Sendable () async throws -> FrozenScreen) {
    setup = Task {
      do {
        let screen = try await capture()
        guard phase == .capturing else { return }
        frozen = screen
        phase = .selecting
        report(.captured(screen))
      } catch {
        guard phase == .capturing, let controller else { return }
        end()
        controller.delegate?.sessionController(controller,
          showNotice: (error as? CaptureError)?.message ?? "SnapScreen couldn't capture the screen. Try again.")
      }
    }
  }

  /// Ends a session the app didn't close. One still capturing has shown nothing, so it ends quietly.
  func expire() {
    guard phase != .ended else { return }
    let shown = phase != .capturing
    let delegate = controller?.delegate
    end()
    if shown { delegate?.session(self, didReport: .ended) }
  }

  private func end() {
    guard phase != .ended else { return }
    phase = .ended
    controller?.remove(self)
    setup?.cancel()
    generation?.task?.cancel()
    setup = nil
    settings = nil
    frozen = nil
    crop = nil
    generation = nil
  }

  private func report(_ event: SessionEvent) {
    guard phase != .ended else { return }
    controller?.delegate?.session(self, didReport: event)
  }

  private func owns(_ generation: Generation) -> Bool {
    phase != .ended && self.generation === generation
  }

  private func generate() {
    guard phase != .ended, crop != nil else { return }
    let generation = Generation()
    self.generation = generation
    phase = .running
    generation.task = Task { await run(generation) }
  }

  private func run(_ generation: Generation) async {
    guard owns(generation) else { return }
    report(.started)
    guard owns(generation), let controller, let crop, let settings else { return }
    do {
      guard let apiKey = try controller.apiKey(), !apiKey.isEmpty else {
        throw AnthropicError("no_api_key", "Add your Anthropic API key in SnapScreen Settings, then Retry.")
      }
      let answer = try await controller.answers.analyzeImage(apiKey: apiKey, image: crop,
        hiddenInstruction: settings.defaultPrompt, userQuestion: nil, limits: settings.limits,
        handlers: streamHandlers(for: generation, scheduler: controller.scheduler))
      guard owns(generation) else { return }
      self.generation = nil
      phase = .ready
      report(.answer(answer, .done))
    } catch {
      guard owns(generation) else { return }
      let failure = error as? AnthropicError ?? (error as? RequestLimitError).map(AnthropicError.init)
        ?? AnthropicError("request_failed", "SnapScreen could not complete this request. Try again.")
      self.generation = nil
      phase = .failed
      report(.failed(failure))
    }
  }

  /// Thinking is reported at once. Answer text, which can arrive many times a frame, is reported
  /// at most every `updateInterval`. Both arrive on the task reading the answer.
  private func streamHandlers(for generation: Generation, scheduler: SessionScheduler) -> StreamHandlers {
    let relay = generation.relay
    let interval = SessionController.updateInterval
    return StreamHandlers(
      onThinking: { [weak self] in
        Task { @MainActor in
          guard let self, self.owns(generation) else { return }
          self.report(.thinking)
        }
      },
      onDelta: { [weak self] text in
        guard relay.update(text) else { return }
        scheduler.after(interval) {
          guard let self, self.owns(generation) else { return }
          self.report(.answer(relay.take(), .streaming))
        }
      })
  }
}

/// One request: the answer or a Retry.
@MainActor
final class Generation {
  let relay = AnswerRelay()
  var task: Task<Void, Never>?
}

/// The answer text so far. The task reading the answer writes it, and the main actor reads it.
final class AnswerRelay: @unchecked Sendable {
  private let lock = NSLock()
  private var latest = ""
  private var scheduled = false

  var text: String { lock.withLock { latest } }

  /// Keeps the text, and returns whether an update needs scheduling for it.
  func update(_ text: String) -> Bool {
    lock.withLock {
      latest = text
      defer { scheduled = true }
      return !scheduled
    }
  }

  /// The text for a scheduled update. Text after this schedules another.
  func take() -> String {
    lock.withLock {
      scheduled = false
      return latest
    }
  }
}
