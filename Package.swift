// swift-tools-version: 6.0
import PackageDescription

// The standalone macOS app (docs/standalone-app-plan.md). scripts/build-app.sh bundles and signs it.
let package = Package(
  name: "SnapScreen",
  // scripts/build-app.sh writes the same minimum into the bundle's Info.plist.
  platforms: [.macOS(.v15)],
  targets: [
    // The API client, conversation state, limits and image fitting: Foundation, CoreGraphics and
    // ImageIO only, with no AppKit.
    .target(
      name: "SnapScreenCore",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .executableTarget(
      name: "SnapScreen",
      dependencies: ["SnapScreenCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "SnapScreenCoreTests",
      dependencies: ["SnapScreenCore"],
      resources: [.copy("Fixtures")],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
