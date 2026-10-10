import Foundation

public let megabyte = 1_000_000

/// A request that breaks a limit in Settings or would send an inconsistent conversation. It's
/// reported before anything is sent.
public struct RequestLimitError: Error, Equatable, Sendable {
  public enum Code: String, Sendable {
    case inputEmpty = "input_empty"
    case inputTooLong = "input_too_long"
    case screenshotInvalid = "screenshot_invalid"
    case screenshotTooLarge = "screenshot_too_large"
    case screenshotDimensionsTooLarge = "screenshot_dimensions_too_large"
    case conversationIncomplete = "conversation_incomplete"
  }

  public let code: Code
  public let message: String

  public init(_ code: Code, _ message: String) {
    self.code = code
    self.message = message
  }
}

/// Code points, which is what the input limits count.
public func countTextCharacters(_ text: String) -> Int { text.unicodeScalars.count }

public func assertUserInputWithinLimit(_ text: String, maxCharacters: Int, label: String = "Question") throws {
  if text.isBlank { throw RequestLimitError(.inputEmpty, "\(label) cannot be empty.") }
  let count = countTextCharacters(text)
  if count > maxCharacters {
    throw RequestLimitError(.inputTooLong,
      "\(label) is \(groupedDigits(count)) characters. The current limit is \(groupedDigits(maxCharacters)). " +
      "Shorten it or raise the limit in Settings.")
  }
}

public struct ScreenshotMetadata: Equatable, Sendable {
  public let bytes: Int
  public let width: Int
  public let height: Int
}

/// The size and dimensions of a PNG, read from its header without decoding it.
public func inspectPNG(_ png: Data) throws -> ScreenshotMetadata {
  if png.isEmpty {
    throw RequestLimitError(.screenshotInvalid, "The captured screenshot is incomplete. Take a new snip and try again.")
  }
  let header = [UInt8](png.prefix(24))
  let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
  guard header.count == 24, header.starts(with: signature), header[12..<16].elementsEqual("IHDR".utf8) else {
    throw RequestLimitError(.screenshotInvalid, "The captured screenshot is not a valid PNG. Take a new snip and try again.")
  }
  func uint32(at offset: Int) -> Int { header[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
  let width = uint32(at: 16)
  let height = uint32(at: 20)
  if width == 0 || height == 0 {
    throw RequestLimitError(.screenshotInvalid,
      "The captured screenshot has invalid dimensions. Take a new snip and try again.")
  }
  return ScreenshotMetadata(bytes: png.count, width: width, height: height)
}

@discardableResult
public func assertScreenshotWithinLimits(_ png: Data, limits: SnapScreenLimits) throws -> ScreenshotMetadata {
  let metadata = try inspectPNG(png)
  if metadata.bytes > limits.maxScreenshotBytes {
    throw RequestLimitError(.screenshotTooLarge,
      "The screenshot is \(formatMegabytes(metadata.bytes)) MB. " +
      "The current limit is \(formatMegabytes(limits.maxScreenshotBytes)) MB. " +
      "Select a smaller region or raise the limit in Settings.")
  }
  if max(metadata.width, metadata.height) > limits.maxScreenshotDimension {
    throw RequestLimitError(.screenshotDimensionsTooLarge,
      "The screenshot is \(groupedDigits(metadata.width)) × \(groupedDigits(metadata.height)) px. " +
      "The current edge limit is \(groupedDigits(limits.maxScreenshotDimension)) px. " +
      "Select a smaller region or raise the limit in Settings.")
  }
  return metadata
}

public func assertHistoryScreenshotsWithinLimits(_ history: [AnthropicMessage], limits: SnapScreenLimits) throws {
  for message in history {
    for case .image(let png) in message.blocks ?? [] {
      try assertScreenshotWithinLimits(png, limits: limits)
    }
  }
}

/// Megabytes with one decimal unless whole, like JavaScript's `toFixed`, which rounds exact
/// halves up where C's formatting rounds them to even.
func formatMegabytes(_ bytes: Int) -> String {
  if bytes % megabyte == 0 { return String(bytes / megabyte) }
  // bytes / 1e6 is exactly a half-tenth only for these remainders.
  if bytes % 500_000 == 250_000 {
    let tenths = (bytes + 50_000) / 100_000
    return "\(tenths / 10).\(tenths % 10)"
  }
  return String(format: "%.1f", Double(bytes) / Double(megabyte))
}

public struct PrunedTurns<Message> {
  public let messages: [Message]
  public let removedTurns: Int
}

/// Keeps the pinned first turn and the newest complete turns, leaving room for the request about
/// to be added. It never returns an unmatched message.
public func pruneApiHistoryForNewestTurn(_ history: [AnthropicMessage], maxConversationTurns: Int) throws
  -> PrunedTurns<AnthropicMessage> {
  let turns = try completePairs(history)
  return keepNewestTurns(turns, original: history, maxConversationTurns: maxConversationTurns)
}

/// The same policy for the visible conversation, which starts with the first answer alone.
public func pruneDisplayHistoryForNewestTurn(_ history: [DisplayMessage], maxConversationTurns: Int) throws
  -> PrunedTurns<DisplayMessage> {
  guard let first = history.first else { return PrunedTurns(messages: [], removedTurns: 0) }
  guard first.role == .assistant else { throw incompleteConversationError() }
  let turns = [[first]] + (try completePairs(Array(history.dropFirst())))
  return keepNewestTurns(turns, original: history, maxConversationTurns: maxConversationTurns)
}

private func keepNewestTurns<Message>(_ turns: [[Message]], original: [Message], maxConversationTurns: Int)
  -> PrunedTurns<Message> {
  let existingBudget = max(1, maxConversationTurns - 1)
  if turns.count <= existingBudget { return PrunedTurns(messages: original, removedTurns: 0) }
  let kept = [turns[0]] + turns.suffix(existingBudget - 1)
  return PrunedTurns(messages: kept.flatMap { $0 }, removedTurns: turns.count - kept.count)
}

private func completePairs<Message: ConversationMessage>(_ messages: [Message]) throws -> [[Message]] {
  guard messages.count.isMultiple(of: 2) else { throw incompleteConversationError() }
  return try stride(from: 0, to: messages.count, by: 2).map { index in
    guard messages[index].role == .user, messages[index + 1].role == .assistant else {
      throw incompleteConversationError()
    }
    return [messages[index], messages[index + 1]]
  }
}

private func incompleteConversationError() -> RequestLimitError {
  RequestLimitError(.conversationIncomplete,
    "The conversation contains an unfinished turn. Retry or remove it before continuing.")
}
