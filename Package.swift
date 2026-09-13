// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FloraMail",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FloraCore", targets: ["FloraCore"]),
        .executable(name: "FloraMail", targets: ["FloraMail"])
    ],
    targets: [
        .target(name: "FloraCore"),
        .executableTarget(name: "FloraMail", dependencies: ["FloraCore"]),
        .executableTarget(name: "FloraLocalAICheck", dependencies: ["FloraCore"], path: "Tools/LocalAICheck"),
        .testTarget(name: "FloraCoreTests", dependencies: ["FloraCore"]),
        .testTarget(name: "FloraMailTests", dependencies: ["FloraMail", "FloraCore"])
    ]
)
