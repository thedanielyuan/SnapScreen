import Foundation
import Testing
import SnapScreenCore

// Sends real requests with the production settings, so a retired model, beta header, or request
// field fails here before it fails in the app. Runs only when SNAPSCREEN_LIVE_API_KEY is set,
// because it spends API credit.
private let apiKey = ProcessInfo.processInfo.environment["SNAPSCREEN_LIVE_API_KEY"] ?? ""

@Suite(.enabled(if: !apiKey.isEmpty, "Set SNAPSCREEN_LIVE_API_KEY to call the real API"))
struct LiveAPITests {
  @Test(.timeLimit(.minutes(1)))
  func acceptsTheSettingsKeyCheck() async throws {
    try await AnthropicClient().verifyAPIKey(apiKey)
  }

  @Test(.timeLimit(.minutes(5)))
  func answersAScreenshotQuestionWithTheProductionRequest() async throws {
    let png = Data(base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    let answer = try await AnthropicClient().analyzeImage(apiKey: apiKey, image: png,
      userQuestion: "Reply with the single word OK.", limits: .defaults)
    #expect(!answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
}
