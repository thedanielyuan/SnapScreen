import AppKit
import Foundation

let maxInputBytes = 8 * 1024 * 1024
let maxOutputBytes = 256 * 1024

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

enum HostCommand {
  case hello
  case capture(String, Data)
  case answer(String, String, Bool)
  case reset(String)
  case shutdown
}

enum WireError: Error { case malformed, oversized, truncated, io }

func validSessionId(_ value: Any?) -> String? {
  guard let value = value as? String, (1...80).contains(value.utf8.count),
    value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
      (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
  return value
}

func parseCommand(_ data: Data) throws -> HostCommand {
  guard data.count <= maxInputBytes,
    let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    let version = value["version"] as? NSNumber,
    CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
    let type = value["type"] as? String else { throw WireError.malformed }
  func keys(_ expected: Set<String>) throws {
    guard Set(value.keys) == expected.union(["version", "type"]) else { throw WireError.malformed }
  }
  switch type {
  case "hello":
    try keys([])
    return .hello
  case "shutdown":
    try keys([])
    return .shutdown
  case "capture":
    try keys(["sessionId", "imageDataUrl"])
    guard let id = validSessionId(value["sessionId"]), let url = value["imageDataUrl"] as? String,
      let comma = url.firstIndex(of: ","),
      ["data:image/png;base64", "data:image/jpeg;base64"].contains(String(url[..<comma])),
      let image = Data(base64Encoded: String(url[url.index(after: comma)...])),
      !image.isEmpty else { throw WireError.malformed }
    return .capture(id, image)
  case "answer":
    try keys(["sessionId", "text", "done"])
    guard let id = validSessionId(value["sessionId"]), let text = value["text"] as? String,
      text.utf16.count <= 16_000, let done = value["done"] as? NSNumber,
      CFGetTypeID(done) == CFBooleanGetTypeID() else { throw WireError.malformed }
    return .answer(id, text, done.boolValue)
  case "reset":
    try keys(["sessionId"])
    guard let id = validSessionId(value["sessionId"]) else { throw WireError.malformed }
    return .reset(id)
  default:
    throw WireError.malformed
  }
}

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

import CoreFoundation

func validImageDimensions(_ width: Double, _ height: Double) -> Bool {
  width.isFinite && height.isFinite && width.rounded() == width && height.rounded() == height &&
    width >= 1 && height >= 1 && width <= 16_384 && height <= 16_384 && width * height <= 80_000_000
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

struct SurfaceGeometryTracker {
  private var frame: CGRect?
  private var scroll: CGRect?

  mutating func begin(frame: CGRect, scroll: CGRect? = nil) {
    self.frame = frame
    self.scroll = scroll
  }

  mutating func observeFrame(_ current: CGRect) -> (moved: Bool, resized: Bool) {
    guard let previous = frame else { return (false, false) }
    frame = current
    return (previous.origin != current.origin, previous.size != current.size)
  }

  mutating func observeScroll(_ current: CGRect) -> Bool {
    guard let previous = scroll else { return false }
    scroll = current
    // Streaming and window layout may change document/viewport size without any scroll.
    return previous.origin != current.origin
  }
}

func geometryMetadata(_ rect: CGRect) -> [String: Double]? {
  guard [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
    rect.width > 0, rect.height > 0 else { return nil }
  return ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
}

/// A released drag must span at least `minimum` displayed points in each direction, matching the
/// extension's 5 CSS-pixel minimum crop. `selection` is normalized within the fitted image.
func selectionMeetsMinimum(_ selection: CGRect, in fitted: CGRect, minimum: CGFloat = 5) -> Bool {
  [selection.width, selection.height, fitted.width, fitted.height].allSatisfy { $0.isFinite } &&
    selection.width * fitted.width >= minimum && selection.height * fitted.height >= minimum
}

/// True when `point` is outside `frame` or within `margin` points of its edge: where AppKit starts
/// a border resize. Title-bar clicks near the top edge also qualify; they lower the shield on release.
func isNearFrameEdge(_ point: CGPoint, _ frame: CGRect, margin: CGFloat = 8) -> Bool {
  !frame.insetBy(dx: margin, dy: margin).contains(point)
}

/// Names the modifier keys pressed or released between two flag states, for example `shift_down`.
func modifierTransitions(from previous: NSEvent.ModifierFlags, to current: NSEvent.ModifierFlags) -> [String] {
  let names: [(NSEvent.ModifierFlags, String)] = [(.shift, "shift"), (.control, "control"),
    (.option, "option"), (.command, "command"), (.capsLock, "caps_lock"), (.function, "function")]
  return names.compactMap { flag, name in
    previous.contains(flag) == current.contains(flag) ? nil : "\(name)_\(current.contains(flag) ? "down" : "up")"
  }
}

/// Telemetry carries fixed identifiers only, such as an input-source ID; anything else is `other`.
func telemetryToken(_ value: String) -> String {
  guard (1...120).contains(value.utf8.count), value.utf8.allSatisfy({ (65...90).contains($0) ||
    (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }) else { return "other" }
  return value
}

/// In-memory comparison for paste verification. Field editors may normalize line breaks, so
/// whitespace is ignored. Neither string is retained or reported.
func containsIgnoringWhitespace(_ text: String, _ expected: String) -> Bool {
  func compact(_ value: String) -> String {
    String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }))
  }
  let needle = compact(expected)
  return !needle.isEmpty && compact(text).contains(needle)
}

/// Tracks whether a pointer pressed inside a panel has left that panel's frame before release.
struct PressedPointerTracker {
  private(set) var outside = false

  mutating func observe(inside: Bool) -> String? {
    if !inside && !outside { outside = true; return "left" }
    if inside && outside { outside = false; return "returned" }
    return nil
  }

  mutating func reset() { outside = false }
}
