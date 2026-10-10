import CoreGraphics
import Foundation
import ImageIO
@testable import SnapScreenCore

/// A value shared with `@Sendable` closures in tests.
final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) { self.value = value }

  var current: Value { withLock { $0 } }

  func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }
}

/// A response for `MockTransport`, in the fixtures' format.
struct ScriptedResponse: Decodable, Sendable {
  enum End: String, Decodable, Sendable {
    case close
    /// The body fails as if the connection dropped.
    case error
    /// The user presses Stop when the client asks for more of the body.
    case stop
  }

  var status: Int?
  var statusText: String?
  var headers: [String: String]?
  var body: String?
  /// Splits the body's UTF-8 bytes into chunks of this many bytes. One chunk by default.
  var chunkSize: Int?
  var end: End?
  /// The request fails before any response arrives.
  var networkError: Bool?

  static func sse(_ events: [String], end: End? = nil) -> ScriptedResponse {
    ScriptedResponse(headers: ["content-type": "text/event-stream"],
      body: events.map { "data: \($0)\n\n" }.joined(), end: end)
  }

  static func answer(_ parts: String..., stopReason: String = "end_turn") -> ScriptedResponse {
    sse(parts.map(textDelta) + finish(stopReason))
  }

  static func json(_ status: Int, _ body: String = "{}", statusText: String = "") -> ScriptedResponse {
    ScriptedResponse(status: status, statusText: statusText, headers: ["content-type": "application/json"],
      body: body)
  }
}

func textDelta(_ text: String) -> String {
  let data = try! JSONSerialization.data(withJSONObject: ["type": "content_block_delta", "index": 0,
    "delta": ["type": "text_delta", "text": text]] as [String: Any])
  return String(decoding: data, as: UTF8.self)
}

let thinkingStart = #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#

func finish(_ stopReason: String) -> [String] {
  [#"{"type":"message_delta","delta":{"stop_reason":"\#(stopReason)"}}"#, #"{"type":"message_stop"}"#]
}

/// Replays scripted responses in order and records the requests.
final class MockTransport: HTTPTransport, @unchecked Sendable {
  struct Failure: Error {}

  private let state: Locked<(responses: [ScriptedResponse], requests: [URLRequest], cancelledBodies: Int)>
  /// Thrown by `send` instead of answering, such as `URLError(.timedOut)`.
  var sendError: (any Error)?
  /// Thrown by the body after its chunks.
  var bodyError: (any Error)?
  /// Holds `send` open until the calling task is cancelled.
  var waitsForCancellation = false

  init(_ responses: ScriptedResponse...) { state = Locked((responses, [], 0)) }
  init(_ responses: [ScriptedResponse]) { state = Locked((responses, [], 0)) }

  var requests: [URLRequest] { state.current.requests }
  var cancelledBodies: Int { state.current.cancelledBodies }

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    let script = state.withLock { state in
      state.requests.append(request)
      return state.responses.isEmpty ? nil : state.responses.removeFirst()
    }
    if waitsForCancellation { try await Task.sleep(for: .seconds(3600)) }
    if let sendError { throw sendError }
    guard let script else { throw Failure() }
    if script.networkError == true { throw URLError(.notConnectedToInternet) }

    let bytes = Data((script.body ?? "").utf8)
    let size = script.chunkSize ?? max(bytes.count, 1)
    let chunks = stride(from: 0, to: bytes.count, by: size).map { Data(bytes[$0..<min($0 + size, bytes.count)]) }
    let next = Locked(0)
    let bodyError = bodyError
    // The unfolding closure runs on the reading task, so `stop` can cancel it the way Stop does.
    let body = AsyncThrowingStream<Data, any Error> {
      let index = next.withLock { index in
        defer { index += 1 }
        return index
      }
      if index < chunks.count { return chunks[index] }
      if let bodyError { throw bodyError }
      switch script.end ?? .close {
      case .close:
        return nil
      case .error:
        throw URLError(.networkConnectionLost)
      case .stop:
        withUnsafeCurrentTask { $0?.cancel() }
        try await Task.sleep(for: .seconds(3600))
        return nil
      }
    }
    return HTTPResponse(status: script.status ?? 200, statusText: script.statusText ?? "",
      headers: script.headers ?? [:], body: body, cancel: { [state] in state.withLock { $0.cancelledBodies += 1 } })
  }
}

/// Any JSON value, compared by value, so key order and formatting don't matter.
enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  init(data: Data) throws { self = try JSONDecoder().decode(JSONValue.self, from: data) }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  subscript(key: String) -> JSONValue? {
    if case .object(let object) = self { return object[key] }
    return nil
  }

  func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
  }
}

/// The JSON body of a request the client sent.
func requestBody(_ request: URLRequest?) throws -> JSONValue {
  try JSONValue(data: request?.httpBody ?? Data())
}

/// The PNG bytes in a base64 data URL.
func dataURLBytes(_ dataURL: String) -> Data {
  Data(base64Encoded: String(dataURL[dataURL.index(after: dataURL.firstIndex(of: ",")!)...]))!
}

/// A PNG's signature and header with the given dimensions, padded to `bytes`. It can't be decoded.
func pngHeader(width: Int, height: Int, bytes: Int = 24) -> Data {
  var data = Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82])
  for value in [width, height] { data.append(contentsOf: withUnsafeBytes(of: UInt32(value).bigEndian, Array.init)) }
  data.append(Data(count: max(0, bytes - data.count)))
  return data
}

/// A real 1 × 1 PNG, the image in the fixtures.
let pixelPNG = Data(base64Encoded:
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

/// A decodable PNG filled by `color(x, y)`, with (0, 0) at the top-left.
func makePNG(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8) = { _, _ in (40, 120, 200) })
  -> Data {
  var pixels = [UInt8](repeating: 255, count: width * height * 4)
  for y in 0..<height {
    for x in 0..<width {
      let (red, green, blue) = color(x, y)
      let offset = (y * width + x) * 4
      pixels[offset] = red
      pixels[offset + 1] = green
      pixels[offset + 2] = blue
    }
  }
  let provider = CGDataProvider(data: Data(pixels) as CFData)!
  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  return try! encodePNG(image)
}

/// The red, green and blue values of the pixel at (x, y) from the top-left of a PNG.
func pixel(_ png: Data, x: Int, y: Int) throws -> (UInt8, UInt8, UInt8) {
  let image = try decodePNG(png)
  var rgba = [UInt8](repeating: 0, count: 4)
  let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  // Bitmap contexts put the origin at the bottom-left.
  context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
  return (rgba[0], rgba[1], rgba[2])
}

/// The error a call throws, if it's of type `E`.
func thrownError<E: Error>(_ type: E.Type, _ body: () async throws -> Void) async -> E? {
  do {
    try await body()
    return nil
  } catch let error as E {
    return error
  } catch {
    return nil
  }
}

func thrownError<E: Error>(_ type: E.Type, _ body: () throws -> Void) -> E? {
  do {
    try body()
    return nil
  } catch let error as E {
    return error
  } catch {
    return nil
  }
}
