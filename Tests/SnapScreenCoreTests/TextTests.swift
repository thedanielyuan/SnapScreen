import Foundation
import Testing
@testable import SnapScreenCore

// The system prompt, code fences, line endings, and the JavaScript string behavior the port keeps.

@Test func guidesCarefulScreenshotAnswers() {
  for phrase in ["Carefully inspect the screenshot", "Identify the main question", "Ignore irrelevant UI",
    "briefly explain why", "answer each one in order", "unclear, unreadable, cropped", "Do not guess",
    "solve the problem carefully", "rather than using Markdown for styling", "rather than LaTeX",
    "whenever they are part of the correct answer"] {
    #expect(screenshotQASystemPrompt.contains(phrase), "\(phrase)")
  }
  #expect(!screenshotQASystemPrompt.contains("no asterisks, hashtags, underscores, backticks"))
  // Adaptive thinking reasons; the prompt has no rules about hiding reasoning.
  #expect(screenshotQASystemPrompt.range(of: "chain-of-thought|hidden reasoning|internally",
    options: [.regularExpression, .caseInsensitive]) == nil)
}

@Test func sharesFollowUpAndCodingRulesInOnePrompt() throws {
  for phrase in ["Follow-up rules", "1–3 sentences unless they ask for more detail",
    "Do not re-summarize or re-describe the screenshot", "fenced code block", "```python", "put only code inside it",
    "Coding rules", "programming language the task requires", "a language the user names",
    "a language the screenshot clearly implies", "do not guess and do not write any code yet",
    "Which language should I use", "Keep the code simple", "Match any given starter code"] {
    #expect(screenshotQASystemPrompt.contains(phrase), "\(phrase)")
  }
  let followUpRules = try #require(screenshotQASystemPrompt.range(of: "Follow-up rules"))
  let rules = screenshotQASystemPrompt[followUpRules.lowerBound...]
  #expect(rules.contains("Code is the exception"))
  #expect(rules.contains("which language to use"))
  #expect(rules.contains("reply with the complete code"))
}

@Test func closesACodeBlockLeftOpen() {
  #expect(closeOpenCodeFence("```python\nprint(1") == "```python\nprint(1\n```")
  #expect(closeOpenCodeFence("~~~~\nx\n") == "~~~~\nx\n~~~~")
  #expect(closeOpenCodeFence("Sure:\r\n  ````js\r\nrun();\r\n```") == "Sure:\r\n  ````js\r\nrun();\r\n```\n````")
  #expect(closeOpenCodeFence("```a\nx\n```\nThen:\n~~~b\ny") == "```a\nx\n```\nThen:\n~~~b\ny\n~~~")
}

@Test func leavesClosedBlocksAndPlainTextUnchanged() {
  for text in ["```python\nprint(1)\n```", "Plain answer", "Use ```a``` here", "    ```python\n    x = 1",
    "```\u{2028}\nnot a fence", "``\nnot a fence", "~~~\nx\n~~~  "] {
    #expect(closeOpenCodeFence(text) == text, "\(text)")
  }
  // A closing fence needs the same marker and at least the opening's length, with nothing after it.
  #expect(closeOpenCodeFence("````\nx\n```") == "````\nx\n```\n````")
  #expect(closeOpenCodeFence("```\nx\n~~~") == "```\nx\n~~~\n```")
  #expect(closeOpenCodeFence("```\nx\n``` y") == "```\nx\n``` y\n```")
}

@Test func normalizesLineEndingsAndKeepsEverythingElse() {
  #expect(normalizeLineEndings("first\r\nsecond\rthird\n\r") == "first\nsecond\nthird\n\n")
  #expect(normalizeLineEndings("a\n\n\n\nb") == "a\n\n\n\nb")
  #expect(normalizeLineEndings("  ## C_preprocessor\n- `user_id` *x*  \n") == "  ## C_preprocessor\n- `user_id` *x*  \n")
}

@Test func trimsAndComparesLikeJavaScript() {
  #expect("\u{FEFF}\u{2028} answer \u{3000}".jsTrimmed == "answer")
  // JavaScript keeps U+0085 and U+200B.
  #expect("\u{85}answer\u{200B}".jsTrimmed == "\u{85}answer\u{200B}")
  #expect(" \u{A0}\t".isBlank && "".isBlank && !" x ".isBlank)
  #expect("a\r\nb".jsHasPrefix("a\r") && !"caf\u{E9}".jsEquals("cafe\u{301}"))
  #expect("ab🙂".prefix(utf16Units: 3) == "ab" && "ab🙂".prefix(utf16Units: 4) == "ab🙂")
  #expect(groupedDigits(0) == "0" && groupedDigits(999) == "999" && groupedDigits(1_000) == "1,000"
    && groupedDigits(10_000_000) == "10,000,000")
}

private func events(_ body: String, chunkSize: Int) -> [String] {
  var splitter = SSEEventSplitter()
  let bytes = Data(body.utf8)
  var events: [String] = []
  for start in stride(from: 0, to: bytes.count, by: chunkSize) {
    events += splitter.append(bytes[start..<min(start + chunkSize, bytes.count)])
  }
  return events + splitter.finish()
}

@Test func splitsEventsTheSameWayForEveryChunking() {
  let body = "a\r\n\r\nb\r\n\nc\n\r\nd\r\r\ne\r\n\rf\n\ng\r\rh\n\ri\r\n" + "café ✓\n\n" + "tail"
  let expected = ["a", "b", "c", "d", "e", "f", "g", "h", "i\r\ncafé ✓", "tail"]
  for chunkSize in 1...body.utf8.count {
    #expect(events(body, chunkSize: chunkSize) == expected, "chunks of \(chunkSize)")
  }
}

@Test func waitsForTheByteAfterATrailingCR() {
  var splitter = SSEEventSplitter()
  #expect(splitter.append(Data("data: x\r\r".utf8)).isEmpty)
  #expect(splitter.append(Data("\n".utf8)) == ["data: x"])
  #expect(splitter.append(Data("data: y\r\n\r".utf8)).isEmpty)
  #expect(splitter.finish() == ["data: y"])
}
