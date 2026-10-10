import Foundation
import Testing
@testable import SnapScreenCore

// The cases the fixtures can't express: timeouts, Stop, body cleanup, and request reuse across turns.
// Fixture replays cover request bodies, stream parsing, and error mapping.

private let limits = SnapScreenLimits.defaults

private func events(_ handlers: (StreamHandlers) async throws -> Void) async rethrows -> [String] {
  let seen = Locked<[String]>([])
  try await handlers(StreamHandlers(onThinking: { seen.withLock { $0.append("(thinking)") } },
    onDelta: { text in seen.withLock { $0.append(text) } }))
  return seen.current
}

@Test func rejectsOversizedScreenshotsAndQuestionsBeforeSending() async {
  let transport = MockTransport()
  let client = AnthropicClient(transport: transport)

  let tooWide = await thrownError(AnthropicError.self) {
    _ = try await client.analyzeImage(apiKey: "key", image: pngHeader(width: 2_577, height: 100), limits: limits)
  }
  #expect(tooWide?.code == "screenshot_dimensions_too_large")
  let tooLong = await thrownError(AnthropicError.self) {
    var small = limits
    small.maxInputCharacters = 100
    _ = try await client.analyzeImage(apiKey: "key", image: pixelPNG, userQuestion: String(repeating: "x", count: 101),
      limits: small)
  }
  #expect(tooLong?.code == "input_too_long")
  #expect(tooLong?.message == "Question is 101 characters. The current limit is 100. Shorten it or raise the limit in Settings.")
  #expect(transport.requests.isEmpty)
}

@Test func keepsMarkdownLookingSyntaxInStreamedAndFinalText() async throws {
  let client = AnthropicClient(transport: MockTransport(.answer("1. `user_", "id` = value_1 # **exact**")))
  var answer: Answer?
  let seen = try await events { handlers in
    answer = try await client.analyzeImage(apiKey: "key", image: pixelPNG, handlers: handlers)
  }
  #expect(answer?.text == "1. `user_id` = value_1 # **exact**")
  #expect(seen == ["1. `user_", "1. `user_id` = value_1 # **exact**"])
}

@Test func reportsThinkingForFollowUpsOnlyWhenTheModelThinks() async throws {
  let history: [AnthropicMessage] = [.user("Earlier question"), .assistant("Earlier answer")]
  let withoutThinking = MockTransport(.answer("Answer"))
  let quiet = try await events { handlers in
    _ = try await AnthropicClient(transport: withoutThinking).followUp(apiKey: "key", text: "And this?",
      history: history, handlers: handlers)
  }
  #expect(quiet == ["Answer"])

  var thinking = ScriptedResponse.answer("Answer")
  thinking.body = "data: \(thinkingStart)\n\n" + thinking.body!
  let seen = try await events { handlers in
    _ = try await AnthropicClient(transport: MockTransport(thinking)).followUp(apiKey: "key", text: "And this?",
      history: history, handlers: handlers)
  }
  #expect(seen == ["(thinking)", "Answer"])
}

@Test func followUpAppendsTheTurnToTheHistory() async throws {
  let history: [AnthropicMessage] = [.user("earlier question"), .assistant("earlier answer")]
  let answer = try await AnthropicClient(transport: MockTransport(.answer("Answer")))
    .followUp(apiKey: "key", text: "And this?", history: history)
  #expect(answer.history == history + [.user("And this?"), .assistant("Answer")])
}

@Test func resendsTheFirstRequestUnchangedSoFollowUpsHitTheCache() async throws {
  let transport = MockTransport(.answer("First"), .answer("Second"))
  let client = AnthropicClient(transport: transport)
  let first = try await client.analyzeImage(apiKey: "key", image: pixelPNG, hiddenInstruction: "Keep it concise.")
  _ = try await client.followUp(apiKey: "key", text: "And this?", history: first.history,
    sessionInstruction: "Keep it concise.")

  let firstBody = try requestBody(transport.requests[0])
  let followUpBody = try requestBody(transport.requests[1])
  #expect(followUpBody["cache_control"] == .object(["type": .string("ephemeral")]))
  #expect(followUpBody["system"] == firstBody["system"])
  guard case .array(let firstMessages)? = firstBody["messages"],
    case .array(let followUpMessages)? = followUpBody["messages"] else {
    Issue.record("Requests have no messages")
    return
  }
  #expect(Array(followUpMessages.prefix(firstMessages.count)) == firstMessages)
}

@Test func encodesScreenshotsAsUnescapedBase64() async throws {
  let transport = MockTransport(.answer("Answer"))
  // Base64 of these bytes includes slashes, which JSONEncoder escapes by default.
  _ = try await AnthropicClient(transport: transport).analyzeImage(apiKey: "key", image: pixelPNG + Data([0xFF, 0xFF]))
  let body = String(decoding: try #require(transport.requests.first?.httpBody), as: UTF8.self)
  #expect(body.contains((pixelPNG + Data([0xFF, 0xFF])).base64EncodedString()))
  #expect(!body.contains("\\/"))
}

@Test func mapsATimeoutWhileWaitingForTheResponse() async {
  let transport = MockTransport()
  transport.sendError = URLError(.timedOut)
  let error = await thrownError(AnthropicError.self) {
    _ = try await AnthropicClient(transport: transport).analyzeImage(apiKey: "key", image: pixelPNG)
  }
  #expect(error == AnthropicError("timeout", "Request timed out. Please try again."))
}

@Test func mapsATimeoutWhileReadingTheStream() async {
  let transport = MockTransport(.sse([textDelta("Partial")]))
  transport.bodyError = URLError(.timedOut)
  let error = await thrownError(AnthropicError.self) {
    _ = try await AnthropicClient(transport: transport).analyzeImage(apiKey: "key", image: pixelPNG)
  }
  #expect(error?.code == "timeout")
}

@Test func mapsADroppedConnectionWhileReadingTheStream() async {
  let error = await thrownError(AnthropicError.self) {
    _ = try await AnthropicClient(transport: MockTransport(.sse([textDelta("Partial")], end: .error)))
      .analyzeImage(apiKey: "key", image: pixelPNG)
  }
  #expect(error == AnthropicError("stream", "The API response stream was interrupted. Please try again."))
}

@Test func stopsWithCancellationWhileReadingTheStream() async throws {
  let transport = MockTransport(.sse([textDelta("Partial")], end: .stop))
  let seen = Locked<[String]>([])
  let task = Task {
    try await AnthropicClient(transport: transport).analyzeImage(apiKey: "key", image: pixelPNG,
      handlers: StreamHandlers(onDelta: { text in seen.withLock { $0.append(text) } }))
  }
  let result = await task.result
  #expect(throws: CancellationError.self) { try result.get() }
  #expect(seen.current == ["Partial"])
  #expect(transport.cancelledBodies == 1)
}

@Test func stopsWithCancellationWhileWaitingForTheResponse() async throws {
  let transport = MockTransport(.answer("Never"))
  transport.waitsForCancellation = true
  let task = Task { try await AnthropicClient(transport: transport).analyzeImage(apiKey: "key", image: pixelPNG) }
  while transport.requests.isEmpty { await Task.yield() }
  task.cancel()
  let result = await task.result
  #expect(throws: CancellationError.self) { try result.get() }
}

@Test func discardsBodiesItDoesNotNeed() async throws {
  for response in [ScriptedResponse.json(401), .json(429), .json(503), .json(400, String(repeating: "z", count: 20_000))] {
    let transport = MockTransport(response)
    _ = await thrownError(AnthropicError.self) {
      _ = try await AnthropicClient(transport: transport).analyzeImage(apiKey: "key", image: pixelPNG)
    }
    #expect(transport.cancelledBodies >= 1, "status \(response.status ?? 0)")
  }
}

@Test func verifiesAKeyWithOneTokenAndDiscardsTheReply() async throws {
  let transport = MockTransport(.json(200, #"{"content":[{"type":"text","text":"Hi"}]}"#))
  try await AnthropicClient(transport: transport).verifyAPIKey("key")
  let request = try #require(transport.requests.first)
  let body = try requestBody(request)
  #expect(body["max_tokens"] == .number(1))
  #expect(body["thinking"] == nil)
  #expect(body["stream"] == nil)
  #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
  #expect(request.value(forHTTPHeaderField: "x-api-key") == "key")
  #expect(transport.cancelledBodies == 1)
}

@Test func sanitizesProviderMessages() {
  let secret = "sk-ant-api03-supersecretvalue123456789"
  let message = sanitizeProviderMessage("Bad\u{0000}  key \(secret) \(String(repeating: "x", count: 500))")
  #expect(message.utf16.count == 240)
  #expect(message.hasPrefix("Bad key [REDACTED API KEY] xxx"))
  #expect(sanitizeProviderMessage(" \u{FEFF}SK-ANT-abcdefgh and sk-ant-short\u{2028}end\u{001C} ")
    == "[REDACTED API KEY] and sk-ant-short end")
  // A key needs eight characters after the prefix, and a non-ASCII letter never matches one.
  #expect(sanitizeProviderMessage("sk-ant-abcdefg \u{017F}k-ant-abcdefgh \u{212A}k-ant-abcdefgh")
    == "sk-ant-abcdefg \u{017F}k-ant-abcdefgh \u{212A}k-ant-abcdefgh")
  // The cap never splits a surrogate pair.
  #expect(sanitizeProviderMessage(String(repeating: "a", count: 239) + "🙂") == String(repeating: "a", count: 239))
}
