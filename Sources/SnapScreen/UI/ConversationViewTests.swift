import AppKit

private enum ConversationTestError: Error { case failed(String) }

/// Thread, Stop, panel and window-geometry checks. Windows stay offscreen and the clipboard is
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
  thread.beginTurn()
  let answer = thread.turn!
  try check(answer.isPending && !answer.pending.isHidden, "the answer starts pending")
  thread.beginTurn()
  try check(thread.turn === answer, "a conversation holds one answer")
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
  // The selection's size holds the thumbnail's place, so the crop, fitted to the limits and a pixel
  // or so different, fills it without moving the thread.
  let placeholder = ConversationView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
  placeholder.reserveScreenshot(size: CGSize(width: 960, height: 270))
  placeholder.beginTurn()
  let reserved = placeholder.thumbnail.frame
  let pendingTop = placeholder.turn!.frame.minY
  try check(!placeholder.thumbnail.isHidden && !placeholder.thumbnail.isEnabled && reserved.width > 0 &&
    placeholder.thumbnail.screenshot == nil, "the thumbnail holds the crop's place, inactive, until it arrives")
  placeholder.setScreenshot(NSImage(size: NSSize(width: 958, height: 269)))
  try check(placeholder.thumbnail.frame == reserved && placeholder.turn!.frame.minY == pendingTop &&
    placeholder.thumbnail.isEnabled, "the crop fills its place without moving the thread")
  placeholder.clear()
  try check(placeholder.thumbnail.reservedSize == nil && placeholder.thumbnail.isHidden, "clear releases the place")
  thread.setThinking()
  try check(answer.state == .thinking && answer.pending.thinking, "thinking keeps the pending indicator")
  answer.pending.since = Date(timeIntervalSinceNow: -2)
  answer.pending.update()
  try check(answer.pending.label.stringValue.isEmpty, "pending label waits five seconds")
  answer.pending.since = Date(timeIntervalSinceNow: -65)
  answer.pending.update()
  try check(answer.pending.label.stringValue == "Thinking…", "pending label names thinking after the delay")
  thread.updateAnswer("Partial", status: .streaming)
  try check(!answer.isPending && answer.pending.isHidden && answer.copyButton.isHidden,
    "streaming text replaces the indicator without offering Copy")
  thread.updateAnswer("Final answer", status: .done)
  try check(answer.state == .done && !answer.copyButton.isHidden && answer.retryButton.isHidden,
    "a finished answer offers Copy")
  thread.actionsEnabled = false
  try check(!answer.copyButton.isEnabled && !thread.thumbnail.isEnabled, "an ended session disables copy and preview")

  // A stopped or failed answer offers Retry when the session can retry, which starts it again.
  let retrying = ConversationView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
  retrying.onRetry = { retries += 1 }
  retrying.beginTurn()
  let again = retrying.turn!
  retrying.updateAnswer("", status: .stopped)
  retrying.canRetry = true
  try check(again.state == .stopped && !again.retryButton.isHidden && again.copyButton.isHidden,
    "a stopped answer without text offers Retry")
  retrying.restartTurn()
  try check(again.isPending && again.retryButton.isHidden && again.answer.renderedText.isEmpty,
    "Retry starts the answer again")
  retrying.updateAnswer("Half an ans", status: .streaming)
  retrying.canRetry = false
  retrying.fail("The request failed.", clearAnswer: false)
  try check(again.state == .failed("The request failed.") && !again.failure.isHidden &&
    again.answer.renderedText == "Half an ans" && again.failure.retryButton.isHidden,
    "a failure keeps streamed text and hides Retry when the session cannot retry")
  retrying.canRetry = true
  try check(!again.failure.retryButton.isHidden, "a failure offers Retry")
  again.failure.retryButton.performClick(nil)
  try check(retries == 1, "failure Retry calls the session")
  retrying.restartTurn()
  try check(again.isPending && again.answer.renderedText.isEmpty && again.failure.isHidden, "Retry clears the failure")
  retrying.updateAnswer("Refused partial text", status: .streaming)
  retrying.fail("Refused.", clearAnswer: true)
  try check(again.answer.segmentViews.isEmpty && again.answer.renderedText.isEmpty, "refused text is cleared")
  retrying.clear()
  try check(retrying.turn == nil && again.superview == nil, "clear releases the answer")

  // Reading position: a long answer is followed until its start reaches the top, then held there.
  // The reader's own position is kept, and the bottom is followed once the reader goes there.
  let reader = ConversationView(frame: NSRect(x: 0, y: 0, width: 460, height: 240))
  reader.setScreenshot(NSImage(size: NSSize(width: 960, height: 270)))
  reader.beginTurn()
  let long = (1...80).map { "Line \($0) of the answer." }.joined(separator: "\n")
  reader.updateAnswer("Line 1 of the answer.", status: .streaming)
  reader.updateAnswer(long, status: .streaming)
  let scroll = reader.scrollView
  let start = reader.turn!.frame.minY - ConversationView.verticalPadding
  try check(scroll.documentView!.frame.height > scroll.contentSize.height, "long answer scrolls")
  try check(start > 0 && abs(scroll.contentView.bounds.minY - start) < 1,
    "a long answer is followed until its start reaches the top")
  // A selection left in the answer after focus moves on must not stop following.
  reader.turn!.answer.segmentViews[0].textView.setSelectedRange(NSRange(location: 0, length: 5))
  reader.updateAnswer(long + "\nMore.", status: .streaming)
  try check(!reader.hasSelection && abs(scroll.contentView.bounds.minY - start) < 1,
    "its start stays in view as the rest streams in, despite an inactive selection")
  scroll.contentView.scroll(to: NSPoint(x: 0, y: 150))
  reader.updateAnswer(long + "\nMore.\nStill more.", status: .streaming)
  try check(abs(scroll.contentView.bounds.minY - 150) < 1, "streaming preserves the reader's position")
  scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.documentView!.frame.height - scroll.contentSize.height))
  reader.updateAnswer(long + "\nMore.\nStill more.\nEven more.", status: .done)
  try check(abs(scroll.contentView.bounds.maxY - scroll.documentView!.frame.height) < 1,
    "streaming follows the bottom once the reader goes there")
  try check(reader.contentHeight == scroll.documentView!.frame.height, "the thread reports its unscrolled height")

  // ⇧⌘C and ⌥⌘C press the answer's Copy buttons. These checks write to a private pasteboard, never
  // the clipboard.
  let general = Clipboard.pasteboard
  let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.snapscreen.self-test.\(UUID().uuidString)"))
  Clipboard.pasteboard = pasteboard
  let copier = ConversationView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
  copier.beginTurn()
  try check(copier.answerToCopy == nil && !copier.copyLatestAnswer() && !copier.copyLatestCode(),
    "nothing is copied while the answer is pending")
  copier.updateAnswer("Streaming", status: .streaming)
  try check(copier.answerToCopy == nil && !copier.copyLatestAnswer(), "nothing is copied while the answer streams")
  let coded = "First\n```js\none()\n```\nThen\n```py\ntwo()\n```"
  copier.updateAnswer(coded, status: .done)
  try check(copier.copyLatestAnswer() && pasteboard.string(forType: .string) == coded, "⇧⌘C copies the answer")
  try check(copier.copyLatestCode() && pasteboard.string(forType: .string) == "two()", "⌥⌘C copies the last code block")
  let blocks = copier.turn!.answer.segmentViews
  try check(copier.turn!.copyButton.toolTip == "Copy answer (⇧⌘C)" && blocks[3].copyButton?.toolTip == "Copy py code (⌥⌘C)" &&
    blocks[1].copyButton?.toolTip == "Copy js code", "tooltips name the shortcuts on the buttons they press")
  copier.showsCopyShortcuts = false
  try check(copier.turn!.copyButton.toolTip == "Copy answer" && blocks[3].copyButton?.toolTip == "Copy py code",
    "passive panels remove existing keyboard shortcut hints")
  copier.restartTurn()
  copier.updateAnswer("```swift\nlet answer = 42\n```", status: .done)
  try check(copier.turn?.copyButton.toolTip == "Copy answer" &&
    copier.turn?.answer.segmentViews.first?.copyButton?.toolTip == "Copy swift code",
    "a retried answer keeps keyboard shortcut hints hidden in passive panels")
  try check(copier.copyLatestAnswer() && pasteboard.string(forType: .string) == "```swift\nlet answer = 42\n```" &&
    copier.copyLatestCode() && pasteboard.string(forType: .string) == "let answer = 42",
    "passive panels retain their answer and code Copy button actions")
  copier.actionsEnabled = false
  try check(!copier.copyLatestAnswer() && !copier.copyLatestCode(), "an ended session copies nothing")
  copier.clear()
  Clipboard.pasteboard = general
  pasteboard.releaseGlobally()

  // Focus: text that's removed can't keep it, and a selection in the focused answer pauses following.
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400), styleMask: [.borderless],
    backing: .buffered, defer: false)
  let focusThread = ConversationView(frame: window.contentLayoutRect)
  window.contentView = focusThread
  focusThread.beginTurn()
  focusThread.updateAnswer("Prose\n```py\nx = 1\n```", status: .done)
  let code = focusThread.turn!.answer.segmentViews[1].textView
  window.makeFirstResponder(code)
  focusThread.turn!.answer.render("Only prose", final: true)
  try check(window.firstResponder !== code, "removed text cannot keep focus")
  let selected = focusThread.turn!.answer.segmentViews[0].textView
  window.makeFirstResponder(selected)
  selected.setSelectedRange(NSRange(location: 0, length: 2))
  try check(focusThread.hasSelection, "a selection in the focused answer pauses following")
  focusThread.clear()
  try check(focusThread.turn == nil && focusThread.thumbnail.screenshot == nil, "clear releases the thread")
  window.contentView = nil

  // Stop's square sits at the circle's centre whether or not it can act. Rendered at 2x, the icon is
  // whatever differs from the fill, sampled above it; the circle's edge is left out.
  let stopButton = StopButton(target: nil, action: nil)
  func iconBounds() -> NSRect? {
    let scale: CGFloat = 2
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(stopButton.bounds.width * scale),
      pixelsHigh: Int(stopButton.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    bitmap.size = stopButton.bounds.size
    stopButton.cacheDisplay(in: stopButton.bounds, to: bitmap)
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
  var iconsCentred = stopButton.frame.width == 32 && stopButton.frame.height == 32
  for enabled in [true, false] {
    stopButton.isEnabled = enabled
    let icon = iconBounds()
    iconsCentred = iconsCentred && icon?.midX == stopButton.bounds.midX && icon?.midY == stopButton.bounds.midY
  }
  try check(iconsCentred, "Stop is a 32-point circle with its square centred, enabled or not")
  try check(stopButton.accessibilityLabel() == "Stop answer" && stopButton.toolTip == "Stop answer",
    "Stop is named for VoiceOver and the pointer")

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

  // The conversation opens small where it was placed at its largest, then grows away from the
  // selection, and the other way once the screen's edge stops it.
  func opening(_ region: CGRect) -> CGRect {
    openingFrame(windowFrame(size: size, beside: region, in: visible), height: 300, beside: region, in: visible)
  }
  try check(opening(CGRect(x: 100, y: 500, width: 300, height: 200)) == CGRect(x: 416, y: 400, width: 460, height: 300),
    "beside its selection, it opens level with the selection's top")
  try check(opening(CGRect(x: 100, y: 40, width: 300, height: 100)) == CGRect(x: 416, y: 0, width: 460, height: 300),
    "near the bottom of the screen, it opens on the screen's edge")
  try check(opening(CGRect(x: 0, y: 700, width: 1440, height: 150)) == CGRect(x: 490, y: 384, width: 460, height: 300),
    "below a wide selection, it opens just below it")
  try check(opening(CGRect(x: 0, y: 40, width: 1440, height: 100)) == CGRect(x: 490, y: 156, width: 460, height: 300),
    "above a wide selection, it opens just above it")
  let small = CGRect(x: 100, y: 500, width: 460, height: 300)
  try check(grownFrame(small, toHeight: 400, maximumHeight: 600, in: visible) ==
    CGRect(x: 100, y: 400, width: 460, height: 400), "it grows down, keeping its top edge")
  try check(grownFrame(small, toHeight: 900, maximumHeight: 600, in: visible).height == 600, "up to its largest")
  try check(grownFrame(small, toHeight: 200, maximumHeight: 600, in: visible) == small, "and never shrinks")
  try check(grownFrame(CGRect(x: 100, y: 50, width: 460, height: 300), toHeight: 500, maximumHeight: 600, in: visible) ==
    CGRect(x: 100, y: 0, width: 460, height: 500), "stopped by the bottom of the screen, it grows up")
  try check(grownFrame(small, toHeight: 400, maximumHeight: 600, upward: true, in: visible) ==
    CGRect(x: 100, y: 500, width: 460, height: 400), "above its selection, it grows up from its bottom edge")
  return count
}
