import Foundation
import Testing
@testable import SnapScreenCore

private let limits = SnapScreenLimits(maxInputCharacters: 4_000, maxScreenshotBytes: 5 * megabyte,
  maxScreenshotDimension: 2_576)

private func code(_ body: () throws -> Void) -> RequestLimitError.Code? { thrownError(RequestLimitError.self, body)?.code }

@Test func countsCodePointsAndAcceptsTheExactBoundary() throws {
  #expect(countTextCharacters("A🙂B") == 3)
  #expect(countTextCharacters("e\u{301}") == 2)
  try assertUserInputWithinLimit("A🙂B", maxCharacters: 3)
}

@Test func reportsInputOverflowWithGroupedNumbers() {
  let error = thrownError(RequestLimitError.self) {
    try assertUserInputWithinLimit(String(repeating: "x", count: 4_001), maxCharacters: 4_000, label: "Default Prompt")
  }
  #expect(error == RequestLimitError(.inputTooLong,
    "Default Prompt is 4,001 characters. The current limit is 4,000. Shorten it or raise the limit in Settings."))
  #expect(code { try assertUserInputWithinLimit(" \u{FEFF}\n", maxCharacters: 10) } == .inputEmpty)
}

@Test func readsPNGSizeAndDimensions() throws {
  #expect(try inspectPNG(pngHeader(width: 800, height: 600, bytes: 30))
    == ScreenshotMetadata(bytes: 30, width: 800, height: 600))
  #expect(try inspectPNG(pixelPNG) == ScreenshotMetadata(bytes: 68, width: 1, height: 1))
}

@Test func acceptsExactScreenshotBoundaries() throws {
  var exact = limits
  exact.maxScreenshotBytes = 30
  try assertScreenshotWithinLimits(pngHeader(width: 2_576, height: 2_576, bytes: 30), limits: exact)
}

@Test func reportsScreenshotSizeAndDimensionOverflowSeparately() {
  var small = limits
  small.maxScreenshotBytes = 30
  #expect(code { try assertScreenshotWithinLimits(pngHeader(width: 100, height: 100, bytes: 31), limits: small) }
    == .screenshotTooLarge)
  let error = thrownError(RequestLimitError.self) {
    try assertScreenshotWithinLimits(pngHeader(width: 2_577, height: 100), limits: limits)
  }
  #expect(error == RequestLimitError(.screenshotDimensionsTooLarge,
    "The screenshot is 2,577 × 100 px. The current edge limit is 2,576 px. Select a smaller region or raise the limit in Settings."))
}

@Test func formatsMegabytesLikeJavaScript() {
  #expect(formatMegabytes(5_000_000) == "5")
  #expect(formatMegabytes(5_500_000) == "5.5")
  // Exact halves round up, as toFixed does.
  #expect(formatMegabytes(5_250_000) == "5.3")
  #expect(formatMegabytes(1_250_000) == "1.3")
  #expect(formatMegabytes(750_000) == "0.8")
  // 1.15 is stored just below the half, so it rounds down in both languages.
  #expect(formatMegabytes(1_150_000) == "1.1")
  #expect(formatMegabytes(9_999_999) == "10.0")
}

@Test func rejectsDataThatIsNotAPNG() {
  #expect(code { _ = try inspectPNG(Data("ABC".utf8)) } == .screenshotInvalid)
  #expect(code { _ = try inspectPNG(Data()) } == .screenshotInvalid)
  #expect(code { _ = try inspectPNG(pngHeader(width: 0, height: 10)) } == .screenshotInvalid)
}
