// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CadenceCore",
    platforms: [.iOS(.v18), .watchOS(.v11), .macOS(.v15)],
    products: [.library(name: "TrainerProtocol", targets: ["TrainerProtocol"])],
    targets: [
        .target(name: "TrainerProtocol", path: "Shared"),
        .testTarget(name: "TrainerProtocolTests", dependencies: ["TrainerProtocol"], path: "Tests")
    ]
)
