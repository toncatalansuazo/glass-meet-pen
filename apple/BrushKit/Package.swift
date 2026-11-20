// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BrushKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BrushKit", targets: ["BrushKit"]),
    ],
    targets: [
        .target(name: "BrushKit"),
        .testTarget(name: "BrushKitTests", dependencies: ["BrushKit"]),
    ]
)
