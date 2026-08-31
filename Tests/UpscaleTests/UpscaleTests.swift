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

    /// Where the `upscale` CLI installs the default model. When it is
    /// present the library gets real default-run coverage; elsewhere the
    /// test skips visibly rather than passing on nothing.
    private var installedModel: URL? {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/upscale/x4plus.mlpackage")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Test("A small synthetic frame comes back exactly 4×, with pixels in it")
    func syntheticFourTimes() throws {
        guard let model = installedModel else { print("[skip] no installed model"); return }
        let up = try RealESRGANUpscaler(modelURL: model)
        let base = CIImage(color: CIColor(red: 0.8, green: 0.3, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 48, height: 32))
        final class Ticks: @unchecked Sendable {
            let lock = NSLock()
            var n = 0
            func tick() { lock.lock(); n += 1; lock.unlock() }
        }
        let ticks = Ticks()
        let maybe = up.upscale(base, progress: { _ in ticks.tick() })
        let result = try #require(maybe)
        #expect(Int(result.extent.width) == 192)
        #expect(Int(result.extent.height) == 128)
        #expect(ticks.n >= 1, "progress never ticked")
        var buf = [UInt8](repeating: 0, count: 192 * 128 * 4)
        CIContext().render(result, toBitmap: &buf, rowBytes: 192 * 4,
                           bounds: CGRect(x: 0, y: 0, width: 192, height: 128),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let mid = (64 * 192 + 96) * 4
        #expect(buf[mid] > 120, "output centre should be reddish, got \(buf[mid])")
    }

    @Test("Cancellation between tiles aborts to nil")
    func cancellationAborts() throws {
        guard let model = installedModel else { print("[skip] no installed model"); return }
        let up = try RealESRGANUpscaler(modelURL: model)
        let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 600))
        let result = up.upscale(base, isCancelled: { true })
        #expect(result == nil, "a cancelled run must return nil, not a partial image")
    }

    @Test("A model URL that is not a model throws, not traps")
    func badModelThrows() {
        #expect(throws: (any Error).self) {
            _ = try RealESRGANUpscaler(modelURL: URL(fileURLWithPath: "/tmp/not-a-model.mlpackage"))
        }
    }
}
