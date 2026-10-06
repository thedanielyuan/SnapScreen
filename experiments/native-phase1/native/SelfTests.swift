import Foundation

private enum SelfTestError: Error { case failed(String) }

func runProtocolSelfTests() throws -> Int {
  var count = 0
  func check(_ value: Bool, _ name: String) throws {
    guard value else { throw SelfTestError.failed(name) }
    count += 1
  }
  func encode(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value)
  }
  func rejects(_ value: [String: Any]) -> Bool {
    do { _ = try parseCommand(encode(value)); return false } catch { return true }
  }
  if case .hello = try parseCommand(encode(["version": 1, "type": "hello"])) { count += 1 }
  else { throw SelfTestError.failed("hello") }
  if case .capture(let id, let bytes) = try parseCommand(encode([
    "version": 1, "type": "capture", "sessionId": "test-1", "imageDataUrl": "data:image/png;base64,AQ==",
  ])) { try check(id == "test-1" && bytes == Data([1]), "capture payload") }
  else { throw SelfTestError.failed("capture") }
  if case .answer(_, let text, let done) = try parseCommand(encode([
    "version": 1, "type": "answer", "sessionId": "test-1", "text": "mock", "done": true,
  ])) { try check(text == "mock" && done, "answer delta") }
  else { throw SelfTestError.failed("answer") }
  try check(rejects(["version": true, "type": "hello"]), "boolean version")
  try check(rejects(["version": 2, "type": "hello"]), "unsupported version")
  try check(rejects(["version": 1, "type": "hello", "extra": "ignored?"]), "unknown fields")
  try check(rejects(["version": 1, "type": "unknown"]), "unknown type")
  try check(rejects(["version": 1, "type": "reset"]), "reset requires session")
  try check(rejects(["version": 1, "type": "reset", "sessionId": "line\nbreak"]), "malformed session")
  try check(rejects(["version": 1, "type": "reset", "sessionId": "trailing\n"]), "trailing newline session")
  try check(rejects(["version": 1, "type": "reset", "sessionId": String(repeating: "a", count: 81)]), "long session")
  try check(rejects(["version": 1, "type": "answer", "sessionId": "test", "text": "", "done": 1]), "numeric bool")
  try check(rejects(["version": 1, "type": "answer", "sessionId": "test",
    "text": String(repeating: "a", count: 16_001), "done": false]), "large answer delta")
  try check(rejects(["version": 1, "type": "capture", "sessionId": "test",
    "imageDataUrl": "data:text/html;base64,AQ=="]), "image MIME type")
  try check(rejects(["version": 1, "type": "capture", "sessionId": "test",
    "imageDataUrl": "data:image/png;base64,!!"]), "invalid base64")
  try check(rejects(["version": 1, "type": "capture", "sessionId": "test",
    "imageDataUrl": "data:image/png;base64,"]), "empty image")

  let message: [String: Any] = ["version": 1, "type": "hello"]
  let frame = try framed(message)
  let expectedBody = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
  try check(frame.prefix(4) == Data([UInt8(expectedBody.count), 0, 0, 0]), "little-endian prefix")
  try check(frame.dropFirst(4) == expectedBody, "frame body")
  func readBytes(_ bytes: Data) throws -> Data? {
    let pipe = Pipe()
    try pipe.fileHandleForWriting.write(contentsOf: bytes)
    try pipe.fileHandleForWriting.close()
    defer { try? pipe.fileHandleForReading.close() }
    return try readFrame(pipe.fileHandleForReading)
  }
  try check(try readBytes(frame) == expectedBody, "frame roundtrip")
  try check(try readBytes(Data()) == nil, "clean EOF")
  for (name, bytes) in [("truncated header", Data([3, 0])), ("truncated body", Data([2, 0, 0, 0, 123])),
    ("zero length", Data([0, 0, 0, 0])), ("oversized input", Data([1, 0, 128, 0]))] {
    do { _ = try readBytes(bytes); throw SelfTestError.failed(name) }
    catch is WireError { count += 1 }
  }
  do { _ = try framed(["text": String(repeating: "x", count: maxOutputBytes)]); throw SelfTestError.failed("oversized output") }
  catch is WireError { count += 1 }

  try check(NormalizedRect(x: 0, y: 0, width: 1, height: 1).isValid, "full image crop")
  try check(NormalizedRect(x: 0.2, y: 0.3, width: 0.5, height: 0.4).isValid, "inner crop")
  try check(!NormalizedRect(x: -0.1, y: 0, width: 0.5, height: 0.5).isValid, "negative crop")
  try check(!NormalizedRect(x: 0, y: 0, width: 0, height: 1).isValid, "empty crop")
  try check(!NormalizedRect(x: 0.8, y: 0, width: 0.5, height: 1).isValid, "out of bounds crop")
  try check(!NormalizedRect(x: .nan, y: 0, width: 1, height: 1).isValid, "nonfinite crop")
  try check(validImageDimensions(3840, 2160), "retina image dimensions")
  try check(!validImageDimensions(1, .infinity), "nonfinite image dimensions")
  try check(!validImageDimensions(16_384, 16_384), "pixel budget")
  try check(!validImageDimensions(16_385, 1), "dimension budget")
  try check(!validImageDimensions(0, 1), "empty image dimension")
  let landscape = fittedImageRect(CGSize(width: 2000, height: 1000), in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
  try check(landscape == CGRect(x: 12, y: 256, width: 976, height: 488), "letterboxed landscape")
  let portrait = fittedImageRect(CGSize(width: 1000, height: 2000), in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
  try check(portrait == CGRect(x: 256, y: 12, width: 488, height: 976), "pillarboxed portrait")
  try check(fittedImageRect(CGSize(width: 1000, height: 1000), in: CGRect(x: 0, y: 0, width: 20, height: 20)) == .zero,
    "tiny selection surface")
  try check(fittedImageRect(.zero, in: CGRect(x: 0, y: 0, width: 1000, height: 1000)) == .zero, "empty fitted image")
  var geometry = SurfaceGeometryTracker()
  let original = CGRect(x: 100, y: 100, width: 640, height: 520)
  let moved = CGRect(x: 200, y: 150, width: 640, height: 520)
  let resized = CGRect(x: 200, y: 150, width: 800, height: 600)
  let beforeShow = geometry.observeFrame(moved)
  try check(!beforeShow.moved && !beforeShow.resized, "pre-show geometry ignored")
  geometry.begin(frame: original, scroll: CGRect(x: 0, y: 0, width: 600, height: 400))
  let baseline = geometry.observeFrame(original)
  try check(!baseline.moved && !baseline.resized, "post-show baseline not a movement")
  let moveChange = geometry.observeFrame(moved)
  try check(moveChange.moved && !moveChange.resized, "position change classified")
  let duplicate = geometry.observeFrame(moved)
  try check(!duplicate.moved && !duplicate.resized, "notification/poll duplicate suppressed")
  let resizeChange = geometry.observeFrame(resized)
  try check(!resizeChange.moved && resizeChange.resized, "size change classified")
  try check(!geometry.observeScroll(CGRect(x: 0, y: 0, width: 700, height: 500)), "viewport resize is not scroll")
  try check(geometry.observeScroll(CGRect(x: 0, y: 80, width: 700, height: 500)), "scroll origin change detected")
  try check(!geometry.observeScroll(CGRect(x: 0, y: 80, width: 700, height: 500)), "duplicate scroll suppressed")
  var previewGeometry = SurfaceGeometryTracker()
  previewGeometry.begin(frame: original)
  try check(!previewGeometry.observeScroll(CGRect(x: 0, y: 80, width: 700, height: 500)), "untracked scroll ignored")
  try check(geometryMetadata(CGRect(x: -100, y: -20, width: 600, height: 400)) != nil, "negative monitor coordinates valid")
  try check(geometryMetadata(.zero) == nil, "empty geometry omitted")
  try check(geometryMetadata(CGRect(x: CGFloat.infinity, y: 0, width: 600, height: 400)) == nil, "nonfinite geometry omitted")
  try check(geometryMetadata(CGRect(x: 1_000_001, y: 0, width: 600, height: 400)) == nil, "oversized geometry omitted")
  let edgeFrame = CGRect(x: 100, y: 100, width: 600, height: 400)
  try check(isNearFrameEdge(CGPoint(x: 96, y: 300), edgeFrame), "outer resize zone is near the edge")
  try check(isNearFrameEdge(CGPoint(x: 695, y: 300), edgeFrame), "inner right edge is near the edge")
  try check(isNearFrameEdge(CGPoint(x: 400, y: 104), edgeFrame), "bottom edge is near the edge")
  try check(!isNearFrameEdge(CGPoint(x: 400, y: 300), edgeFrame), "panel interior is not an edge")
  try check(modifierTransitions(from: [], to: [.shift]) == ["shift_down"], "shift press named")
  try check(modifierTransitions(from: [.shift, .command], to: [.command]) == ["shift_up"], "shift release named")
  try check(modifierTransitions(from: [.option], to: [.command]) == ["option_up", "command_down"], "modifier swap named")
  try check(modifierTransitions(from: [.command], to: [.command]).isEmpty, "unchanged modifiers ignored")
  let fittedSurface = CGRect(x: 12, y: 12, width: 1000, height: 500)
  try check(selectionMeetsMinimum(CGRect(x: 0.1, y: 0.1, width: 0.005, height: 0.01), in: fittedSurface),
    "released drag at the minimum submits")
  try check(!selectionMeetsMinimum(CGRect(x: 0.1, y: 0.1, width: 0.004, height: 0.5), in: fittedSurface),
    "narrow released drag cancels")
  try check(!selectionMeetsMinimum(.zero, in: fittedSurface), "click without drag cancels")
  try check(!selectionMeetsMinimum(CGRect(x: 0, y: 0, width: 0.5, height: 0.5), in: .zero), "empty image cancels")
  try check(!selectionMeetsMinimum(CGRect(x: 0, y: 0, width: CGFloat.nan, height: 0.5), in: fittedSurface),
    "nonfinite selection cancels")
  try check(telemetryToken("com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese")
    == "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", "input source identifier kept")
  try check(telemetryToken("com.example.keylayout.My Layout") == "other", "spaced identifier replaced")
  try check(telemetryToken("") == "other" && telemetryToken(String(repeating: "a", count: 121)) == "other",
    "empty and long identifiers replaced")
  try check(telemetryToken("com.apple.keylayout.ABC\n") == "other", "control character identifier replaced")
  try check(containsIgnoringWhitespace("Answer line one\n\nline two", "Answer line one line two"), "line breaks ignored")
  try check(containsIgnoringWhitespace("prefix Answer text", "Answer text"), "paste into existing text")
  try check(!containsIgnoringWhitespace("Answer", "Answer text"), "partial paste differs")
  try check(!containsIgnoringWhitespace("anything", " \n"), "empty copy never matches")
  var pressed = PressedPointerTracker()
  try check(pressed.observe(inside: true) == nil, "pressed pointer inside")
  try check(pressed.observe(inside: false) == "left" && pressed.outside, "pressed pointer left panel")
  try check(pressed.observe(inside: false) == nil, "pressed pointer outside reported once")
  try check(pressed.observe(inside: true) == "returned" && !pressed.outside, "pressed pointer returned")
  pressed.reset()
  try check(!pressed.outside, "pressed pointer reset on release")
  return count
}
