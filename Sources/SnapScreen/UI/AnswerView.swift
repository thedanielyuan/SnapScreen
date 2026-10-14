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
  // As in CodeFence.swift, only fences are interpreted, never other Markdown or HTML.
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
    // The label is capped at 24 UTF-16 units, without cutting a Unicode scalar in half.
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


/// Selectable, read-only text.
class ReadOnlyTextView: NSTextView {
  private let contextMenu = PassiveMenu()

  // NSTextView's native contextual menu tracks the keyboard even in a non-key panel. Keep its
  // useful read-only actions in a passive pointer menu instead; typing still reaches the app below.
  override func menu(for event: NSEvent) -> NSMenu? { nil }

  override func rightMouseDown(with event: NSEvent) { showContextMenu(for: event) }

  // A drag of the selection runs a dragging session, which takes the foreground window's key
  // status until it ends. Copy and Select All do what a drag would.
  override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool { false }

  override func mouseDown(with event: NSEvent) {
    if event.modifierFlags.contains(.control) { showContextMenu(for: event) }
    else { super.mouseDown(with: event) }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { contextMenu.dismiss() }
  }

  /// Retry may clear a failed answer through accessibility without a pointer press to dismiss
  /// its menu. Close that menu even when this view stays attached to the same window.
  func clearText() {
    contextMenu.dismiss()
    string = ""
  }

  private func showContextMenu(for event: NSEvent) {
    guard let window else { return }
    contextMenu.show(contextMenuItems(), at: window.convertPoint(toScreen: event.locationInWindow))
  }

  /// Actions read the current selection only when clicked and never keep answer text alive.
  func contextMenuItems() -> [PassiveMenuItem] {
    [PassiveMenuItem(title: "Copy", isEnabled: selectedRange().length > 0) { [weak self] in
      guard let self else { return }
      let text = self.string as NSString
      let range = self.selectedRange()
      guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= text.length else { return }
      Clipboard.copy(text.substring(with: range))
    }, PassiveMenuItem(title: "Select All", isEnabled: !string.isEmpty) { [weak self] in
      guard let self else { return }
      self.setSelectedRange(NSRange(location: 0, length: (self.string as NSString).length))
    }]
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
  /// A list item's marker at the start of a line, after at most eight spaces or tabs: a number or
  /// letter followed by `.` or `)`, one in parentheses, or a bullet, then a space and text.
  static let listMarker = try! NSRegularExpression(
    pattern: "^[ \\t]{0,8}(?:(?:\\d{1,3}|[A-Za-z])[.)]|\\((?:\\d{1,3}|[A-Za-z])\\)|[-*•◦–])[ \\t]+(?=\\S)")
  static let listItemSpacing: CGFloat = 4

  /// A list item hangs its wrapped lines under its text, a little apart from the line before it.
  /// Only the layout changes: the text stays as written, so selecting and copying it don't.
  static func listItemParagraph(_ line: String, first: Bool) -> NSParagraphStyle? {
    let value = line as NSString
    guard let marker = listMarker.firstMatch(in: line, range: NSRange(location: 0, length: value.length)) else {
      return nil
    }
    let style = proseParagraph.mutableCopy() as! NSMutableParagraphStyle
    style.headIndent = ceil(NSAttributedString(string: value.substring(with: marker.range),
      attributes: [.font: proseFont]).size().width)
    style.paragraphSpacingBefore = first ? 0 : listItemSpacing
    return style
  }
}

/// Each segment keeps its text view while streaming, so selections and copy targets survive
/// incremental snapshots. Text storage contains literal strings, never markup.
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
  private var copyLabel = "Copy code"
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
      copy.hoverTint = Theme.accent
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
      // A count, not the string: the text view's string is its live storage, which grows below.
      let oldLength = (textView.string as NSString).length
      let newText = value.text as NSString
      let changedRange: NSRange
      // Appending only the new tail leaves already-read text and its selection intact.
      if value.text.utf16.starts(with: textView.string.utf16) {
        textView.textStorage?.replaceCharacters(in: NSRange(location: oldLength, length: 0),
          with: newText.substring(from: oldLength))
        changedRange = NSRange(location: oldLength, length: newText.length - oldLength)
      } else {
        textView.string = value.text
        changedRange = NSRange(location: 0, length: newText.length)
      }
      // Direct text-storage mutations do not inherit NSTextView's typing attributes when the
      // storage is empty. Always attach the intended font and dynamic color to inserted text.
      textView.textStorage?.setAttributes([.font: contentFont, .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraph], range: changedRange)
      if !value.isCode { styleListItems(touching: changedRange) }
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
      copyLabel = language.isEmpty ? "Copy code" : "Copy \(language) code"
      copyButton?.setAccessibilityLabel(copyLabel)
      copyButton?.toolTip = copyLabel
    }
    updateCopyVisibility()
  }

  private func updateCopyVisibility() {
    guard case .code(_, _, let complete) = segment else { return }
    copyButton?.isHidden = !(complete || answerIsFinal)
  }

  /// Lays out each prose paragraph that a change touched as a list item or a plain paragraph. A
  /// streamed line is styled again as it grows, so its marker counts once it's complete.
  private func styleListItems(touching range: NSRange) {
    guard let storage = textView.textStorage, storage.length > 0, NSMaxRange(range) <= storage.length else { return }
    let text = storage.string as NSString
    storage.beginEditing()
    text.enumerateSubstrings(in: text.paragraphRange(for: range), options: .byParagraphs) { line, _, enclosing, _ in
      let style = line.flatMap { AnswerStyle.listItemParagraph($0, first: enclosing.location == 0) } ?? self.paragraph
      storage.addAttribute(.paragraphStyle, value: style, range: enclosing)
    }
    storage.endEditing()
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
    Theme.surface.setFill()
    shape.fill()
    Theme.surfaceBorder.setStroke()
    shape.lineWidth = 1
    shape.stroke()
    Theme.surfaceBorder.setFill()
    NSRect(x: 1, y: Self.codeHeaderHeight - 1, width: bounds.width - 2, height: 1).fill()
  }

  /// No streaming/render path writes the clipboard. This action runs only from the explicit button.
  @objc private func copyCode() {
    guard copyEnabled, case .code(let code, _, _) = segment else { return }
    Clipboard.copy(code)
    copyButton?.showFeedback(symbol: "checkmark", title: "Copied", label: "Copied", color: Theme.accent)
  }

  func clear() {
    segment = .text("")
    textView.clearText()
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
