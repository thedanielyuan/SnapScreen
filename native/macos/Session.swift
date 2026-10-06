import Foundation

/// One Chrome-launched process owns exactly one connection and one capture. This state contains
/// no screenshot or conversation data. Expiry is terminal; reconnecting requires a new process.
struct NativeSession {
  enum Phase { case connecting, ready, selecting, accepting, waiting, streaming, done, stopped, failed, expired, closed }
  private(set) var phase: Phase = .connecting
  private(set) var connectionId: String?
  private(set) var sessionId: String?
  private(set) var requestId: String?
  private(set) var maxInputCharacters = maxFollowupCharacters
  private(set) var hasCrop = false
  private(set) var stopRequested = false
  private var seenRequestIds = Set<String>()

  var canFollowup: Bool { hasCrop && (phase == .done || phase == .stopped || phase == .failed) }
  var canRetry: Bool { hasCrop && (phase == .failed || phase == .stopped) }
  var canStop: Bool { phase == .streaming && !stopRequested }
  var active: Bool { phase != .expired && phase != .closed && sessionId != nil }

  mutating func receive(_ command: HostCommand) -> Bool {
    if case .hello = command.payload {
      guard phase == .connecting else { return false }
      connectionId = command.connectionId
      phase = .ready
      return true
    }
    guard command.connectionId == connectionId, phase != .closed, phase != .expired else { return false }
    if case .capture = command.payload {
      guard phase == .ready, let id = command.sessionId, let request = command.requestId else { return false }
      sessionId = id
      requestId = request
      seenRequestIds.insert(request)
      phase = .selecting
      return true
    }
    guard command.sessionId == sessionId, sessionId != nil else { return false }
    if case .started = command.payload {
      guard phase == .waiting, let request = command.requestId, !seenRequestIds.contains(request) else { return false }
      requestId = request
      seenRequestIds.insert(request)
      stopRequested = false
      phase = .streaming
      return true
    }
    guard command.requestId == requestId else { return false }
    switch command.payload {
    case .accepted(_, let limit):
      guard phase == .accepting else { return false }
      hasCrop = true
      maxInputCharacters = limit
      phase = .waiting
    case .thinking:
      guard phase == .streaming else { return false }
    case .answer(_, let status):
      guard phase == .streaming else { return false }
      if status == .done { phase = .done }
      if status == .stopped { phase = .stopped }
    case .error:
      guard phase == .selecting || phase == .accepting || phase == .waiting || phase == .streaming else { return false }
      phase = .failed
    case .expired:
      expire()
    default: return false
    }
    return true
  }

  func readyMessage() -> [String: Any]? {
    guard phase == .ready, let connection = connectionId else { return nil }
    return ["version": protocolVersion, "type": "ready", "connectionId": connection]
  }

  mutating func command(_ type: String, rect: NormalizedRect? = nil, text: String? = nil) -> [String: Any]? {
    guard active, let connection = connectionId, let session = sessionId, let request = requestId else { return nil }
    var fields: [String: Any] = ["version": protocolVersion, "type": type,
      "connectionId": connection, "sessionId": session, "requestId": request]
    switch type {
    case "selected":
      guard phase == .selecting, let rect = rect, rect.isValid else { return nil }
      fields["rect"] = rect.json
      phase = .accepting
    case "followup":
      guard canFollowup, let text = text, !trimProtocolText(text).isEmpty,
        inputFitsLimits(text, maximum: maxInputCharacters) else { return nil }
      fields["text"] = text
      phase = .waiting
    case "retry":
      guard canRetry else { return nil }
      phase = .waiting
    case "stop":
      guard canStop else { return nil }
      stopRequested = true
    case "cancelled":
      guard phase == .selecting else { return nil }
      close()
    case "close": close()
    default: return nil
    }
    return fields
  }

  mutating func expire() {
    phase = .expired
    forget()
  }

  private mutating func close() {
    phase = .closed
    forget()
  }

  private mutating func forget() {
    connectionId = nil
    sessionId = nil
    requestId = nil
    hasCrop = false
    stopRequested = false
    maxInputCharacters = maxFollowupCharacters
    seenRequestIds.removeAll()
  }
}
