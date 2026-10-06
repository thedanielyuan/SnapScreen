import AppKit
import CoreFoundation
import Foundation
import ImageIO

let protocolVersion = 2
let maxInputBytes = 32 * 1024 * 1024
let maxOutputBytes = 512 * 1024
let maxImageURLBytes = 24 * 1024 * 1024
let maxAnswerCharacters = 262_144
let maxFollowupCharacters = 50_000

// ECMAScript String.trim() whitespace, shared with the extension's runtime validators. Foundation
// differs for U+FEFF, U+0085 and U+200B; mismatches could turn harmless blank input into disconnects.
private let protocolWhitespace = CharacterSet(charactersIn:
  "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}" +
  "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}" +
  "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")

func trimProtocolText(_ value: String) -> String { value.trimmingCharacters(in: protocolWhitespace) }

func inputFitsLimits(_ value: String, maximum: Int) -> Bool {
  // The preference counts Unicode code points, matching the extension's for...of counter.
  // The independent wire bound counts UTF-16 code units, matching JavaScript string.length.
  value.unicodeScalars.count <= maximum && value.utf16.count <= maxFollowupCharacters
}

struct NormalizedRect {
  let x: Double
  let y: Double
  let width: Double
  let height: Double

  var json: [String: Double] { ["x": x, "y": y, "width": width, "height": height] }
  var isValid: Bool {
    [x, y, width, height].allSatisfy { $0.isFinite } &&
      x >= 0 && y >= 0 && width > 0 && height > 0 &&
      x + width <= 1 && y + height <= 1
  }
}

enum AnswerStatus: String { case streaming, done, stopped }

enum CommandPayload {
  case hello
  case capture(Data)
  case accepted(Data, Int)
  case started
  case thinking
  case answer(String, AnswerStatus)
  case error(String, String)
  case notice(String)
  case expired(String)
}

struct HostCommand {
  let connectionId: String
  let sessionId: String?
  let requestId: String?
  let payload: CommandPayload
}

enum WireError: Error { case malformed, oversized, truncated }

func validId(_ value: Any?) -> String? {
  guard let value = value as? String, (1...80).contains(value.utf8.count),
    value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
      (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
  return value
}

private func number(_ value: Any?) -> Double? {
  guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
    value.doubleValue.isFinite else { return nil }
  return value.doubleValue
}

private func pngData(_ value: Any?) throws -> Data {
  let prefix = "data:image/png;base64,"
  guard let url = value as? String, url.utf8.count <= maxImageURLBytes, url.hasPrefix(prefix),
    let bytes = Data(base64Encoded: String(url.dropFirst(prefix.count))),
    bytes.count >= 24, bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
    bytes[8...15] == Data([0, 0, 0, 13, 73, 72, 68, 82]) else { throw WireError.malformed }
  // Check the mandatory IHDR before ImageIO can allocate a decoded pixel buffer.
  func dimension(_ offset: Int) -> Double {
    Double(bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
  }
  guard validImageDimensions(dimension(16), dimension(20)) else { throw WireError.malformed }
  return bytes
}

func parseCommand(_ data: Data) throws -> HostCommand {
  guard data.count <= maxInputBytes else { throw WireError.oversized }
  guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    number(value["version"]) == Double(protocolVersion),
    let connectionId = validId(value["connectionId"]),
    let type = value["type"] as? String else { throw WireError.malformed }
  let base: Set<String> = ["version", "type", "connectionId"]
  if type == "hello" {
    guard Set(value.keys) == base else { throw WireError.malformed }
    return HostCommand(connectionId: connectionId, sessionId: nil, requestId: nil, payload: .hello)
  }
  guard let sessionId = validId(value["sessionId"]), let requestId = validId(value["requestId"])
    else { throw WireError.malformed }
  func keys(_ fields: Set<String>) throws {
    guard Set(value.keys) == base.union(["sessionId", "requestId"]).union(fields)
      else { throw WireError.malformed }
  }
  let payload: CommandPayload
  switch type {
  case "capture":
    try keys(["imageDataUrl"])
    payload = .capture(try pngData(value["imageDataUrl"]))
  case "accepted":
    try keys(["imageDataUrl", "maxInputCharacters"])
    guard let limit = number(value["maxInputCharacters"]), limit.rounded() == limit,
      limit >= 1, limit <= Double(maxFollowupCharacters) else { throw WireError.malformed }
    payload = .accepted(try pngData(value["imageDataUrl"]), Int(limit))
  case "started":
    try keys([])
    payload = .started
  case "thinking":
    try keys([])
    payload = .thinking
  case "answer":
    try keys(["text", "status"])
    guard let text = value["text"] as? String, text.utf16.count <= maxAnswerCharacters,
      let status = value["status"] as? String, let parsedStatus = AnswerStatus(rawValue: status)
      else { throw WireError.malformed }
    payload = .answer(text, parsedStatus)
  case "error":
    try keys(["code", "message"])
    guard let code = validId(value["code"]),
      let message = value["message"] as? String, message.utf16.count <= 1024,
      !trimProtocolText(message).isEmpty else { throw WireError.malformed }
    payload = .error(code, message)
  case "notice", "expired":
    try keys(["message"])
    guard let message = value["message"] as? String, message.utf16.count <= 1024,
      !trimProtocolText(message).isEmpty else { throw WireError.malformed }
    payload = type == "notice" ? .notice(message) : .expired(message)
  default:
    throw WireError.malformed
  }
  return HostCommand(connectionId: connectionId, sessionId: sessionId, requestId: requestId, payload: payload)
}

/// Chrome's native messaging framing is a uint32 length in native byte order (little endian on macOS).
func framed(_ object: [String: Any]) throws -> Data {
  let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  guard data.count <= maxOutputBytes else { throw WireError.oversized }
  var length = UInt32(data.count).littleEndian
  var result = withUnsafeBytes(of: &length) { Data($0) }
  result.append(data)
  return result
}

func readFrame(_ handle: FileHandle) throws -> Data? {
  func readExactly(_ size: Int, allowEOF: Bool) throws -> Data? {
    var result = Data()
    while result.count < size {
      guard let chunk = try handle.read(upToCount: size - result.count), !chunk.isEmpty else {
        if allowEOF && result.isEmpty { return nil }
        throw WireError.truncated
      }
      result.append(chunk)
    }
    return result
  }
  guard let header = try readExactly(4, allowEOF: true) else { return nil }
  let length = header.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << UInt32($1.offset * 8)) }
  guard length > 0, length <= maxInputBytes else { throw WireError.oversized }
  return try readExactly(Int(length), allowEOF: false)
}

func validImageDimensions(_ width: Double, _ height: Double) -> Bool {
  width.isFinite && height.isFinite && width.rounded() == width && height.rounded() == height &&
    width >= 1 && height >= 1 && width <= 16_384 && height <= 16_384 && width * height <= 80_000_000
}

func decodeImage(_ bytes: Data) -> NSImage? {
  guard let source = CGImageSourceCreateWithData(bytes as CFData,
    [kCGImageSourceShouldCache: false] as CFDictionary),
    CGImageSourceGetType(source) as String? == "public.png", CGImageSourceGetCount(source) == 1,
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
    let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
    let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
    validImageDimensions(width.doubleValue, height.doubleValue),
    let decoded = CGImageSourceCreateImageAtIndex(source, 0,
      [kCGImageSourceShouldCacheImmediately: false] as CFDictionary) else { return nil }
  return NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
}

func fittedImageRect(_ imageSize: CGSize, in bounds: CGRect) -> CGRect {
  guard imageSize.width.isFinite, imageSize.height.isFinite,
    imageSize.width > 0, imageSize.height > 0, bounds.width > 24, bounds.height > 24 else { return .zero }
  let available = bounds.insetBy(dx: 12, dy: 12)
  let scale = min(available.width / imageSize.width, available.height / imageSize.height)
  let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
  return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
    width: size.width, height: size.height)
}

func selectionMeetsMinimum(_ selection: CGRect, in fitted: CGRect, minimum: CGFloat = 5) -> Bool {
  [selection.width, selection.height, fitted.width, fitted.height].allSatisfy { $0.isFinite } &&
    selection.width * fitted.width >= minimum && selection.height * fitted.height >= minimum
}

func isNearFrameEdge(_ point: CGPoint, _ frame: CGRect, margin: CGFloat = 8) -> Bool {
  !frame.insetBy(dx: margin, dy: margin).contains(point)
}
