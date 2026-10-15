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

/// How often, and after how long, the client sends a request again after a `TransientFailure`.
struct RetryPolicy: Sendable {
  /// The wait before each retry, so there's one retry for each.
  var delays: [Duration]
  /// The longest wait the API may ask for. After a longer one, the failure is reported at once.
  var longestRequestedDelay: Duration
  var sleep: @Sendable (Duration) async throws -> Void

  /// Two retries, as Anthropic's SDKs make, but no silent wait over 10 s while the user watches.
  static let standard = RetryPolicy(delays: [.seconds(1), .seconds(2)], longestRequestedDelay: .seconds(10),
    sleep: { try await Task.sleep(for: $0) })
  /// Every failure is reported at once.
  static let none = RetryPolicy(delays: [], longestRequestedDelay: .zero, sleep: { _ in })
}

/// A failure that sending the same request again may get past: the request never got a response,
/// the API was briefly unable to answer, or the answer's stream failed before any of its text.
struct TransientFailure: Error {
  /// What's reported if the request isn't sent again.
  let error: AnthropicError
  /// The wait the API asked for with `retry-after-ms` or `retry-after`.
  var requestedDelay: Duration?
}

/// The Messages API client. Cancelling the calling task stops a
/// request with `CancellationError`; every other failure is an `AnthropicError`. A transient
/// failure is retried first, so it's reported only if it persists.
public struct AnthropicClient: Sendable {
  public static let model = "claude-opus-5-5"
  static let url = URL(string: "https://api.anthropic.com/v1/messages")!
  // Server-side refusal fallback: when a safety classifier declines, the API reruns the request on
  // the model Anthropic recommends for that refusal category, within the same stream.
  static let refusalFallbackBeta = "server-side-fallback-2026-07-01"
  static let maxProviderErrorBytes = 16_384

  private let transport: any HTTPTransport
  private let retries: RetryPolicy

  public init(transport: any HTTPTransport = URLSessionTransport()) {
    self.init(transport: transport, retries: .standard)
  }

  init(transport: any HTTPTransport, retries: RetryPolicy) {
    self.transport = transport
    self.retries = retries
  }

  /// Answers a screenshot. The Default Prompt goes with it as guidance, and `userQuestion` when
  /// there is one. Returns the answer's text.
  public func analyzeImage(apiKey: String, image: Data, hiddenInstruction: String? = nil,
    userQuestion: String? = nil, limits: SnapScreenLimits = .defaults,
    handlers: StreamHandlers = StreamHandlers()) async throws -> String {
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
    let message = AnthropicMessage(role: .user,
      content: .blocks(createScreenshotUserContent(image, instruction: hiddenInstruction, question: userQuestion)))
    return try await answer(apiKey: apiKey, messages: [message], handlers: handlers)
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
        // blocks, so the answer holds only its text.
        thinking: .init(type: "adaptive"),
        // Opus 5.5 defaults to medium.
        outputConfig: .init(effort: "high"),
        fallbacks: "default",
        stream: true,
        // No prompt caching: without follow-ups only a Retry could read a cache, which isn't worth
        // its write cost or the longer time Anthropic would keep the screenshot.
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
        return closeOpenCodeFence(cleaned) + "\n\n(Answer was cut off — snip a smaller region for a complete answer.)"
      }
      return cleaned
    }
  }

  /// Runs `operation`, retrying it as the policy allows, then reports a stop as `CancellationError`
  /// and turns transport failures into user-facing errors.
  private func mappingFailures<T>(_ operation: () async throws -> T) async throws -> T {
    do {
      return try await retrying(operation)
    } catch {
      if Task.isCancelled { throw CancellationError() }
      if isTimeout(error) { throw AnthropicError.timeout }
      if isCancellation(error) { throw AnthropicError.network }
      throw error
    }
  }

  /// Runs `attempt` again after each transient failure, once for each of the policy's delays. Stop
  /// ends a wait at once.
  private func retrying<T>(_ attempt: () async throws -> T) async throws -> T {
    for delay in retries.delays {
      do {
        return try await attempt()
      } catch let failure as TransientFailure {
        let wait = failure.requestedDelay ?? delay
        guard wait <= retries.longestRequestedDelay else { throw failure.error }
        try await retries.sleep(wait)
      }
    }
    do {
      return try await attempt()
    } catch let failure as TransientFailure {
      throw failure.error
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
      if retriesConnectionFailure(error) { throw TransientFailure(error: .network) }
      throw AnthropicError.network
    }
    guard (200...299).contains(response.status) else {
      let error = try await failure(of: response)
      guard shouldRetry(response) else { throw error }
      throw TransientFailure(error: error, requestedDelay: requestedRetryDelay(response.headers))
    }
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

#if SNAPSCREEN_TEST_HOOKS
extension AnthropicClient {
  /// Without retries, the focus tests' scripted failures reach the window at once. Production
  /// builds have no way to turn retries off.
  public init(transport: any HTTPTransport, retryingTransientFailures: Bool) {
    self.init(transport: transport, retries: retryingTransientFailures ? .standard : .none)
  }
}
#endif

private struct MessagesRequest: Encodable {
  struct TypeField: Encodable { let type: String }
  struct OutputConfig: Encodable { let effort: String }

  let model: String
  let maxTokens: Int
  var thinking: TypeField?
  var outputConfig: OutputConfig?
  var fallbacks: String?
  var stream: Bool?
  var system: String?
  let messages: [AnthropicMessage]

  enum CodingKeys: String, CodingKey {
    case model, thinking, fallbacks, stream, system, messages
    case maxTokens = "max_tokens"
    case outputConfig = "output_config"
  }
}

func isCancellation(_ error: any Error) -> Bool {
  error is CancellationError || (error as? URLError)?.code == .cancelled
}

func isTimeout(_ error: any Error) -> Bool { (error as? URLError)?.code == .timedOut }

/// Whether a request that failed this way, before any response, may get one in a moment: a pooled
/// connection that died while the Mac slept, Wi-Fi that's still reconnecting, or a failed lookup.
func retriesConnectionFailure(_ error: any Error) -> Bool {
  guard let code = (error as? URLError)?.code else { return false }
  return [.networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
    .dnsLookupFailed].contains(code)
}

/// Whether to send a request again after this failed response. As in Anthropic's SDKs, the API's
/// `x-should-retry` decides, and without it a timeout, conflict, rate limit or server error does.
private func shouldRetry(_ response: HTTPResponse) -> Bool {
  switch response.headers["x-should-retry"] {
  case "true": return true
  case "false": return false
  default: return [408, 409, 429].contains(response.status) || response.status >= 500
  }
}

/// The wait a failed response asks for, from `retry-after-ms` in milliseconds or `retry-after` in
/// seconds. A date isn't read, so the policy's own wait applies.
func requestedRetryDelay(_ headers: [String: String]) -> Duration? {
  if let milliseconds = headers["retry-after-ms"].flatMap({ Double($0) }), milliseconds.isFinite, milliseconds >= 0 {
    return .milliseconds(milliseconds)
  }
  if let seconds = headers["retry-after"].flatMap({ Double($0) }), seconds.isFinite, seconds >= 0 {
    return .seconds(seconds)
  }
  return nil
}

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
