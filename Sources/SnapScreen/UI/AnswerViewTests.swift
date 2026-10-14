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

  // Initialize AppKit without opening, ordering or activating a window. Copy uses a private board.
  _ = NSApplication.shared
  let previousPasteboard = Clipboard.pasteboard
  let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.snapscreen.self-test.\(UUID().uuidString)"))
  Clipboard.pasteboard = pasteboard
  defer { Clipboard.pasteboard = previousPasteboard; pasteboard.releaseGlobally() }
  let selectable = ReadOnlyTextView(frame: .zero)
  selectable.configureReadOnly(font: AnswerStyle.proseFont)
  selectable.string = "one 😀 two"
  selectable.setSelectedRange(NSRange(location: 4, length: 2))
  let selectedActions = selectable.contextMenuItems()
  selectedActions[0].action()
  try check(pasteboard.string(forType: .string) == "😀",
    "the passive Copy action copies only the selected UTF-16 range to the private pasteboard")
  selectedActions[1].action()
  try check(selectable.selectedRange() == NSRange(location: 0, length: 10),
    "the passive Select All action selects text without needing a key window")
  let drag = #selector(NSTextView.dragSelection(with:offset:slideBack:))
  try check(class_getMethodImplementation(ReadOnlyTextView.self, drag) !=
    class_getMethodImplementation(NSTextView.self, drag) &&
    !selectable.dragSelection(with: NSEvent(), offset: .zero, slideBack: false),
    "selected answer text can't be dragged, which would start a session that takes the keyboard")
  selectable.setSelectedRange(NSRange(location: 0, length: 0))
  try check(!selectable.contextMenuItems()[0].isEnabled, "Copy is disabled without a selection")
  selectable.string = ""
  selectedActions[0].action()
  try check(pasteboard.string(forType: .string) == "😀" && !selectable.contextMenuItems()[1].isEnabled,
    "a cleared answer leaves nothing for an old Copy action or Select All")
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
  func pointer(_ type: NSEvent.EventType) -> NSEvent {
    NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
      eventNumber: 0, trackingNumber: 0, userData: nil)!
  }
  block.copyButton?.mouseEntered(with: pointer(.mouseEntered))
  try check(block.copyButton?.contentTintColor == Theme.accent, "Copy takes the accent under the pointer")
  block.copyButton?.mouseExited(with: pointer(.mouseExited))
  try check(block.copyButton?.contentTintColor == .secondaryLabelColor, "Copy is grey again at rest")
  try check(hasTextAttributes(prose.textView, font: AnswerStyle.proseFont) && hasTextAttributes(block.textView, font: AnswerStyle.codeFont),
    "streamed append preserves font and dynamic foreground on every character")
  func lineSpacing(_ text: NSTextView) -> Set<CGFloat> {
    var spacings: Set<CGFloat> = []
    text.textStorage?.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.textStorage!.length)) { value, _, _ in
      spacings.insert((value as? NSParagraphStyle)?.lineSpacing ?? -1)
    }
    return spacings
  }
  try check(lineSpacing(prose.textView) == [AnswerStyle.proseParagraph.lineSpacing] &&
    lineSpacing(block.textView) == [AnswerStyle.codeParagraph.lineSpacing],
    "streamed text, first and appended, takes its paragraph's line spacing")
  view.render("```js\nopen(", final: false)
  try check(view.segmentViews[0].copyButton?.isHidden == true, "an unclosed fence hides Copy while streaming")
  view.render("```js\nopen(", final: true)
  try check(view.segmentViews[0].copyButton?.isHidden == false, "a stopped answer's unclosed fence offers Copy")
  // Without an appearance of its own, the block takes the app's, which is always dark.
  var legible = false
  block.effectiveAppearance.performAsCurrentDrawingAppearance {
    legible = NSColor.labelColor.usingColorSpace(.deviceRGB)!.redComponent >
      Theme.surface.usingColorSpace(.deviceRGB)!.redComponent + 0.5
  }
  try check(legible, "code stays legible on its background")
  let level = { (color: NSColor) in color.usingColorSpace(.deviceRGB)!.redComponent }
  try check(level(Theme.background) < 0.06 && level(Theme.background) < level(Theme.surface) &&
    level(Theme.surface) < level(Theme.surfaceBorder), "code sits a shade lighter than the near-black window, outlined")
  // List items hang wrapped lines under their text, a little apart, and the text stays as written.
  let list = AnswerView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
  let item = "1. The first cause is long enough to wrap onto a second line at this width."
  let items = "Three causes:\n\(item)\n(b) Lettered\n  - Bullet\n2026. Not a list item\n1.5 is a number"
  list.render(items, final: true)
  let listText = list.segmentViews[0].textView
  let storage = listText.textStorage!
  func paragraphStyle(_ prefix: String) -> NSParagraphStyle? {
    storage.attribute(.paragraphStyle, at: (storage.string as NSString).range(of: prefix).location,
      effectiveRange: nil) as? NSParagraphStyle
  }
  func width(_ text: String) -> CGFloat { ceil(NSAttributedString(string: text, attributes: [.font: AnswerStyle.proseFont]).size().width) }
  try check(listText.string == items && list.renderedText == items, "list layout keeps the answer's text as written")
  try check(paragraphStyle("Three")?.headIndent == 0 && paragraphStyle("1. The")?.headIndent == width("1. ") &&
    paragraphStyle("1. The")?.paragraphSpacingBefore == AnswerStyle.listItemSpacing,
    "a numbered item's wrapped lines hang under its text")
  try check(paragraphStyle("(b)")?.headIndent == width("(b) ") && paragraphStyle("  - ")?.headIndent == width("  - "),
    "lettered and indented bulleted items hang too")
  try check(paragraphStyle("2026.")?.headIndent == 0 && paragraphStyle("1.5")?.headIndent == 0,
    "years and decimals stay plain lines")
  _ = list.height(for: 300)
  let manager = listText.layoutManager!
  let itemRange = (storage.string as NSString).range(of: item)
  let firstLine = manager.lineFragmentUsedRect(forGlyphAt: manager.glyphIndexForCharacter(at: itemRange.location),
    effectiveRange: nil)
  let lastLine = manager.lineFragmentUsedRect(forGlyphAt: manager.glyphIndexForCharacter(at: NSMaxRange(itemRange) - 1),
    effectiveRange: nil)
  try check(lastLine.minY > firstLine.minY && firstLine.minX == 0 && lastLine.minX == width("1. "),
    "the item's second line starts under its text")
  listText.setSelectedRange(NSRange(location: itemRange.location + 3, length: 5))
  try check(paragraphStyle("1. The")?.headIndent == width("1. "), "selecting text keeps the layout")
  list.render("Steps:\n1", final: false)
  list.render("Steps:\n1. Open it", final: false)
  let streamed = list.segmentViews[0].textView
  streamed.setSelectedRange(NSRange(location: 0, length: 5))
  list.render("Steps:\n1. Open it\n2. Close it", final: false)
  let streamedStorage = streamed.textStorage!
  let headIndents = [7, 18].map { (streamedStorage.attribute(.paragraphStyle, at: $0, effectiveRange: nil) as? NSParagraphStyle)?.headIndent }
  try check(headIndents == [width("1. "), width("2. ")] && streamed.selectedRange() == NSRange(location: 0, length: 5),
    "streamed items take the layout as their markers arrive, keeping the reader's selection")
  list.clear()

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
  return count
}
