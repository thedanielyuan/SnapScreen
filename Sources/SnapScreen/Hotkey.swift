import AppKit
import Carbon.HIToolbox

/// A global shortcut, registered with Carbon's RegisterEventHotKey. Unlike a key event monitor, it
/// needs no Accessibility or Input Monitoring permission: SnapScreen receives this one key
/// combination and nothing else that's typed.
final class Hotkey {
  struct Combination: Equatable {
    let keyCode: UInt32
    /// Carbon modifier flags, such as `controlKey`.
    let modifiers: UInt32
    /// How menus write it, such as ⌃⌥⇧S.
    let display: String
    let menuKey: String
    let menuModifiers: NSEvent.ModifierFlags

    /// ⌃⌥⇧S, because ⌥⇧S stays the Chrome extension's until the app replaces it
    /// (Phase 5 of docs/standalone-app-plan.md).
    static let snip = Combination(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey | shiftKey),
      display: "⌃⌥⇧S", menuKey: "s", menuModifiers: [.control, .option, .shift])
  }

  let combination: Combination
  var onPress: (() -> Void)?
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let id: UInt32
  private static let signature: OSType = 0x534E_5053 // "SNPS"
  private static var nextID: UInt32 = 1

  init(_ combination: Combination) {
    self.combination = combination
    id = Self.nextID
    Self.nextID += 1
  }

  deinit { unregister() }

  /// Returns false when another app already has the combination.
  func register() -> Bool {
    guard hotKey == nil else { return true }
    var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    guard InstallEventHandler(GetApplicationEventTarget(), handleHotkeyEvent, 1, &pressed,
      Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr else { return false }
    // Exclusive, so a combination another app already registered fails instead of being shared.
    guard RegisterEventHotKey(combination.keyCode, combination.modifiers, EventHotKeyID(signature: Self.signature, id: id),
      GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey) == noErr else {
      unregister()
      return false
    }
    return true
  }

  func unregister() {
    if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
    if let handler = handler { RemoveEventHandler(handler) }
    hotKey = nil
    handler = nil
  }

  fileprivate func handle(_ event: EventRef) -> OSStatus {
    var received = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
      nil, MemoryLayout<EventHotKeyID>.size, nil, &received)
    // Another Hotkey's combination passes on to its own handler.
    guard status == noErr, received.signature == Self.signature, received.id == id else {
      return OSStatus(eventNotHandledErr)
    }
    onPress?()
    return noErr
  }
}

private func handleHotkeyEvent(_ next: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?) -> OSStatus {
  guard let event = event, let context = context else { return OSStatus(eventNotHandledErr) }
  return Unmanaged<Hotkey>.fromOpaque(context).takeUnretainedValue().handle(event)
}
