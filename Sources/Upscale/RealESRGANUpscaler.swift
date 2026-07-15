//
//  RealESRGANUpscaler.swift
//  Upscale
//
//  Created by David Sherlock on 2026.
//

import CoreImage
import CoreML
import Foundation

/// Real-ESRGAN 4× super-resolution (BSD-3) on-device. The Core ML model has a
/// fixed 256×256 → 1024×1024 tile; `upscale` tiles an arbitrary image, runs each
/// tile 4×, and feather-blends the seams. Recovers real detail (hair, texture)
/// rather than just sharpening — the "AI upscale" look.
public final class RealESRGANUpscaler: @unchecked Sendable {

    /// The model's fixed magnification.
    public static let scale = 4
    static let tile = 256
    /// Overlap (input px) between neighbouring tiles, feather-blended to hide seams.
    static let overlap = 24

    private let model: MLModel
    private let ciContext: CIContext
    private let deviceRGB = CGColorSpaceCreateDeviceRGB()

    public init(modelURL: URL) throws {
        let url = modelURL.pathExtension == "mlmodelc" ? modelURL : try MLModel.compileModel(at: modelURL)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine   // ~25% faster than .all for this model
        model = try MLModel(contentsOf: url, configuration: cfg)
        ciContext = CIContext(options: [.cacheIntermediates: false])
    }

    /// Upscales `image` by 4×. `progress` reports 0…1 over the tile grid.
    /// Returns a CIImage 4× the input size (origin at 0,0).
    public func upscale(_ image: CIImage, progress: (@Sendable (Double) -> Void)? = nil) -> CIImage? {
        let ext = image.extent.integral
        guard ext.width >= 1, ext.height >= 1 else { return nil }
        let W = Int(ext.width), H = Int(ext.height), S = Self.scale, T = Self.tile
        let img = image
            .transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
            .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))

        let xs = origins(W), ys = origins(H)
        let total = xs.count * ys.count
        var done = 0
        let canvas = CGRect(x: 0, y: 0, width: W * S, height: H * S)
        var acc = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: canvas)

        for (yi, oy) in ys.enumerated() {
            for (xi, ox) in xs.enumerated() {
                let tileImg = img.clampedToExtent()
                    .cropped(to: CGRect(x: ox, y: oy, width: T, height: T))
                    .transformed(by: CGAffineTransform(translationX: -CGFloat(ox), y: -CGFloat(oy)))
                guard let up = predictTile(tileImg) else { return nil }
                let mask = blendMask(left: xi > 0, right: xi < xs.count - 1,
                                     bottom: yi > 0, top: yi < ys.count - 1)
                let shift = CGAffineTransform(translationX: CGFloat(ox * S), y: CGFloat(oy * S))
                acc = up.transformed(by: shift).applyingFilter("CIBlendWithMask", parameters: [
                    "inputBackgroundImage": acc,
                    "inputMaskImage": mask.transformed(by: shift),
                ]).cropped(to: canvas)
                done += 1
                progress?(Double(done) / Double(total))
            }
        }
        return acc
    }

    /// Tile origins along an axis: a clamped grid of 256-wide tiles stepping by
    /// (256 − overlap), the last tile flush to the far edge.
    private func origins(_ len: Int) -> [Int] {
        let T = Self.tile, step = Self.tile - Self.overlap
        if len <= T { return [0] }
        var o = [Int](), p = 0
        while p + T < len { o.append(p); p += step }
        o.append(len - T)
        return o
    }

    // MARK: - Single tile: CIImage 256² → Core ML → CIImage 1024²

    private func predictTile(_ tile: CIImage) -> CIImage? {
        let T = Self.tile, N = T * Self.scale
        guard let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: T), NSNumber(value: T)], dataType: .float32)
        else { return nil }

        var pixels = [UInt8](repeating: 0, count: T * T * 4)
        pixels.withUnsafeMutableBytes {
            ciContext.render(tile, toBitmap: $0.baseAddress!, rowBytes: T * 4,
                             bounds: CGRect(x: 0, y: 0, width: T, height: T),
                             format: .RGBA8, colorSpace: deviceRGB)
        }
        let ip = input.dataPointer.bindMemory(to: Float32.self, capacity: 3 * T * T)
        let plane = T * T
        for i in 0..<plane {
            ip[i] = Float32(pixels[i * 4 + 0]) / 255              // R
            ip[plane + i] = Float32(pixels[i * 4 + 1]) / 255      // G
            ip[2 * plane + i] = Float32(pixels[i * 4 + 2]) / 255  // B
        }

        guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "input": MLFeatureValue(multiArray: input),
        ])), let arr = out.featureValue(for: "output")?.multiArrayValue else { return nil }

        let plane2 = N * N
        var obuf = [UInt8](repeating: 255, count: plane2 * 4)
        readCHW(arr, plane: plane2) { i, r, g, b in
            obuf[i * 4 + 0] = r; obuf[i * 4 + 1] = g; obuf[i * 4 + 2] = b
        }
        return CIImage(bitmapData: Data(obuf), bytesPerRow: N * 4,
                       size: CGSize(width: N, height: N), format: .RGBA8, colorSpace: deviceRGB)
    }

    /// Reads a [1,3,N,N] output array (float32 or float16) as RGB bytes.
    private func readCHW(_ arr: MLMultiArray, plane: Int, _ store: (Int, UInt8, UInt8, UInt8) -> Void) {
        @inline(__always) func px(_ f: Float) -> UInt8 { UInt8(max(0, min(255, f * 255 + 0.5))) }
        switch arr.dataType {
        case .float32:
            let p = arr.dataPointer.bindMemory(to: Float32.self, capacity: 3 * plane)
            for i in 0..<plane { store(i, px(p[i]), px(p[plane + i]), px(p[2 * plane + i])) }
        case .float16:
            let p = arr.dataPointer.bindMemory(to: Float16.self, capacity: 3 * plane)
            for i in 0..<plane { store(i, px(Float(p[i])), px(Float(p[plane + i])), px(Float(p[2 * plane + i]))) }
        default:
            for i in 0..<plane {
                store(i, px(arr[i].floatValue), px(arr[plane + i].floatValue), px(arr[2 * plane + i].floatValue))
            }
        }
    }

    // MARK: - Feather mask (1024²), ramped only on sides that have a neighbour

    private func blendMask(left: Bool, right: Bool, bottom: Bool, top: Bool) -> CIImage {
        let N = CGFloat(Self.tile * Self.scale), f = CGFloat(Self.overlap * Self.scale)
        let full = CGRect(x: 0, y: 0, width: N, height: N)
        var mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: full)
        func ramp(_ p0: CGPoint, _ p1: CGPoint) {
            let g = CIFilter(name: "CILinearGradient")!
            g.setValue(CIVector(cgPoint: p0), forKey: "inputPoint0")
            g.setValue(CIVector(cgPoint: p1), forKey: "inputPoint1")
            g.setValue(CIColor(red: 0, green: 0, blue: 0), forKey: "inputColor0")
            g.setValue(CIColor(red: 1, green: 1, blue: 1), forKey: "inputColor1")
            guard let grad = g.outputImage?.cropped(to: full) else { return }
            mask = grad.applyingFilter("CIMultiplyCompositing", parameters: ["inputBackgroundImage": mask]).cropped(to: full)
        }
        if left { ramp(CGPoint(x: 0, y: 0), CGPoint(x: f, y: 0)) }
        if right { ramp(CGPoint(x: N, y: 0), CGPoint(x: N - f, y: 0)) }
        if bottom { ramp(CGPoint(x: 0, y: 0), CGPoint(x: 0, y: f)) }
        if top { ramp(CGPoint(x: 0, y: N), CGPoint(x: 0, y: N - f)) }
        return mask
    }
}
