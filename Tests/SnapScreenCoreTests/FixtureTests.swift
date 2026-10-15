import Foundation
import Testing
@testable import SnapScreenCore

// Replays the golden fixtures recorded from the Chrome extension's TypeScript before it was
// removed. Every client call must send the same request and reach the same result. Edit them by
// hand only for an intended change to the client, limits or prompt. The session fixtures also
// replay through SessionController. Each records one attempt, so the client replays them without
// retries, which AnthropicClientTests covers.

private let fixturesURL = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
private let fixtureNames = (try? FileManager.default.contentsOfDirectory(atPath: fixturesURL.path))
  .map { $0.filter { $0.hasSuffix(".json") }.sorted() } ?? []
private let systemPromptReference = "(system-prompt.txt)"
// The Chrome extension needed this header for CORS; the app deliberately doesn't send it.
private let browserOnlyHeader = "anthropic-dangerous-direct-browser-access"

private struct Fixture: Decodable {
  let description: String
  let steps: [Step]
}

private struct Step: Decodable {
  let note: String?
  let op: String
  let input: JSONValue
  let response: ScriptedResponse
  let request: RecordedRequest?
  let events: [StreamEvent]?
  let outcome: Outcome
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

@Test func systemPromptMatchesItsFixture() throws {
  let recorded = try String(contentsOf: fixturesURL.appending(path: "system-prompt.txt"), encoding: .utf8)
  #expect(screenshotQASystemPrompt.jsEquals(recorded))
}

@Test(arguments: fixtureNames)
func replaysFixture(_ name: String) async throws {
  let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixturesURL.appending(path: name)))
  #expect(!fixture.steps.isEmpty)
  for (index, step) in fixture.steps.enumerated() {
    try await replayCall(step, Comment(rawValue: "\(name) step \(index + 1): \(step.note ?? step.op)"))
  }
}

private func replayCall(_ step: Step, _ location: Comment) async throws {
  let transport = MockTransport(step.response)
  let client = AnthropicClient(transport: transport, retries: .none)
  let events = Locked<[StreamEvent]>([])
  let handlers = StreamHandlers(
    onThinking: { events.withLock { $0.append(StreamEvent(type: "thinking", text: nil)) } },
    onDelta: { text in events.withLock { $0.append(StreamEvent(type: "delta", text: text)) } })
  // Its own task, because a scripted Stop cancels the task reading the answer.
  let op = step.op
  let input = step.input
  let call = Task { () async throws -> String? in
    switch op {
    case "analyzeImage":
      let input = try input.decode(AnalyzeInput.self)
      return try await client.analyzeImage(apiKey: input.apiKey, image: dataURLBytes(input.image),
        hiddenInstruction: input.hiddenInstruction, userQuestion: input.userQuestion, limits: input.limits,
        handlers: handlers)
    case "verifyApiKey":
      try await client.verifyAPIKey(try input.decode([String: String].self)["apiKey"]!)
      return nil
    default:
      throw MockTransport.Failure()
    }
  }

  let outcome = step.outcome
  switch await call.result {
  case .success(let answer?):
    #expect(outcome.type == "answer", location)
    #expect(answer.jsEquals(outcome.text ?? ""), location)
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

/// Replays a session fixture through `SessionController` and the real client, as the user would:
/// select a region, then Retry. Each request must be the recorded one and report the recorded
/// result.
@Test(arguments: fixtureNames.filter { $0.hasPrefix("session-") }) @MainActor
func replaysSessionThroughTheController(_ name: String) async throws {
  let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixturesURL.appending(path: name)))
  let first = try fixture.steps[0].input.decode(AnalyzeInput.self)
  let image = dataURLBytes(first.image)
  let transport = MockTransport(fixture.steps.map(\.response))
  let log = EventLog()
  let controller = SessionController(answers: AnthropicClient(transport: transport, retries: .none),
    apiKey: { first.apiKey },
    settings: { SessionSettings(defaultPrompt: first.hiddenInstruction ?? "", limits: first.limits) },
    scheduler: ManualTimers().scheduler, cropSelection: { _, _, _ in image })
  controller.delegate = log
  let session = try #require(controller.start { FrozenScreen(image: try decodePNG(image), displayID: 1) })
  transport.onStop = { Task { @MainActor in session.stop() } }
  try await waitUntil { session.phase == .selecting }

  for (index, call) in fixture.steps.enumerated() {
    let location = Comment(rawValue: "\(name) answer \(index + 1): \(call.note ?? call.op)")
    let reported = log.events.count
    let requests = transport.requests.count
    if index == 0 {
      #expect(session.select(CGRect(x: 0, y: 0, width: 1, height: 1)), location)
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
    // A stopped answer reports the text streamed before Stop.
    let partialAnswer = call.events?.last { $0.type == "delta" }?.text ?? ""
    let result: SessionEvent = switch call.outcome.type {
    case "answer": .answer(call.outcome.text ?? "", .done)
    case "stopped": .answer(partialAnswer, .stopped)
    default: .failed(AnthropicError(call.outcome.code ?? "", call.outcome.message ?? ""))
    }
    #expect(events.last(where: \.endsAnswer) == result, location)
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
