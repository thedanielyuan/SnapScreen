import AppKit
import Foundation

enum NativeAnswerSegment: Equatable {
  case text(String)
  case code(String, language: String, complete: Bool)

  var text: String {
    switch self {
    case .text(let value), .code(let value, _, _): return value
    }
  }

  var isCode: Bool {
    if case .code = self { return true }
    return false
  }
}

private enum AnswerFences {
  // Match src/lib/code-blocks.ts: only fences are interpreted, never other Markdown or HTML.
  static let opening = try! NSRegularExpression(pattern: "^( {0,3})(`{3,}|~{3,})([^\\n\\r\\u2028\\u2029]*)$")
  static let closing = try! NSRegularExpression(pattern: "^ {0,3}(`{3,}|~{3,})[ \\t]*$")

  static func match(_ expression: NSRegularExpression, _ line: String) -> [String]? {
    let value = line as NSString
    guard let result = expression.firstMatch(in: line, range: NSRange(location: 0, length: value.length))
      else { return nil }
    return (1..<result.numberOfRanges).map { value.substring(with: result.range(at: $0)) }
  }

  static func trimEnd(_ value: String) -> String {
    var scalars = value.unicodeScalars
    while let last = scalars.last, trimProtocolText(String(last)).isEmpty { scalars.removeLast() }
    return String(scalars)
  }
}

func splitNativeAnswerSegments(_ text: String) -> [NativeAnswerSegment] {
  let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
    .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
  var segments: [NativeAnswerSegment] = []
  var textLines: [String] = []
  func flushText() {
    let content = textLines.drop(while: { $0.allSatisfy { $0 == " " || $0 == "\t" } }).joined(separator: "\n")
    let value = AnswerFences.trimEnd(content)
    if !trimProtocolText(value).isEmpty { segments.append(.text(value)) }
    textLines.removeAll(keepingCapacity: true)
  }
  var index = 0
  while index < lines.count {
    guard let opening = AnswerFences.match(AnswerFences.opening, lines[index]),
      !(opening[1].first == "`" && opening[2].contains("`")) else {
      textLines.append(lines[index])
      index += 1
      continue
    }
    flushText()
    let info = trimProtocolText(opening[2])
    let word = info.unicodeScalars.prefix(while: { !trimProtocolText(String($0)).isEmpty })
    // The extension caps the label at 24 UTF-16 units. Avoid cutting a Unicode scalar in half.
    var language = ""
    for scalar in word {
      if language.utf16.count + String(scalar).utf16.count > 24 { break }
      language.unicodeScalars.append(scalar)
    }
    var codeLines: [String] = []
    var complete = false
    index += 1
    while index < lines.count {
      if let closing = AnswerFences.match(AnswerFences.closing, lines[index]),
        closing[0].first == opening[1].first, closing[0].count >= opening[1].count {
        complete = true
        index += 1
        break
      }
      let line = lines[index]
      let indentation = min(opening[0].count, line.prefix(while: { $0 == " " }).count)
      codeLines.append(String(line.dropFirst(indentation)))
      index += 1
    }
    segments.append(.code(codeLines.joined(separator: "\n"), language: language, complete: complete))
  }
  flushText()
  return segments
}


/// Selectable, read-only text. Tab moves focus instead of being swallowed by the text view, and
/// typing while reading continues in the conversation's composer.
class ReadOnlyTextView: NSTextView {
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 48 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
      if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
      else { window?.selectNextKeyView(self) }
      return
    }
    if Self.isTyping(event), let target = typingTarget, window?.makeFirstResponder(target) == true {
      // Redeliver through normal dispatch so the composer's input method sees the key.
      NSApp.postEvent(event, atStart: true)
      return
    }
    super.keyDown(with: event)
  }

  /// Printable input without Command or Control; arrows and other function keys keep their meaning.
  static func isTyping(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, event.modifierFlags.intersection([.command, .control]).isEmpty,
      let characters = event.characters, !characters.isEmpty else { return false }
    return characters.unicodeScalars.allSatisfy {
      !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
    }
  }

  private var typingTarget: NSView? {
    var view = superview
    while let current = view {
      if let conversation = current as? ConversationView { return conversation.focusFallback?() }
      view = current.superview
    }
    return nil
  }

  func configureReadOnly(font: NSFont) {
    isEditable = false
    isSelectable = true
    isRichText = false
    importsGraphics = false
    allowsUndo = false
    drawsBackground = false
    textContainerInset = .zero
    textContainer?.lineFragmentPadding = 0
    textContainer?.widthTracksTextView = false
    textContainer?.heightTracksTextView = false
    isHorizontallyResizable = false
    isVerticallyResizable = false
    isAutomaticLinkDetectionEnabled = false
    isAutomaticDataDetectionEnabled = false
    self.font = font
    textColor = .labelColor
  }

  /// Lays out for `width` and returns the text's height.
  func measuredHeight(for width: CGFloat) -> CGFloat {
    textContainer?.containerSize = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
    guard let container = textContainer, let manager = layoutManager else { return 0 }
    manager.ensureLayout(for: container)
    return ceil(max(manager.usedRect(for: container).height, manager.extraLineFragmentRect.maxY))
  }
}

enum AnswerStyle {
  static let proseFont = NSFont.systemFont(ofSize: 14)
  static let codeFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
  static let proseParagraph: NSParagraphStyle = {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 3
    return style
  }()
  static let codeParagraph: NSParagraphStyle = {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 2
    return style
  }()
}

/// Each segment keeps its text view while streaming, so selections, keyboard focus and copy
/// targets survive incremental snapshots. Text storage contains literal strings, never markup.
final class AnswerSegmentView: NSView {
  private(set) var segment: NativeAnswerSegment
  let textView = ReadOnlyTextView(frame: .zero)
  private(set) var copyButton: ActionButton?
  private var languageLabel: NSTextField?
  private var measuredWidth: CGFloat = -1
  private var measuredHeight: CGFloat = 0
  private var textNeedsLayout = true
  private let contentFont: NSFont
  private let paragraph: NSParagraphStyle
  /// A streaming code block has no Copy control until its fence closes or the answer ends.
  var answerIsFinal = false { didSet { updateCopyVisibility() } }
  var copyEnabled = true { didSet { copyButton?.isEnabled = copyEnabled } }
  override var isFlipped: Bool { true }

  static let codeHeaderHeight: CGFloat = 32
  static let codeInset: CGFloat = 12

  init(segment: NativeAnswerSegment) {
    self.segment = segment
    contentFont = segment.isCode ? AnswerStyle.codeFont : AnswerStyle.proseFont
    paragraph = segment.isCode ? AnswerStyle.codeParagraph : AnswerStyle.proseParagraph
    super.init(frame: .zero)
    textView.configureReadOnly(font: contentFont)
    textView.defaultParagraphStyle = paragraph
    textView.setAccessibilityLabel(segment.isCode ? "Code" : "Answer text")
    addSubview(textView)
    if segment.isCode {
      let label = NSTextField(labelWithString: "")
      label.font = .systemFont(ofSize: 11.5, weight: .medium)
      label.textColor = .secondaryLabelColor
      label.lineBreakMode = .byTruncatingTail
      label.setAccessibilityElement(false)
      addSubview(label)
      languageLabel = label
      let copy = ActionButton(symbol: "doc.on.doc", title: "Copy", label: "Copy code", target: self,
        action: #selector(copyCode))
      addSubview(copy)
      copyButton = copy
    }
    update(segment)
  }

  required init?(coder: NSCoder) { nil }

  func update(_ value: NativeAnswerSegment) {
    segment = value
    if !textView.string.utf16.elementsEqual(value.text.utf16) {
      let selections = textView.selectedRanges
      let oldText = textView.string as NSString
      let newText = value.text as NSString
      let changedRange: NSRange
      // Appending only the new tail leaves already-read text and its selection intact.
      if value.text.utf16.starts(with: textView.string.utf16) {
        textView.textStorage?.replaceCharacters(in: NSRange(location: oldText.length, length: 0),
          with: newText.substring(from: oldText.length))
        changedRange = NSRange(location: oldText.length, length: newText.length - oldText.length)
      } else {
        textView.string = value.text
        changedRange = NSRange(location: 0, length: newText.length)
      }
      // Direct text-storage mutations do not inherit NSTextView's typing attributes when the
      // storage is empty. Always attach the intended font and dynamic color to inserted text.
      textView.textStorage?.setAttributes([.font: contentFont, .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraph], range: changedRange)
      // Plain NSTextView normalizes its storage to its own uniform typing attributes when
      // selection changes. Update those defaults too, including after an empty first insertion.
      textView.font = contentFont
      textView.textColor = .labelColor
      textView.selectedRanges = selections.map {
        let range = $0.rangeValue
        let start = min(range.location, newText.length)
        return NSValue(range: NSRange(location: start, length: min(range.length, newText.length - start)))
      }
      textNeedsLayout = true
    }
    if case .code(_, let language, _) = value {
      languageLabel?.stringValue = language.isEmpty ? "code" : language
      textView.setAccessibilityLabel(language.isEmpty ? "Code block" : "\(language) code block")
      let label = language.isEmpty ? "Copy code" : "Copy \(language) code"
      copyButton?.toolTip = label
      copyButton?.setAccessibilityLabel(label)
    }
    updateCopyVisibility()
  }

  private func updateCopyVisibility() {
    guard case .code(_, _, let complete) = segment else { return }
    copyButton?.isHidden = !(complete || answerIsFinal)
  }

  func height(for width: CGFloat) -> CGFloat {
    let inset: CGFloat = segment.isCode ? Self.codeInset : 0
    let contentWidth = max(1, width - inset * 2)
    if measuredWidth != width || textNeedsLayout {
      measuredHeight = max(segment.isCode ? 16 : 18, textView.measuredHeight(for: contentWidth))
      measuredWidth = width
      textNeedsLayout = false
    }
    guard segment.isCode else {
      textView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: measuredHeight)
      return measuredHeight
    }
    let header = Self.codeHeaderHeight
    textView.frame = NSRect(x: inset, y: header + 10, width: contentWidth, height: measuredHeight)
    if let button = copyButton {
      let size = button.buttonSize
      button.frame = NSRect(x: width - size.width - 4, y: (header - size.height) / 2, width: size.width, height: size.height)
      languageLabel?.frame = NSRect(x: inset, y: (header - 16) / 2, width: max(1, width - inset - size.width - 12), height: 16)
    }
    return header + 10 + measuredHeight + 12
  }

  override func draw(_ dirtyRect: NSRect) {
    guard segment.isCode else { return }
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
    Theme.codeBackground.setFill()
    shape.fill()
    NSColor.separatorColor.setStroke()
    shape.lineWidth = 1
    shape.stroke()
    // System separator colours carry their own alpha; replacing it would darken the line.
    NSColor.separatorColor.setFill()
    NSRect(x: 1, y: Self.codeHeaderHeight - 1, width: bounds.width - 2, height: 1).fill()
  }

  /// No streaming/render path writes the clipboard. This action runs only from the explicit button.
  @objc private func copyCode() {
    guard copyEnabled, case .code(let code, _, _) = segment else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(code, forType: .string)
    copyButton?.showFeedback(symbol: "checkmark", title: "Copied", label: "Copied", color: .systemGreen)
  }

  func clear() {
    segment = .text("")
    textView.string = ""
    textView.undoManager?.removeAllActions()
    languageLabel?.stringValue = ""
    copyButton?.cancelFeedback()
    copyButton?.isEnabled = false
    copyButton?.target = nil
    copyButton?.action = nil
  }
}

/// One answer's prose and fenced code, laid out by its turn in the conversation.
final class AnswerView: NSView {
  private(set) var segmentViews: [AnswerSegmentView] = []
  private(set) var renderedText = ""
  private(set) var isFinal = false
  var copyEnabled = true { didSet { segmentViews.forEach { $0.copyEnabled = copyEnabled } } }
  override var isFlipped: Bool { true }
  static let segmentSpacing: CGFloat = 12

  /// Returns whether segment views were added or removed, which changes the key-view loop.
  @discardableResult
  func render(_ text: String, final: Bool) -> Bool {
    let finalChanged = final != isFinal
    isFinal = final
    guard !text.utf16.elementsEqual(renderedText.utf16) else {
      if finalChanged { segmentViews.forEach { $0.answerIsFinal = final } }
      return false
    }
    let segments = splitNativeAnswerSegments(text)
    var commonCount = 0
    while commonCount < min(segments.count, segmentViews.count),
      segments[commonCount].isCode == segmentViews[commonCount].segment.isCode {
      segmentViews[commonCount].update(segments[commonCount])
      commonCount += 1
    }
    let structureChanged = commonCount != segmentViews.count || commonCount != segments.count
    for view in segmentViews.dropFirst(commonCount) {
      if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: view) {
        window?.makeFirstResponder(nil)
      }
      view.clear()
      view.removeFromSuperview()
    }
    segmentViews.removeSubrange(commonCount...)
    for segment in segments.dropFirst(commonCount) {
      let view = AnswerSegmentView(segment: segment)
      view.copyEnabled = copyEnabled
      addSubview(view)
      segmentViews.append(view)
    }
    segmentViews.forEach { $0.answerIsFinal = final }
    renderedText = text
    return structureChanged
  }

  func height(for width: CGFloat) -> CGFloat {
    var y: CGFloat = 0
    for (index, view) in segmentViews.enumerated() {
      if index > 0 { y += Self.segmentSpacing }
      let height = view.height(for: width)
      view.frame = NSRect(x: 0, y: y, width: width, height: height)
      y += height
    }
    return y
  }

  var hasSelection: Bool { segmentViews.contains { $0.textView.selectedRange().length > 0 } }

  func clear() {
    if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) {
      window?.makeFirstResponder(nil)
    }
    for view in segmentViews { view.clear(); view.removeFromSuperview() }
    segmentViews.removeAll()
    renderedText = ""
    isFinal = false
  }
}
