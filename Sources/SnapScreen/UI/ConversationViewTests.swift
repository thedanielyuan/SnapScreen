import AppKit

private enum ConversationTestError: Error { case failed(String) }

/// Thread, composer, panel and window-geometry checks. Windows stay offscreen and the clipboard is
/// never touched.
func runConversationViewTests() throws -> Int {
  var count = 0
  func check(_ value: Bool, _ name: String) throws {
    guard value else { throw ConversationTestError.failed(name) }
    count += 1
  }
  _ = NSApplication.shared

  let thread = ConversationView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
  var previews = 0
  var retries = 0
  thread.onPreview = { previews += 1 }
  thread.onRetry = { retries += 1 }
  thread.beginTurn(question: nil)
  let first = thread.latestTurn!
  try check(first.question == nil && first.isPending && !first.pending.isHidden, "first answer starts pending")
  try check(thread.thumbnail.isHidden, "no thumbnail before the crop is accepted")
  thread.setScreenshot(NSImage(size: NSSize(width: 960, height: 270)))
  try check(!thread.thumbnail.isHidden && thread.thumbnail.frame.width <= 300 && thread.thumbnail.frame.height <= 150,
    "accepted crop appears as a bounded thumbnail")
  thread.setScreenshot(NSImage(size: NSSize(width: 1200, height: 40)))
  let thin = thread.thumbnail.imageRect
  try check(thread.thumbnail.frame.height >= 24 && abs(thin.width / thin.height - 30) < 0.01,
    "a thin crop keeps a usable button without stretching the image")
  thread.setScreenshot(NSImage(size: NSSize(width: 960, height: 270)))
  thread.thumbnail.performClick(nil)
  try check(previews == 1, "thumbnail opens the preview")
  thread.setThinking()
  try check(first.state == .thinking && first.pending.thinking, "thinking keeps the pending indicator")
  first.pending.since = Date(timeIntervalSinceNow: -2)
  first.pending.update()
  try check(first.pending.label.stringValue.isEmpty, "pending label waits five seconds")
  first.pending.since = Date(timeIntervalSinceNow: -65)
  first.pending.update()
  try check(first.pending.label.stringValue == "Thinking…", "pending label names thinking after the delay")
  thread.updateAnswer("Partial", status: .streaming)
  try check(!first.isPending && first.pending.isHidden && first.copyButton.isHidden,
    "streaming text replaces the indicator without offering Copy")
  thread.updateAnswer("Final answer", status: .done)
  try check(first.state == .done && !first.copyButton.isHidden && first.retryButton.isHidden,
    "a finished answer offers Copy")

  thread.beginTurn(question: "Why?")
  let second = thread.latestTurn!
  try check(!first.isLatest && second.isLatest && second.question == "Why?", "a follow-up starts a new exchange")
  thread.updateAnswer("", status: .stopped)
  thread.canRetry = true
  try check(second.state == .stopped && !second.retryButton.isHidden && second.copyButton.isHidden,
    "a stopped answer without text offers Retry")
  try check(!second.isHeld(asFirst: false) && first.isHeld(asFirst: true),
    "an unanswered stopped follow-up is not part of the conversation")
  thread.removeAbandonedTurn()
  try check(thread.turns.count == 1 && thread.latestTurn === first && first.isLatest,
    "the next follow-up drops the abandoned question, as the conversation does")

  thread.beginTurn(question: "Again?")
  let third = thread.latestTurn!
  thread.updateAnswer("Half an ans", status: .streaming)
  thread.canRetry = false
  thread.fail("The request failed.", clearAnswer: false)
  try check(third.state == .failed("The request failed.") && !third.failure.isHidden &&
    third.answer.renderedText == "Half an ans" && third.failure.retryButton.isHidden,
    "a failure keeps streamed text and hides Retry when the session cannot retry")
  thread.canRetry = true
  try check(!third.failure.retryButton.isHidden, "the newest failure offers Retry")
  thread.beginTurn(question: "Once more?")
  let fourth = thread.latestTurn!
  thread.fail("Also failed.", clearAnswer: false)
  try check(!fourth.failure.retryButton.isHidden && !third.failure.isHidden && third.failure.retryButton.isHidden,
    "only the newest of several failures offers Retry")
  fourth.failure.retryButton.performClick(nil)
  try check(retries == 1, "failure Retry calls the session")
  thread.restartLatestTurn()
  try check(fourth.isPending && fourth.answer.renderedText.isEmpty && fourth.failure.isHidden,
    "Retry restarts the newest exchange")
  thread.updateAnswer("Refused partial text", status: .streaming)
  thread.fail("Refused.", clearAnswer: true)
  try check(fourth.answer.segmentViews.isEmpty && fourth.answer.renderedText.isEmpty,
    "refused text is cleared")
  try check(first.isHeld(asFirst: false) && first.isHeld(asFirst: true), "a finished answer is always held")
  try check(fourth.isHeld(asFirst: false) && !fourth.isHeld(asFirst: true),
    "a failed follow-up is held, but a first answer that failed without text is cleared")

  // Pruning keeps the first answer and drops the oldest follow-ups.
  thread.beginTurn(question: "Fifth?")
  let fifth = thread.latestTurn!
  try check(thread.heldTurns.map { $0 === first || $0 === third || $0 === fourth } == [true, true, true] &&
    thread.heldTurns.count == 3, "the request in progress is not yet held")
  thread.addNotice("2 older conversation turns were removed to keep the screenshot and newest request within the configured limit.",
    removedTurns: 2)
  try check(thread.turns.count == 2 && thread.turns[0] === first && thread.turns[1] === fifth,
    "removed turns leave the thread, keeping the first answer")
  try check(third.answer.renderedText.isEmpty && third.superview == nil, "removed turns release their text")
  try check(fifth.noticeView?.label.stringValue.hasPrefix("2 older") == true, "the notice sits on the request it concerns")
  thread.addNotice("Nothing removed.", removedTurns: 0)
  try check(thread.turns.count == 2 && fifth.noticeView?.label.stringValue == "Nothing removed.",
    "a notice without removals only updates the newest request")
  thread.updateAnswer("Fifth answer", status: .done)
  thread.beginTurn(question: "Sixth?")
  thread.addNotice("Removed.", removedTurns: 5)
  try check(thread.turns.count == 2 && thread.turns[0] === first,
    "a larger count than the held follow-ups removes only what exists")

  // A first answer that failed without text is not held: the next request becomes the first.
  let restart = ConversationView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
  restart.beginTurn(question: nil)
  restart.fail("No answer.", clearAnswer: false)
  restart.beginTurn(question: "Try this instead")
  restart.updateAnswer("", status: .stopped)
  let stoppedFirst = restart.latestTurn!
  restart.removeAbandonedTurn()
  try check(restart.latestTurn === stoppedFirst, "a stopped request that became the first answer is kept")
  restart.beginTurn(question: "Then this")
  try check(restart.heldTurns.count == 1 && restart.heldTurns[0] === stoppedFirst,
    "held turns skip a first answer that failed without text")
  restart.clear()

  thread.actionsEnabled = false
  try check(!first.copyButton.isEnabled && !thread.thumbnail.isEnabled, "an ended session disables copy and preview")

  // Reading position: retained above the bottom, followed at the bottom, and a new question shows.
  let reader = ConversationView(frame: NSRect(x: 0, y: 0, width: 460, height: 240))
  reader.beginTurn(question: nil)
  let long = (1...80).map { "Line \($0) of the answer." }.joined(separator: "\n")
  reader.updateAnswer(long, status: .streaming)
  let scroll = reader.scrollView
  try check(scroll.documentView!.frame.height > scroll.contentSize.height, "long answer scrolls")
  scroll.contentView.scroll(to: NSPoint(x: 0, y: 90))
  reader.updateAnswer(long + "\nMore.", status: .streaming)
  try check(abs(scroll.contentView.bounds.minY - 90) < 1, "streaming preserves the reader's position")
  scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.documentView!.frame.height - scroll.contentSize.height))
  reader.updateAnswer(long + "\nMore.\nEven more.", status: .done)
  try check(abs(scroll.contentView.bounds.maxY - scroll.documentView!.frame.height) < 1,
    "streaming follows the bottom when the reader is there")
  scroll.contentView.scroll(to: .zero)
  reader.beginTurn(question: "Next?")
  try check(abs(scroll.contentView.bounds.maxY - scroll.documentView!.frame.height) < 1,
    "asking a question brings it into view")
  // A selection left behind in an earlier answer must not stop following once focus moves on.
  reader.turns[0].answer.segmentViews[0].textView.setSelectedRange(NSRange(location: 0, length: 5))
  reader.updateAnswer(long, status: .streaming)
  try check(!reader.hasSelection && abs(scroll.contentView.bounds.maxY - scroll.documentView!.frame.height) < 1,
    "an inactive selection elsewhere does not pause following")

  // Focus: removing the focused text falls back to the composer.
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400), styleMask: [.borderless],
    backing: .buffered, defer: false)
  let root = NSView(frame: window.contentLayoutRect)
  window.contentView = root
  let focusThread = ConversationView(frame: NSRect(x: 0, y: 60, width: 460, height: 340))
  let composer = ComposerView(frame: NSRect(x: 0, y: 0, width: 460, height: 60))
  root.addSubview(focusThread)
  root.addSubview(composer)
  focusThread.focusFallback = { [weak composer] in composer?.textView }
  focusThread.beginTurn(question: nil)
  focusThread.updateAnswer("Prose\n```py\nx = 1\n```", status: .done)
  let code = focusThread.latestTurn!.answer.segmentViews[1].textView
  window.makeFirstResponder(code)
  focusThread.beginTurn(question: "Q")
  focusThread.restartLatestTurn()
  focusThread.updateAnswer("Replacement", status: .streaming)
  try check(window.firstResponder === code, "streaming another answer leaves the reader's focus alone")
  focusThread.latestTurn!.answer.render("", final: false)
  window.makeFirstResponder(focusThread.turns[0].answer.segmentViews[1].textView)
  focusThread.turns[0].answer.render("Only prose", final: true)
  try check(window.firstResponder !== code, "removed text cannot keep focus")
  focusThread.updateAnswer("Next", status: .done)
  try check(window.firstResponder === composer.textView, "focus falls back to the composer")
  let selected = focusThread.latestTurn!.answer.segmentViews[0].textView
  window.makeFirstResponder(selected)
  selected.setSelectedRange(NSRange(location: 0, length: 2))
  try check(focusThread.hasSelection, "a selection in the focused answer pauses following")

  // Composer: Return asks, limits are enforced, and the button switches between Send and Stop.
  var submitted: [String] = []
  var stops = 0
  composer.onSubmit = { submitted.append($0) }
  composer.onStop = { stops += 1 }
  composer.maximumCharacters = 10
  composer.canSubmit = true
  try check(!composer.sendButton.isEnabled && composer.sendButton.mode == .send, "empty draft cannot be sent")
  composer.setDraft("  Hi  ")
  try check(composer.sendButton.isEnabled, "a draft can be sent")
  _ = composer.textView(composer.textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
  try check(submitted == ["Hi"], "Return asks the trimmed draft")
  composer.setDraft(" \u{FEFF}\n")
  _ = composer.textView(composer.textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
  try check(submitted.count == 1 && !composer.sendButton.isEnabled, "blank drafts are never sent")
  composer.setDraft("123456789")
  try check(!composer.textView(composer.textView, shouldChangeTextIn: NSRange(location: 9, length: 0),
    replacementString: "😀😀") && !composer.hintLabel.isHidden && composer.hintLabel.stringValue.contains("too long"),
    "input beyond the limit is refused with feedback")
  try check(composer.textView(composer.textView, shouldChangeTextIn: NSRange(location: 9, length: 0),
    replacementString: "😀"), "input at the limit counts Unicode scalars")
  composer.setDraft("short")
  try check(composer.hintLabel.isHidden, "the length hint stays hidden well below the limit")
  composer.isRunning = true
  composer.canStop = false
  try check(composer.sendButton.mode == .stop && !composer.sendButton.isEnabled, "Stop waits for the answer to start")
  _ = composer.textView(composer.textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
  try check(submitted.count == 1, "Return does not ask while an answer is in progress")
  composer.canStop = true
  composer.sendButton.performClick(nil)
  try check(stops == 1 && submitted.count == 1, "the button stops a running answer")
  try check(window.firstResponder === composer.textView, "after Stop, typing continues in the field")
  composer.isRunning = false
  composer.canSubmit = true
  composer.maximumCharacters = 4000
  composer.setDraft("Sent with the button")
  window.makeFirstResponder(composer.sendButton)
  composer.sendButton.performClick(nil)
  try check(submitted.last == "Sent with the button" && window.firstResponder === composer.textView,
    "after Send, typing continues in the field")
  composer.setDraft("hello ")
  composer.textView.setSelectedRange(NSRange(location: 6, length: 0))
  composer.textView.setMarkedText("nihon", selectedRange: NSRange(location: 5, length: 0),
    replacementRange: NSRange(location: NSNotFound, length: 0))
  try check(composer.textView.hasMarkedText(), "an input method can leave unfinished text")
  composer.submit()
  try check(submitted.last == "hello nihon" && !composer.textView.hasMarkedText(),
    "sending commits unfinished input-method text first")

  // Laid out as the answer window does: narrowing it must grow the field to fit the wrapped text.
  let layoutWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.borderless],
    backing: .buffered, defer: false)
  let layoutRoot = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
  layoutWindow.contentView = layoutRoot
  let pinned = ComposerView()
  pinned.translatesAutoresizingMaskIntoConstraints = false
  layoutRoot.addSubview(pinned)
  NSLayoutConstraint.activate([
    pinned.leadingAnchor.constraint(equalTo: layoutRoot.leadingAnchor, constant: 14),
    pinned.trailingAnchor.constraint(equalTo: layoutRoot.trailingAnchor, constant: -14),
    pinned.bottomAnchor.constraint(equalTo: layoutRoot.bottomAnchor, constant: -14),
  ])
  pinned.setDraft("A question long enough to wrap onto several lines when the window becomes narrow")
  layoutRoot.layoutSubtreeIfNeeded()
  let wideHeight = pinned.frame.height
  layoutWindow.setContentSize(NSSize(width: 220, height: 400))
  layoutRoot.layoutSubtreeIfNeeded()
  let narrowHeight = pinned.frame.height
  try check(narrowHeight > wideHeight, "narrowing the window grows the field")
  layoutWindow.setContentSize(NSSize(width: 900, height: 400))
  layoutRoot.layoutSubtreeIfNeeded()
  try check(pinned.frame.height == wideHeight, "widening it again shrinks the field back")
  // Only a draft past six lines gets a scroller, even where macOS draws scrollers always.
  let draftScroll = pinned.textView.enclosingScrollView!
  draftScroll.scrollerStyle = .legacy
  pinned.setDraft("d")
  layoutRoot.layoutSubtreeIfNeeded()
  try check(!draftScroll.hasVerticalScroller, "a short draft has no scroller beside the button")
  pinned.setDraft((1...9).map { "Line \($0)" }.joined(separator: "\n"))
  layoutRoot.layoutSubtreeIfNeeded()
  try check(draftScroll.hasVerticalScroller && draftScroll.verticalScroller?.isHidden == false,
    "a draft past six lines scrolls")
  pinned.setDraft("d")
  layoutRoot.layoutSubtreeIfNeeded()
  try check(!draftScroll.hasVerticalScroller, "the scroller goes once the draft fits again")
  func hasDraftAttributes() -> Bool {
    guard let storage = pinned.textView.textStorage, storage.length > 0 else { return false }
    var matches = true
    storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
      let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
      matches = matches && (attributes[.font] as? NSFont)?.pointSize == 15 &&
        paragraph?.minimumLineHeight == 20 && paragraph?.maximumLineHeight == 20
    }
    return matches
  }
  pinned.clearDraft()
  pinned.textView.insertText("Typed", replacementRange: NSRange(location: 0, length: 0))
  let typedAttributes = hasDraftAttributes()
  pinned.setDraft("Set")
  try check(typedAttributes && hasDraftAttributes(), "a draft is 15-point text on 20-point lines, typed or set")
  // Send keeps to the bottom-right corner, beside the last line, so it's centred on one line.
  var heights: [CGFloat] = []
  var besideLastLine = true
  for lines in 1...8 {
    pinned.setDraft((1...lines).map { "Line \($0)" }.joined(separator: "\n"))
    layoutRoot.layoutSubtreeIfNeeded()
    heights.append(pinned.frame.height)
    let manager = pinned.textView.layoutManager!
    let lastLine = manager.lineFragmentRect(forGlyphAt: manager.numberOfGlyphs - 1, effectiveRange: nil)
    besideLastLine = besideLastLine &&
      abs(pinned.sendButton.frame.midY - pinned.textView.convert(lastLine, to: pinned).midY) < 0.5
  }
  try check(heights[0] == ComposerView.minimumFieldHeight && zip(heights[0..<5], heights[1...5]).allSatisfy {
    $1 - $0 == ComposerView.lineHeight } && heights[5...].allSatisfy { $0 == heights[5] },
    "the field grows a line at a time to six lines, then holds")
  pinned.setDraft("One line")
  layoutRoot.layoutSubtreeIfNeeded()
  try check(besideLastLine && abs(pinned.sendButton.frame.midY - pinned.bounds.midY) < 0.5,
    "Send sits beside the last line, centred while the draft is one line")
  // Its arrow, and Stop's square, sit at the circle's centre whether or not it can act. Rendered at
  // 2x, the icon is whatever differs from the fill, sampled above it; the circle's edge is left out.
  let sendButton = SendButton(target: nil, action: nil)
  sendButton.frame.size = pinned.sendButton.frame.size
  func iconBounds() -> NSRect? {
    let scale: CGFloat = 2
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(sendButton.bounds.width * scale),
      pixelsHigh: Int(sendButton.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    bitmap.size = sendButton.bounds.size
    sendButton.cacheDisplay(in: sendButton.bounds, to: bitmap)
    guard let fill = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: Int(3 * scale)) else { return nil }
    let edge = Int(6 * scale)
    var icon: NSRect?
    for y in edge..<(bitmap.pixelsHigh - edge) {
      for x in edge..<(bitmap.pixelsWide - edge) {
        guard let color = bitmap.colorAt(x: x, y: y) else { continue }
        let difference = abs(color.redComponent - fill.redComponent) + abs(color.greenComponent - fill.greenComponent) +
          abs(color.blueComponent - fill.blueComponent) + abs(color.alphaComponent - fill.alphaComponent)
        guard difference > 0.02 else { continue }
        let pixel = NSRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale)
        icon = icon.map { $0.union(pixel) } ?? pixel
      }
    }
    return icon
  }
  var iconsCentred = sendButton.frame.width == 32 && sendButton.frame.height == 32
  for mode in [SendButton.Mode.send, .stop] {
    for enabled in [true, false] {
      sendButton.mode = mode
      sendButton.isEnabled = enabled
      let icon = iconBounds()
      iconsCentred = iconsCentred && icon?.midX == sendButton.bounds.midX && icon?.midY == sendButton.bounds.midY
    }
  }
  try check(iconsCentred, "Send is a 32-point circle with its arrow, or Stop's square, centred, enabled or not")
  pinned.clear()
  layoutWindow.contentView = nil
  composer.canSubmit = false
  try check(!composer.sendButton.isEnabled, "the button waits for the session to accept follow-ups")
  composer.clear()
  try check(composer.draft.isEmpty && composer.textView.delegate == nil && composer.onSubmit == nil, "clear releases the draft")
  focusThread.clear()
  try check(focusThread.turns.isEmpty && focusThread.thumbnail.screenshot == nil, "clear releases the thread")
  window.contentView = nil

  // Escape and Command-W close on key release, so the release can't reach the app beneath.
  final class CloseCounter: NSObject, NSWindowDelegate {
    var count = 0
    func windowShouldClose(_ sender: NSWindow) -> Bool { count += 1; return false }
  }
  let panel = CompanionPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
    styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
  let counter = CloseCounter()
  panel.delegate = counter
  func key(_ type: NSEvent.EventType, _ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: panel.windowNumber,
      context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
  }
  panel.sendEvent(key(.keyDown, 53, "\u{1B}"))
  try check(counter.count == 0, "Escape does not close on key down")
  panel.sendEvent(key(.keyDown, 0, "a"))
  try check(counter.count == 0, "keys pressed while Escape is held are ignored")
  NSApp.sendEvent(key(.keyUp, 53, "\u{1B}"))
  try check(counter.count == 1, "Escape closes on release")
  try check(panel.performKeyEquivalent(with: key(.keyDown, 13, "w", .command)) && counter.count == 1,
    "Command-W is claimed on key down without closing")
  // AppKit never dispatches a key-up with Command held to a window; the release must still close.
  NSApp.sendEvent(key(.keyUp, 13, "w", .command))
  try check(counter.count == 2, "Command-W closes on release while Command is held")
  NSApp.sendEvent(key(.keyUp, 13, "w", .command))
  try check(counter.count == 2, "a later release does not close again")
  // The File menu's Close arrives as performClose during the key press, on any keyboard layout.
  panel.performClose(nil, during: key(.keyDown, 13, "w", .command))
  try check(counter.count == 2, "a menu close from the keyboard waits for release")
  NSApp.sendEvent(key(.keyUp, 13, "w", .command))
  try check(counter.count == 3, "the menu close completes on release")
  panel.performClose(nil, during: NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
    timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  try check(counter.count == 4, "the close button closes at once")
  panel.sendEvent(key(.keyDown, 53, "\u{1B}"))
  panel.resignKey()
  // The close is queued on the main queue. Wait for it rather than a fixed slice, since slow CI
  // runners can miss a short one, but stop well before the 4 s release fallback could close it.
  let resignDeadline = Date(timeIntervalSinceNow: 1)
  while counter.count < 5, Date() < resignDeadline {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
  }
  try check(counter.count == 5, "losing the keyboard while Escape is held closes, since the release cannot arrive")
  panel.delegate = nil

  // Window geometry.
  let natural = imageWindowContentSize(CGSize(width: 1600, height: 1000), backingScale: 2,
    maximum: CGSize(width: 1400, height: 900), minimum: CGSize(width: 480, height: 320), chrome: CGSize(width: 16, height: 44))
  try check(natural == CGSize(width: 816, height: 544), "an image that fits is shown at captured size")
  let bounded = imageWindowContentSize(CGSize(width: 3000, height: 1000), backingScale: 1,
    maximum: CGSize(width: 1016, height: 900), minimum: CGSize(width: 480, height: 320), chrome: CGSize(width: 16, height: 44))
  try check(bounded == CGSize(width: 1016, height: 377), "a large image is scaled to fit, keeping its aspect")
  let tiny = imageWindowContentSize(CGSize(width: 40, height: 30), backingScale: 1,
    maximum: CGSize(width: 1000, height: 800), minimum: CGSize(width: 320, height: 220), chrome: CGSize(width: 24, height: 52))
  try check(tiny == CGSize(width: 320, height: 220), "a tiny image keeps a usable window")
  let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
  let size = CGSize(width: 460, height: 600)
  try check(windowFrame(size: size, beside: CGRect(x: 100, y: 500, width: 300, height: 200), in: visible) ==
    CGRect(x: 416, y: 100, width: 460, height: 600), "the answer opens to the right of the selection")
  try check(windowFrame(size: size, beside: CGRect(x: 1000, y: 500, width: 300, height: 200), in: visible) ==
    CGRect(x: 524, y: 100, width: 460, height: 600), "or to its left when the right side is full")
  try check(windowFrame(size: size, beside: CGRect(x: 0, y: 0, width: 1440, height: 900), in: visible) ==
    CGRect(x: 964, y: 150, width: 460, height: 600), "a full-screen selection puts the answer at the right edge")
  try check(windowFrame(size: size, beside: nil, in: visible) == CGRect(x: 490, y: 150, width: 460, height: 600),
    "without a selection the window is centred")
  try check(windowFrame(size: CGSize(width: 2000, height: 1200), beside: nil, in: visible) == visible,
    "a window never exceeds the visible screen")
  return count
}
