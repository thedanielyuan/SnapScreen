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
  // A real 1×1 PNG, only for in-memory validation. Production screenshots are never written.
  let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aFe8AAAAASUVORK5CYII="
  let hello: [String: Any] = ["version": 2, "type": "hello", "connectionId": "connection-1"]
  func message(_ type: String, _ fields: [String: Any] = [:], request: String = "capture-1",
    session: String = "session-1", connection: String = "connection-1") -> [String: Any] {
    var value: [String: Any] = ["version": 2, "type": type, "connectionId": connection,
      "sessionId": session, "requestId": request]
    for (key, item) in fields { value[key] = item }
    return value
  }
  func command(_ type: String, _ fields: [String: Any] = [:], request: String = "capture-1",
    session: String = "session-1", connection: String = "connection-1") throws -> HostCommand {
    try parseCommand(encode(message(type, fields, request: request, session: session, connection: connection)))
  }
  let greeting = try parseCommand(encode(hello))
  if case .hello = greeting.payload { count += 1 } else { throw SelfTestError.failed("hello") }
  let capture = try command("capture", ["imageDataUrl": png])
  if case .capture(let bytes) = capture.payload {
    try check(decodeImage(bytes) != nil, "valid bounded PNG decodes")
  } else { throw SelfTestError.failed("capture") }
  let accepted = try command("accepted", ["imageDataUrl": png, "maxInputCharacters": 4000])
  if case .accepted(_, let limit) = accepted.payload { try check(limit == 4000, "accepted crop input limit") }
  else { throw SelfTestError.failed("accepted") }
  for type in ["started", "thinking"] { _ = try command(type); count += 1 }
  for status in ["streaming", "done", "stopped"] {
    _ = try command("answer", ["text": "Answer", "status": status]); count += 1
  }
  _ = try command("error", ["code": "NETWORK", "message": "Try again."]); count += 1
  _ = try command("expired", ["message": "Disconnected."]); count += 1

  for field in ["connectionId", "sessionId", "requestId"] {
    for invalid in ["", "line\nbreak", "trailing\n", "white space", String(repeating: "a", count: 81)] {
      var value = message("thinking")
      value[field] = invalid
      try check(rejects(value), "invalid \(field)")
    }
    var value = message("thinking")
    value.removeValue(forKey: field)
    try check(rejects(value), "missing \(field)")
  }
  try check(validId("AZ_az-0123") != nil && validId("é") == nil, "ASCII IDs only")
  try check(trimProtocolText("\u{FEFF}").isEmpty, "ECMAScript BOM whitespace is blank")
  try check(trimProtocolText("\u{0085}\u{200B}") == "\u{0085}\u{200B}", "non-ECMAScript Foundation whitespace retained")
  for version: Any in [true, 1, 3, 2.5, "2"] {
    var value = hello
    value["version"] = version
    try check(rejects(value), "unsupported or malformed version")
  }
  for value in [message("hello"), message("unknown"), message("ready"), message("stop"),
    message("answer", ["text": "x", "status": "complete"]),
    message("answer", ["text": String(repeating: "a", count: maxAnswerCharacters + 1), "status": "done"]),
    message("answer", ["text": String(repeating: "😀", count: maxAnswerCharacters / 2 + 1), "status": "done"]),
    message("error", ["code": String(repeating: "x", count: 81), "message": "x"]),
    message("error", ["code": "", "message": "x"]),
    message("error", ["code": "code\n", "message": "x"]),
    message("error", ["code": "code", "message": " \n"]),
    message("expired", ["message": " \n"]),
    message("error", ["code": "err", "message": String(repeating: "x", count: 1025)]),
    message("expired", ["message": String(repeating: "x", count: 1025)]),
    message("capture", ["imageDataUrl": "data:image/jpeg;base64,AQ=="]),
    message("capture", ["imageDataUrl": "data:image/png;base64,!!"]),
    message("capture", ["imageDataUrl": "data:image/png;base64,"]),
    message("capture", ["imageDataUrl": "data:image/png;base64," + String(repeating: "A", count: maxImageURLBytes)])] {
    try check(rejects(value), "reject invalid message")
  }
  for limit: Any in [0, -1, 50_001, 1.5, true, "4000"] {
    try check(rejects(message("accepted", ["imageDataUrl": png, "maxInputCharacters": limit])), "invalid input limit")
  }
  for value in [hello, message("capture", ["imageDataUrl": png]),
    message("accepted", ["imageDataUrl": png, "maxInputCharacters": 4000]), message("started"), message("thinking"),
    message("answer", ["text": "x", "status": "streaming"]), message("error", ["code": "x", "message": "x"]),
    message("expired", ["message": "x"])] {
    var extra = value
    extra["apiKey"] = "unknown field"
    try check(rejects(extra), "every variant has exact keys")
  }
  var bomb = Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
    0, 0, 64, 0, 0, 0, 64, 0])
  try check(rejects(message("capture", ["imageDataUrl": "data:image/png;base64," + bomb.base64EncodedString()])),
    "reject IHDR pixel bomb before decoding")
  bomb[18] = 65
  try check(rejects(message("capture", ["imageDataUrl": "data:image/png;base64," + bomb.base64EncodedString()])),
    "reject oversized IHDR dimension")
  do { _ = try parseCommand(Data(repeating: 32, count: maxInputBytes + 1)); throw SelfTestError.failed("large input") }
  catch is WireError { count += 1 }

  let frame = try framed(hello)
  let body = try JSONSerialization.data(withJSONObject: hello, options: [.sortedKeys])
  try check(frame.prefix(4) == Data([UInt8(body.count), 0, 0, 0]), "little-endian framing")
  try check(frame.dropFirst(4) == body, "frame body")
  func readBytes(_ bytes: Data) throws -> Data? {
    let pipe = Pipe()
    try pipe.fileHandleForWriting.write(contentsOf: bytes)
    try pipe.fileHandleForWriting.close()
    defer { try? pipe.fileHandleForReading.close() }
    return try readFrame(pipe.fileHandleForReading)
  }
  try check(try readBytes(frame) == body, "frame roundtrip")
  try check(try readBytes(Data()) == nil, "clean EOF")
  for bytes in [Data([3, 0]), Data([2, 0, 0, 0, 123]), Data([0, 0, 0, 0]), Data([1, 0, 0, 2])] {
    do { _ = try readBytes(bytes); throw SelfTestError.failed("invalid frame") }
    catch is WireError { count += 1 }
  }
  do { _ = try framed(["text": String(repeating: "x", count: maxOutputBytes)]); throw SelfTestError.failed("large output") }
  catch is WireError { count += 1 }

  var state = NativeSession()
  try check(!state.receive(capture), "capture before handshake rejected")
  try check(state.receive(greeting), "handshake binds connection")
  try check(state.readyMessage()?["connectionId"] as? String == "connection-1", "ready echoes identity")
  try check(Set(state.readyMessage()!.keys) == ["version", "type", "connectionId"], "ready exact keys")
  try check(!state.receive(greeting), "duplicate handshake rejected")
  try check(!state.receive(try command("capture", ["imageDataUrl": png], connection: "other")), "cross-connection capture rejected")
  try check(state.receive(capture), "first capture accepted")
  try check(!state.receive(capture), "one capture per process")
  try check(!state.receive(accepted), "crop acceptance before selection rejected")
  let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
  try check(state.command("selected", rect: full)?["requestId"] as? String == "capture-1", "selection echoes capture request")
  try check(!state.hasCrop, "selection does not make a local preview crop")
  try check(!state.receive(try command("accepted", ["imageDataUrl": png, "maxInputCharacters": 4000], session: "other")),
    "cross-session acceptance ignored")
  try check(state.receive(accepted) && state.hasCrop, "accepted crop retained")
  try check(state.maxInputCharacters == 4000, "session limit applied")
  try check(!state.receive(try command("started")), "capture request ID cannot be reused for generation")
  try check(state.receive(try command("started", request: "generation-1")), "new generation begins")
  try check(!state.receive(try command("thinking")), "stale generation event ignored")
  try check(state.command("followup", text: "question") == nil, "follow-up while streaming rejected")
  try check(state.command("stop")?["requestId"] as? String == "generation-1", "stop echoes active request")
  try check(state.command("stop") == nil, "duplicate stop rejected")
  try check(state.receive(try command("answer", ["text": "partial", "status": "stopped"], request: "generation-1")),
    "stop response accepted")
  try check(state.canRetry && state.canFollowup, "stopped controls available")
  try check(state.command("retry") != nil, "retry waits for new generation")
  try check(!state.receive(try command("answer", ["text": "late", "status": "done"], request: "generation-1")),
    "late answer during retry ignored")
  try check(!state.receive(try command("started", request: "generation-1")), "old generation start rejected")
  try check(state.receive(try command("started", request: "generation-2")), "retry starts new generation")
  try check(state.receive(try command("answer", ["text": "answer", "status": "done"], request: "generation-2")), "answer done")
  try check(state.canFollowup && !state.canRetry && !state.canStop, "completed controls")
  try check(state.command("followup", text: " \n") == nil, "empty follow-up rejected")
  try check(state.command("followup", text: "\u{FEFF}") == nil, "BOM-only follow-up rejected locally")
  try check(inputFitsLimits(String(repeating: "😀", count: 2001), maximum: 4000), "preference counts Unicode scalars")
  try check(state.command("followup", text: String(repeating: "😀", count: 4001)) == nil, "preference scalar bound")
  try check(inputFitsLimits(String(repeating: "😀", count: 25_000), maximum: 50_000), "UTF16 hard bound accepts boundary")
  try check(!inputFitsLimits(String(repeating: "😀", count: 25_001), maximum: 50_000), "UTF16 hard bound rejects excess")
  let followup = state.command("followup", text: "Question")!
  try check(Set(followup.keys) == ["version", "type", "connectionId", "sessionId", "requestId", "text"], "follow-up exact keys")
  try check(followup["requestId"] as? String == "generation-2", "follow-up echoes preceding generation")
  try check(state.receive(try command("started", request: "generation-3")), "follow-up generation starts")
  try check(state.receive(try command("error", ["code": "network", "message": "Try again"], request: "generation-3")), "request error")
  try check(state.canRetry && state.canFollowup, "error offers retry and follow-up")
  try check(state.receive(try command("expired", ["message": "Disconnected"], request: "generation-3")), "expiry accepted")
  try check(state.phase == .expired && state.sessionId == nil && state.requestId == nil && !state.hasCrop,
    "expiry forgets session and retained crop state")
  try check(state.command("retry") == nil && state.command("close") == nil, "expired commands disabled")
  try check(!state.receive(greeting) && !state.receive(capture), "expired session cannot reconnect or replay")

  for closeType in ["close", "cancelled"] {
    var closing = NativeSession()
    _ = closing.receive(greeting)
    _ = closing.receive(capture)
    let closed = closing.command(closeType)!
    try check(Set(closed.keys) == ["version", "type", "connectionId", "sessionId", "requestId"], "close exact keys")
    try check(closing.phase == .closed && closing.sessionId == nil, "close clears state")
  }
  var disconnected = NativeSession()
  _ = disconnected.receive(greeting)
  _ = disconnected.receive(capture)
  disconnected.expire()
  try check(disconnected.phase == .expired && !disconnected.active, "EOF during selection expires")
  try check(disconnected.command("selected", rect: full) == nil, "EOF cannot submit selection")

  try check(full.isValid, "full-image normalized crop")
  try check(!NormalizedRect(x: -0.1, y: 0, width: 1, height: 1).isValid, "negative crop rejected")
  try check(!NormalizedRect(x: 0, y: 0, width: 0, height: 1).isValid, "empty crop rejected")
  try check(!NormalizedRect(x: 0.8, y: 0, width: 0.5, height: 1).isValid, "outside crop rejected")
  try check(!NormalizedRect(x: .nan, y: 0, width: 1, height: 1).isValid, "nonfinite crop rejected")
  try check(validImageDimensions(3840, 2160) && !validImageDimensions(16_384, 16_384), "pixel budget")
  try check(!validImageDimensions(16_385, 1) && !validImageDimensions(0, 1), "dimension budget")
  let landscape = fittedImageRect(CGSize(width: 2000, height: 1000), in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
  try check(landscape == CGRect(x: 12, y: 256, width: 976, height: 488), "fitted landscape mapping")
  let portrait = fittedImageRect(CGSize(width: 1000, height: 2000), in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
  try check(portrait == CGRect(x: 256, y: 12, width: 488, height: 976), "fitted portrait mapping")
  try check(fittedImageRect(.zero, in: CGRect(x: 0, y: 0, width: 1000, height: 1000)) == .zero, "empty fitted image")
  let fitted = CGRect(x: 12, y: 12, width: 1000, height: 500)
  try check(selectionMeetsMinimum(CGRect(x: 0.1, y: 0.1, width: 0.005, height: 0.01), in: fitted), "minimum drag submits")
  try check(!selectionMeetsMinimum(.zero, in: fitted), "click cancels")
  try check(!selectionMeetsMinimum(CGRect(x: 0, y: 0, width: 0.004, height: 1), in: fitted), "tiny drag cancels")
  let edge = CGRect(x: 100, y: 100, width: 600, height: 400)
  try check(isNearFrameEdge(CGPoint(x: 96, y: 300), edge), "outer edge raises shield")
  try check(isNearFrameEdge(CGPoint(x: 695, y: 300), edge), "inner edge raises shield")
  try check(!isNearFrameEdge(CGPoint(x: 400, y: 300), edge), "interior leaves shield transparent")
  return count
}
