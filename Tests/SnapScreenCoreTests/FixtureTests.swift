import Foundation
import Testing
@testable import SnapScreenCore

// Replays the golden fixtures that src/lib/core-fixtures.test.ts records from the extension's
// TypeScript. Every client call must send the same request and reach the same result, and every
// conversation-state step must produce the same output.

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
