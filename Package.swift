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

// Swift 7's import rule, today: a file must import every module whose members
// it uses, rather than leaning on another file's imports.
for target in package.targets where target.type != .system && target.type != .binary && target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("MemberImportVisibility")]
}
