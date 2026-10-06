import AppKit

/// Keep native actions reachable with Tab even when macOS Full Keyboard Access is off.
final class CompanionButton: NSButton {
  override var acceptsFirstResponder: Bool { isEnabled }
  override var canBecomeKeyView: Bool {
    isEnabled && !isHiddenOrHasHiddenAncestor && window != nil
  }
}
