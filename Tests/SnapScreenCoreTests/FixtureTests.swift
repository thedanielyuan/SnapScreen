import Foundation
import Testing
@testable import SnapScreenCore

// Replays the golden fixtures that src/lib/core-fixtures.test.ts records from the extension's
// TypeScript. Every client call must send the same request and reach the same result, and every
// conversation-state step must produce the same output. The session fixtures also replay through
// SessionController.

private let fixturesURL = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
private let fixtureNames = (try? FileManager.default.contentsOfDirectory(atPath: fixturesURL.path))
  .map { $0.filter { $0.hasSuffix(".json") }.sorted() } ?? []
private let systemPromptReference = "(system-prompt.txt)"
// The Chrome extension needs this header for CORS; the app deliberately doesn't send it.
private let browserOnlyHeader = "anthropic-dangerous-direct-browser-access"

private struct Fixture: Decodable {
  let description: String
  let steps: [Step]
}

private struct Step: Decodable {
  let note: String?
  let op: String
  let input: JSONValue
  let response: ScriptedResponse?
  let request: RecordedRequest?
  let events: [StreamEvent]?
  let outcome: Outcome?
  let output: JSONValue?
}

private struct RecordedRequest: Decodable {
  let url: String
  let method: String
  let headers: [String: String]
  let body: JSONValue
}

private struct StreamEvent: Codable, Equatable, Sendable {
  let type: String
  let text: String?
}

private struct Outcome: Decodable {
  let type: String
  let text: String?
  let history: [AnthropicMessage]?
  let code: String?
  let message: String?
}

private struct AnalyzeInput: Decodable {
  let apiKey: String
  let image: String
  let hiddenInstruction: String?
  let userQuestion: String?
  let limits: SnapScreenLimits
}

private struct FollowUpInput: Decodable {
  let apiKey: String
  let text: String
  let history: [AnthropicMessage]
  let sessionInstruction: String?
  let limits: SnapScreenLimits
}

private struct StateOutput: Decodable {
  let displayMessages: [DisplayMessage]
  let conversationHistory: [AnthropicMessage]

  var state: ConversationState {
    ConversationState(displayMessages: displayMessages, conversationHistory: conversationHistory)
  }
}

@Test func systemPromptMatchesTheExtension() throws {
  let recorded = try String(contentsOf: fixturesURL.appending(path: "system-prompt.txt"), encoding: .utf8)
  #expect(screenshotQASystemPrompt.jsEquals(recorded))
}

@Test(arguments: fixtureNames)
func replaysFixture(_ name: String) async throws {
  let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixturesURL.appending(path: name)))
  #expect(!fixture.steps.isEmpty)
  for (index, step) in fixture.steps.enumerated() {
    let location = Comment(rawValue: "\(name) step \(index + 1): \(step.note ?? step.op)")
    if step.response != nil {
      try await replayCall(step, location)
    } else {
      try replayStateChange(step, location)
    }
  }
}

private func replayCall(_ step: Step, _ location: Comment) async throws {
  let transport = MockTransport(try #require(step.response, location))
  let client = AnthropicClient(transport: transport)
  let events = Locked<[StreamEvent]>([])
  let handlers = StreamHandlers(
    onThinking: { events.withLock { $0.append(StreamEvent(type: "thinking", text: nil)) } },
    onDelta: { text in events.withLock { $0.append(StreamEvent(type: "delta", text: text)) } })
  // Its own task, because a scripted Stop cancels the task reading the answer.
  let op = step.op
  let input = step.input
  let call = Task { () async throws -> Answer? in
    switch op {
    case "analyzeImage":
      let input = try input.decode(AnalyzeInput.self)
      return try await client.analyzeImage(apiKey: input.apiKey, image: dataURLBytes(input.image),
        hiddenInstruction: input.hiddenInstruction, userQuestion: input.userQuestion, limits: input.limits,
        handlers: handlers)
    case "followUp":
      let input = try input.decode(FollowUpInput.self)
      return try await client.followUp(apiKey: input.apiKey, text: input.text, history: input.history,
        sessionInstruction: input.sessionInstruction, limits: input.limits, handlers: handlers)
    case "verifyApiKey":
      try await client.verifyAPIKey(try input.decode([String: String].self)["apiKey"]!)
      return nil
    default:
      throw MockTransport.Failure()
    }
  }

  let outcome = try #require(step.outcome, location)
  switch await call.result {
  case .success(let answer?):
    #expect(outcome.type == "answer", location)
    #expect(answer.text.jsEquals(outcome.text ?? ""), location)
    #expect(answer.history == outcome.history, location)
  case .success(nil):
    #expect(outcome.type == "verified", location)
  case .failure(let error as AnthropicError):
    #expect(outcome.type == "error", location)
    #expect(error.code == outcome.code, location)
    #expect(error.message.jsEquals(outcome.message ?? ""), location)
  case .failure(is CancellationError):
    #expect(outcome.type == "stopped", location)
  case .failure(let error):
    Issue.record(error, location)
  }
  #expect(events.current == step.events ?? [], location)

  guard let expected = step.request else {
    #expect(transport.requests.isEmpty, location)
    return
  }
  let request = try #require(transport.requests.first, location)
  #expect(transport.requests.count == 1, location)
  try expectRequest(request, matches: expected, location)
}

private func expectRequest(_ request: URLRequest, matches expected: RecordedRequest, _ location: Comment) throws {
  #expect(request.url?.absoluteString == expected.url, location)
  #expect(request.httpMethod == expected.method, location)
  var expectedHeaders = Dictionary(uniqueKeysWithValues: expected.headers.map { ($0.key.lowercased(), $0.value) })
  expectedHeaders[browserOnlyHeader] = nil
  let headers = Dictionary(uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) })
  #expect(headers == expectedHeaders, location)

  var body = try requestBody(request)
  if case .object(var object) = body, case .string(let system)? = object["system"] {
    #expect(system.jsEquals(screenshotQASystemPrompt), location)
    object["system"] = .string(systemPromptReference)
    body = .object(object)
  }
  #expect(body == expected.body, location)
}

private func replayStateChange(_ step: Step, _ location: Comment) throws {
  let input = step.input
  let output = try #require(step.output, location)
  func value<T: Decodable>(_ key: String, _ type: T.Type = T.self) throws -> T {
    try (input[key] ?? .null).decode(type)
  }
  let image = try dataURLBytes(value("dataUrl", String?.self) ?? "data:,")
  let kind = try AnswerKind(rawValue: value("kind", String?.self) ?? "")

  switch step.op {
  case "prepareAlignedConversationForNewestTurn":
    let aligned = try prepareAlignedConversationForNewestTurn(value("displayMessages"), value("conversationHistory"),
      maxConversationTurns: value("maxConversationTurns"))
    #expect(aligned.state == (try output.decode(StateOutput.self)).state, location)
    #expect(aligned.removedTurns == (try output["removedTurns"]?.decode(Int.self)), location)
    let notice = aligned.removedTurns > 0 ? describeRemovedTurns(aligned.removedTurns) : nil
    #expect(notice == (try output["notice"]?.decode(String.self)), location)
  case "settleSuccessfulConversation":
    let state = try settleSuccessfulConversation(kind: #require(kind, location),
      baseDisplayMessages: value("baseDisplayMessages"), baseHistory: value("baseHistory"),
      assistantText: value("assistantText"), image: image, providerHistory: value("providerHistory"),
      userText: value("userText"), sessionInstruction: value("sessionInstruction"))
    #expect(state == (try output.decode(StateOutput.self)).state, location)
  case "settleStoppedConversation":
    let state = try settleStoppedConversation(kind: #require(kind, location),
      baseDisplayMessages: value("baseDisplayMessages"), baseHistory: value("baseHistory"),
      partialAnswer: value("partialAnswer"), image: image, userText: value("userText"),
      sessionInstruction: value("sessionInstruction"))
    #expect(state == (try output.decode(StateOutput.self)).state, location)
  case "settleFailedFirstAnswer":
    let state = try settleFailedFirstAnswer(partialAnswer: value("partialAnswer"), errorMessage: value("errorMessage"),
      image: image, sessionInstruction: value("sessionInstruction"), userText: value("userText"))
    #expect(state == (try output.decode(StateOutput.self)).state, location)
  case "settleFailedFollowUp":
    let failed = try settleFailedFollowUp(baseDisplayMessages: value("baseDisplayMessages"),
      baseHistory: value("baseHistory"), partialAnswer: value("partialAnswer"), errorMessage: value("errorMessage"),
      image: image, sessionInstruction: value("sessionInstruction"), userText: value("userText"))
    #expect(failed.state == (try output.decode(StateOutput.self)).state, location)
    #expect(failed.baseDisplayMessages == (try output["baseDisplayMessages"]?.decode([DisplayMessage].self)), location)
    #expect(failed.baseHistory == (try output["baseHistory"]?.decode([AnthropicMessage].self)), location)
    #expect(failed.userText == (try output["userText"]?.decode(String.self)), location)
  default:
    Issue.record("\(location.rawValue): unknown step \(step.op)")
  }
}

/// Replays a session fixture through `SessionController` and the real client, as the user would:
/// select a region, then ask or Retry. Each answer must send the recorded request, report the
/// recorded notice and result, and leave the recorded conversation.
@Test(arguments: fixtureNames.filter { $0.hasPrefix("session-") }) @MainActor
func replaysSessionThroughTheController(_ name: String) async throws {
  let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixturesURL.appending(path: name)))
  // Each answer takes three steps: aligning the conversation, the client call, and settling it.
  let answers = stride(from: 0, to: fixture.steps.count, by: 3).map { Array(fixture.steps[$0..<$0 + 3]) }
  let first = try fixture.steps[1].input.decode(AnalyzeInput.self)
  let image = dataURLBytes(first.image)
  let transport = MockTransport(answers.compactMap { $0[1].response })
  let log = EventLog()
  let controller = SessionController(answers: AnthropicClient(transport: transport), apiKey: { first.apiKey },
    settings: { SessionSettings(defaultPrompt: first.hiddenInstruction ?? "", limits: first.limits) },
    scheduler: ManualTimers().scheduler, cropSelection: { _, _, _ in image })
  controller.delegate = log
  let session = try #require(controller.start { FrozenScreen(image: try decodePNG(image), displayID: 1) })
  transport.onStop = { Task { @MainActor in session.stop() } }
  try await waitUntil { session.phase == .selecting }

  for (index, steps) in answers.enumerated() {
    let (aligned, call, settled) = (steps[0], steps[1], steps[2])
    let location = Comment(rawValue: "\(name) answer \(index + 1): \(call.note ?? call.op)")
    let reported = log.events.count
    let requests = transport.requests.count
    // A question asked from the current conversation; otherwise Retry resends an earlier one.
    let base = try aligned.input.decode(StateOutput.self).state
    let question = try (call.input["text"] ?? call.input["userQuestion"])?.decode(String.self)
    if index == 0 {
      #expect(session.select(CGRect(x: 0, y: 0, width: 1, height: 1)), location)
    } else if let question,
      base == ConversationState(displayMessages: session.display, conversationHistory: session.history) {
      #expect(session.ask(question), location)
    } else {
      #expect(session.retry(), location)
    }
    try await waitUntil { log.events.dropFirst(reported).contains(where: \.endsAnswer) }
    let events = log.events.dropFirst(reported)

    if let expected = call.request {
      #expect(transport.requests.count == requests + 1, location)
      try expectRequest(transport.requests[requests], matches: expected, location)
    } else {
      #expect(transport.requests.count == requests, location)
    }
    let removedTurns = try aligned.output?["removedTurns"]?.decode(Int.self) ?? 0
    if removedTurns > 0 {
      let notice = try #require(aligned.output?["notice"], location).decode(String.self)
      #expect(events.contains(.notice(notice, removedTurns: removedTurns)), location)
    } else {
      #expect(!events.contains { if case .notice = $0 { true } else { false } }, location)
    }
    let outcome = try #require(call.outcome, location)
    let result: SessionEvent = switch outcome.type {
    case "answer": .answer(outcome.text ?? "", .done)
    case "stopped": .answer(try settled.input["partialAnswer"]?.decode(String.self) ?? "", .stopped)
    default: .failed(AnthropicError(outcome.code ?? "", outcome.message ?? ""))
    }
    #expect(events.last(where: \.endsAnswer) == result, location)
    let state = try #require(settled.output, location).decode(StateOutput.self).state
    #expect(ConversationState(displayMessages: session.display, conversationHistory: session.history) == state,
      location)
  }
  session.close()
}

private extension SessionEvent {
  var endsAnswer: Bool {
    switch self {
    case .answer(_, .done), .answer(_, .stopped), .failed: true
    default: false
    }
  }
}
