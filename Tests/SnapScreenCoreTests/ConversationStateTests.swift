import Foundation
import Testing
@testable import SnapScreenCore

private let image = Data("ABC".utf8)

private func imageTurn(_ guidance: String?, question: String? = nil) -> AnthropicMessage {
  AnthropicMessage(role: .user, content: .blocks(createScreenshotUserContent(image, instruction: guidance,
    question: question)))
}

private func assistant(_ text: String, failed: Bool = false) -> DisplayMessage {
  DisplayMessage(role: .assistant, content: text, failed: failed)
}

private func user(_ text: String) -> DisplayMessage { DisplayMessage(role: .user, content: text) }

@Test func showsOnlyTheAssistantAnswerForTheFirstAnswer() {
  #expect(appendAssistantMessage([], "B. Photosynthesis") == [assistant("B. Photosynthesis")])
  #expect(appendAssistantMessage(appendUserMessage([assistant("B")], "Why?"), "Light.")
    == [assistant("B"), user("Why?"), assistant("Light.")])
  #expect(appendGenerationStoppedMessage([]) == [assistant("Generation stopped.")])
}

@Test func rebuildsTheHiddenScreenshotTurnWhenAnAnswerHasNoProviderHistory() {
  let state = settleSuccessfulConversation(kind: .initial, baseDisplayMessages: [], baseHistory: [],
    assistantText: "Initial answer", image: image, sessionInstruction: "What does this show?")
  #expect(state.displayMessages == [assistant("Initial answer")])
  #expect(state.conversationHistory == [imageTurn("What does this show?"), .assistant("Initial answer")])
}

@Test func rebuildsAnAlignedFollowUpWhenProviderHistoryIsMissing() {
  let baseHistory: [AnthropicMessage] = [.user("Hidden screenshot turn"), .assistant("Initial answer")]
  let state = settleSuccessfulConversation(kind: .followUp, baseDisplayMessages: [assistant("Initial answer")],
    baseHistory: baseHistory, assistantText: "Because.", image: image, userText: "Why?")
  #expect(state.displayMessages == [assistant("Initial answer"), user("Why?"), assistant("Because.")])
  #expect(state.conversationHistory == baseHistory + [.user("Why?"), .assistant("Because.")])
}

@Test func prefersTheProviderHistory() {
  let provider: [AnthropicMessage] = [imageTurn(nil), .assistant("Answer")]
  let state = settleSuccessfulConversation(kind: .initial, baseDisplayMessages: [], baseHistory: [],
    assistantText: "Answer", image: image, providerHistory: provider)
  #expect(state.conversationHistory == provider)
}

private let priorDisplay = [assistant("Original answer")]
private let priorHistory: [AnthropicMessage] = [.user("Original question"), .assistant("Original answer")]

@Test func keepsAStoppedFollowUpsPartialTextInBothHistories() {
  let state = settleStoppedConversation(kind: .followUp, baseDisplayMessages: priorDisplay, baseHistory: priorHistory,
    partialAnswer: "  Partial reply  ", image: image, userText: "Why?")
  #expect(state.displayMessages == priorDisplay + [user("Why?"), assistant("Partial reply")])
  #expect(state.conversationHistory == priorHistory + [.user("Why?"), .assistant("Partial reply")])
}

@Test func removesAFollowUpStoppedBeforeAnyText() {
  let state = settleStoppedConversation(kind: .followUp, baseDisplayMessages: priorDisplay, baseHistory: priorHistory,
    partialAnswer: "", image: image, userText: "Why?")
  #expect(state == ConversationState(displayMessages: priorDisplay, conversationHistory: priorHistory))
}

@Test func marksAFirstAnswerStoppedBeforeAnyText() {
  let state = settleStoppedConversation(kind: .initial, baseDisplayMessages: [], baseHistory: [], partialAnswer: "",
    image: image, sessionInstruction: "Initial prompt")
  #expect(state.displayMessages == [assistant("Generation stopped.")])
  #expect(state.conversationHistory == [
    AnthropicMessage(role: .user, content: .blocks([.image(image), .text("Screenshot task guidance:\nInitial prompt")])),
    .assistant("Generation stopped."),
  ])
}

@Test func keepsTheScreenshotWhenAFirstAnswerIsStoppedWithText() {
  let state = settleStoppedConversation(kind: .initial, baseDisplayMessages: [], baseHistory: [],
    partialAnswer: "Partial answer", image: image, sessionInstruction: "Answer the screenshot.")
  #expect(state.conversationHistory == [imageTurn("Answer the screenshot."), .assistant("Partial answer")])
}

private func failFirst(_ partialAnswer: String) -> ConversationState {
  settleFailedFirstAnswer(partialAnswer: partialAnswer, errorMessage: "Request timed out.", image: image,
    sessionInstruction: "Answer the screenshot.")
}

@Test func keepsAFailedFirstAnswersTextMarkedInterrupted() {
  let text = "Partial answer\n\nResponse interrupted: Request timed out."
  let failed = failFirst("  Partial answer  ")
  #expect(failed.displayMessages == [assistant(text, failed: true)])
  #expect(failed.conversationHistory == [imageTurn("Answer the screenshot."), .assistant(text)])
  #expect(failFirst("  ") == .empty)
}

@Test func keepsAFailedFirstAnswerAlignedForAFollowUp() throws {
  let failed = failFirst("Partial answer")
  let display = settleSuccessfulFollowUp(failed.displayMessages, userText: "Go on", assistantText: "The rest.")
  let history = failed.conversationHistory + [.user("Go on"), .assistant("The rest.")]
  _ = try prepareAlignedConversationForNewestTurn(display, history, maxConversationTurns: 2)
}

private let initialDisplay = [assistant("Initial answer")]
private let initialHistory: [AnthropicMessage] = [.user("Initial prompt"), .assistant("Initial answer")]

private func failFollowUp(_ partialAnswer: String = "") throws -> FailedFollowUpState {
  try settleFailedFollowUp(baseDisplayMessages: initialDisplay, baseHistory: initialHistory,
    partialAnswer: partialAnswer, errorMessage: "Network disconnected.", image: image, userText: "Why?")
}

@Test func recordsAFailedFollowUpAsTheSamePairInBothHistories() throws {
  let failed = try failFollowUp()
  #expect(failed.state.displayMessages.suffix(2) == [user("Why?"),
    assistant("Response failed: Network disconnected.", failed: true)])
  #expect(failed.state.conversationHistory.suffix(2) == [.user("Why?"),
    .assistant("Response failed: Network disconnected.")])
}

@Test func keepsAFailedFollowUpsPartialTextMarkedInterrupted() throws {
  let failed = try failFollowUp("Partial answer")
  let text = "Partial answer\n\nResponse interrupted: Network disconnected."
  #expect(failed.state.displayMessages.last?.content == text)
  #expect(failed.state.conversationHistory.last == .assistant(text))
}

@Test func restoresTheConversationBeforeAFailedFollowUpForRetry() throws {
  let restored = restoreBeforeFailedFollowUp(try failFollowUp())
  #expect(restored == ConversationState(displayMessages: initialDisplay, conversationHistory: initialHistory))
  #expect(settleSuccessfulFollowUp(restored.displayMessages, userText: "Why?", assistantText: "Because.")
    == initialDisplay + [user("Why?"), assistant("Because.")])
}

@Test func keepsAFailedPairAsContextForTheNextQuestion() throws {
  let failed = try failFollowUp()
  let display = settleSuccessfulFollowUp(failed.state.displayMessages, userText: "Different question",
    assistantText: "Later answer")
  let history = failed.state.conversationHistory + [.user("Different question"), .assistant("Later answer")]
  #expect(display.map { AnthropicMessage(role: $0.role, content: .text($0.content)) } == Array(history.dropFirst()))
}

@Test func keepsTheScreenshotWhenAFollowUpWithoutHistoryFails() throws {
  let failed = try settleFailedFollowUp(baseDisplayMessages: [], baseHistory: [], partialAnswer: "",
    errorMessage: "Request failed.", image: image, sessionInstruction: "Answer the screenshot.",
    userText: "Can you answer it?")
  #expect(failed.state.conversationHistory == [imageTurn("Answer the screenshot.", question: "Can you answer it?"),
    .assistant("Response failed: Request failed.")])
}

@Test func keepsAStoppedMarkerBeforeAFailedFollowUp() throws {
  let failed = try settleFailedFollowUp(baseDisplayMessages: [assistant("Generation stopped.")], baseHistory: [],
    partialAnswer: "", errorMessage: "Request failed.", image: image, sessionInstruction: "Initial prompt",
    userText: "Can you answer it?")
  #expect(failed.state.displayMessages.count == 3)
  #expect(failed.state.conversationHistory.count == 4)
  #expect(failed.state.conversationHistory[0] == imageTurn("Initial prompt"))
  #expect(failed.state.conversationHistory[1] == .assistant("Generation stopped."))
}

@Test func trimsTheSameOldestTurnsFromBothHistories() throws {
  let display = [assistant("Initial answer"), user("Old"), assistant("Old answer"), user("Recent"),
    assistant("Recent answer")]
  let model = [AnthropicMessage.user("Hidden screenshot prompt")]
    + display.map { AnthropicMessage(role: $0.role, content: .text($0.content)) }
  let aligned = try prepareAlignedConversationForNewestTurn(display, model, maxConversationTurns: 2)
  #expect(aligned == AlignedConversation(state: ConversationState(displayMessages: Array(display.prefix(1)),
    conversationHistory: Array(model.prefix(2))), removedTurns: 2))
  #expect(describeRemovedTurns(2)
    == "2 older conversation turns were removed to keep the screenshot and newest request within the configured limit.")
  #expect(describeRemovedTurns(1).hasPrefix("1 older conversation turn was removed"))
}

@Test func refusesHistoriesThatNoLongerMatch() {
  let error = thrownError(RequestLimitError.self) {
    _ = try prepareAlignedConversationForNewestTurn([assistant("Answer")],
      [.user("Prompt"), .assistant("Answer"), .user("Extra"), .assistant("Extra answer")], maxConversationTurns: 2)
  }
  #expect(error?.message.contains("out of sync") == true)
  // Text that only looks the same, such as a decomposed accent, doesn't match.
  #expect(thrownError(RequestLimitError.self) {
    _ = try prepareAlignedConversationForNewestTurn([assistant("caf\u{E9}")], [.user("Prompt"), .assistant("cafe\u{301}")],
      maxConversationTurns: 4)
  } != nil)
}

@Test func keepsAStoppedFirstAnswerAlignedForFollowUps() throws {
  let stopped = settleStoppedConversation(kind: .initial, baseDisplayMessages: [], baseHistory: [], partialAnswer: "",
    image: image, sessionInstruction: "Initial prompt")
  let display = settleSuccessfulFollowUp(stopped.displayMessages, userText: "Try this question",
    assistantText: "Follow-up answer")
  let history = stopped.conversationHistory + [.user("Try this question"), .assistant("Follow-up answer")]
  _ = try prepareAlignedConversationForNewestTurn(display, history, maxConversationTurns: 2)
  #expect(clearIncompleteInitialFailure() == .empty)
}

@Test func addsGuidanceOnlyWhenTheScreenshotTurnHasNone() {
  let history: [AnthropicMessage] = [imageTurn(nil), .assistant("A")]
  #expect(retainSessionGuidance(history, instruction: "  Use SI units. ")[0] == imageTurn("Use SI units."))
  #expect(retainSessionGuidance(history, instruction: " ") == history)
  let pinned: [AnthropicMessage] = [imageTurn("Original"), .assistant("A")]
  #expect(retainSessionGuidance(pinned, instruction: "Changed") == pinned)
  #expect(createScreenshotUserContent(image, instruction: " ", question: "\tWhy? ") == [.image(image), .text("Why?")])
}
