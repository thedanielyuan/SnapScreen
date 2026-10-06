import AppKit
import Foundation

private enum AnswerViewTestError: Error { case failed(String) }

func runAnswerViewTests() throws -> Int {
  var count = 0
  func check(_ value: Bool, _ name: String) throws {
    guard value else { throw AnswerViewTestError.failed(name) }
    count += 1
  }

  try check(splitNativeAnswerSegments("The answer is 4.") == [.text("The answer is 4.")], "plain answer")
  try check(splitNativeAnswerSegments("Here:\n\n```python\ndef add(a, b):\n    return a + b\n```\n\nDone.") == [
    .text("Here:"), .code("def add(a, b):\n    return a + b", language: "python", complete: true), .text("Done."),
  ], "fenced answer preserves ordering and language")
  let code = "# comment\n\nx = a * b  # *not* emphasis\n\tprint(`x`)\n"
  try check(splitNativeAnswerSegments("```\n\(code)\n```") == [.code(code, language: "", complete: true)],
    "code retains blank lines, whitespace and literal markup")
  try check(splitNativeAnswerSegments("```js title=\"add.js\"\nadd();\n```") == [
    .code("add();", language: "js", complete: true),
  ], "language is first info word")
  try check(splitNativeAnswerSegments("~~~sql\nSELECT 1;\n~~~") == [.code("SELECT 1;", language: "sql", complete: true)],
    "tilde fence")
  try check(splitNativeAnswerSegments("````markdown\n```python\nprint(1)\n```\n````") == [
    .code("```python\nprint(1)\n```", language: "markdown", complete: true),
  ], "longer fences contain shorter fences")
  try check(splitNativeAnswerSegments("  ```c\n  int x;\n    y();\n  ```") == [
    .code("int x;\n  y();", language: "c", complete: true),
  ], "opening indentation removed from code")
  for literal in ["Use ```a``` here", "    ```python\n    x = 1\n    ```", "```x```", "**bold** <script>x</script>"] {
    try check(splitNativeAnswerSegments(literal) == [.text(literal)], "non-fence markup stays literal")
  }
  try check(splitNativeAnswerSegments("Sure:\n```java\nclass A {") == [
    .text("Sure:"), .code("class A {", language: "java", complete: false),
  ], "streaming fence remains open")
  try check(splitNativeAnswerSegments("```py") == [.code("", language: "py", complete: false)], "empty streaming fence")
  try check(splitNativeAnswerSegments("```go\r\nfmt.Println()\r```") == [
    .code("fmt.Println()", language: "go", complete: true),
  ], "CRLF and CR normalize")
  try check(splitNativeAnswerSegments("~~~js\nx\n```\n~~~~") == [
    .code("x\n```", language: "js", complete: true),
  ], "closing fence matches marker and minimum length")
  try check(splitNativeAnswerSegments("\t \n text \t\n\u{FEFF}") == [.text(" text")], "prose trim matches ECMAScript")
  try check(splitNativeAnswerSegments("\u{0085}") == [.text("\u{0085}")], "non-ECMAScript whitespace retained")
  try check(splitNativeAnswerSegments("```" + String(repeating: "a", count: 40) + "\nx\n```") == [
    .code("x", language: String(repeating: "a", count: 24), complete: true),
  ], "language label is bounded")

  // Initialize AppKit without opening, ordering or activating a window. Never touch the clipboard.
  _ = NSApplication.shared
  let view = AnswerView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
  view.render("**Literal** <b>text</b>\n```swift\nlet n = 1", final: false)
  try check(view.segmentViews.count == 2, "separate prose and code views")
  let prose = view.segmentViews[0]
  let block = view.segmentViews[1]
  try check(prose.textView.string == "**Literal** <b>text</b>", "renderer does not interpret markup")
  try check(prose.textView.isSelectable && !prose.textView.isEditable && !prose.textView.isRichText,
    "prose selectable and plain")
  try check(block.textView.isSelectable && !block.textView.isEditable && !block.textView.isRichText,
    "code selectable and plain")
  func hasTextAttributes(_ text: NSTextView, font: NSFont) -> Bool {
    guard let storage = text.textStorage, storage.length > 0 else { return false }
    var matches = true
    storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
      matches = matches && (attributes[.font] as? NSFont) == font &&
        (attributes[.foregroundColor] as? NSColor) == .labelColor
    }
    return matches
  }
  try check(hasTextAttributes(prose.textView, font: AnswerStyle.proseFont), "initial prose has system font and dynamic foreground")
  try check(hasTextAttributes(block.textView, font: AnswerStyle.codeFont), "initial code has monospaced font and dynamic foreground")
  try check(block.copyButton?.target === block, "copy action belongs to its code block")
  try check(block.copyButton?.isHidden == true, "a streaming code block offers no partial Copy")
  block.textView.setSelectedRange(NSRange(location: 4, length: 1))
  view.render("**Literal** <b>text</b>\n```swift\nlet n = 12\n```\nNext.", final: false)
  try check(view.segmentViews[0] === prose && view.segmentViews[1] === block, "streaming reuses existing views")
  try check(block.textView.selectedRange() == NSRange(location: 4, length: 1), "streaming preserves text selection")
  try check(block.segment == .code("let n = 12", language: "swift", complete: true), "copy source updates with snapshot")
  try check(block.copyButton?.isHidden == false && block.copyButton?.isEnabled == true, "a closed fence offers Copy")
  try check(hasTextAttributes(prose.textView, font: AnswerStyle.proseFont) && hasTextAttributes(block.textView, font: AnswerStyle.codeFont),
    "streamed append preserves font and dynamic foreground on every character")
  view.render("```js\nopen(", final: false)
  try check(view.segmentViews[0].copyButton?.isHidden == true, "an unclosed fence hides Copy while streaming")
  view.render("```js\nopen(", final: true)
  try check(view.segmentViews[0].copyButton?.isHidden == false, "a stopped answer's unclosed fence offers Copy")
  block.appearance = NSAppearance(named: .darkAqua)
  var darkContrast = false
  block.effectiveAppearance.performAsCurrentDrawingAppearance {
    let foreground = NSColor.labelColor.usingColorSpace(.deviceRGB)!
    let background = Theme.codeBackground.usingColorSpace(.deviceRGB)!
    darkContrast = foreground.redComponent > background.redComponent + 0.5
  }
  try check(darkContrast, "dark appearance keeps code legible on its background")
  view.copyEnabled = false
  view.render("```\n\u{00E9}\n```", final: true)
  let canonicalBlock = view.segmentViews[0]
  view.render("```\ne\u{0301}\n```", final: true)
  try check(canonicalBlock.textView.string.utf16.elementsEqual("e\u{0301}".utf16),
    "equivalent Unicode snapshots preserve exact code units for copying")
  try check(hasTextAttributes(canonicalBlock.textView, font: AnswerStyle.codeFont),
    "replacement content retains monospaced font and dynamic foreground")
  try check(canonicalBlock.copyButton?.isEnabled == false, "new blocks inherit disabled copy state")
  let height = view.height(for: 400)
  try check(height > 0 && canonicalBlock.frame.width == 400, "segments lay out to the answer width")
  view.clear()
  try check(view.segmentViews.isEmpty && view.renderedText.isEmpty, "clear removes answer")
  try check(canonicalBlock.textView.string.isEmpty && canonicalBlock.segment.text.isEmpty &&
    canonicalBlock.copyButton?.target == nil, "removed views release text and copy targets")
  try check(ReadOnlyTextView.isTyping(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
    timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
    isARepeat: false, keyCode: 0)!), "printable keys continue in the composer")
  try check(!ReadOnlyTextView.isTyping(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
    timestamp: 0, windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c",
    isARepeat: false, keyCode: 8)!), "Command shortcuts stay with the selected text")
  try check(!ReadOnlyTextView.isTyping(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
    timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
    isARepeat: false, keyCode: 125)!), "arrow keys stay with the selected text")
  return count
}
