// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AgentMeter",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "MeterCore", linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "AgentMeter", dependencies: ["MeterCore"]),
    .testTarget(name: "MeterCoreTests", dependencies: ["MeterCore"]),
  ],
  swiftLanguageModes: [.v5]
)
