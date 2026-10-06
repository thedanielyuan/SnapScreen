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
  view.render("**Literal** <b>text</b>\n```swift\nlet n = 1")
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
  let proseFont = NSFont.systemFont(ofSize: 14)
  let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  try check(hasTextAttributes(prose.textView, font: proseFont), "initial prose has system font and dynamic foreground")
  try check(hasTextAttributes(block.textView, font: codeFont), "initial code has monospaced font and dynamic foreground")
  try check(block.copyButton?.isEnabled == true && block.copyButton?.target === block,
    "copy action belongs to its code block")
  block.textView.setSelectedRange(NSRange(location: 4, length: 1))
  view.render("**Literal** <b>text</b>\n```swift\nlet n = 12\n```\nNext.")
  try check(view.segmentViews[0] === prose && view.segmentViews[1] === block, "streaming reuses existing views")
  try check(block.textView.selectedRange() == NSRange(location: 4, length: 1), "streaming preserves text selection")
  try check(block.segment == .code("let n = 12", language: "swift", complete: true), "copy source updates with snapshot")
  try check(hasTextAttributes(prose.textView, font: proseFont) && hasTextAttributes(block.textView, font: codeFont),
    "streamed append preserves font and dynamic foreground on every character")
  block.appearance = NSAppearance(named: .darkAqua)
  block.viewDidChangeEffectiveAppearance()
  var darkContrast = false
  block.effectiveAppearance.performAsCurrentDrawingAppearance {
    let foreground = NSColor.labelColor.usingColorSpace(.deviceRGB)!
    let background = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)!
    darkContrast = foreground.redComponent > background.redComponent + 0.5
  }
  try check(darkContrast && hasTextAttributes(block.textView, font: codeFont),
    "dark appearance retains a legible dynamic label foreground")
  try check(block.layer?.backgroundColor != nil && block.layer?.borderWidth == 1,
    "code container has initialized background and border")
  try check(view.focusTarget === prose.textView && block.copyButton?.acceptsFirstResponder == true,
    "answer and copy expose keyboard focus targets")
  view.copyEnabled = false
  try check(block.copyButton?.isEnabled == false, "copy disabled by session controls")
  view.render("```\n\u{00E9}\n```")
  let canonicalBlock = view.segmentViews[0]
  view.render("```\ne\u{0301}\n```")
  try check(canonicalBlock.textView.string.utf16.elementsEqual("e\u{0301}".utf16),
    "equivalent Unicode snapshots preserve exact code units for copying")
  try check(hasTextAttributes(canonicalBlock.textView, font: codeFont),
    "replacement content retains monospaced font and dynamic foreground")
  try check(canonicalBlock.copyButton?.isEnabled == false, "new blocks inherit disabled copy state")

  view.clear()
  let longText = (1...100).map { "Line \($0) of the answer." }.joined(separator: "\n")
  view.render(longText)
  let scroll = view.scrollView
  try check(scroll.documentView!.frame.height > scroll.contentSize.height, "long answer scrolls")
  scroll.contentView.scroll(to: NSPoint(x: 0, y: 90))
  view.render(longText + "\nNew streamed line.")
  try check(abs(scroll.contentView.bounds.minY - 90) < 1, "streaming preserves reader's scroll position")
  scroll.contentView.scroll(to: NSPoint(x: 0,
    y: scroll.documentView!.frame.height - scroll.contentSize.height))
  view.render(longText + "\nNew streamed line.\nAnother line.")
  try check(abs(scroll.contentView.bounds.maxY - scroll.documentView!.frame.height) < 1,
    "streaming follows bottom when reader is there")
  view.clear()
  try check(view.segmentViews.isEmpty && view.focusTarget === view && scroll.contentView.bounds.origin == .zero,
    "clear removes answer and resets scroll")
  try check(block.textView.string.isEmpty && block.segment.text.isEmpty && block.copyButton?.target == nil,
    "removed views release text and copy targets")
  view.render("Replacement answer")
  try check(view.segmentViews.count == 1 && view.segmentViews[0].textView.string == "Replacement answer",
    "fresh generation renders after clear")
  view.clear()
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
    styleMask: [.borderless], backing: .buffered, defer: false)
  window.contentView = view
  view.copyEnabled = true
  window.makeFirstResponder(view.focusTarget)
  try check(window.firstResponder === view, "empty answer accepts keyboard focus")
  view.render("First snapshot")
  try check(window.firstResponder === view.segmentViews[0].textView,
    "first snapshot transfers answer-owned focus to selectable text")
  view.render("First snapshot\n```swift\nlet value = 1\n```")
  let nextCopy = view.segmentViews[1].copyButton!
  let firstText = view.segmentViews[0].textView
  var reachable: [NSView] = []
  var next = firstText.nextValidKeyView
  for _ in 0..<8 {
    guard let value = next, value !== firstText else { break }
    reachable.append(value)
    next = value.nextValidKeyView
  }
  try check(reachable.contains(where: { $0 === nextCopy }), "dynamic key loop includes code Copy without Full Keyboard Access")
  try check(reachable.contains(where: { $0 === view.segmentViews[1].textView }), "dynamic key loop includes selectable code")
  try check(!reachable.contains(where: { $0 === view }), "populated answer omits redundant empty focus target from Tab loop")
  nextCopy.isEnabled = false
  try check(!nextCopy.canBecomeKeyView, "disabled Copy is omitted from keyboard traversal")
  view.clear()
  try check(window.firstResponder === view, "clear returns removed text focus to stable empty answer")
  view.render("First snapshot")
  let unrelatedControl = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
  view.addSubview(unrelatedControl)
  window.makeFirstResponder(unrelatedControl)
  let previousResponder = window.firstResponder
  view.render("First snapshot continues")
  try check(window.firstResponder === previousResponder, "streaming does not steal focus from an input")
  view.clear()
  try check(window.firstResponder === previousResponder, "clear does not steal focus from an input")
  window.makeFirstResponder(nil)
  window.contentView = nil
  view.clear()
  return count
}
