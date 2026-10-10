import CoreGraphics
import Foundation

// Snips and their conversations, ported from src/background/native-session.ts without the native
// messaging bridge. The app calls a session's methods where the companion sent commands, and the
// delegate receives the events the extension sent the companion.

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
  /// The selection, cropped and fitted to the limits. Every request in the session sends this PNG.
  case accepted(Data)
  /// A request started: the first answer, a follow-up or a Retry.
  case started
  case thinking
  /// Older turns were removed to keep the screenshot and the new request within the turn limit.
  case notice(String, removedTurns: Int)
  /// The answer so far, at most ten times a second while it streams, then once when it's done or
  /// stopped.
  case answer(String, AnswerStatus)
  /// The request failed, with a message written for the user.
  case failed(AnthropicError)
  /// The session ended without the app closing it: a new snip replaced its selection, the
  /// selection timed out, or cropping failed. Its windows should close.
  case ended
}

/// The app's windows. Calls arrive on the main actor. `select`, `ask` and `retry` report nothing
/// before they return, so the app can update its windows after calling them.
@MainActor
public protocol SessionControllerDelegate: AnyObject {
  func session(_ session: SnipSession, didReport event: SessionEvent)
  /// A snip failed before it showed anything, so a notice should say why.
  func sessionController(_ controller: SessionController, showNotice message: String)
}

/// What a session needs from `AnthropicClient`, so tests can script answers.
public protocol AnswerClient: Sendable {
  func analyzeImage(apiKey: String, image: Data, hiddenInstruction: String?, userQuestion: String?,
    limits: SnapScreenLimits, handlers: StreamHandlers) async throws -> Answer
  func followUp(apiKey: String, text: String, history: [AnthropicMessage], sessionInstruction: String?,
    limits: SnapScreenLimits, handlers: StreamHandlers) async throws -> Answer
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
  /// An unfinished selection ends after this long.
  static let selectionTimeout: Duration = .seconds(120)
  /// Streaming answer text reaches the windows at most this often.
  static let updateInterval: Duration = .milliseconds(100)

  public weak var delegate: (any SessionControllerDelegate)?
  private(set) var sessions: [SnipSession] = []

  let answers: any AnswerClient
  let apiKey: @MainActor () -> String?
  let settings: @MainActor () -> SessionSettings
  let scheduler: SessionScheduler
  let cropSelection: @Sendable (CGImage, CGRect, SnapScreenLimits) async throws -> Data

  /// `apiKey` is read for each request, so a key saved in Settings applies to open conversations.
  /// `settings` is read once per snip and kept for its whole conversation.
  public convenience init(answers: any AnswerClient = AnthropicClient(),
    apiKey: @escaping @MainActor () -> String?,
    settings: @escaping @MainActor () -> SessionSettings = { SessionSettings.load() }) {
    self.init(answers: answers, apiKey: apiKey, settings: settings, scheduler: .live, cropSelection: cropAndFit)
  }

  init(answers: any AnswerClient, apiKey: @escaping @MainActor () -> String?,
    settings: @escaping @MainActor () -> SessionSettings, scheduler: SessionScheduler,
    cropSelection: @escaping @Sendable (CGImage, CGRect, SnapScreenLimits) async throws -> Data) {
    self.answers = answers
    self.apiKey = apiKey
    self.settings = settings
    self.scheduler = scheduler
    self.cropSelection = cropSelection
  }

  /// Starts a snip. `capture` freezes the display to snip. A selection that hasn't been accepted
  /// yet ends, reporting `ended`. With four sessions open, this shows a notice and returns nil.
  @discardableResult
  public func start(capture: @escaping @Sendable () async throws -> FrozenScreen) -> SnipSession? {
    for session in sessions where !session.isAccepted { session.expire() }
    guard sessions.count < Self.maxSessions else {
      delegate?.sessionController(self, showNotice: "Close a SnapScreen window before starting another snip.")
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

/// One snip: its frozen screen, then its screenshot and conversation. The app calls these methods
/// from its windows, and the session reports through the controller's delegate. When it ends, it
/// stops any request and releases every image and all text.
@MainActor
public final class SnipSession {
  public enum Phase: Sendable {
    case capturing
    case selecting
    case cropping
    /// Answered, so the user can ask a follow-up.
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
  /// The accepted selection, which every request sends.
  private(set) var crop: Data?
  private(set) var history: [AnthropicMessage] = []
  private(set) var display: [DisplayMessage] = []
  private(set) var generation: Generation?
  /// The failed or stopped request that Retry sends again.
  private(set) var retryGeneration: Generation?
  /// The capture, then the crop.
  private var setup: Task<Void, Never>?

  init(controller: SessionController, settings: SessionSettings) {
    self.controller = controller
    self.settings = settings
  }

  public var canAsk: Bool { phase == .ready || phase == .failed || phase == .stopped }
  public var canRetry: Bool { (phase == .failed || phase == .stopped) && retryGeneration != nil }
  public var canStop: Bool { phase == .running }
  /// The longest question the composer accepts.
  public var maxInputCharacters: Int {
    (settings?.limits ?? .defaults).normalized.maxInputCharacters
  }

  var isAccepted: Bool { crop != nil }

  /// Crops the frozen screen to `rect`, given as fractions of its width and height from its
  /// top-left corner, then asks for the first answer. Returns false unless the session is
  /// selecting.
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
      // Accept, and start the first answer, before reporting it. From here, a new snip leaves this
      // conversation alone.
      crop = fitted
      self.frozen = nil
      generate(userText: nil, retry: nil)
      report(.accepted(fitted))
    }
    return true
  }

  /// Asks a question in the conversation. Returns false while a request runs or before the
  /// selection is accepted.
  @discardableResult
  public func ask(_ text: String) -> Bool {
    guard canAsk else { return false }
    generate(userText: text, retry: nil)
    return true
  }

  /// Sends the failed or stopped request again, building on the conversation before it.
  @discardableResult
  public func retry() -> Bool {
    guard canRetry, let retry = retryGeneration else { return false }
    generate(userText: retry.userText, retry: retry)
    return true
  }

  /// Stops the request and keeps the answer so far, which it reports before returning.
  @discardableResult
  public func stop() -> Bool {
    guard phase == .running, let generation, let crop, let settings else { return false }
    self.generation = nil
    generation.task?.cancel()
    let partialAnswer = generation.relay.text
    apply(settleStoppedConversation(kind: generation.kind, baseDisplayMessages: generation.baseDisplayMessages,
      baseHistory: generation.baseHistory, partialAnswer: partialAnswer, image: crop, userText: generation.userText,
      sessionInstruction: settings.defaultPrompt))
    retryGeneration = generation
    phase = .stopped
    report(.answer(partialAnswer, .stopped))
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
    history = []
    display = []
    generation = nil
    retryGeneration = nil
  }

  private func report(_ event: SessionEvent) {
    guard phase != .ended else { return }
    controller?.delegate?.session(self, didReport: event)
  }

  private func owns(_ generation: Generation) -> Bool {
    phase != .ended && self.generation === generation
  }

  private func apply(_ state: ConversationState) {
    history = state.conversationHistory
    display = state.displayMessages
  }

  private func generate(userText: String?, retry: Generation?) {
    guard phase != .ended, crop != nil else { return }
    let baseHistory = retry?.baseHistory ?? history
    let generation = Generation(kind: baseHistory.isEmpty ? .initial : .followUp, userText: userText,
      baseHistory: baseHistory, baseDisplayMessages: retry?.baseDisplayMessages ?? display)
    self.generation = generation
    retryGeneration = nil
    phase = .running
    generation.task = Task { await run(generation) }
  }

  private func run(_ generation: Generation) async {
    guard owns(generation) else { return }
    report(.started)
    guard owns(generation), let controller, let crop, let settings else { return }
    do {
      guard let apiKey = controller.apiKey(), !apiKey.isEmpty else {
        throw AnthropicError("no_api_key", "Add your Anthropic API key in SnapScreen Settings, then Retry.")
      }
      let aligned = try prepareAlignedConversationForNewestTurn(generation.baseDisplayMessages,
        generation.baseHistory, maxConversationTurns: settings.limits.maxConversationTurns)
      generation.baseHistory = aligned.state.conversationHistory
      generation.baseDisplayMessages = aligned.state.displayMessages
      if aligned.removedTurns > 0 {
        report(.notice(describeRemovedTurns(aligned.removedTurns), removedTurns: aligned.removedTurns))
        guard owns(generation) else { return }
      }
      let handlers = streamHandlers(for: generation, scheduler: controller.scheduler)
      let answer: Answer
      if generation.kind == .initial {
        answer = try await controller.answers.analyzeImage(apiKey: apiKey, image: crop,
          hiddenInstruction: settings.defaultPrompt, userQuestion: generation.userText, limits: settings.limits,
          handlers: handlers)
      } else {
        answer = try await controller.answers.followUp(apiKey: apiKey, text: generation.userText ?? "",
          history: generation.baseHistory, sessionInstruction: settings.defaultPrompt, limits: settings.limits,
          handlers: handlers)
      }
      guard owns(generation) else { return }
      apply(settleSuccessfulConversation(kind: generation.kind, baseDisplayMessages: generation.baseDisplayMessages,
        baseHistory: generation.baseHistory, assistantText: answer.text, image: crop, providerHistory: answer.history,
        userText: generation.userText, sessionInstruction: settings.defaultPrompt))
      self.generation = nil
      phase = .ready
      report(.answer(answer.text, .done))
    } catch {
      guard owns(generation) else { return }
      let failure = error as? AnthropicError ?? (error as? RequestLimitError).map(AnthropicError.init)
        ?? AnthropicError("request_failed", "SnapScreen could not complete this request. Try again.")
      // Refused text is never kept as an answer or sent back with a follow-up.
      let partialAnswer = failure.code == "refusal" ? "" : generation.relay.text
      if generation.kind == .initial {
        apply(settleFailedFirstAnswer(partialAnswer: partialAnswer, errorMessage: failure.message, image: crop,
          sessionInstruction: settings.defaultPrompt, userText: generation.userText))
      } else {
        // A follow-up builds on an answered history, which can't fail this check.
        apply((try? settleFailedFollowUp(baseDisplayMessages: generation.baseDisplayMessages,
          baseHistory: generation.baseHistory, partialAnswer: partialAnswer, errorMessage: failure.message,
          image: crop, sessionInstruction: settings.defaultPrompt, userText: generation.userText ?? ""))?.state
          ?? ConversationState(displayMessages: generation.baseDisplayMessages,
            conversationHistory: generation.baseHistory))
      }
      self.generation = nil
      retryGeneration = generation
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

/// One request, and the conversation it builds on. A failed or stopped one is kept for Retry.
@MainActor
final class Generation {
  let kind: AnswerKind
  let userText: String?
  var baseHistory: [AnthropicMessage]
  var baseDisplayMessages: [DisplayMessage]
  let relay = AnswerRelay()
  var task: Task<Void, Never>?

  init(kind: AnswerKind, userText: String?, baseHistory: [AnthropicMessage], baseDisplayMessages: [DisplayMessage]) {
    self.kind = kind
    self.userText = userText
    self.baseHistory = baseHistory
    self.baseDisplayMessages = baseDisplayMessages
  }
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
