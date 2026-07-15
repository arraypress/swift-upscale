//
//  UpscaleTests.swift
//  UpscaleTests
//

import CoreImage
import Foundation
import Testing
@testable import Upscale

@Suite("Upscale")
struct UpscaleTests {

    private func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] }

    @Test("Tiled 4× upscale of a full frame",
          .enabled(if: ProcessInfo.processInfo.environment["UPSCALE_RENDER"] != nil))
    func upscaleRender() throws {
        guard let modelPath = env("UPSCALE_MODEL") else { print("[skip] set UPSCALE_MODEL"); return }
        let up = try RealESRGANUpscaler(modelURL: URL(fileURLWithPath: modelPath))
        let imgPath = env("UPSCALE_IMAGE") ?? (NSHomeDirectory() + "/Downloads/depth_frame.png")
        guard let full = CIImage(contentsOf: URL(fileURLWithPath: imgPath)) else { print("[skip] no image"); return }

        // Simulate a low-res source: downscale to ~540p so the 4× is meaningful
        // and the tiler runs a real grid (multiple tiles + seams to check).
        let scale = 540 / full.extent.height
        let low = full.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale]).cropped(to: full.extent.applying(CGAffineTransform(scaleX: scale, y: scale)))
        let W = Int(low.extent.width), H = Int(low.extent.height)

        let t0 = Date().timeIntervalSinceReferenceDate
        guard let result = up.upscale(low, progress: { p in if Int(p * 100) % 25 == 0 { print("  \(Int(p * 100))%") } }) else { Issue.record("no result"); return }
        let ms = (Date().timeIntervalSinceReferenceDate - t0) * 1000
        print("UPSCALE \(W)x\(H) → \(Int(result.extent.width))x\(Int(result.extent.height)) in \(Int(ms))ms")
        #expect(Int(result.extent.width) == W * 4)
        #expect(Int(result.extent.height) == H * 4)

        try CIContext().writePNGRepresentation(of: result,
                                               to: URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/upscale_swift.png"),
                                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        // bicubic reference at the same output size, for a seam/detail comparison
        let bic = low.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": 4.0])
        try CIContext().writePNGRepresentation(of: bic.cropped(to: result.extent),
                                               to: URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/upscale_bicubic.png"),
                                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        print("WROTE ~/Downloads/upscale_swift.png + upscale_bicubic.png")
    }
}
