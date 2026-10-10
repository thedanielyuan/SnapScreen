import Foundation

/// A limit's allowed range and default value.
public struct LimitConstraint: Sendable {
  public let min: Int
  public let max: Int
  public let defaultValue: Int

  func clamped(_ value: Int) -> Int { Swift.min(max, Swift.max(min, value)) }
}

/// The advanced limits in Settings.
public struct SnapScreenLimits: Codable, Equatable, Sendable {
  public var maxInputCharacters: Int
  public var maxScreenshotBytes: Int
  public var maxScreenshotDimension: Int
  public var maxConversationTurns: Int

  public init(maxInputCharacters: Int, maxScreenshotBytes: Int, maxScreenshotDimension: Int,
    maxConversationTurns: Int) {
    self.maxInputCharacters = maxInputCharacters
    self.maxScreenshotBytes = maxScreenshotBytes
    self.maxScreenshotDimension = maxScreenshotDimension
    self.maxConversationTurns = maxConversationTurns
  }

  public static let inputCharacters = LimitConstraint(min: 100, max: 50_000, defaultValue: 4_000)
  /// Anthropic's direct API accepts at most 10 MB per base64 image.
  public static let screenshotBytes = LimitConstraint(min: 1_000_000, max: 10_000_000, defaultValue: 5_000_000)
  /// 2,576 px is Opus 5.5's native long edge; 8,000 px is the API ceiling.
  public static let screenshotDimension = LimitConstraint(min: 512, max: 8_000, defaultValue: 2_576)
  public static let conversationTurns = LimitConstraint(min: 2, max: 50, defaultValue: 12)

  public static let defaults = SnapScreenLimits(
    maxInputCharacters: inputCharacters.defaultValue,
    maxScreenshotBytes: screenshotBytes.defaultValue,
    maxScreenshotDimension: screenshotDimension.defaultValue,
    maxConversationTurns: conversationTurns.defaultValue)

  /// Each limit clamped to its allowed range.
  public var normalized: SnapScreenLimits {
    SnapScreenLimits(
      maxInputCharacters: Self.inputCharacters.clamped(maxInputCharacters),
      maxScreenshotBytes: Self.screenshotBytes.clamped(maxScreenshotBytes),
      maxScreenshotDimension: Self.screenshotDimension.clamped(maxScreenshotDimension),
      maxConversationTurns: Self.conversationTurns.clamped(maxConversationTurns))
  }

  var dictionary: [String: Int] {
    ["maxInputCharacters": maxInputCharacters, "maxScreenshotBytes": maxScreenshotBytes,
     "maxScreenshotDimension": maxScreenshotDimension, "maxConversationTurns": maxConversationTurns]
  }
}

/// Reads stored limits. A missing, non-numeric or non-finite value takes its default, and any
/// other value is rounded and clamped to its range.
public func normalizeLimits(_ value: Any?) -> SnapScreenLimits {
  let stored = value as? [String: Any] ?? [:]
  return SnapScreenLimits(
    maxInputCharacters: normalizeInteger(stored["maxInputCharacters"], SnapScreenLimits.inputCharacters),
    maxScreenshotBytes: normalizeInteger(stored["maxScreenshotBytes"], SnapScreenLimits.screenshotBytes),
    maxScreenshotDimension: normalizeInteger(stored["maxScreenshotDimension"], SnapScreenLimits.screenshotDimension),
    maxConversationTurns: normalizeInteger(stored["maxConversationTurns"], SnapScreenLimits.conversationTurns))
}

private func normalizeInteger(_ value: Any?, _ constraint: LimitConstraint) -> Int {
  // Booleans bridge to NSNumber, but they aren't numbers.
  guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
    number.doubleValue.isFinite else { return constraint.defaultValue }
  return Int(min(Double(constraint.max), max(Double(constraint.min), number.doubleValue.rounded())))
}

/// The settings a capture keeps for its whole conversation. The API key is stored separately, in
/// the Keychain.
public struct SessionSettings: Equatable, Sendable {
  public var defaultPrompt: String
  public var limits: SnapScreenLimits

  public init(defaultPrompt: String, limits: SnapScreenLimits) {
    self.defaultPrompt = defaultPrompt
    self.limits = limits
  }

  public static let defaults = SessionSettings(
    defaultPrompt: "Answer the question shown in this screenshot.", limits: .defaults)

  private static let defaultPromptKey = "defaultPrompt"
  private static let limitsKey = "limits"

  /// The saved settings, with defaults for anything missing or invalid.
  public static func load(from store: UserDefaults = .standard) -> SessionSettings {
    normalized(storedPrompt: store.object(forKey: defaultPromptKey), storedLimits: store.object(forKey: limitsKey))
  }

  static func normalized(storedPrompt: Any?, storedLimits: Any?) -> SessionSettings {
    let prompt = (storedPrompt as? String)?.jsTrimmed ?? ""
    return SessionSettings(defaultPrompt: prompt.isEmpty ? defaults.defaultPrompt : prompt,
      limits: normalizeLimits(storedLimits))
  }

  public static func save(defaultPrompt: String, to store: UserDefaults = .standard) {
    store.set(defaultPrompt, forKey: defaultPromptKey)
  }

  public static func save(limits: SnapScreenLimits, to store: UserDefaults = .standard) {
    store.set(limits.normalized.dictionary, forKey: limitsKey)
  }
}
