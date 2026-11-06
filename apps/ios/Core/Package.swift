// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DiceCaptureCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "DiceCaptureCore", targets: ["DiceCaptureCore"])],
    targets: [.target(name: "DiceCaptureCore"), .testTarget(name: "DiceCaptureCoreTests", dependencies: ["DiceCaptureCore"])]
)
