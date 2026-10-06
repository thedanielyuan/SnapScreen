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

private final class AnswerDocumentView: NSView {
  override var isFlipped: Bool { true }
}

private final class AnswerTextView: NSTextView {
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 48 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
      if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
      else { window?.selectNextKeyView(self) }
      return
    }
    super.keyDown(with: event)
  }
}

/// Each segment retains its text view while streaming, so selections, keyboard focus and copy
/// targets survive incremental snapshots. Text storage contains literal strings, never markup.
final class AnswerSegmentView: NSView {
  private(set) var segment: NativeAnswerSegment
  let textView: NSTextView = AnswerTextView(frame: .zero)
  private(set) var copyButton: NSButton?
  private var languageLabel: NSTextField?
  private var measuredWidth: CGFloat = -1
  private var measuredHeight: CGFloat = 0
  private var textNeedsLayout = true
  private let contentFont: NSFont
  var copyEnabled = true { didSet { copyButton?.isEnabled = copyEnabled } }
  override var isFlipped: Bool { true }

  init(segment: NativeAnswerSegment) {
    self.segment = segment
    contentFont = segment.isCode ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 14)
    super.init(frame: .zero)
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = false
    textView.drawsBackground = false
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.heightTracksTextView = false
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.font = contentFont
    textView.textColor = .labelColor
    textView.setAccessibilityLabel(segment.isCode ? "Code" : "Answer text")
    addSubview(textView)
    if segment.isCode {
      wantsLayer = true
      layer?.cornerRadius = 8
      let label = NSTextField(labelWithString: "")
      label.font = .systemFont(ofSize: 11, weight: .medium)
      label.textColor = .secondaryLabelColor
      label.lineBreakMode = .byTruncatingTail
      addSubview(label)
      languageLabel = label
      let copy = CompanionButton(title: "Copy code", target: self, action: #selector(copyCode))
      copy.bezelStyle = .rounded
      copy.setAccessibilityLabel("Copy code block")
      addSubview(copy)
      copyButton = copy
      updateColors()
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
      textView.textStorage?.setAttributes([.font: contentFont, .foregroundColor: NSColor.labelColor],
        range: changedRange)
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
      languageLabel?.stringValue = language.isEmpty ? "Code" : language
      textView.setAccessibilityLabel(language.isEmpty ? "Code block" : "\(language) code block")
      copyButton?.setAccessibilityLabel(language.isEmpty ? "Copy code block" : "Copy \(language) code block")
    }
  }

  func height(for width: CGFloat) -> CGFloat {
    let inset: CGFloat = segment.isCode ? 12 : 0
    let contentWidth = max(1, width - inset * 2)
    if measuredWidth != width || textNeedsLayout {
      textView.textContainer?.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
      if let container = textView.textContainer, let manager = textView.layoutManager {
        manager.ensureLayout(for: container)
        measuredHeight = max(20, ceil(max(manager.usedRect(for: container).height, manager.extraLineFragmentRect.maxY)))
      }
      measuredWidth = width
      textNeedsLayout = false
    }
    let header: CGFloat = segment.isCode ? 38 : 0
    textView.frame = NSRect(x: inset, y: header, width: contentWidth, height: measuredHeight)
    if let button = copyButton {
      button.frame = NSRect(x: max(inset, width - inset - 92), y: 6, width: 92, height: 26)
      languageLabel?.frame = NSRect(x: inset, y: 12, width: max(1, width - inset * 2 - 104), height: 16)
    }
    return header + measuredHeight + (segment.isCode ? 12 : 0)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  private func updateColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
      layer?.borderColor = NSColor.separatorColor.cgColor
      layer?.borderWidth = 1
    }
  }

  /// No streaming/render path writes the clipboard. This action runs only from the explicit button.
  @objc private func copyCode() {
    guard copyEnabled, case .code(let code, _, _) = segment else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(code, forType: .string)
  }

  func clear() {
    segment = .text("")
    textView.string = ""
    textView.undoManager?.removeAllActions()
    languageLabel?.stringValue = ""
    copyButton?.isEnabled = false
    copyButton?.target = nil
    copyButton?.action = nil
  }
}

/// Native answer surface; owns scrolling, literal text selection and explicit per-code copying.
final class AnswerView: NSView {
  let scrollView = NSScrollView(frame: .zero)
  private let document = AnswerDocumentView(frame: .zero)
  private(set) var segmentViews: [AnswerSegmentView] = []
  private var renderedText = ""
  private var layingOut = false
  var copyEnabled = true { didSet { segmentViews.forEach { $0.copyEnabled = copyEnabled } } }
  var focusTarget: NSView { segmentViews.first?.textView ?? self }
  override var acceptsFirstResponder: Bool { true }
  override var canBecomeKeyView: Bool { segmentViews.isEmpty && !isHiddenOrHasHiddenAncestor }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    scrollView.frame = bounds
    scrollView.autoresizingMask = [.width, .height]
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .bezelBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor
    scrollView.documentView = document
    scrollView.setAccessibilityLabel("Answer")
    addSubview(scrollView)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.recalculateKeyViewLoop()
  }

  func render(_ text: String) {
    guard !text.utf16.elementsEqual(renderedText.utf16) else { return }
    let position = scrollView.contentView.bounds.origin
    let followBottom = isAtBottom && !hasSelection
    let segments = splitNativeAnswerSegments(text)
    var commonCount = 0
    while commonCount < min(segments.count, segmentViews.count),
      segments[commonCount].isCode == segmentViews[commonCount].segment.isCode {
      segmentViews[commonCount].update(segments[commonCount])
      commonCount += 1
    }
    let structureChanged = commonCount != segmentViews.count || commonCount != segments.count
    for view in segmentViews.dropFirst(commonCount) { view.clear(); view.removeFromSuperview() }
    segmentViews.removeSubrange(commonCount...)
    for segment in segments.dropFirst(commonCount) {
      let view = AnswerSegmentView(segment: segment)
      view.copyEnabled = copyEnabled
      document.addSubview(view)
      segmentViews.append(view)
    }
    renderedText = text
    layoutSegments()
    restoreScroll(position, followBottom: followBottom)
    if structureChanged { window?.recalculateKeyViewLoop() }
    if window?.firstResponder === self, let textView = segmentViews.first?.textView {
      window?.makeFirstResponder(textView)
    }
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 48 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
      if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
      else { window?.selectNextKeyView(self) }
      return
    }
    // Before the first snapshot there is no text to scroll; retain this accessible focus target.
    if segmentViews.isEmpty && [115, 116, 119, 121, 123, 124, 125, 126].contains(event.keyCode) { return }
    super.keyDown(with: event)
  }

  private var hasSelection: Bool { segmentViews.contains { $0.textView.selectedRange().length > 0 } }
  private var isAtBottom: Bool {
    document.frame.height - scrollView.contentView.bounds.maxY <= 24
  }

  override func layout() {
    let position = scrollView.contentView.bounds.origin
    let followBottom = isAtBottom && !hasSelection
    super.layout()
    layoutSegments()
    restoreScroll(position, followBottom: followBottom)
  }

  private func layoutSegments() {
    guard !layingOut else { return }
    layingOut = true
    defer { layingOut = false }
    scrollView.tile()
    let width = max(1, scrollView.contentSize.width)
    var y: CGFloat = 12
    for view in segmentViews {
      let height = view.height(for: max(1, width - 24))
      view.frame = NSRect(x: 12, y: y, width: max(1, width - 24), height: height)
      y += height + 12
    }
    document.frame = NSRect(x: 0, y: 0, width: width, height: max(scrollView.contentSize.height, y))
  }

  private func restoreScroll(_ position: NSPoint, followBottom: Bool) {
    let maximum = max(0, document.frame.height - scrollView.contentSize.height)
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: followBottom ? maximum : min(position.y, maximum)))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  func clear() {
    if let responder = window?.firstResponder as? NSView,
      segmentViews.contains(where: { responder.isDescendant(of: $0) }) {
      window?.makeFirstResponder(self)
    }
    for view in segmentViews { view.clear(); view.removeFromSuperview() }
    segmentViews.removeAll()
    renderedText = ""
    document.frame = NSRect(origin: .zero, size: scrollView.contentSize)
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    window?.recalculateKeyViewLoop()
  }
}
