import Foundation

public enum MessageRole: String, Codable, Sendable {
  case user
  case assistant
}

/// A content block in an Anthropic API message. Screenshots are PNG data, sent as base64.
public enum AnthropicContentBlock: Equatable, Sendable {
  case text(String)
  case image(Data)
}

/// A message sent to the API.
public struct AnthropicMessage: Equatable, Sendable {
  public enum Content: Equatable, Sendable {
    case text(String)
    case blocks([AnthropicContentBlock])
  }

  public var role: MessageRole
  public var content: Content

  public init(role: MessageRole, content: Content) {
    self.role = role
    self.content = content
  }

  public static func user(_ text: String) -> AnthropicMessage { AnthropicMessage(role: .user, content: .text(text)) }
}

// The JSON shape the Messages API uses.

extension AnthropicContentBlock: Codable {
  private enum CodingKeys: String, CodingKey { case type, text, source }
  private enum SourceKeys: String, CodingKey { case type, mediaType = "media_type", data }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .type) {
    case "text":
      self = .text(try container.decode(String.self, forKey: .text))
    case "image":
      let source = try container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
      guard let data = Data(base64Encoded: try source.decode(String.self, forKey: .data)) else {
        throw DecodingError.dataCorruptedError(forKey: .data, in: source, debugDescription: "Invalid base64")
      }
      self = .image(data)
    case let type:
      throw DecodingError.dataCorruptedError(forKey: .type, in: container,
        debugDescription: "Unsupported content block \(type)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let text):
      try container.encode("text", forKey: .type)
      try container.encode(text, forKey: .text)
    case .image(let data):
      try container.encode("image", forKey: .type)
      var source = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
      try source.encode("base64", forKey: .type)
      try source.encode("image/png", forKey: .mediaType)
      try source.encode(data.base64EncodedString(), forKey: .data)
    }
  }
}

extension AnthropicMessage: Codable {
  private enum CodingKeys: String, CodingKey { case role, content }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    role = try container.decode(MessageRole.self, forKey: .role)
    if let text = try? container.decode(String.self, forKey: .content) {
      content = .text(text)
    } else {
      content = .blocks(try container.decode([AnthropicContentBlock].self, forKey: .content))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(role, forKey: .role)
    switch content {
    case .text(let text): try container.encode(text, forKey: .content)
    case .blocks(let blocks): try container.encode(blocks, forKey: .content)
    }
  }
}

// A snip's one message: the screenshot, the Default Prompt as guidance, and an optional question.

public let sessionGuidancePrefix = "Screenshot task guidance:\n"

func sessionGuidanceBlock(_ instruction: String) -> AnthropicContentBlock {
  .text(sessionGuidancePrefix + instruction)
}

/// The screenshot, then the trimmed guidance and question when they aren't blank.
public func createScreenshotUserContent(_ image: Data, instruction: String? = nil,
  question: String? = nil) -> [AnthropicContentBlock] {
  var content: [AnthropicContentBlock] = [.image(image)]
  if let instruction = instruction?.jsTrimmed, !instruction.isEmpty { content.append(sessionGuidanceBlock(instruction)) }
  if let question = question?.jsTrimmed, !question.isEmpty { content.append(.text(question)) }
  return content
}
