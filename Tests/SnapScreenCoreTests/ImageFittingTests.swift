import CoreGraphics
import Foundation
import Testing
@testable import SnapScreenCore

private func size(_ png: Data) throws -> (Int, Int) {
  let metadata = try inspectPNG(png)
  return (metadata.width, metadata.height)
}

@Test func cropsScaledBoundsFromTheTopLeft() throws {
  // Red in the bottom ten rows, so a crop from the top would come out blue.
  let source = makePNG(width: 200, height: 200) { _, y in y >= 190 ? (255, 0, 0) : (0, 0, 255) }
  let cropped = try cropImage(source, normalizedRect: CGRect(x: 0, y: 0.95, width: 0.15, height: 0.05))
  #expect(try size(cropped) == (30, 10))
  #expect(try pixel(cropped, x: 0, y: 0) == (255, 0, 0))
  #expect(try pixel(cropped, x: 29, y: 9) == (255, 0, 0))
}

@Test func roundsNormalizedBoundsToDecodedPixels() throws {
  let source = makePNG(width: 200, height: 200) { x, _ in x >= 101 && x < 121 ? (0, 255, 0) : (0, 0, 0) }
  let cropped = try cropImage(source, normalizedRect: CGRect(x: 0.505, y: 0.05, width: 0.1, height: 0.1))
  #expect(try size(cropped) == (20, 20))
  #expect(try pixel(cropped, x: 0, y: 0) == (0, 255, 0))
  #expect(try pixel(cropped, x: 19, y: 19) == (0, 255, 0))
}

@Test func mapsTheSameRegionWhateverThePixelDensity() throws {
  let source = makePNG(width: 1_600, height: 900) { x, y in x == 200 && y == 180 ? (255, 255, 0) : (0, 0, 0) }
  let cropped = try cropImage(source, normalizedRect: CGRect(x: 0.125, y: 0.2, width: 0.5, height: 0.4))
  #expect(try size(cropped) == (800, 360))
  #expect(try pixel(cropped, x: 0, y: 0) == (255, 255, 0))
}

@Test func cropsAFrozenScreenTheSameAsItsPNG() throws {
  let source = makePNG(width: 200, height: 200) { _, y in y >= 190 ? (255, 0, 0) : (0, 0, 255) }
  let rect = CGRect(x: 0, y: 0.95, width: 0.15, height: 0.05)
  #expect(try cropImage(decodePNG(source), normalizedRect: rect) == cropImage(source, normalizedRect: rect))
  #expect(throws: ImageFittingError.invalidCrop) {
    try cropImage(decodePNG(source), normalizedRect: CGRect(x: 0.9, y: 0, width: 0.2, height: 1))
  }
}

@Test func rejectsInvalidCropsBeforeDecoding() {
  let notAPNG = Data("not a png".utf8)
  for rect in [CGRect(x: 0, y: 0, width: 0, height: 0.2), CGRect(x: 0.9, y: 0.1, width: 0.2, height: 0.2),
    CGRect(x: -0.1, y: 0, width: 0.5, height: 0.5), CGRect(x: CGFloat.nan, y: 0, width: 0.5, height: 0.5)] {
    #expect(throws: ImageFittingError.invalidCrop) { try cropImage(notAPNG, normalizedRect: rect) }
  }
  #expect(throws: ImageFittingError.unreadableImage) {
    try cropImage(notAPNG, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
  }
}

@Test func rejectsACropThatRoundsToNoPixels() {
  let source = makePNG(width: 10, height: 10)
  #expect(throws: ImageFittingError.emptyCrop) {
    try cropImage(source, normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0.01, height: 0.01))
  }
}

private let limits = SnapScreenLimits.defaults

@Test func returnsAScreenshotWithinBothLimitsUnchanged() {
  // A header only, so decoding it would fail.
  let header = pngHeader(width: 2_576, height: 1_000, bytes: 1_000)
  #expect(fitScreenshotToLimits(header, limits: limits) == header)
}

@Test func downscalesACaptureWhoseLongEdgeExceedsTheLimit() throws {
  let fitted = fitScreenshotToLimits(makePNG(width: 2_880, height: 1_800), limits: limits)
  #expect(try size(fitted) == (2_576, 1_610))
}

@Test func shrinksAgainUntilTheEncodedPNGFits() throws {
  let encoded = Locked<[(Int, Int)]>([])
  // Four times the byte limit, so the first pass scales by √¼ × 0.9 = 0.45. Decoders ignore the padding.
  let png = makePNG(width: 2_000, height: 1_000)
  let padded = png + Data(count: 40_000 - png.count)
  let sizes = [15_000, 8_000]
  let fitted = fitScreenshotToLimits(padded, maxBytes: 10_000, maxDimension: 2_576) { _, width, height in
    let pass = encoded.withLock { passes in
      passes.append((width, height))
      return passes.count - 1
    }
    return Data(count: sizes[pass])
  }
  #expect(fitted.count == 8_000)
  #expect(encoded.current.map { [$0.0, $0.1] } == [[900, 450], [661, 331]])
}

@Test func returnsTheOriginalWhenItCannotGetUnderTheByteLimit() {
  let passes = Locked(0)
  let original = makePNG(width: 2_000, height: 1_000) + Data(count: 4_000)
  let fitted = fitScreenshotToLimits(original, maxBytes: 1_000, maxDimension: 2_576) { _, _, _ in
    passes.withLock { $0 += 1 }
    return Data(count: 5_000)
  }
  #expect(fitted == original)
  #expect(passes.current == 4)
}

@Test func returnsTheOriginalWhenItCannotBeDecoded() {
  let header = pngHeader(width: 2_880, height: 1_800, bytes: 1_000)
  #expect(fitScreenshotToLimits(header, limits: limits) == header)
  let notAPNG = Data("SOURCE".utf8)
  #expect(fitScreenshotToLimits(notAPNG, limits: limits) == notAPNG)
}

@Test func fitsOnlyOversizeScreenshotsInHistory() throws {
  let fitting = pngHeader(width: 2_576, height: 1_000, bytes: 1_000)
  let history: [AnthropicMessage] = [
    AnthropicMessage(role: .user, content: .blocks([.image(makePNG(width: 2_880, height: 1_800)), .text("Guidance")])),
    .assistant("Answer"),
    AnthropicMessage(role: .user, content: .blocks([.image(fitting)])),
  ]
  let fitted = fitHistoryScreenshotsToLimits(history, limits: limits)
  guard case .blocks(let first) = fitted[0].content, case .image(let png) = first[0] else {
    Issue.record("The screenshot turn lost its image")
    return
  }
  #expect(try size(png) == (2_576, 1_610))
  #expect(first[1] == .text("Guidance"))
  #expect(fitted[1] == history[1])
  #expect(fitted[2] == history[2])
}
