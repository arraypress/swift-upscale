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
    // Scratch reused across tiles (a 1080p frame runs ~45 tiles; fresh buffers
    // per tile were ~380MB of transient allocations per frame).
    private var pixelScratch = [UInt8](repeating: 0, count: RealESRGANUpscaler.tile * RealESRGANUpscaler.tile * 4)
    private lazy var inputScratch: MLMultiArray? = try? MLMultiArray(
        shape: [1, 3, NSNumber(value: Self.tile), NSNumber(value: Self.tile)], dataType: .float32)

    public init(modelURL: URL) throws {
        let url = try Self.compiledURL(for: modelURL)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine   // ~25% faster than .all for this model
        model = try MLModel(contentsOf: url, configuration: cfg)
        ciContext = CIContext(options: [.cacheIntermediates: false])
    }

    /// Compiles once and caches in Caches/ keyed by name + mtime — compiling
    /// the .mlpackage on every init cost seconds of startup per session.
    static func compiledURL(for modelURL: URL) throws -> URL {
        if modelURL.pathExtension == "mlmodelc" { return modelURL }
        let fm = FileManager.default
        let mtime = (try? fm.attributesOfItem(atPath: modelURL.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let dir = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("swift-upscale/CompiledModels", isDirectory: true)
        let dst = dir.appendingPathComponent("\(modelURL.deletingPathExtension().lastPathComponent)-\(Int(mtime)).mlmodelc")
        if fm.fileExists(atPath: dst.path) { return dst }
        let compiled = try MLModel.compileModel(at: modelURL)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: dst)
        try fm.moveItem(at: compiled, to: dst)
        return dst
    }

    /// Upscales `image` by 4×. `progress` reports 0…1 over the tile grid;
    /// `isCancelled` is polled between tiles — return true to abort (nil out).
    /// Returns a CIImage 4× the input size (origin at 0,0).
    public func upscale(_ image: CIImage,
                        isCancelled: (@Sendable () -> Bool)? = nil,
                        progress: (@Sendable (Double) -> Void)? = nil) -> CIImage? {
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
                if isCancelled?() == true { return nil }
                let tileImg = img.clampedToExtent()
                    .cropped(to: CGRect(x: ox, y: oy, width: T, height: T))
                    .transformed(by: CGAffineTransform(translationX: -CGFloat(ox), y: -CGFloat(oy)))
                guard let up = predictTile(tileImg) else { return nil }
                // Sequential paint-over: ONLY the incoming tile ramps, and only
                // on sides facing already-painted content (left/bottom in this
                // scan order) — the blend is then tile·m + acc·(1−m) over
                // full-weight pixels, total weight ≡ 1. Ramping BOTH sides of a
                // seam under-weighted the band (t + (1−t)² = 0.75 at center),
                // which showed up as a 25% alpha/brightness dip along seams.
                let mask = blendMask(left: xi > 0, right: false,
                                     bottom: yi > 0, top: false)
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

    /// Tile origins along an axis: the minimum number of 256-wide tiles whose
    /// spacing keeps at least `overlap` px shared with each neighbour, spread
    /// evenly (first at 0, last flush to the far edge). Even spacing avoids the
    /// old stepping grid's lopsided last pair (up to a near-duplicate tile).
    private func origins(_ len: Int) -> [Int] {
        let T = Self.tile, step = Self.tile - Self.overlap
        if len <= T { return [0] }
        let n = Int(ceil(Double(len - T) / Double(step))) + 1
        return (0..<n).map { Int((Double($0) * Double(len - T) / Double(n - 1)).rounded()) }
    }

    // MARK: - Single tile: CIImage 256² → Core ML → CIImage 1024²

    private func predictTile(_ tile: CIImage) -> CIImage? {
        let T = Self.tile, N = T * Self.scale
        guard let input = inputScratch else { return nil }

        pixelScratch.withUnsafeMutableBytes {
            ciContext.render(tile, toBitmap: $0.baseAddress!, rowBytes: T * 4,
                             bounds: CGRect(x: 0, y: 0, width: T, height: T),
                             format: .RGBA8, colorSpace: deviceRGB)
        }
        let plane = T * T
        pixelScratch.withUnsafeBufferPointer { pixels in
            let ip = input.dataPointer.bindMemory(to: Float32.self, capacity: 3 * plane)
            for i in 0..<plane {
                ip[i] = Float32(pixels[i * 4 + 0]) / 255              // R
                ip[plane + i] = Float32(pixels[i * 4 + 1]) / 255      // G
                ip[2 * plane + i] = Float32(pixels[i * 4 + 2]) / 255  // B
            }
        }

        guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "input": MLFeatureValue(multiArray: input),
        ])), let arr = out.featureValue(for: "output")?.multiArrayValue else { return nil }

        let plane2 = N * N
        var obuf = [UInt8](repeating: 255, count: plane2 * 4)
        readCHW(arr, n: N) { i, r, g, b in
            obuf[i * 4 + 0] = r; obuf[i * 4 + 1] = g; obuf[i * 4 + 2] = b
        }
        // The Data copy is what CIImage retains — obuf itself dies here, so
        // the per-tile transient is one 4MB buffer, not two.
        return CIImage(bitmapData: Data(obuf), bytesPerRow: N * 4,
                       size: CGSize(width: N, height: N), format: .RGBA8, colorSpace: deviceRGB)
    }

    /// Reads a [1,3,N,N] output array (float32 or float16) as RGB bytes,
    /// honoring the array's strides (ANE-backed outputs may be padded).
    private func readCHW(_ arr: MLMultiArray, n: Int, _ store: (Int, UInt8, UInt8, UInt8) -> Void) {
        @inline(__always) func px(_ f: Float) -> UInt8 { UInt8(max(0, min(255, f * 255 + 0.5))) }
        let sChan = arr.strides[1].intValue, sRow = arr.strides[2].intValue, sCol = arr.strides[3].intValue
        func run(_ at: (Int) -> Float) {
            var i = 0
            for y in 0..<n {
                let row = y * sRow
                for x in 0..<n {
                    let o = row + x * sCol
                    store(i, px(at(o)), px(at(sChan + o)), px(at(2 * sChan + o)))
                    i += 1
                }
            }
        }
        switch arr.dataType {
        case .float32:
            let p = arr.dataPointer.bindMemory(to: Float32.self, capacity: 3 * sChan)
            run { Float(p[$0]) }
        case .float16:
            let p = arr.dataPointer.bindMemory(to: Float16.self, capacity: 3 * sChan)
            run { Float(p[$0]) }
        default:
            let plane = n * n
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
