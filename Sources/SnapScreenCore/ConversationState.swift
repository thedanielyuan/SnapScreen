import Foundation

// Keeps the visible conversation and the API history aligned through answers, stops, failures and
// retries. The API history also holds the hidden screenshot turn, so it's one message longer.

public enum AnswerKind: String, Sendable {
  case initial
  case followUp = "follow-up"
}

public struct ConversationState: Equatable, Sendable {
  public var displayMessages: [DisplayMessage]
  public var conversationHistory: [AnthropicMessage]

  public init(displayMessages: [DisplayMessage], conversationHistory: [AnthropicMessage]) {
    self.displayMessages = displayMessages
    self.conversationHistory = conversationHistory
  }

  public static let empty = ConversationState(displayMessages: [], conversationHistory: [])
}

public let generationStoppedText = "Generation stopped."

public func appendAssistantMessage(_ messages: [DisplayMessage], _ text: String) -> [DisplayMessage] {
  messages + [DisplayMessage(role: .assistant, content: text)]
}

public func appendUserMessage(_ messages: [DisplayMessage], _ text: String) -> [DisplayMessage] {
  messages + [DisplayMessage(role: .user, content: text)]
}

public func appendGenerationStoppedMessage(_ messages: [DisplayMessage]) -> [DisplayMessage] {
  appendAssistantMessage(messages, generationStoppedText)
}

public func settleSuccessfulFollowUp(_ baseDisplayMessages: [DisplayMessage], userText: String,
  assistantText: String) -> [DisplayMessage] {
  baseDisplayMessages + [DisplayMessage(role: .user, content: userText),
    DisplayMessage(role: .assistant, content: assistantText)]
}

private func buildImageTurn(_ image: Data, sessionInstruction: String?, userText: String?,
  assistantText: String) -> [AnthropicMessage] {
  [AnthropicMessage(role: .user,
     content: .blocks(createScreenshotUserContent(image, instruction: sessionInstruction, question: userText))),
   .assistant(assistantText)]
}

/// The user's text as JavaScript tests it: any non-empty string, even whitespace, counts.
private func present(_ text: String?) -> String? {
  guard let text, !text.isEmpty else { return nil }
  return text
}

public func settleSuccessfulConversation(kind: AnswerKind, baseDisplayMessages: [DisplayMessage],
  baseHistory: [AnthropicMessage], assistantText: String, image: Data, providerHistory: [AnthropicMessage]? = nil,
  userText: String? = nil, sessionInstruction: String? = nil) -> ConversationState {
  let userText = present(userText)
  let displayMessages = if kind == .followUp, let userText {
    settleSuccessfulFollowUp(baseDisplayMessages, userText: userText, assistantText: assistantText)
  } else {
    appendAssistantMessage(baseDisplayMessages, assistantText)
  }
  if let providerHistory, !providerHistory.isEmpty {
    return ConversationState(displayMessages: displayMessages, conversationHistory: providerHistory)
  }
  let conversationHistory = if !baseHistory.isEmpty, let userText {
    baseHistory + [.user(userText), .assistant(assistantText)]
  } else {
    buildImageTurn(image, sessionInstruction: sessionInstruction, userText: userText, assistantText: assistantText)
  }
  return ConversationState(displayMessages: displayMessages, conversationHistory: conversationHistory)
}

public func settleStoppedConversation(kind: AnswerKind, baseDisplayMessages: [DisplayMessage],
  baseHistory: [AnthropicMessage], partialAnswer: String, image: Data, userText: String? = nil,
  sessionInstruction: String? = nil) -> ConversationState {
  let partialAnswer = partialAnswer.jsTrimmed
  let userText = present(userText)
  if partialAnswer.isEmpty {
    if kind == .followUp {
      return ConversationState(displayMessages: baseDisplayMessages, conversationHistory: baseHistory)
    }
    return ConversationState(displayMessages: appendGenerationStoppedMessage(baseDisplayMessages),
      conversationHistory: buildImageTurn(image, sessionInstruction: sessionInstruction, userText: userText,
        assistantText: generationStoppedText))
  }
  let withUser = if kind == .followUp, let userText {
    appendUserMessage(baseDisplayMessages, userText)
  } else {
    baseDisplayMessages
  }
  let conversationHistory = if !baseHistory.isEmpty, let userText {
    baseHistory + [.user(userText), .assistant(partialAnswer)]
  } else {
    buildImageTurn(image, sessionInstruction: sessionInstruction, userText: userText, assistantText: partialAnswer)
  }
  return ConversationState(displayMessages: appendAssistantMessage(withUser, partialAnswer),
    conversationHistory: conversationHistory)
}

private func failedAnswerText(_ partialAnswer: String, _ errorMessage: String) -> String {
  let partial = partialAnswer.jsTrimmed
  let message = errorMessage.jsTrimmed
  let failure = message.isEmpty ? "The response could not be completed." : message
  return partial.isEmpty ? "Response failed: \(failure)" : "\(partial)\n\nResponse interrupted: \(failure)"
}

/// Keeps the text a first answer streamed before it failed, marked as interrupted the same way as
/// a failed follow-up, so follow-ups can still build on it. Without streamed text there is nothing
/// to keep.
public func settleFailedFirstAnswer(partialAnswer: String, errorMessage: String, image: Data,
  sessionInstruction: String? = nil, userText: String? = nil) -> ConversationState {
  if partialAnswer.isBlank { return clearIncompleteInitialFailure() }
  let assistantText = failedAnswerText(partialAnswer, errorMessage)
  return ConversationState(
    displayMessages: [DisplayMessage(role: .assistant, content: assistantText, failed: true)],
    conversationHistory: buildImageTurn(image, sessionInstruction: sessionInstruction, userText: present(userText),
      assistantText: assistantText))
}

/// A failed follow-up, with the conversation before it for Retry.
public struct FailedFollowUpState: Equatable, Sendable {
  public var state: ConversationState
  public var baseDisplayMessages: [DisplayMessage]
  public var baseHistory: [AnthropicMessage]
  public var userText: String
}

public func settleFailedFollowUp(baseDisplayMessages: [DisplayMessage], baseHistory: [AnthropicMessage],
  partialAnswer: String, errorMessage: String, image: Data, sessionInstruction: String? = nil,
  userText: String) throws -> FailedFollowUpState {
  let userText = userText.jsTrimmed
  let assistantText = failedAnswerText(partialAnswer, errorMessage)
  let displayMessages = baseDisplayMessages + [DisplayMessage(role: .user, content: userText),
    DisplayMessage(role: .assistant, content: assistantText, failed: true)]
  let failedTurn: [AnthropicMessage] = [.user(userText), .assistant(assistantText)]
  let conversationHistory = if !baseHistory.isEmpty {
    baseHistory + failedTurn
  } else if !baseDisplayMessages.isEmpty {
    try modelHistoryFromDisplay(baseDisplayMessages, image: image, sessionInstruction: sessionInstruction) + failedTurn
  } else {
    buildImageTurn(image, sessionInstruction: sessionInstruction, userText: userText, assistantText: assistantText)
  }
  return FailedFollowUpState(
    state: ConversationState(displayMessages: displayMessages, conversationHistory: conversationHistory),
    baseDisplayMessages: baseDisplayMessages, baseHistory: baseHistory, userText: userText)
}

private func modelHistoryFromDisplay(_ displayMessages: [DisplayMessage], image: Data,
  sessionInstruction: String?) throws -> [AnthropicMessage] {
  // Check the visible conversation's shape before rebuilding the longer API history from it.
  _ = try pruneDisplayHistoryForNewestTurn(displayMessages, maxConversationTurns: .max)
  return [AnthropicMessage(role: .user, content: .blocks(createScreenshotUserContent(image,
      instruction: sessionInstruction)))]
    + displayMessages.map { AnthropicMessage(role: $0.role, content: .text($0.content)) }
}

public func restoreBeforeFailedFollowUp(_ failed: FailedFollowUpState) -> ConversationState {
  ConversationState(displayMessages: failed.baseDisplayMessages, conversationHistory: failed.baseHistory)
}

public func describeRemovedTurns(_ removedTurns: Int) -> String {
  "\(removedTurns) older conversation \(removedTurns == 1 ? "turn was" : "turns were") removed to keep the " +
    "screenshot and newest request within the configured limit."
}

public struct AlignedConversation: Equatable, Sendable {
  public var state: ConversationState
  public var removedTurns: Int
}

/// Trims both histories by the same oldest turns before a new request, and refuses to continue if
/// they no longer describe the same conversation.
public func prepareAlignedConversationForNewestTurn(_ displayMessages: [DisplayMessage],
  _ conversationHistory: [AnthropicMessage], maxConversationTurns: Int) throws -> AlignedConversation {
  let display = try pruneDisplayHistoryForNewestTurn(displayMessages, maxConversationTurns: maxConversationTurns)
  let model = try pruneApiHistoryForNewestTurn(conversationHistory, maxConversationTurns: maxConversationTurns)
  guard display.removedTurns == model.removedTurns,
    historiesDescribeSameConversation(display.messages, model.messages) else {
    throw RequestLimitError(.conversationIncomplete,
      "Visible and model conversation history are out of sync. Retry or start a new snip.")
  }
  return AlignedConversation(
    state: ConversationState(displayMessages: display.messages, conversationHistory: model.messages),
    removedTurns: display.removedTurns)
}

private func historiesDescribeSameConversation(_ displayMessages: [DisplayMessage],
  _ conversationHistory: [AnthropicMessage]) -> Bool {
  if displayMessages.isEmpty || conversationHistory.isEmpty {
    return displayMessages.isEmpty && conversationHistory.isEmpty
  }
  guard conversationHistory.count == displayMessages.count + 1 else { return false }
  return zip(displayMessages, conversationHistory.dropFirst()).allSatisfy { display, model in
    model.role == display.role && model.textContent?.jsEquals(display.content) == true
  }
}

public func clearIncompleteInitialFailure() -> ConversationState { .empty }
