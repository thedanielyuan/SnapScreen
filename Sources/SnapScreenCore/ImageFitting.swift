import CoreGraphics
import Foundation
import ImageIO

public enum ImageFittingError: Error, Equatable, Sendable {
  /// The normalized rectangle isn't finite or doesn't lie within the image.
  case invalidCrop
  /// After rounding to pixels, the rectangle covers no pixels of the image.
  case emptyCrop
  case unreadableImage
  case encodingFailed
}

// PNG size tracks pixel count only roughly, so an image over the byte limit can need a second,
// smaller pass.
private let maxFitPasses = 4

/// Crops a PNG to a rectangle given as fractions of its width and height from its top-left corner.
/// Edges are rounded to whole pixels of the decoded image.
public func cropImage(_ png: Data, normalizedRect rect: CGRect) throws -> Data {
  let values = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
  guard values.allSatisfy(\.isFinite), rect.origin.x >= 0, rect.origin.y >= 0, rect.size.width > 0,
    rect.size.height > 0, rect.origin.x + rect.size.width <= 1, rect.origin.y + rect.size.height <= 1 else {
    throw ImageFittingError.invalidCrop
  }
  let image = try decodePNG(png)
  // Rounding matches JavaScript's Math.round for these non-negative values.
  func edge(_ fraction: CGFloat, _ size: Int) -> Int {
    Int((Double(fraction) * Double(size)).rounded()).clamped(to: 0...size)
  }
  let left = edge(rect.origin.x, image.width)
  let top = edge(rect.origin.y, image.height)
  let right = edge(rect.origin.x + rect.size.width, image.width)
  let bottom = edge(rect.origin.y + rect.size.height, image.height)
  guard right > left, bottom > top,
    let cropped = image.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top)) else {
    throw ImageFittingError.emptyCrop
  }
  return try encodePNG(cropped)
}

/// Downscales a PNG that exceeds the edge or byte limit, so a large selection on a high-DPI screen
/// is sent at a lower resolution instead of being rejected. An image that already fits, can't be
/// decoded, or stays too large is returned unchanged, so request validation still reports it.
public func fitScreenshotToLimits(_ png: Data, limits: SnapScreenLimits) -> Data {
  fitScreenshotToLimits(png, maxBytes: limits.maxScreenshotBytes, maxDimension: limits.maxScreenshotDimension,
    encode: encodeScaledPNG)
}

func fitScreenshotToLimits(_ png: Data, maxBytes: Int, maxDimension: Int,
  encode: (CGImage, Int, Int) throws -> Data) -> Data {
  guard let metadata = try? inspectPNG(png) else { return png }
  let longestEdge = max(metadata.width, metadata.height)
  if metadata.bytes <= maxBytes && longestEdge <= maxDimension { return png }

  var scale = min(1, Double(maxDimension) / Double(longestEdge), byteScale(metadata.bytes, maxBytes))
  do {
    let image = try decodePNG(png)
    for _ in 0..<maxFitPasses {
      // Rounding keeps the longest edge exactly at the limit when scaling by edge.
      let scaled = try encode(image, max(1, Int((Double(image.width) * scale).rounded())),
        max(1, Int((Double(image.height) * scale).rounded())))
      if scaled.count <= maxBytes { return scaled }
      scale *= byteScale(scaled.count, maxBytes)
    }
  } catch {
    // Validation reports the original image's size or format instead.
  }
  return png
}

private func byteScale(_ bytes: Int, _ maxBytes: Int) -> Double {
  // Aims 10% under the limit, because PNG size isn't proportional to area.
  bytes > maxBytes ? (Double(maxBytes) / Double(bytes)).squareRoot() * 0.9 : 1
}

/// Fits every screenshot in a conversation, like `fitScreenshotToLimits`. History rebuilt after a
/// first answer is stopped or interrupted holds the full-size capture. History from a completed
/// answer already holds the fitted one, which passes through unchanged.
public func fitHistoryScreenshotsToLimits(_ history: [AnthropicMessage], limits: SnapScreenLimits)
  -> [AnthropicMessage] {
  history.map { message in
    guard case .blocks(let blocks) = message.content else { return message }
    var fitted = message
    fitted.content = .blocks(blocks.map { block in
      guard case .image(let png) = block else { return block }
      return .image(fitScreenshotToLimits(png, limits: limits))
    })
    return fitted
  }
}

func decodePNG(_ png: Data) throws -> CGImage {
  guard let source = CGImageSourceCreateWithData(png as CFData, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImageFittingError.unreadableImage }
  return image
}

func encodePNG(_ image: CGImage) throws -> Data {
  let data = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)
    else { throw ImageFittingError.encodingFailed }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { throw ImageFittingError.encodingFailed }
  return data as Data
}

/// Redraws the image at the given size with high-quality interpolation, in its own color space when
/// a bitmap can use it.
func encodeScaledPNG(_ image: CGImage, width: Int, height: Int) throws -> Data {
  let space = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
    ?? CGColorSpace(name: CGColorSpace.sRGB)!
  guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    throw ImageFittingError.encodingFailed
  }
  context.interpolationQuality = .high
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  guard let scaled = context.makeImage() else { throw ImageFittingError.encodingFailed }
  return try encodePNG(scaled)
}

private extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
