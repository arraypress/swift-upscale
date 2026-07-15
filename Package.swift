// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Upscale",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "Upscale", targets: ["Upscale"])],
    targets: [
        .target(name: "Upscale"),
        .testTarget(name: "UpscaleTests", dependencies: ["Upscale"]),
    ]
)
