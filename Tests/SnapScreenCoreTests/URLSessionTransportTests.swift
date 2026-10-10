import Foundation
import Testing
@testable import SnapScreenCore

// Runs the client over the real URLSession transport, with a URLProtocol standing in for the server.

private final class StubServer: URLProtocol, @unchecked Sendable {
  enum Ending { case finish, stall, fail(URLError) }
  struct Reply {
    var status = 200
    var headers = ["Content-Type": "text/event-stream"]
    var chunks: [Data]
    var ending = Ending.finish
  }

  private static let replies = Locked<[String: Reply]>([:])
  private static let stopped = Locked<Set<String>>([])

  /// A transport whose requests get `reply`, and the key that identifies them.
  static func transport(_ reply: Reply) -> (URLSessionTransport, String) {
    let key = UUID().uuidString
    replies.withLock { $0[key] = reply }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubServer.self]
    configuration.httpAdditionalHeaders = ["X-Stub-Key": key]
    return (URLSessionTransport(configuration: configuration), key)
  }

  static func wasStopped(_ key: String) -> Bool { stopped.current.contains(key) }

  private var key: String { request.value(forHTTPHeaderField: "X-Stub-Key") ?? "" }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let reply = Self.replies.withLock({ $0[key] }), let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/2", headerFields: reply.headers)
    else { return client!.urlProtocol(self, didFailWithError: URLError(.badURL)) }
    client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for chunk in reply.chunks { client!.urlProtocol(self, didLoad: chunk) }
    switch reply.ending {
    case .finish: client!.urlProtocolDidFinishLoading(self)
    case .stall: break
    case .fail(let error): client!.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {
    let key = key
    Self.stopped.withLock { _ = $0.insert(key) }
  }
}

@Test func streamsAnAnswerOverURLSession() async throws {
  let stream = Data(("data: \(thinkingStart)\n\ndata: \(textDelta("Hello, "))\n\ndata: \(textDelta("café"))\n\n"
    + finish("end_turn").map { "data: \($0)\n\n" }.joined()).utf8)
  // Split inside the "é", as network packets can be.
  let split = stream.firstIndex(of: 0xC3)! + 1
  let (transport, _) = StubServer.transport(StubServer.Reply(chunks: [stream[..<split], stream[split...]]))
  let seen = Locked<[String]>([])
  let answer = try await AnthropicClient(transport: transport).analyzeImage(apiKey: "key", image: pixelPNG,
    handlers: StreamHandlers(onThinking: { seen.withLock { $0.append("(thinking)") } },
      onDelta: { text in seen.withLock { $0.append(text) } }))
  #expect(answer.text == "Hello, café")
  #expect(seen.current == ["(thinking)", "Hello, ", "Hello, café"])
}

@Test func reportsStatusAndHeadersFromURLSession() async {
  let (transport, _) = StubServer.transport(StubServer.Reply(status: 429,
    headers: ["Content-Type": "application/json", "Retry-After": "12"], chunks: [Data("{}".utf8)]))
  let error = await thrownError(AnthropicError.self) {
    _ = try await AnthropicClient(transport: transport).analyzeImage(apiKey: "key", image: pixelPNG)
  }
  #expect(error == AnthropicError("rate_limit", "Rate limit reached. Try again in ~12s."))
}

@Test func readsAProviderErrorOverURLSessionWithoutAStatusText() async {
  let (transport, _) = StubServer.transport(StubServer.Reply(status: 400, headers: [:], chunks: [Data("<html>".utf8)]))
  let error = await thrownError(AnthropicError.self) {
    _ = try await AnthropicClient(transport: transport).analyzeImage(apiKey: "key", image: pixelPNG)
  }
  #expect(error == AnthropicError("api", "API error (400): Unknown error"))
}

@Test func mapsURLSessionTimeoutsAndDroppedConnections() async {
  for (failure, code) in [(URLError(.timedOut), "timeout"), (URLError(.networkConnectionLost), "stream")] {
    let (transport, _) = StubServer.transport(StubServer.Reply(chunks: [Data("data: \(textDelta("Partial"))\n\n".utf8)],
      ending: .fail(failure)))
    let error = await thrownError(AnthropicError.self) {
      _ = try await AnthropicClient(transport: transport).analyzeImage(apiKey: "key", image: pixelPNG)
    }
    #expect(error?.code == code)
  }
}

@Test func stopCancelsTheURLSessionRequest() async throws {
  let (transport, key) = StubServer.transport(StubServer.Reply(chunks: [Data("data: \(textDelta("Partial"))\n\n".utf8)],
    ending: .stall))
  let received = Locked(false)
  let task = Task {
    try await AnthropicClient(transport: transport).analyzeImage(apiKey: "key", image: pixelPNG,
      handlers: StreamHandlers(onDelta: { _ in received.withLock { $0 = true } }))
  }
  while !received.current { try await Task.sleep(for: .milliseconds(5)) }
  task.cancel()
  let result = await task.result
  #expect(throws: CancellationError.self) { try result.get() }
  for _ in 0..<200 where !StubServer.wasStopped(key) { try await Task.sleep(for: .milliseconds(5)) }
  #expect(StubServer.wasStopped(key))
}
