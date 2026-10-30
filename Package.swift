// swift-tools-version: 6.2
import PackageDescription

/// The native engine for the platform: UIKit on iOS, AppKit on macOS, neither
/// on Linux.
let nativeEngines: [Target.Dependency] = [
  .target(name: "ComposerUIKit", condition: .when(platforms: [.iOS])),
  .target(name: "ComposerAppKit", condition: .when(platforms: [.macOS])),
]

let package = Package(
  name: "Composer",
  defaultLocalization: "en",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "ComposerCore", targets: ["ComposerCore"]),
    .library(name: "ComposerUIKit", targets: ["ComposerUIKit"]),
    .library(name: "ComposerAppKit", targets: ["ComposerAppKit"]),
    .library(name: "ComposerSwiftUI", targets: ["ComposerSwiftUI"]),
    .library(name: "ComposerStyled", targets: ["ComposerStyled"]),
    .library(name: "ComposerTesting", targets: ["ComposerTesting"]),
  ],
  dependencies: [
    // Test-only: snapshot tests of ComposerStyled.
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.7")
  ],
  targets: [
    // The String Catalog holds the VoiceOver labels of Core's plugins.
    .target(name: "ComposerCore", resources: [.process("Resources")]),
    // Internal: TextKit 2 shared by the UIKit and AppKit engines.
    .target(name: "ComposerTextKit", dependencies: ["ComposerCore"]),
    .target(name: "ComposerUIKit", dependencies: ["ComposerCore", "ComposerTextKit"]),
    .target(name: "ComposerAppKit", dependencies: ["ComposerCore", "ComposerTextKit"]),
    .target(name: "ComposerSwiftUI", dependencies: ["ComposerCore"] + nativeEngines),
    .target(
      name: "ComposerStyled", dependencies: ["ComposerCore", "ComposerSwiftUI"] + nativeEngines),
    // The session format and assertions build everywhere; the native session
    // drivers are Apple-only.
    .target(name: "ComposerTesting", dependencies: ["ComposerCore"] + nativeEngines),
    .testTarget(name: "ComposerCoreTests", dependencies: ["ComposerCore", "ComposerTesting"]),
    // Apple-only, and empty elsewhere: the conformance suite against real text
    // views, the performance budgets, the SwiftUI binding, and ComposerStyled's
    // snapshots.
    .testTarget(
      name: "ConformanceTests", dependencies: ["ComposerCore", "ComposerTesting"] + nativeEngines),
    .testTarget(
      name: "PerformanceTests", dependencies: ["ComposerCore", "ComposerTesting"] + nativeEngines),
    .testTarget(
      name: "ComposerSwiftUITests", dependencies: ["ComposerSwiftUI"] + nativeEngines),
    .testTarget(
      name: "StyledSnapshotTests",
      dependencies: [
        "ComposerStyled",
        .product(
          name: "SnapshotTesting", package: "swift-snapshot-testing",
          condition: .when(platforms: [.iOS, .macOS])),
      ]),
  ],
  swiftLanguageModes: [.v6]
)
