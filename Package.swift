// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Upscale",
    // Core AI (SwinIR-L, AdcSR) arrived in the 27 SDKs.
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [.library(name: "Upscale", targets: ["Upscale"])],
    targets: [
        // NonisolatedNonsendingByDefault stays OFF: upscaling is seconds of
        // tile work in async calls, which must not run on a main-actor caller.
        .target(name: "Upscale"),
        .testTarget(name: "UpscaleTests", dependencies: ["Upscale"]),
    ]
)

// Swift 7's import rule, today: a file must import every module whose members
// it uses, rather than leaning on another file's imports.
for target in package.targets where target.type != .system && target.type != .binary && target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("MemberImportVisibility")]
}
