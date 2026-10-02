// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AgentMeter",
  platforms: [.macOS(.v14)],
  dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")],
  targets: [
    .target(name: "MeterCore", linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(
      name: "AgentMeter", dependencies: ["MeterCore", .product(name: "Sparkle", package: "Sparkle")]),
    .testTarget(name: "MeterCoreTests", dependencies: ["MeterCore"]),
  ],
  swiftLanguageModes: [.v5]
)
