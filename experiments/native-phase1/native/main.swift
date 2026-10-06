import AppKit
import Carbon
import Foundation
import ImageIO

final class ExperimentPanel: NSPanel {
  var telemetrySurface = "unknown"
  var geometry = SurfaceGeometryTracker()
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// The follow-up field's editor. It reports editing commands and input-method composition as
/// event names only; it never reads, retains, or reports the text being edited or composed.
final class InstrumentedFieldEditor: NSTextView {
  var onEvent: ((String) -> Void)?
  var onPaste: (() -> Void)?
  private var committing = false

  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    onEvent?(hasMarkedText() ? "followup.composition_update" : "followup.composition_cleared")
  }

  override func unmarkText() {
    let composing = hasMarkedText()
    super.unmarkText()
    if composing && !committing { onEvent?("followup.composition_committed") }
  }

  override func insertText(_ string: Any, replacementRange: NSRange) {
    let composing = hasMarkedText()
    committing = composing
    super.insertText(string, replacementRange: replacementRange)
    committing = false
    if composing { onEvent?("followup.composition_committed") }
  }

  override func paste(_ sender: Any?) {
    super.paste(sender)
    onPaste?()
  }

  override func selectAll(_ sender: Any?) {
    super.selectAll(sender)
    onEvent?("followup.select_all")
  }
}

/// A transparent, nonactivating window kept directly beneath the panels. Reshaping a window under
/// the pointer exposes whatever lies below it; without the shield that is Chrome, whose page then
/// observes hover events with the button pressed. It ignores the mouse except while a panel is
/// pressed near its edge or live-resizing, so the page stays usable around the panels.
final class PointerShield: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

final class SelectionView: NSView {
  var image: NSImage?
  var selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
  var onConfirm: ((NormalizedRect) -> Void)?
  var onCancel: (() -> Void)?
  var onEvent: ((String) -> Void)?
  private var anchor: CGPoint?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  var imageRect: CGRect {
    guard let image = image else { return .zero }
    return fittedImageRect(image.size, in: bounds)
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
    let fitted = imageRect
    image?.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    let selected = CGRect(x: fitted.minX + selection.minX * fitted.width,
      y: fitted.minY + selection.minY * fitted.height,
      width: selection.width * fitted.width, height: selection.height * fitted.height)
    let shade = NSBezierPath(rect: fitted)
    shade.appendRect(selected)
    shade.windingRule = .evenOdd
    NSColor.black.withAlphaComponent(0.42).setFill()
    shade.fill()
    NSColor.systemYellow.setStroke()
    let outline = NSBezierPath(rect: selected)
    outline.lineWidth = 3
    outline.stroke()
  }

  private func normalizedPoint(_ event: NSEvent) -> CGPoint {
    let point = convert(event.locationInWindow, from: nil)
    let fitted = imageRect
    return CGPoint(x: max(0, min(1, (point.x - fitted.minX) / max(1, fitted.width))),
      y: max(0, min(1, (point.y - fitted.minY) / max(1, fitted.height))))
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
    anchor = normalizedPoint(event)
    onEvent?("selection.drag_start")
  }

  override func mouseDragged(with event: NSEvent) {
    guard let anchor = anchor else { return }
    let point = normalizedPoint(event)
    selection = CGRect(x: min(point.x, anchor.x), y: min(point.y, anchor.y),
      width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    guard anchor != nil else { return }
    mouseDragged(with: event)
    anchor = nil
    onEvent?("selection.drag_end")
    // As in the extension's snip overlay, releasing a drag submits it and a click or tiny drag cancels.
    if selectionMeetsMinimum(selection, in: imageRect) { confirm() } else { onCancel?() }
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 76: confirm()
    case 53: onCancel?()
    case 123, 124, 125, 126:
      let fitted = imageRect
      let dx: CGFloat = event.keyCode == 123 ? -1 / max(1, fitted.width) :
        (event.keyCode == 124 ? 1 / max(1, fitted.width) : 0)
      let dy: CGFloat = event.keyCode == 126 ? -1 / max(1, fitted.height) :
        (event.keyCode == 125 ? 1 / max(1, fitted.height) : 0)
      if event.modifierFlags.contains(.shift) {
        selection.size.width = max(1 / max(1, fitted.width), min(1 - selection.minX, selection.width + dx))
        selection.size.height = max(1 / max(1, fitted.height), min(1 - selection.minY, selection.height + dy))
        onEvent?("selection.keyboard_resize")
      } else {
        selection.origin.x = max(0, min(1 - selection.width, selection.minX + dx))
        selection.origin.y = max(0, min(1 - selection.height, selection.minY + dy))
        onEvent?("selection.keyboard_move")
      }
      needsDisplay = true
    default:
      // Selection owns keyboard input. Do not forward unknown keys to Chrome.
      onEvent?("selection.key_consumed")
    }
  }

  @objc func confirm() {
    let x = max(0, min(1, selection.minX))
    let y = max(0, min(1, selection.minY))
    let rect = NormalizedRect(x: x, y: y,
      width: min(1 - x, selection.width), height: min(1 - y, selection.height))
    guard rect.isValid else { return }
    onConfirm?(rect)
  }
}

final class Host: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {
  private var sessionId: String?
  private var panel: ExperimentPanel?
  private var previewPanel: ExperimentPanel?
  private var selectionView: SelectionView?
  private var cropImage: NSImage?
  private var answerView: NSTextView?
  private var answerScrollView: NSScrollView?
  private var scrollObserver: NSObjectProtocol?
  private var geometryTimer: Timer?
  private var followupField: NSTextField?
  private var followupEditor: InstrumentedFieldEditor?
  private var statusLabel: NSTextField?
  private var answerText = ""
  private var lastCopiedAnswer: String?
  private var answerTextSelected = false
  private var acceptingAnswer = false
  private var role = "none"
  private var monitor: Any?
  private var handshake = false
  private var shuttingDown = false
  private var lastPointerEventAt = 0.0
  private var pressedWindow: ExperimentPanel?
  private var pressedPointer = PressedPointerTracker()
  private var shield: PointerShield?
  private var liveResizing = false
  private var modifierFlags: NSEvent.ModifierFlags = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    installEditingMenu()
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown,
      .leftMouseUp, .leftMouseDragged, .rightMouseDown, .scrollWheel, .mouseMoved]) { [weak self] event in
      guard let self = self else { return event }
      if event.type == .flagsChanged {
        // Modifier names only, so leaked page modifier events can be matched to native presses.
        let surface = (event.window as? ExperimentPanel)?.telemetrySurface ?? "unknown"
        let current = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        for change in modifierTransitions(from: self.modifierFlags, to: current) {
          self.telemetry("\(surface).modifier_\(change)")
        }
        self.modifierFlags = current
        return event
      }
      let name: String
      switch event.type {
      case .keyDown: name = "key_down"
      case .keyUp: name = "key_up"
      case .leftMouseDown, .rightMouseDown: name = "pointer_down"
      case .leftMouseUp: name = "pointer_up"
      case .leftMouseDragged: name = "pointer_drag"
      case .scrollWheel: name = "scroll"
      default: name = "pointer_move"
      }
      let now = Date().timeIntervalSince1970
      let sampledPointer = name == "pointer_move" || name == "pointer_drag"
      if !sampledPointer || now - self.lastPointerEventAt > 0.25 {
        if sampledPointer { self.lastPointerEventAt = now }
        let surface = (event.window as? ExperimentPanel)?.telemetrySurface ?? "unknown"
        self.telemetry("\(surface).\(name)")
      }
      switch event.type {
      case .leftMouseDown:
        self.endPressTracking()
        self.pressedWindow = event.window as? ExperimentPanel
        if let panel = self.pressedWindow, panel.styleMask.contains(.resizable),
          isNearFrameEdge(NSEvent.mouseLocation, panel.frame) {
          // Raise before AppKit starts the live resize; mouse-up lowers it if no resize began.
          self.raiseShield(below: panel)
        }
        self.samplePressedPointer()
      case .leftMouseDragged: self.samplePressedPointer()
      case .leftMouseUp: self.endPressTracking()
      default: break
      }
      return event
    }
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      self?.sampleGeometry(source: "poll")
      // Nested tracking loops (text selection, buttons, title-bar drags) bypass the event monitor.
      self?.samplePressedPointer()
    }
    timer.tolerance = 0.02
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .eventTracking)
    geometryTimer = timer
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        while let data = try readFrame(FileHandle.standardInput) {
          let command = try parseCommand(data)
          DispatchQueue.main.async { self?.receive(command) }
        }
        DispatchQueue.main.async { self?.stop(reason: "transport.eof") }
      } catch {
        DispatchQueue.main.async { self?.stop(reason: "transport.rejected") }
      }
    }
  }

  private func installEditingMenu() {
    // A programmatically created AppKit app has no nib-provided Edit menu. Its key
    // equivalents are needed for the field editor's normal selection and clipboard actions.
    let mainMenu = NSMenu(title: "Main")
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    // Nil targets dispatch through the key panel's first-responder chain without activation.
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)
    NSApp.mainMenu = mainMenu
  }

  private func send(_ fields: [String: Any]) {
    guard !shuttingDown else { return }
    var value = fields
    value["version"] = 1
    do { try FileHandle.standardOutput.write(contentsOf: framed(value)) }
    catch { stop(reason: "transport.write_failed") }
  }

  private func currentInputSource() -> String {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
      let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "unknown" }
    return telemetryToken(Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String)
  }

  private func telemetry(_ event: String, frame: CGRect? = nil, scroll: CGRect? = nil,
    geometrySource: String? = nil, includeInputSource: Bool = false) {
    var value: [String: Any] = ["type": "telemetry", "event": event,
      "at": Date().timeIntervalSince1970 * 1000,
      "appActive": NSApp.isActive, "keyWindow": NSApp.keyWindow != nil]
    if let id = sessionId { value["sessionId"] = id }
    if let frame = frame, let metadata = geometryMetadata(frame) { value["frame"] = metadata }
    if let scroll = scroll, let metadata = geometryMetadata(scroll) { value["scroll"] = metadata }
    if value["frame"] != nil || value["scroll"] != nil { value["geometrySource"] = geometrySource }
    // An input-source identifier names the active keyboard layout or input method, never its text.
    if includeInputSource { value["inputSource"] = currentInputSource() }
    // Metadata only: no image pixels, answer text, follow-ups, key values, or clipboard data.
    if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
      try? FileHandle.standardError.write(contentsOf: bytes + Data([10]))
    }
    if handshake { send(value) }
  }

  func applicationDidBecomeActive(_ notification: Notification) { telemetry("app.active") }
  func applicationDidResignActive(_ notification: Notification) { telemetry("app.inactive") }
  private func surface(_ notification: Notification) -> String {
    (notification.object as? ExperimentPanel)?.telemetrySurface ?? "unknown"
  }
  func windowDidBecomeKey(_ notification: Notification) { telemetry("\(surface(notification)).key_acquired") }
  func windowDidResignKey(_ notification: Notification) { telemetry("\(surface(notification)).key_resigned") }
  func windowWillStartLiveResize(_ notification: Notification) {
    telemetry("\(surface(notification)).live_resize_begin")
    liveResizing = true
    if let window = notification.object as? ExperimentPanel { raiseShield(below: window) }
  }
  func windowDidEndLiveResize(_ notification: Notification) {
    sampleGeometry(source: "notification")
    liveResizing = false
    lowerShield()
    telemetry("\(surface(notification)).live_resize_end")
  }

  /// Orders the click-through shield beneath `window` when a panel appears, so that raising it later
  /// only changes its mouse handling: creating or ordering a screen-sized window in was too slow.
  private func placeShield(below window: ExperimentPanel) {
    guard let frame = (window.screen ?? NSScreen.main)?.frame else { return }
    let value = shield ?? {
      let panel = PointerShield(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)
      // Visually clear and non-opaque, so it cannot occlude Chrome, but a hit-test target when raised.
      panel.isOpaque = false
      panel.backgroundColor = NSColor(calibratedWhite: 0, alpha: 1 / 255)
      panel.ignoresMouseEvents = true
      panel.hasShadow = false
      panel.level = .floating
      panel.hidesOnDeactivate = false
      panel.isReleasedWhenClosed = false
      panel.animationBehavior = .none
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
      return panel
    }()
    shield = value
    if value.frame != frame { value.setFrame(frame, display: true) }
    value.order(.below, relativeTo: window.windowNumber)
  }

  private func raiseShield(below window: ExperimentPanel) {
    guard let value = shield else { return }
    if value.ignoresMouseEvents {
      value.ignoresMouseEvents = false
      telemetry("\(window.telemetrySurface).shield_raised")
    }
    value.order(.below, relativeTo: window.windowNumber)
  }

  private func lowerShield() {
    guard let value = shield, !value.ignoresMouseEvents else { return }
    value.ignoresMouseEvents = true
    telemetry("shield.lowered")
  }
  func windowDidMove(_ notification: Notification) {
    if let window = notification.object as? ExperimentPanel { sampleWindow(window, source: "notification") }
  }
  func windowDidResize(_ notification: Notification) {
    if let window = notification.object as? ExperimentPanel { sampleWindow(window, source: "notification") }
    sampleScroll(source: "notification")
  }
  func controlTextDidBeginEditing(_ notification: Notification) {
    telemetry("followup.edit_begin", includeInputSource: true)
  }
  func controlTextDidEndEditing(_ notification: Notification) { telemetry("followup.edit_end") }
  func controlTextDidChange(_ notification: Notification) { telemetry("followup.edited") }

  func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
    guard let field = followupField, (client as? NSTextField) === field else { return nil }
    if let editor = followupEditor { return editor }
    let editor = InstrumentedFieldEditor()
    editor.isFieldEditor = true
    editor.onEvent = { [weak self] event in
      self?.telemetry(event, includeInputSource: event.hasPrefix("followup.composition"))
    }
    editor.onPaste = { [weak self] in self?.followupPasted() }
    followupEditor = editor
    return editor
  }

  private func followupPasted() {
    guard let field = followupField else { return }
    // Compare in memory only: telemetry says whether the copied mock answer arrived, not what was pasted.
    let text = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
    guard let copied = lastCopiedAnswer else { telemetry("followup.paste_without_copy"); return }
    telemetry(containsIgnoringWhitespace(text, copied) ? "followup.paste_matches_copy" : "followup.paste_differs_from_copy")
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    guard let view = notification.object as? NSTextView, view === answerView else { return }
    let selected = view.selectedRange().length > 0
    guard selected != answerTextSelected else { return }
    answerTextSelected = selected
    telemetry(selected ? "answer.text_selected" : "answer.text_selection_cleared")
  }

  private func samplePressedPointer() {
    guard let window = pressedWindow else { return }
    guard NSEvent.pressedMouseButtons & 1 != 0, window.isVisible else { endPressTracking(); return }
    if let transition = pressedPointer.observe(inside: window.frame.contains(NSEvent.mouseLocation)) {
      telemetry("\(window.telemetrySurface).pressed_pointer_\(transition)")
    }
  }

  private func endPressTracking() {
    if let window = pressedWindow, pressedPointer.outside {
      telemetry("\(window.telemetrySurface).pressed_pointer_released_outside")
    }
    pressedWindow = nil
    pressedPointer.reset()
    if !liveResizing { lowerShield() }
  }

  private func beginGeometryObservation(_ window: ExperimentPanel, scroll: CGRect? = nil) {
    // Start after ordering/layout, so creation and center() are explicitly only a baseline.
    window.contentView?.layoutSubtreeIfNeeded()
    window.geometry.begin(frame: window.frame, scroll: scroll)
  }

  private func sampleWindow(_ window: ExperimentPanel, source: String) {
    guard window.isVisible else { return }
    let changes = window.geometry.observeFrame(window.frame)
    if changes.moved {
      telemetry("\(window.telemetrySurface).moved", frame: window.frame, geometrySource: source)
    }
    if changes.resized {
      telemetry("\(window.telemetrySurface).resized", frame: window.frame, geometrySource: source)
    }
  }

  private func sampleScroll(source: String) {
    guard let window = panel, window.telemetrySurface == "answer", window.isVisible,
      let bounds = answerScrollView?.contentView.bounds else { return }
    if window.geometry.observeScroll(bounds) {
      telemetry("answer.scroll_changed", scroll: bounds, geometrySource: source)
    }
  }

  private func sampleGeometry(source: String) {
    if let window = panel { sampleWindow(window, source: source) }
    if let window = previewPanel { sampleWindow(window, source: source) }
    sampleScroll(source: source)
  }

  private func receive(_ command: HostCommand) {
    switch command {
    case .hello:
      handshake = true
      send(["type": "hello", "pid": ProcessInfo.processInfo.processIdentifier])
      telemetry("host.ready")
    case .shutdown: stop(reason: "host.shutdown")
    default:
      guard handshake else { stop(reason: "protocol.handshake_required"); return }
      switch command {
      case .capture(let id, let bytes):
        // Inspect dimensions before requesting decoded pixels; input byte bounds alone do not bound memory.
        guard let source = CGImageSourceCreateWithData(bytes as CFData,
          [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetCount(source) == 1,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
          validImageDimensions(width.doubleValue, height.doubleValue),
          let decoded = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: false] as CFDictionary) else {
          stop(reason: "capture.image_rejected"); return
        }
        clearSession()
        sessionId = id
        showSelection(NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height)))
      case .answer(let id, let text, let done):
        guard id == sessionId, role == "answer", acceptingAnswer,
          answerText.utf16.count + text.utf16.count <= 1_000_000 else {
          telemetry("answer.stale_or_invalid"); return
        }
        answerText += text
        answerView?.string = answerText
        statusLabel?.stringValue = done ? "Mock answer complete" : "Streaming mock answer…"
        if done { acceptingAnswer = false }
        telemetry(done ? "answer.complete" : "answer.delta")
      case .reset(let id):
        guard id == sessionId else { telemetry("session.stale_reset"); return }
        telemetry("session.reset")
        clearSession()
      default: break
      }
    }
  }

  private func makePanel(title: String, size: NSSize, surface: String) -> ExperimentPanel {
    let value = ExperimentPanel(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
    value.telemetrySurface = surface
    value.title = title
    value.identifier = NSUserInterfaceItemIdentifier(title)
    value.level = .floating
    value.hidesOnDeactivate = false
    value.becomesKeyOnlyIfNeeded = false
    value.isReleasedWhenClosed = false
    value.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    value.acceptsMouseMovedEvents = true
    value.minSize = NSSize(width: surface == "answer" ? 560 : 450, height: 350)
    value.center()
    value.delegate = self
    return value
  }

  private func showSelection(_ image: NSImage) {
    role = "selection"
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
    let window = makePanel(title: "SnapScreen Phase 1 — Select region",
      size: NSSize(width: min(1100, screen.width - 60), height: min(760, screen.height - 80)), surface: "selection")
    let root = NSView()
    window.contentView = root
    let view = SelectionView()
    view.image = image
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setAccessibilityLabel("Frozen screenshot region selection")
    view.setAccessibilityRole(.image)
    view.onEvent = { [weak self] in self?.telemetry($0) }
    view.onCancel = { [weak self] in self?.cancel() }
    view.onConfirm = { [weak self] rect in self?.selected(rect) }
    root.addSubview(view)
    let hint = NSTextField(labelWithString: "Drag a region; releasing it asks. Keyboard: arrows move, Shift + arrows resize, Enter selects. Escape cancels.")
    hint.font = .systemFont(ofSize: 12)
    hint.maximumNumberOfLines = 3
    hint.lineBreakMode = .byWordWrapping
    hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let cancel = button("Cancel selection", #selector(cancel))
    let footer = NSStackView(views: [hint, cancel])
    footer.orientation = .horizontal
    footer.spacing = 10
    footer.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(footer)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: root.leadingAnchor), view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      view.topAnchor.constraint(equalTo: root.topAnchor), view.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
      footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
      footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
      footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
    ])
    panel = window
    selectionView = view
    telemetry("selection.will_show")
    window.makeKeyAndOrderFront(nil)
    placeShield(below: window)
    window.makeFirstResponder(view)
    beginGeometryObservation(window)
    telemetry("selection.shown", frame: window.frame, geometrySource: "baseline", includeInputSource: true)
  }

  private func button(_ title: String, _ selector: Selector) -> NSButton {
    let value = NSButton(title: title, target: self, action: selector)
    value.bezelStyle = .rounded
    value.setAccessibilityLabel(title)
    return value
  }

  private func selected(_ rect: NormalizedRect) {
    guard let id = sessionId, let image = selectionView?.image else { return }
    sampleGeometry(source: "close")
    telemetry("selection.confirmed")
    var imageRect = CGRect(origin: .zero, size: image.size)
    if let cgImage = image.cgImage(forProposedRect: &imageRect, context: nil, hints: nil) {
      let pixels = CGRect(x: rect.x * Double(cgImage.width), y: rect.y * Double(cgImage.height),
        width: rect.width * Double(cgImage.width), height: rect.height * Double(cgImage.height)).integral
      if let cropped = cgImage.cropping(to: pixels),
        let copy = CGContext(data: nil, width: cropped.width, height: cropped.height,
          bitsPerComponent: 8, bytesPerRow: cropped.width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        // CGImage.cropping may retain the full original backing store. Copy only selected pixels.
        copy.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        if let independent = copy.makeImage() {
          cropImage = NSImage(cgImage: independent, size: NSSize(width: independent.width, height: independent.height))
        }
      }
    }
    selectionView?.image = nil
    panel?.delegate = nil
    panel?.close()
    panel = nil
    selectionView = nil
    showAnswer()
    send(["type": "selected", "sessionId": id, "rect": rect.json])
  }

  private func showAnswer() {
    role = "answer"
    answerText = ""
    acceptingAnswer = true
    let window = makePanel(title: "SnapScreen Phase 1 — Mock answer", size: NSSize(width: 640, height: 520), surface: "answer")
    let root = NSView()
    window.contentView = root
    let status = NSTextField(labelWithString: "Waiting for extension mock answer…")
    status.font = .systemFont(ofSize: 12)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 350))
    text.isEditable = false
    text.isSelectable = true
    text.font = .systemFont(ofSize: 15)
    text.textContainerInset = NSSize(width: 12, height: 12)
    text.autoresizingMask = [.width]
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.textContainer?.widthTracksTextView = true
    text.setAccessibilityLabel("Mock answer text")
    text.delegate = self
    scroll.documentView = text
    let field = NSTextField()
    field.placeholderString = "Type a mock follow-up"
    field.setAccessibilityLabel("Follow-up question")
    field.delegate = self
    field.target = self
    field.action = #selector(submitFollowup)
    let ask = button("Ask mock follow-up", #selector(submitFollowup))
    let entry = NSStackView(views: [field, ask])
    entry.spacing = 8
    entry.orientation = .horizontal
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let controls = NSStackView(views: [button("Copy answer", #selector(copyAnswer)),
      button("Screenshot preview", #selector(showPreview)), button("Close", #selector(closeAnswer))])
    controls.spacing = 8
    controls.orientation = .horizontal
    let stack = NSStackView(views: [status, scroll, entry, controls])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
      scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
      entry.widthAnchor.constraint(equalTo: stack.widthAnchor),
      controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
      scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
    ])
    panel = window
    answerView = text
    answerScrollView = scroll
    scroll.contentView.postsBoundsChangedNotifications = true
    scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
      object: scroll.contentView, queue: .main) { [weak self] _ in
      self?.sampleScroll(source: "notification")
    }
    followupField = field
    statusLabel = status
    window.makeKeyAndOrderFront(nil)
    placeShield(below: window)
    // Do not focus the follow-up automatically; text entry is a separately measured action.
    window.makeFirstResponder(text)
    window.contentView?.layoutSubtreeIfNeeded()
    beginGeometryObservation(window, scroll: scroll.contentView.bounds)
    telemetry("answer.shown", frame: window.frame, scroll: scroll.contentView.bounds, geometrySource: "baseline",
      includeInputSource: true)
  }

  @objc private func submitFollowup() {
    guard let id = sessionId, let field = followupField else { return }
    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf16.count <= 4000, !acceptingAnswer else {
      telemetry("followup.rejected"); return
    }
    telemetry("followup.submitted", includeInputSource: true)
    field.stringValue = ""
    answerText = ""
    answerView?.string = ""
    acceptingAnswer = true
    statusLabel?.stringValue = "Waiting for mock follow-up…"
    send(["type": "followup", "sessionId": id, "text": value])
  }

  @objc private func copyAnswer() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(answerText, forType: .string)
    lastCopiedAnswer = answerText
    telemetry("answer.copied")
  }

  @objc private func showPreview() {
    guard let image = cropImage else { telemetry("preview.unavailable"); return }
    if let existing = previewPanel { existing.makeKeyAndOrderFront(nil); return }
    let window = makePanel(title: "SnapScreen Phase 1 — Screenshot preview", size: NSSize(width: 580, height: 420), surface: "preview")
    let imageView = NSImageView()
    imageView.image = image
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.setAccessibilityLabel("Selected screenshot preview")
    window.contentView = imageView
    previewPanel = window
    window.makeKeyAndOrderFront(nil)
    beginGeometryObservation(window)
    telemetry("preview.shown", frame: window.frame, geometrySource: "baseline")
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if sender === previewPanel {
      if let window = previewPanel { sampleWindow(window, source: "close") }
      telemetry("preview.closed", frame: sender.frame, geometrySource: "close")
      previewPanel?.delegate = nil
      previewPanel = nil
      return true
    }
    if role == "selection" { cancel() } else { closeAnswer() }
    return false
  }

  @objc private func cancel() {
    guard let id = sessionId else { return }
    sampleGeometry(source: "close")
    telemetry("selection.cancelled", frame: panel?.frame, geometrySource: "close")
    send(["type": "cancelled", "sessionId": id])
    clearSession()
  }

  @objc private func closeAnswer() {
    guard let id = sessionId else { return }
    sampleGeometry(source: "close")
    telemetry("answer.closed", frame: panel?.frame, geometrySource: "close")
    send(["type": "closed", "sessionId": id])
    clearSession()
  }

  private func clearSession() {
    lowerShield()
    liveResizing = false
    shield?.orderOut(nil)
    sampleGeometry(source: "close")
    if let preview = previewPanel {
      telemetry("preview.closed_with_parent", frame: preview.frame, geometrySource: "close")
    }
    if let observer = scrollObserver { NotificationCenter.default.removeObserver(observer) }
    scrollObserver = nil
    answerScrollView = nil
    panel?.delegate = nil
    previewPanel?.delegate = nil
    panel?.close()
    previewPanel?.close()
    panel = nil
    previewPanel = nil
    selectionView?.image = nil
    selectionView = nil
    cropImage = nil
    answerView?.string = ""
    answerView = nil
    followupField?.stringValue = ""
    followupField = nil
    followupEditor = nil
    statusLabel = nil
    answerText = ""
    lastCopiedAnswer = nil
    answerTextSelected = false
    acceptingAnswer = false
    sessionId = nil
    role = "none"
  }

  private func stop(reason: String) {
    guard !shuttingDown else { return }
    shuttingDown = true
    telemetry(reason)
    clearSession()
    if let monitor = monitor { NSEvent.removeMonitor(monitor) }
    geometryTimer?.invalidate()
    geometryTimer = nil
    NSApp.terminate(nil)
  }
}

if CommandLine.arguments.contains("--self-test") {
  do {
    let count = try runProtocolSelfTests()
    // The explicit self-test CLI mode is not a native-messaging connection.
    print("Native protocol self-test: \(count) checks passed")
    exit(0)
  } catch {
    fputs("Native protocol self-test failed: \(error)\n", stderr)
    exit(1)
  }
}

// A Chrome-launched executable owns every AppKit window. No app relay, IPC socket, or activation call.
signal(SIGPIPE, SIG_IGN)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let host = Host()
application.delegate = host
application.run()
