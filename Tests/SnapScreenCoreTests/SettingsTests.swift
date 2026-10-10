import Foundation
import Testing
@testable import SnapScreenCore

@Test func usesDefaultsForMissingSettings() {
  #expect(SessionSettings.normalized(storedPrompt: nil, storedLimits: nil) == .defaults)
  #expect(SessionSettings.defaults.defaultPrompt == "Answer the question shown in this screenshot.")
  #expect(SnapScreenLimits.defaults == SnapScreenLimits(maxInputCharacters: 4_000, maxScreenshotBytes: 5_000_000,
    maxScreenshotDimension: 2_576, maxConversationTurns: 12))
}

@Test func trimsTheSavedPromptAndReplacesABlankOne() {
  #expect(SessionSettings.normalized(storedPrompt: "\n\t", storedLimits: nil).defaultPrompt
    == SessionSettings.defaults.defaultPrompt)
  #expect(SessionSettings.normalized(storedPrompt: "  Be concise.  ", storedLimits: nil).defaultPrompt == "Be concise.")
  #expect(SessionSettings.normalized(storedPrompt: 42, storedLimits: nil).defaultPrompt
    == SessionSettings.defaults.defaultPrompt)
}

@Test func clampsCorruptedAndOutOfRangeLimits() {
  let limits = normalizeLimits(["maxInputCharacters": -1, "maxScreenshotBytes": Double.infinity,
    "maxScreenshotDimension": 99_999, "maxConversationTurns": 3.7] as [String: Any])
  #expect(limits == SnapScreenLimits(maxInputCharacters: 100, maxScreenshotBytes: 5_000_000,
    maxScreenshotDimension: 8_000, maxConversationTurns: 4))
}

@Test func ignoresLimitsThatAreNotNumbers() {
  #expect(normalizeLimits(["maxInputCharacters": true, "maxScreenshotBytes": "6000000",
    "maxConversationTurns": NSNull()] as [String: Any]) == .defaults)
  #expect(normalizeLimits([1, 2, 3]) == .defaults)
  #expect(normalizeLimits(nil) == .defaults)
}

@Test func clampsLimitsPassedToTheClient() {
  let limits = SnapScreenLimits(maxInputCharacters: 1, maxScreenshotBytes: 99_000_000, maxScreenshotDimension: 600,
    maxConversationTurns: 1).normalized
  #expect(limits == SnapScreenLimits(maxInputCharacters: 100, maxScreenshotBytes: 10_000_000,
    maxScreenshotDimension: 600, maxConversationTurns: 2))
}

@Test func savesAndLoadsSettings() throws {
  let suite = "SnapScreenCoreTests.\(UUID().uuidString)"
  let store = try #require(UserDefaults(suiteName: suite))
  defer { store.removePersistentDomain(forName: suite) }

  #expect(SessionSettings.load(from: store) == .defaults)
  SessionSettings.save(defaultPrompt: "Answer in French.", to: store)
  SessionSettings.save(limits: SnapScreenLimits(maxInputCharacters: 60_000, maxScreenshotBytes: 2_000_000,
    maxScreenshotDimension: 4_000, maxConversationTurns: 20), to: store)
  #expect(SessionSettings.load(from: store) == SessionSettings(defaultPrompt: "Answer in French.",
    limits: SnapScreenLimits(maxInputCharacters: 50_000, maxScreenshotBytes: 2_000_000, maxScreenshotDimension: 4_000,
      maxConversationTurns: 20)))
}
