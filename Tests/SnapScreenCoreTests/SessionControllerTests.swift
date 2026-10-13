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
    let image: Data
    let hiddenInstruction: String?
    let question: String?
    let limits: SnapScreenLimits
    let handlers: StreamHandlers
    fileprivate let cancelled = Locked(false)
    fileprivate var continuation: CheckedContinuation<String, any Error>?

    init(apiKey: String, image: Data, hiddenInstruction: String?, question: String?, limits: SnapScreenLimits,
      handlers: StreamHandlers) {
      self.apiKey = apiKey
      self.image = image
      self.hiddenInstruction = hiddenInstruction
      self.question = question
      self.limits = limits
      self.handlers = handlers
    }

    var wasCancelled: Bool { cancelled.current }

    func resolve(_ text: String) {
      continuation?.resume(returning: text)
      continuation = nil
    }

    func reject(_ error: any Error) {
      continuation?.resume(throwing: error)
      continuation = nil
    }
  }

  private(set) var calls: [Call] = []
  /// Replies for the next calls, in order. A call without one answers.
  var replies: [Reply] = []

  func analyzeImage(apiKey: String, image: Data, hiddenInstruction: String?, userQuestion: String?,
    limits: SnapScreenLimits, handlers: StreamHandlers) async throws -> String {
    let call = Call(apiKey: apiKey, image: image, hiddenInstruction: hiddenInstruction, question: userQuestion,
      limits: limits, handlers: handlers)
    calls.append(call)
    return try await reply(replies.isEmpty ? .answer("First answer") : replies.removeFirst(), to: call)
  }

  private func reply(_ reply: Reply, to call: Call) async throws -> String {
    switch reply {
    case .answer(let text):
      return text
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

  /// Starts a snip, selects a region, and lets the answer run.
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
  let call = try #require(harness.answers.calls.first)
  #expect(call.apiKey == "sk-ant-test-secret" && call.image == cropped && call.hiddenInstruction == "Keep guidance."
    && call.question == nil && call.limits == .defaults)
  // The windows never get the key or the Default Prompt.
  let reported = String(describing: harness.log.events)
  #expect(!reported.contains("sk-ant") && !reported.contains("Keep guidance"))
  #expect(session.phase == .ready && !session.canRetry && !session.canStop && !session.retry())
  session.close()
  #expect(session.phase == .ended && harness.controller.sessions.isEmpty)
}

@Test @MainActor func aNewSnipLeavesAcceptedConversationsOpen() async throws {
  let harness = Harness()
  harness.answers.replies = [.hold]
  let session = try await harness.accepted()
  let next = try #require(await harness.start())
  #expect(session.phase == .running && next.phase == .selecting)
  try #require(harness.answers.calls.first).resolve("First answer")
  await flush()
  #expect(session.phase == .ready && harness.log.events(of: session).last == firstAnswer)
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
    #expect(session.phase == .cropping && !session.canRetry && !session.canStop)
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
  harness.answers.replies = [.hold]
  let session = try await harness.accepted()
  let call = try #require(harness.answers.calls.first)
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
  #expect(!selecting.retry() && !selecting.stop())
  selecting.close()

  harness.answers.replies = [.hold]
  let session = try await harness.accepted()
  #expect(!session.select(half))
  #expect(!session.retry() && session.canStop)
  await flush()
  #expect(harness.answers.calls.count == 1)
  session.close()
  #expect(!session.retry() && !session.stop() && !session.canRetry)
  await flush()
  #expect(harness.answers.calls.count == 1)
}

@Test @MainActor func stopsOnceReportsTheTextAndRetriesTheSameRequest() async throws {
  let harness = Harness()
  harness.answers.replies = [.hold]
  let session = try await harness.accepted()
  let stopped = try #require(harness.answers.calls.first)
  stopped.handlers.onDelta("Partial answer")
  #expect(session.stop())
  #expect(stopped.wasCancelled && harness.latest == .answer("Partial answer", .stopped))
  #expect(!session.stop() && session.canRetry)
  #expect(session.retry())
  await flush()
  let retried = try #require(harness.answers.calls.last)
  #expect(harness.answers.calls.count == 2 && retried.image == stopped.image && retried.question == nil
    && retried.hiddenInstruction == stopped.hiddenInstruction && retried.limits == stopped.limits)
  stopped.resolve("Late result")
  await flush()
  #expect(!session.stop() && harness.latest == firstAnswer)
}

@Test @MainActor func retryingAFailedAnswerResendsTheSameRequest() async throws {
  let harness = Harness()
  harness.answers.replies = [.failure(AnthropicError("network", "Connection interrupted."))]
  let session = try await harness.accepted()
  #expect(harness.latest == .failed(AnthropicError("network", "Connection interrupted.")) && session.canRetry)
  #expect(session.retry())
  await flush()
  let calls = harness.answers.calls
  #expect(calls.count == 2 && calls[0].image == calls[1].image && calls[0].question == calls[1].question
    && calls[0].hiddenInstruction == calls[1].hiddenInstruction && calls[0].limits == calls[1].limits)
  #expect(harness.latest == firstAnswer && !session.canRetry)
}

@Test @MainActor func reportsAGenericErrorForUnexpectedFailures() async throws {
  struct Unexpected: Error, CustomStringConvertible {
    var description: String { "sk-ant-private provider\u{0}details" }
  }
  let harness = Harness()
  harness.answers.replies = [.failure(Unexpected())]
  _ = try await harness.accepted()
  #expect(harness.latest == .failed(AnthropicError("request_failed",
    "SnapScreen could not complete this request. Try again.")))
  #expect(!String(describing: harness.log.events).contains("private"))
}

@Test @MainActor func retriesUseTheSnapshottedSettingsWithTheCurrentKey() async throws {
  let harness = Harness()
  harness.answers.replies = [.failure(AnthropicError("network", "Try again."))]
  let session = try await harness.accepted()
  harness.apiKey = "replacement-key"
  harness.settings = SessionSettings(defaultPrompt: "Changed preference",
    limits: SnapScreenLimits(maxInputCharacters: 100, maxScreenshotBytes: 5_000_000, maxScreenshotDimension: 2_576))
  #expect(session.retry())
  await flush()
  let call = try #require(harness.answers.calls.last)
  #expect(harness.answers.calls.count == 2 && call.apiKey == "replacement-key"
    && call.hiddenInstruction == "Keep guidance." && call.limits == .defaults)
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
  harness.answers.replies = [.failure(AnthropicError("network", "Try again."))]
  var sessions: [SnipSession] = []
  for _ in 0..<SessionController.maxSessions { sessions.append(try await harness.accepted()) }
  #expect(await harness.start() == nil)
  #expect(harness.log.notices == ["Close a SnapScreen window before starting another snip."])
  #expect(harness.captures == 4)
  #expect(sessions[0].phase == .failed && sessions.dropFirst().allSatisfy { $0.phase == .ready })
  sessions[0].retry()
  await flush()
  #expect(harness.answers.calls.count == 5 && sessions.allSatisfy { $0.phase == .ready })
  sessions[0].close()
  #expect(await harness.start() != nil)
}

@Test @MainActor func refusesARetryWhileTheAnswerStarts() async throws {
  let harness = Harness()
  var retried: Bool?
  harness.log.onEvent = { session, event in if event == .accepted(cropped) { retried = session.retry() } }
  let session = try await harness.accepted()
  #expect(retried == false && harness.answers.calls.count == 1 && harness.answers.calls[0].question == nil)
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
  #expect(harness.answers.calls.isEmpty && session.canRetry)
  harness.apiKey = "sk-ant-test-secret"
  #expect(session.retry())
  await flush()
  #expect(harness.answers.calls.count == 1 && harness.latest == firstAnswer)
}

@Test @MainActor func reportsAKeyThatCannotBeReadInItsOwnWords() async throws {
  let harness = Harness()
  let keychain = AnthropicError("keychain", "Couldn't read the API key from your Keychain because access was denied.")
  harness.keyError = keychain
  let session = try await harness.accepted()
  #expect(harness.latest == .failed(keychain) && harness.answers.calls.isEmpty && session.canRetry)
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
  harness.answers.replies = [.failure(RequestLimitError(.inputTooLong, "The Default Prompt is limited."))]
  _ = try await harness.accepted()
  #expect(harness.latest == .failed(AnthropicError("input_too_long", "The Default Prompt is limited.")))
}

@Test @MainActor func sendsStreamingTextAtMostEveryHundredMillisecondsAndNothingAfterClose() async throws {
  let harness = Harness()
  harness.answers.replies = [.hold]
  let session = try await harness.accepted()
  let call = try #require(harness.answers.calls.first)
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
  harness.answers.replies = [.hold]
  let session = try await harness.accepted()
  let call = try #require(harness.answers.calls.first)
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
  harness.answers.replies = [.hold]
  let session = try await harness.accepted()
  #expect(session.frozen == nil && session.crop == cropped && session.generation != nil)
  let call = try #require(harness.answers.calls.first)
  call.handlers.onDelta("Partial answer")
  session.close()
  #expect(call.wasCancelled && session.phase == .ended)
  #expect(session.frozen == nil && session.crop == nil && session.settings == nil && session.generation == nil)
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
