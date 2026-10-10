import Foundation

/// Splits a server-sent events byte stream into events. An event ends
/// at two line endings, each CRLF, LF or CR. A CR at the end of the bytes so far waits for the next
/// chunk, because it may be the first half of a CRLF.
struct SSEEventSplitter {
  private var buffer: [UInt8] = []
  /// Positions before this one have been checked, and no later bytes can make them a boundary.
  private var searchStart = 0

  // As in the regex this replaced, the first of these to match at the leftmost position wins, so
  // a CRLF is never read as a CR and an LF.
  private static let boundaries: [[UInt8]] = [
    [13, 10, 13, 10], [13, 10, 10], [10, 13, 10], [13, 13, 10], [13, 10, 13], [10, 10], [13, 13], [10, 13],
  ]

  mutating func append(_ bytes: Data) -> [String] {
    buffer.append(contentsOf: bytes)
    return takeEvents(flush: false)
  }

  /// The events left when the stream ends, including a last one with no blank line after it.
  mutating func finish() -> [String] {
    var events = takeEvents(flush: true)
    if !buffer.isEmpty {
      events.append(String(decoding: buffer, as: UTF8.self))
      buffer.removeAll()
    }
    return events
  }

  private mutating func takeEvents(flush: Bool) -> [String] {
    var events: [String] = []
    while let (index, length) = nextBoundary(flush: flush) {
      // Boundaries are ASCII, so decoding each event alone matches decoding the whole stream.
      events.append(String(decoding: buffer[..<index], as: UTF8.self))
      buffer.removeFirst(index + length)
      searchStart = 0
    }
    return events
  }

  private mutating func nextBoundary(flush: Bool) -> (index: Int, length: Int)? {
    for index in searchStart..<max(searchStart, buffer.count) {
      guard let boundary = Self.boundaries.first(where: { buffer[index...].starts(with: $0) }) else { continue }
      if !flush && boundary.last == 13 && index + boundary.count == buffer.count {
        searchStart = index
        return nil
      }
      return (index, boundary.count)
    }
    // A boundary is at most four bytes, so only the last three positions can still start one.
    searchStart = max(0, buffer.count - 3)
    return nil
  }
}

/// Reads an answer from the API's event stream. Thinking text is omitted, and any other content
/// block, such as the marker where a refused answer continues on a fallback model, is skipped, so
/// only answer text is kept.
struct AnswerStreamReader {
  private(set) var text = ""
  private(set) var stopReason: String?
  private(set) var sawMessageStop = false
  private var sawThinking = false
  private let handlers: StreamHandlers

  init(handlers: StreamHandlers) { self.handlers = handlers }

  mutating func handle(_ rawEvent: String) throws {
    var dataLines: [String] = []
    var eventName = ""
    let lines = normalizeLineEndings(rawEvent).unicodeScalars.split(separator: "\n")
    for line in lines where line.first != ":" {
      let colon = line.firstIndex(of: ":")
      let field = String(Substring(colon.map { line[..<$0] } ?? line[...]))
      var value = colon.map { line[line.index(after: $0)...] } ?? line[line.endIndex...]
      if value.first == " " { value = value.dropFirst() }
      if field == "data" { dataLines.append(String(Substring(value))) }
      if field == "event" { eventName = String(Substring(value)) }
    }
    if dataLines.isEmpty { return }

    let malformed = AnthropicError.stream("The API returned malformed streaming data. Please try again.")
    guard let json = try? JSONSerialization.jsonObject(with: Data(dataLines.joined(separator: "\n").utf8)),
      let data = json as? [String: Any] else { throw malformed }

    switch data["type"] as? String ?? eventName {
    case "content_block_start":
      // Thinking text is omitted, but its blocks still stream, so their start shows that the model
      // is thinking before it answers.
      let blockType = (data["content_block"] as? [String: Any])?["type"] as? String
      if !sawThinking && (blockType == "thinking" || blockType == "redacted_thinking") {
        sawThinking = true
        handlers.onThinking()
      }
    case "content_block_delta":
      guard let delta = data["delta"] as? [String: Any] else { throw malformed }
      if delta["type"] as? String == "text_delta" {
        guard let part = delta["text"] as? String else { throw malformed }
        text += part
        handlers.onDelta(text)
      }
    case "message_delta":
      guard let delta = data["delta"] as? [String: Any] else { throw malformed }
      if let reason = delta["stop_reason"], !(reason is NSNull) {
        guard let reason = reason as? String else { throw malformed }
        stopReason = reason
      }
    case "message_stop":
      sawMessageStop = true
    case "error":
      let message = ((data["error"] as? [String: Any])?["message"] as? String).map(sanitizeProviderMessage) ?? ""
      throw AnthropicError("api", message.isEmpty ? "The API stream reported an error." : message)
    default:
      break
    }
  }
}

/// Reads a streamed answer to its end. Stopping the calling task ends it with `CancellationError`.
func readAnswerStream(_ response: HTTPResponse, handlers: StreamHandlers) async throws
  -> (text: String, stopReason: String?) {
  var splitter = SSEEventSplitter()
  var reader = AnswerStreamReader(handlers: handlers)
  var chunks = response.body.makeAsyncIterator()
  while true {
    let chunk: Data?
    do {
      chunk = try await chunks.next()
    } catch {
      if Task.isCancelled || isCancellation(error) || isTimeout(error) { throw error }
      throw AnthropicError.stream("The API response stream was interrupted. Please try again.")
    }
    // A cancelled stream ends early, which isn't the end of the answer.
    try Task.checkCancellation()
    guard let chunk else { break }
    for event in splitter.append(chunk) { try reader.handle(event) }
  }
  for event in splitter.finish() { try reader.handle(event) }
  guard reader.sawMessageStop else {
    throw AnthropicError.stream("The API response ended before it was complete. Please try again.")
  }
  return (reader.text, reader.stopReason)
}
