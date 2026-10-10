import Foundation

/// A failed request, with a message written for the user. Any text from the API in it has passed
/// through `sanitizeProviderMessage`.
public struct AnthropicError: Error, Equatable, Sendable {
  public let code: String
  public let message: String

  public init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }

  init(_ error: RequestLimitError) { self.init(error.code.rawValue, error.message) }

  static let timeout = AnthropicError("timeout", "Request timed out. Please try again.")
  static let network = AnthropicError("network", "Network error. Check your connection and try again.")
  static func stream(_ message: String) -> AnthropicError { AnthropicError("stream", message) }
}

/// Called while an answer streams, on the task reading it.
public struct StreamHandlers: Sendable {
  /// Called once, when the stream starts the first thinking block.
  public var onThinking: @Sendable () -> Void
  /// Called with all of the answer's text so far, each time more arrives.
  public var onDelta: @Sendable (String) -> Void

  public init(onThinking: @escaping @Sendable () -> Void = {}, onDelta: @escaping @Sendable (String) -> Void = { _ in }) {
    self.onThinking = onThinking
    self.onDelta = onDelta
  }
}

public struct Answer: Equatable, Sendable {
  public let text: String
  /// The request's messages followed by the answer, which the next follow-up sends.
  public let history: [AnthropicMessage]

  public init(text: String, history: [AnthropicMessage]) {
    self.text = text
    self.history = history
  }
}

/// The Messages API client, ported from src/lib/anthropic.ts. Cancelling the calling task stops a
/// request with `CancellationError`; every other failure is an `AnthropicError`.
public struct AnthropicClient: Sendable {
  public static let model = "claude-opus-5-5"
  static let url = URL(string: "https://api.anthropic.com/v1/messages")!
  // Server-side refusal fallback: when a safety classifier declines, the API reruns the request on
  // the model Anthropic recommends for that refusal category, within the same stream.
  static let refusalFallbackBeta = "server-side-fallback-2026-07-01"
  static let maxProviderErrorBytes = 16_384

  private let transport: any HTTPTransport

  public init(transport: any HTTPTransport = URLSessionTransport()) {
    self.transport = transport
  }

  /// Answers a new screenshot. The Default Prompt goes with it as guidance, and a question when the
  /// user asks one before the first answer.
  public func analyzeImage(apiKey: String, image: Data, hiddenInstruction: String? = nil,
    userQuestion: String? = nil, limits: SnapScreenLimits = .defaults,
    handlers: StreamHandlers = StreamHandlers()) async throws -> Answer {
    let limits = limits.normalized
    do {
      try assertScreenshotWithinLimits(image, limits: limits)
      if let hiddenInstruction, !hiddenInstruction.isBlank {
        try assertUserInputWithinLimit(hiddenInstruction, maxCharacters: limits.maxInputCharacters,
          label: "Default Prompt")
      }
      if let userQuestion, !userQuestion.isBlank {
        try assertUserInputWithinLimit(userQuestion, maxCharacters: limits.maxInputCharacters)
      }
    } catch let error as RequestLimitError {
      throw AnthropicError(error)
    }
    let messages = [AnthropicMessage(role: .user,
      content: .blocks(createScreenshotUserContent(image, instruction: hiddenInstruction, question: userQuestion)))]
    let text = try await answer(apiKey: apiKey, messages: messages, handlers: handlers)
    return Answer(text: text, history: messages + [.assistant(text)])
  }

  /// Answers a follow-up. `history` is the conversation so far; its oldest turns are trimmed to fit
  /// `maxConversationTurns`, always keeping the screenshot turn.
  public func followUp(apiKey: String, text: String, history: [AnthropicMessage], sessionInstruction: String? = nil,
    limits: SnapScreenLimits = .defaults, handlers: StreamHandlers = StreamHandlers()) async throws -> Answer {
    let limits = limits.normalized
    let retained: [AnthropicMessage]
    do {
      try assertUserInputWithinLimit(text, maxCharacters: limits.maxInputCharacters)
      try assertHistoryScreenshotsWithinLimits(history, limits: limits)
      if let sessionInstruction, !sessionInstruction.isBlank {
        try assertUserInputWithinLimit(sessionInstruction, maxCharacters: limits.maxInputCharacters,
          label: "Default Prompt")
      }
      retained = try pruneApiHistoryForNewestTurn(retainSessionGuidance(history, instruction: sessionInstruction),
        maxConversationTurns: limits.maxConversationTurns).messages
    } catch let error as RequestLimitError {
      throw AnthropicError(error)
    }
    let messages = retained + [.user(text)]
    let answer = try await answer(apiKey: apiKey, messages: messages, handlers: handlers)
    return Answer(text: answer, history: messages + [.assistant(answer)])
  }

  /// Checks a key with a one-token request.
  public func verifyAPIKey(_ apiKey: String) async throws {
    try await mappingFailures {
      // Opus 5.5 can't turn thinking off, and max_tokens caps thinking and text together, so the
      // check sends no thinking field and stops after one token.
      let response = try await post(apiKey: apiKey,
        body: MessagesRequest(model: Self.model, maxTokens: 1, messages: [.user("Hi")]))
      response.cancel()
    }
  }

  private func answer(apiKey: String, messages: [AnthropicMessage], handlers: StreamHandlers) async throws -> String {
    try await mappingFailures {
      let response = try await post(apiKey: apiKey, body: MessagesRequest(
        model: Self.model,
        // Thinking counts toward max_tokens, so the budget covers reasoning plus the visible answer.
        maxTokens: 32_000,
        // Adaptive thinking: the model reasons before answering, which math, logic and test-style
        // questions need. Thinking text is omitted by default and the stream reader skips thinking
        // blocks, so history keeps only answer text and never replays thinking.
        thinking: .init(type: "adaptive"),
        // Opus 5.5 defaults to medium.
        outputConfig: .init(effort: "high"),
        fallbacks: "default",
        stream: true,
        // Automatic prompt caching: the cache breakpoint follows the newest message, so follow-ups
        // re-read the screenshot and earlier turns at the cache-read rate. Any change to the system
        // prompt or earlier messages misses the cache, which is why first answers and follow-ups
        // share one system prompt.
        cacheControl: .init(type: "ephemeral"),
        system: screenshotQASystemPrompt,
        messages: messages), betas: [Self.refusalFallbackBeta])
      defer { response.cancel() }
      let (text, stopReason) = try await readAnswerStream(response, handlers: handlers)
      if stopReason == "refusal" {
        throw AnthropicError("refusal", "Claude declined to answer this question.")
      }
      let cleaned = normalizeLineEndings(text)
      if cleaned.isBlank { throw AnthropicError("api", "No response text received from the API.") }
      if stopReason == "max_tokens" {
        // A cut-off can land inside a code block; close it so the notice isn't shown, or copied, as code.
        return closeOpenCodeFence(cleaned) + "\n\n(Answer was cut off — ask a follow-up to continue.)"
      }
      return cleaned
    }
  }

  /// Reports a stop as `CancellationError` and turns transport failures into user-facing errors.
  private func mappingFailures<T>(_ operation: () async throws -> T) async throws -> T {
    do {
      return try await operation()
    } catch {
      if Task.isCancelled { throw CancellationError() }
      if isTimeout(error) { throw AnthropicError.timeout }
      if isCancellation(error) { throw AnthropicError.network }
      throw error
    }
  }

  private func post(apiKey: String, body: MessagesRequest, betas: [String] = []) async throws -> HTTPResponse {
    var request = URLRequest(url: Self.url)
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    if !betas.isEmpty { request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    request.httpBody = try encoder.encode(body)

    let response: HTTPResponse
    do {
      response = try await transport.send(request)
    } catch {
      if Task.isCancelled || isCancellation(error) || isTimeout(error) { throw error }
      throw AnthropicError.network
    }
    guard (200...299).contains(response.status) else { throw try await failure(of: response) }
    return response
  }

  private func failure(of response: HTTPResponse) async throws -> AnthropicError {
    switch response.status {
    case 401, 403:
      response.cancel()
      return AnthropicError("auth", "Invalid API key. Check your settings.")
    case 429:
      response.cancel()
      let retryAfter = response.headers["retry-after"] ?? ""
      let seconds = !retryAfter.isEmpty && retryAfter.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
      return AnthropicError("rate_limit",
        "Rate limit reached. " + (seconds ? "Try again in ~\(retryAfter)s." : "Please try again shortly."))
    case 500...:
      response.cancel()
      return AnthropicError("server", "Service unavailable. Please try again.")
    default:
      var providerMessage = ""
      do {
        providerMessage = try await readProviderErrorMessage(response)
      } catch {
        if Task.isCancelled || isCancellation(error) || isTimeout(error) { throw error }
      }
      let statusText = sanitizeProviderMessage(response.statusText)
      let detail = !providerMessage.isEmpty ? providerMessage : !statusText.isEmpty ? statusText : "Unknown error"
      return AnthropicError("api", "API error (\(response.status)): \(detail)")
    }
  }

  /// The message in a small JSON error body. A larger body isn't read to the end or shown.
  private func readProviderErrorMessage(_ response: HTTPResponse) async throws -> String {
    defer { response.cancel() }
    var raw = Data()
    for try await chunk in response.body {
      raw.append(chunk.prefix(Self.maxProviderErrorBytes - raw.count))
      if raw.count >= Self.maxProviderErrorBytes { return "" }
    }
    try Task.checkCancellation()
    var text = String(decoding: raw, as: UTF8.self)
    // Like TextDecoder, drop a byte order mark.
    if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
    guard let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
      return ""
    }
    let nested = (parsed["error"] as? [String: Any])?["message"]
    return sanitizeProviderMessage(nested as? String ?? parsed["message"] as? String ?? "")
  }
}

private struct MessagesRequest: Encodable {
  struct TypeField: Encodable { let type: String }
  struct OutputConfig: Encodable { let effort: String }

  let model: String
  let maxTokens: Int
  var thinking: TypeField?
  var outputConfig: OutputConfig?
  var fallbacks: String?
  var stream: Bool?
  var cacheControl: TypeField?
  var system: String?
  let messages: [AnthropicMessage]

  enum CodingKeys: String, CodingKey {
    case model, thinking, fallbacks, stream, system, messages
    case maxTokens = "max_tokens"
    case outputConfig = "output_config"
    case cacheControl = "cache_control"
  }
}

func isCancellation(_ error: any Error) -> Bool {
  error is CancellationError || (error as? URLError)?.code == .cancelled
}

func isTimeout(_ error: any Error) -> Bool { (error as? URLError)?.code == .timedOut }

/// Makes text from the API safe to show: API keys are redacted, each run of control characters and
/// whitespace becomes one space, and the result is trimmed and capped at 240 UTF-16 code units.
public func sanitizeProviderMessage(_ message: String) -> String {
  let scalars = Array(message.unicodeScalars)
  var redacted: [Unicode.Scalar] = []
  var index = 0
  while index < scalars.count {
    if let end = apiKeyEnd(in: scalars, from: index) {
      redacted.append(contentsOf: "[REDACTED API KEY]".unicodeScalars)
      index = end
    } else {
      redacted.append(scalars[index])
      index += 1
    }
  }
  var cleaned = String.UnicodeScalarView()
  var pendingSpace = false
  for scalar in redacted {
    if scalar.value < 0x20 || scalar.value == 0x7F || javaScriptWhitespace.contains(scalar) {
      pendingSpace = !cleaned.isEmpty
      continue
    }
    if pendingSpace { cleaned.append(" ") }
    pendingSpace = false
    cleaned.append(scalar)
  }
  return String(cleaned).prefix(utf16Units: 240)
}

/// Where an API key starting at `start` ends: `sk-ant-` in any ASCII case, then at least eight
/// letters, digits, underscores or hyphens, like /sk-ant-[A-Za-z0-9_-]{8,}/i.
private func apiKeyEnd(in scalars: [Unicode.Scalar], from start: Int) -> Int? {
  let prefix = Array("sk-ant-".unicodeScalars)
  guard start + prefix.count <= scalars.count,
    zip(scalars[start...], prefix).allSatisfy({ asciiLowercased($0) == $1 }) else { return nil }
  var end = start + prefix.count
  while end < scalars.count, isKeyCharacter(scalars[end]) { end += 1 }
  return end - start - prefix.count >= 8 ? end : nil
}

private func asciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
  ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32)! : scalar
}

private func isKeyCharacter(_ scalar: Unicode.Scalar) -> Bool {
  ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    || scalar == "_" || scalar == "-"
}
