import CoreGraphics
import Foundation
import Testing
@testable import SnapScreenCore

private let frozen = FrozenScreen(image: try! decodePNG(makePNG(width: 4, height: 2)), displayID: 7)
private let cropped = Data("CROP".utf8)
private let half = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
private let firstAnswer = SessionEvent.answer("First answer", .done)

/// Answers each call with its scripted reply: text, an error, or nothing until the test settles it.
@MainActor
private final class ScriptedAnswers: AnswerClient {
  enum Reply {
    case answer(String)
    case failure(any Error)
    case hold
  }

  @MainActor
  final class Call {
    let apiKey: String
    /// The screenshot, sent with a first answer.
    let image: Data?
    let hiddenInstruction: String?
    /// The first answer's question, or the follow-up.
    let question: String?
    /// The conversation, sent with a follow-up.
    let history: [AnthropicMessage]?
    let sessionInstruction: String?
    let limits: SnapScreenLimits
    let handlers: StreamHandlers
    fileprivate let cancelled = Locked(false)
    fileprivate var continuation: CheckedContinuation<Answer, any Error>?

    init(apiKey: String, image: Data? = nil, hiddenInstruction: String? = nil, question: String?,
      history: [AnthropicMessage]? = nil, sessionInstruction: String? = nil, limits: SnapScreenLimits,
      handlers: StreamHandlers) {
      self.apiKey = apiKey
      self.image = image
      self.hiddenInstruction = hiddenInstruction
      self.question = question
      self.history = history
      self.sessionInstruction = sessionInstruction
      self.limits = limits
      self.handlers = handlers
    }

    var wasCancelled: Bool { cancelled.current }

    func resolve(_ text: String) {
      continuation?.resume(returning: Answer(text: text, history: []))
      continuation = nil
    }

    func reject(_ error: any Error) {
      continuation?.resume(throwing: error)
      continuation = nil
    }
  }

  private(set) var calls: [Call] = []
  /// Replies for the next calls, in order. A call without one answers.
  var analyzeReplies: [Reply] = []
  var followUpReplies: [Reply] = []

  var analyzeCalls: [Call] { calls.filter { $0.image != nil } }
  var followUpCalls: [Call] { calls.filter { $0.history != nil } }

  func analyzeImage(apiKey: String, image: Data, hiddenInstruction: String?, userQuestion: String?,
    limits: SnapScreenLimits, handlers: StreamHandlers) async throws -> Answer {
    let call = Call(apiKey: apiKey, image: image, hiddenInstruction: hiddenInstruction, question: userQuestion,
      limits: limits, handlers: handlers)
    calls.append(call)
    return try await reply(analyzeReplies.isEmpty ? .answer("First answer") : analyzeReplies.removeFirst(), to: call)
  }

  func followUp(apiKey: String, text: String, history: [AnthropicMessage], sessionInstruction: String?,
    limits: SnapScreenLimits, handlers: StreamHandlers) async throws -> Answer {
    let call = Call(apiKey: apiKey, question: text, history: history, sessionInstruction: sessionInstruction,
      limits: limits, handlers: handlers)
    calls.append(call)
    return try await reply(followUpReplies.isEmpty ? .answer("Follow-up answer") : followUpReplies.removeFirst(),
      to: call)
  }

  private func reply(_ reply: Reply, to call: Call) async throws -> Answer {
    switch reply {
    case .answer(let text):
      return Answer(text: text, history: [])
    case .failure(let error):
      throw error
    case .hold:
      // Like an aborted fetch, a cancelled call can still settle later.
      let cancelled = call.cancelled
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { call.continuation = $0 }
      } onCancel: {
        cancelled.withLock { $0 = true }
      }
    }
  }
}

@MainActor
private final class Harness {
  let answers = ScriptedAnswers()
  let timers = ManualTimers()
  let log = EventLog()
  var apiKey: String? = "sk-ant-test-secret"
  /// Thrown instead of reading the key.
  var keyError: (any Error)?
  var settings = SessionSettings(defaultPrompt: "Keep guidance.", limits: .defaults)
  private(set) var captures = 0
  private(set) var crops: [(image: CGImage, rect: CGRect)] = []
  var cropError: (any Error)?
  /// Holds crops until `finishCrop`.
  var holdsCrop = false
  private var heldCrop: CheckedContinuation<Data, any Error>?

  private(set) lazy var controller: SessionController = {
    let controller = SessionController(answers: answers, apiKey: { [unowned self] in
      if let keyError = self.keyError { throw keyError }
      return self.apiKey
    },
      settings: { [unowned self] in self.settings }, scheduler: timers.scheduler,
      cropSelection: { @MainActor [unowned self] image, rect, _ in try await self.crop(image, rect) })
    controller.delegate = log
    return controller
  }()

  var latest: SessionEvent? { log.events.last }

  /// Starts a snip and lets its capture finish.
  @discardableResult
  func start(capture: (@Sendable () async throws -> FrozenScreen)? = nil) async -> SnipSession? {
    let capture = capture ?? { @MainActor [unowned self] in
      self.captures += 1
      return frozen
    }
    let session = controller.start(capture: capture)
    await flush()
    return session
  }

  /// Starts a snip, selects a region, and lets the first answer run.
  func accepted() async throws -> SnipSession {
    let session = try #require(await start())
    session.select(half)
    await flush()
    return session
  }

  func finishCrop() {
    heldCrop?.resume(returning: cropped)
    heldCrop = nil
  }

  private func crop(_ image: CGImage, _ rect: CGRect) async throws -> Data {
    crops.append((image, rect))
    if let cropError { throw cropError }
    guard holdsCrop else { return cropped }
    return try await withCheckedThrowingContinuation { heldCrop = $0 }
  }
}

/// Holds a capture open until the test releases it.
@MainActor
private final class Gate {
  private var continuation: CheckedContinuation<FrozenScreen, any Error>?

  func wait() async throws -> FrozenScreen { try await withCheckedThrowingContinuation { continuation = $0 } }

  func open() {
    continuation?.resume(returning: frozen)
    continuation = nil
  }
}

@MainActor
private func streamed(_ log: EventLog) -> [SessionEvent] {
  log.events.filter { if case .answer(_, .streaming) = $0 { true } else { false } }
}

@Test @MainActor func reportsEachStepAndAnswersTheCropWithTheSnapshottedSettings() async throws {
  let harness = Harness()
  let session = try await harness.accepted()
  #expect(harness.log.events(of: session) == [.captured(frozen), .accepted(cropped), .started, firstAnswer])
  #expect(harness.crops.count == 1 && harness.crops.first?.image === frozen.image && harness.crops.first?.rect == half)
  let call = try #require(harness.answers.analyzeCalls.first)
  #expect(call.apiKey == "sk-ant-test-secret" && call.image == cropped && call.hiddenInstruction == "Keep guidance."
    && call.question == nil && call.limits == .defaults)
  // The windows never get the key or the Default Prompt.
  let reported = String(describing: harness.log.events)
  #expect(!reported.contains("sk-ant") && !reported.contains("Keep guidance"))
  #expect(session.phase == .ready && session.canAsk && !session.canRetry && !session.canStop)
  session.close()
  #expect(session.phase == .ended && harness.controller.sessions.isEmpty)
}

@Test @MainActor func aNewSnipLeavesAcceptedConversationsOpen() async throws {
  let harness = Harness()
  let session = try await harness.accepted()
  let next = try #require(await harness.start())
  #expect(session.phase == .ready && next.phase == .selecting)
  #expect(session.ask("Explain it"))
  await flush()
  let call = try #require(harness.answers.followUpCalls.first)
  #expect(call.apiKey == "sk-ant-test-secret" && call.question == "Explain it"
    && call.sessionInstruction == "Keep guidance.")
  #expect(call.history?.contains(.assistant("First answer")) == true)
  #expect(harness.captures == 2 && !harness.log.events(of: session).contains(.ended))
}

@Test(arguments: [false, true]) @MainActor
func aNewSnipEndsAnUnacceptedSelection(whileCropping: Bool) async throws {
  let harness = Harness()
  harness.holdsCrop = true
  let session = try #require(await harness.start())
  if whileCropping {
    session.select(half)
    await flush()
    #expect(session.phase == .cropping && !session.canAsk)
  }
  await harness.start()
  harness.finishCrop()
  await flush()
  #expect(session.phase == .ended && harness.log.events(of: session) == [.captured(frozen), .ended])
  #expect(harness.answers.calls.isEmpty && harness.log.notices.isEmpty)
}

@Test @MainActor func endsAnUnfinishedCaptureQuietlyWhenANewerSnipStarts() async throws {
  let harness = Harness()
  let gate = Gate()
  let first = try #require(await harness.start { @MainActor in try await gate.wait() })
  let second = try #require(await harness.start())
  gate.open()
  await flush()
  #expect(first.phase == .ended && harness.log.events(of: first).isEmpty)
  #expect(harness.log.events(of: second) == [.captured(frozen)] && harness.log.notices.isEmpty)
}

@Test @MainActor func closingCancelsTheRequestAndIgnoresAnythingLate() async throws {
  let harness = Harness()
  harness.answers.analyzeReplies = [.hold]
  let session = try await harness.accepted()
  let call = try #require(harness.answers.analyzeCalls.first)
  session.close()
  #expect(call.wasCancelled)
  call.handlers.onDelta("Late secret")
  call.handlers.onThinking()
  call.resolve("Late answer")
  await flush()
  harness.timers.advance(by: .seconds(1))
  #expect(harness.log.events(of: session) == [.captured(frozen), .accepted(cropped), .started])
  let next = try #require(await harness.start())
  #expect(harness.answers.calls.count == 1 && harness.log.events(of: next) == [.captured(frozen)])
}

@Test @MainActor func refusesRequestsThePhaseDoesNotAllow() async throws {
  let harness = Harness()
  let selecting = try #require(await harness.start())
  #expect(!selecting.ask("Too early") && !selecting.retry() && !selecting.stop())
  selecting.close()

  harness.answers.followUpReplies = [.hold]
  let session = try await harness.accepted()
  #expect(!session.select(half))
  #expect(session.ask("One"))
  #expect(!session.ask("Duplicate") && !session.retry() && session.canStop)
  await flush()
  #expect(harness.answers.followUpCalls.count == 1)
  session.close()
  #expect(!session.ask("Closed") && !session.retry() && !session.stop() && !session.canAsk)
  await flush()
  #expect(harness.answers.followUpCalls.count == 1)
}

@Test @MainActor func stopsOnceKeepsTheTextAndRetriesFromTheSameConversation() async throws {
  let harness = Harness()
  harness.answers.analyzeReplies = [.hold]
  let session = try await harness.accepted()
  let stopped = try #require(harness.answers.analyzeCalls.first)
  stopped.handlers.onDelta("Partial answer")
  #expect(session.stop())
  #expect(stopped.wasCancelled && harness.latest == .answer("Partial answer", .stopped))
  #expect(session.display == [DisplayMessage(role: .assistant, content: "Partial answer")])
  #expect(!session.stop() && session.canRetry && session.canAsk)
  #expect(session.retry())
  await flush()
  #expect(harness.answers.analyzeCalls.count == 2 && harness.answers.analyzeCalls[1].question == nil)
  stopped.resolve("Late result")
  await flush()
  #expect(!session.stop() && harness.latest == firstAnswer)
  #expect(session.display == [DisplayMessage(role: .assistant, content: "First answer")])
}

@Test @MainActor func retryingAFailedFollowUpResendsTheSameRequest() async throws {
  let harness = Harness()
  let session = try await harness.accepted()
  harness.answers.followUpReplies = [.failure(AnthropicError("network", "Connection interrupted."))]
  session.ask("Retry this")
  await flush()
  #expect(harness.latest == .failed(AnthropicError("network", "Connection interrupted.")) && session.canRetry)
  #expect(session.retry())
  await flush()
  let calls = harness.answers.followUpCalls
  #expect(calls.count == 2 && calls[0].question == calls[1].question && calls[0].history == calls[1].history)
  #expect(harness.latest == .answer("Follow-up answer", .done))
}

@Test @MainActor func reportsAGenericErrorForUnexpectedFailures() async throws {
  struct Unexpected: Error, CustomStringConvertible {
    var description: String { "sk-ant-private provider\u{0}details" }
  }
  let harness = Harness()
  harness.answers.analyzeReplies = [.failure(Unexpected())]
  _ = try await harness.accepted()
  #expect(harness.latest == .failed(AnthropicError("request_failed",
    "SnapScreen could not complete this request. Try again.")))
  #expect(!String(describing: harness.log.events).contains("private"))
}

@Test @MainActor func followUpsUseTheSnapshottedSettingsWithTheCurrentKey() async throws {
  let harness = Harness()
  let session = try await harness.accepted()
  harness.apiKey = "replacement-key"
  harness.settings = SessionSettings(defaultPrompt: "Changed preference",
    limits: SnapScreenLimits(maxInputCharacters: 100, maxScreenshotBytes: 5_000_000, maxScreenshotDimension: 2_576,
      maxConversationTurns: 12))
  session.ask("Follow up")
  await flush()
  let call = try #require(harness.answers.followUpCalls.first)
  #expect(call.apiKey == "replacement-key" && call.sessionInstruction == "Keep guidance." && call.limits == .defaults)
  #expect(session.maxInputCharacters == SnapScreenLimits.defaults.maxInputCharacters)
}

@Test @MainActor func endsAnIdleSelectionAfterTwoMinutes() async throws {
  let harness = Harness()
  let session = try #require(await harness.start())
  harness.timers.advance(by: .seconds(119))
  #expect(session.phase == .selecting)
  harness.timers.advance(by: .seconds(1))
  #expect(session.phase == .ended && session.frozen == nil && harness.latest == .ended)
  #expect(harness.captures == 1 && harness.answers.calls.isEmpty && harness.log.notices.isEmpty)

  let accepted = try await harness.accepted()
  harness.timers.advance(by: .seconds(120))
  #expect(accepted.phase == .ready)
}

@Test @MainActor func keepsSessionsApartAndHoldsAtMostFour() async throws {
  let harness = Harness()
  var sessions: [SnipSession] = []
  for _ in 0..<SessionController.maxSessions { sessions.append(try await harness.accepted()) }
  #expect(await harness.start() == nil)
  #expect(harness.log.notices == ["Close a SnapScreen window before starting another snip."])
  #expect(harness.captures == 4)
  sessions[0].ask("Only the first")
  await flush()
  #expect(harness.answers.followUpCalls.count == 1)
  #expect(sessions.dropFirst().allSatisfy { $0.phase == .ready && $0.history.count == 2 })
  sessions[0].close()
  #expect(await harness.start() != nil)
}

@Test @MainActor func refusesAQuestionWhileTheFirstAnswerStarts() async throws {
  let harness = Harness()
  var asked: Bool?
  harness.log.onEvent = { session, event in if event == .accepted(cropped) { asked = session.ask("Too soon") } }
  let session = try await harness.accepted()
  #expect(asked == false && harness.answers.calls.count == 1 && harness.answers.calls[0].question == nil)
  #expect(harness.log.events(of: session).suffix(2) == [.started, firstAnswer])
}

@Test(arguments: [SessionEvent.accepted(cropped), .started]) @MainActor
func makesNoRequestForASessionClosedBeforeItsRequest(closedAt: SessionEvent) async throws {
  let harness = Harness()
  harness.log.onEvent = { session, event in if event == closedAt { session.close() } }
  let session = try await harness.accepted()
  #expect(session.phase == .ended && harness.answers.calls.isEmpty)
  #expect(harness.log.events(of: session).last == closedAt)
}

@Test @MainActor func asksForAKeyWithoutARequestAndRetriesOnceThereIsOne() async throws {
  let harness = Harness()
  harness.apiKey = ""
  let session = try await harness.accepted()
  #expect(harness.latest == .failed(AnthropicError("no_api_key",
    "Add your Anthropic API key in SnapScreen Settings, then Retry.")))
  #expect(harness.answers.calls.isEmpty && session.display.isEmpty && session.canRetry)
  harness.apiKey = "sk-ant-test-secret"
  #expect(session.retry())
  await flush()
  #expect(harness.answers.analyzeCalls.count == 1 && harness.latest == firstAnswer)
}

@Test @MainActor func reportsAKeyThatCannotBeReadInItsOwnWords() async throws {
  let harness = Harness()
  let keychain = AnthropicError("keychain", "Couldn't read the API key from your Keychain because access was denied.")
  harness.keyError = keychain
  let session = try await harness.accepted()
  #expect(harness.latest == .failed(keychain) && harness.answers.calls.isEmpty && session.canRetry)
}

@Test(arguments: [true, false]) @MainActor
func keepsHistoryAlignedAfterAFirstQuestionEnds(stopped: Bool) async throws {
  let harness = Harness()
  harness.answers.analyzeReplies = [.failure(AnthropicError("network", "Try again.")), .hold]
  let session = try await harness.accepted()
  #expect(session.display.isEmpty && session.history.isEmpty)
  session.ask("Initial question after failure")
  await flush()
  let call = try #require(harness.answers.analyzeCalls.last)
  #expect(harness.answers.analyzeCalls.count == 2 && call.question == "Initial question after failure")
  call.handlers.onDelta("Partial")
  if stopped { session.stop() } else { call.reject(AnthropicError("network", "Interrupted.")) }
  await flush()
  session.ask("Continue")
  await flush()
  let followUp = try #require(harness.answers.followUpCalls.first)
  let imageTurn = createScreenshotUserContent(cropped, instruction: "Keep guidance.",
    question: "Initial question after failure")
  #expect(followUp.history?.first == AnthropicMessage(role: .user, content: .blocks(imageTurn)))
  #expect(harness.latest == .answer("Follow-up answer", .done))
}

@Test @MainActor func reportsCaptureFailuresInTheirOwnWordsOrAGenericOne() async throws {
  let harness = Harness()
  let session = await harness.start { @MainActor in throw CaptureError("The display was disconnected.") }
  #expect(harness.log.notices == ["The display was disconnected."])
  #expect(session?.phase == .ended && harness.log.events.isEmpty && harness.controller.sessions.isEmpty)
  await harness.start { @MainActor in throw URLError(.unknown) }
  #expect(harness.log.notices.last == "SnapScreen couldn't capture the screen. Try again.")
}

@Test @MainActor func endsTheSessionWhenCroppingFails() async throws {
  let harness = Harness()
  harness.cropError = ImageFittingError.emptyCrop
  let session = try #require(await harness.start())
  session.select(half)
  await flush()
  #expect(session.phase == .ended && harness.latest == .ended && harness.answers.calls.isEmpty)
}

@Test @MainActor func reportsRequestLimitErrorsInTheirOwnWords() async throws {
  let harness = Harness()
  let session = try await harness.accepted()
  harness.answers.followUpReplies = [.failure(RequestLimitError(.inputTooLong, "Questions are limited."))]
  session.ask("Too long")
  await flush()
  #expect(harness.latest == .failed(AnthropicError("input_too_long", "Questions are limited.")))
}

@Test @MainActor func reportsRemovedTurnsRightAfterTheRequestStarts() async throws {
  let harness = Harness()
  harness.settings.limits.maxConversationTurns = 2
  let session = try await harness.accepted()
  for text in ["Second", "Third"] {
    session.ask(text)
    await flush()
  }
  let events = harness.log.events(of: session)
  let notice = SessionEvent.notice("1 older conversation turn was removed to keep the screenshot and newest "
    + "request within the configured limit.", removedTurns: 1)
  #expect(events.filter { if case .notice = $0 { true } else { false } } == [notice])
  #expect(events.lastIndex(of: notice) == events.lastIndex(of: .started).map { $0 + 1 })
}

@Test(arguments: [AnswerKind.initial, .followUp]) @MainActor
func neverKeepsRefusedText(_ kind: AnswerKind) async throws {
  let harness = Harness()
  if kind == .initial { harness.answers.analyzeReplies = [.hold] } else { harness.answers.followUpReplies = [.hold] }
  let session = try await harness.accepted()
  if kind == .followUp {
    session.ask("Refused question")
    await flush()
  }
  let call = try #require(harness.answers.calls.last)
  call.handlers.onDelta("Refused partial")
  call.reject(AnthropicError("refusal", "Claude declined to answer this question."))
  await flush()
  #expect(harness.latest == .failed(AnthropicError("refusal", "Claude declined to answer this question.")))
  session.ask("Next question")
  await flush()
  let next = try #require(harness.answers.calls.last)
  let request = String(describing: (next.question, next.history))
  #expect(request.contains("Next question") && !request.contains("Refused partial"))
  #expect(!String(describing: session.display).contains("Refused partial"))
}

@Test @MainActor func sendsStreamingTextAtMostEveryHundredMillisecondsAndNothingAfterClose() async throws {
  let harness = Harness()
  harness.answers.analyzeReplies = [.hold]
  let session = try await harness.accepted()
  let call = try #require(harness.answers.analyzeCalls.first)
  for index in 0..<100 { call.handlers.onDelta("Text \(index)") }
  #expect(streamed(harness.log).isEmpty)
  harness.timers.advance(by: .milliseconds(100))
  #expect(streamed(harness.log) == [.answer("Text 99", .streaming)])
  call.handlers.onDelta("Text 100")
  harness.timers.advance(by: .milliseconds(99))
  #expect(streamed(harness.log).count == 1)
  harness.timers.advance(by: .milliseconds(1))
  #expect(streamed(harness.log).last == .answer("Text 100", .streaming))
  call.handlers.onDelta("Later text")
  session.close()
  harness.timers.advance(by: .milliseconds(100))
  #expect(streamed(harness.log).count == 2)
}

@Test @MainActor func reportsThinkingOnlyWhileTheRequestRuns() async throws {
  let harness = Harness()
  harness.answers.analyzeReplies = [.hold]
  let session = try await harness.accepted()
  let call = try #require(harness.answers.analyzeCalls.first)
  call.handlers.onThinking()
  await flush()
  #expect(harness.latest == .thinking)
  session.stop()
  call.handlers.onThinking()
  await flush()
  #expect(harness.latest == .answer("", .stopped))
}

@Test @MainActor func releasesItsImagesAndTextWhenItEnds() async throws {
  let harness = Harness()
  harness.answers.followUpReplies = [.hold]
  let session = try await harness.accepted()
  #expect(session.frozen == nil && session.crop == cropped)
  session.ask("Why?")
  await flush()
  let call = try #require(harness.answers.followUpCalls.first)
  #expect(!session.history.isEmpty && !session.display.isEmpty && session.generation != nil)
  session.close()
  #expect(call.wasCancelled && session.phase == .ended)
  #expect(session.frozen == nil && session.crop == nil && session.settings == nil && session.history.isEmpty
    && session.display.isEmpty && session.generation == nil && session.retryGeneration == nil)
}

@Test @MainActor func cropsAndFitsTheSelectionOffTheMainActorByDefault() async throws {
  let log = EventLog()
  let controller = SessionController(answers: ScriptedAnswers(), apiKey: { "sk-ant-test-secret" },
    settings: { .defaults })
  controller.delegate = log
  let screen = try decodePNG(makePNG(width: 40, height: 20) { x, _ in x < 20 ? (255, 0, 0) : (0, 0, 255) })
  let session = try #require(controller.start { FrozenScreen(image: screen, displayID: 1) })
  try await waitUntil { session.phase == .selecting }
  session.select(CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
  try await waitUntil { log.events.contains(firstAnswer) }
  let crop = try #require(session.crop)
  let metadata = try inspectPNG(crop)
  #expect(metadata.width == 20 && metadata.height == 20)
  #expect(try pixel(crop, x: 0, y: 0) == (0, 0, 255) && pixel(crop, x: 19, y: 19) == (0, 0, 255))
  #expect(log.events == [.captured(FrozenScreen(image: screen, displayID: 1)), .accepted(crop), .started, firstAnswer])
  session.close()
}
