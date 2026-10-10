import Foundation

/// A response whose body arrives in chunks as the server sends it.
public struct HTTPResponse: Sendable {
  public let status: Int
  /// The reason phrase. Empty over HTTP/2, which has none.
  public let statusText: String
  /// Header values by lowercased name.
  public let headers: [String: String]
  public let body: AsyncThrowingStream<Data, any Error>
  /// Stops the transfer. The client calls it once it needs no more of the body.
  public let cancel: @Sendable () -> Void

  public init(status: Int, statusText: String = "", headers: [String: String] = [:],
    body: AsyncThrowingStream<Data, any Error>, cancel: @escaping @Sendable () -> Void) {
    self.status = status
    self.statusText = statusText
    self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { _, last in last }
    self.body = body
    self.cancel = cancel
  }
}

/// Sends the API's requests, so tests can replace the network.
public protocol HTTPTransport: Sendable {
  /// Returns once the response headers arrive. Task cancellation cancels the request.
  func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// Sends requests with URLSession. It keeps nothing on disk, and it ends a request that receives
/// nothing for `idleTimeout` or takes longer than `overallTimeout` with `URLError.timedOut`.
public struct URLSessionTransport: HTTPTransport {
  /// The API sends events, including pings, while it works, so a minute of silence is a stall.
  public static let idleTimeout: TimeInterval = 60
  /// The longest one answer may take, including adaptive thinking and the whole stream.
  public static let overallTimeout: TimeInterval = 600

  private let session: URLSession

  public init() { self.init(configuration: .ephemeral) }

  init(configuration: URLSessionConfiguration) {
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = Self.idleTimeout
    configuration.timeoutIntervalForResource = Self.overallTimeout
    session = URLSession(configuration: configuration)
  }

  public func send(_ request: URLRequest) async throws -> HTTPResponse {
    var request = request
    request.timeoutInterval = Self.idleTimeout
    let (bytes, response) = try await session.bytes(for: request)
    let task = bytes.task
    guard let http = response as? HTTPURLResponse else {
      task.cancel()
      throw URLError(.badServerResponse)
    }
    let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    let reader = Task {
      do {
        var chunk = Data()
        for try await byte in bytes {
          chunk.append(byte)
          // Hands over each line as it ends, so an event never waits for the next one.
          if byte == 0x0A || byte == 0x0D || chunk.count >= 16_384 {
            continuation.yield(chunk)
            chunk.removeAll(keepingCapacity: true)
          }
        }
        if !chunk.isEmpty { continuation.yield(chunk) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    let cancel: @Sendable () -> Void = {
      reader.cancel()
      task.cancel()
    }
    continuation.onTermination = { _ in cancel() }
    var headers: [String: String] = [:]
    for (name, value) in http.allHeaderFields {
      if let name = name as? String, let value = value as? String { headers[name] = value }
    }
    return HTTPResponse(status: http.statusCode, headers: headers, body: body, cancel: cancel)
  }
}
