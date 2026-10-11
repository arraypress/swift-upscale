//
//  CoreAIUpscaler.swift
//  Upscale
//
//  Created by David Sherlock on 2026.
//
//  The Core AI upscalers — SwinIR-L (the default) and AdcSR (opt-in, invents
//  detail) — share one runner: a fixed 128-px tile, 4× out, painted in scan
//  order with ramped seams straight into one buffer (Support/TileCanvas). Measured for SwinIR-L: the tile
//  size with the lowest cost per new pixel was 128 (24.9 µs, against 26.9 at
//  256 and 29.0 at 192); float16 matches PyTorch float32 at 66–68 dB PSNR.
//

import CoreAI
import CoreImage
import Foundation

/// A Core AI super-resolution model run over a tile grid.
public actor CoreAIUpscaler: Upscaler {

    /// Which model this runs.
    public nonisolated let model: UpscaleModel
    public nonisolated let scale = 4

    /// Input px shared between neighbouring tiles, feather-blended.
    static let overlap = 16

    private let function: InferenceFunction
    private let tile: Int
    private let inputName: String
    private let outputName: String
    private let halfPrecision: Bool
    private let signed: Bool
    private let colourMatch: Bool
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Loads `model`'s asset from `url` onto the GPU.
    ///
    /// - Throws: ``UpscaleError/modelUnavailable(_:)`` when `model` is not a
    ///   Core AI model or the asset will not load.
    public init(model: UpscaleModel, url: URL) async throws(UpscaleError) {
        guard case let .coreAI(tile, input, output, half, signed, colourMatch) = ModelCatalog.record(model).engine else {
            throw .modelUnavailable("\(model.rawValue) is a Core ML model; use RealESRGANUpscaler")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw .modelUnavailable("no model at \(url.path)")
        }
        do {
            let loaded = try await AIModel(contentsOf: url, options: SpecializationOptions(preferredComputeUnitKind: .gpu))
            guard let function = try loaded.loadFunction(named: "main") else {
                throw UpscaleError.modelUnavailable("\(url.lastPathComponent) has no main function")
            }
            self.function = function
        } catch let error as UpscaleError {
            throw error
        } catch {
            throw .modelUnavailable("\(url.lastPathComponent): \(error)")
        }
        self.model = model
        self.tile = tile
        self.inputName = input
        self.outputName = output
        self.halfPrecision = half
        self.signed = signed
        self.colourMatch = colourMatch
    }

    public func upscale(_ image: CIImage,
                        isCancelled: (@Sendable () -> Bool)? = nil,
                        progress: (@Sendable (Double) -> Void)? = nil) async throws(UpscaleError) -> CIImage? {
        guard let (source, width, height) = Tiling.normalised(image) else { return nil }
        let size = tile * scale
        let bounds = CGRect(x: 0, y: 0, width: width * scale, height: height * scale)
        let xs = Tiling.origins(width, tile: tile, overlap: Self.overlap)
        let ys = Tiling.origins(height, tile: tile, overlap: Self.overlap)
        let total = xs.count * ys.count
        let canvas = TileCanvas(width: width * scale, height: height * scale)
        var done = 0
        for (row, y) in ys.enumerated() {
            for (column, x) in xs.enumerated() {
                if isCancelled?() == true || Task.isCancelled { return nil }
                let upscaled = try await run(Tiling.crop(source, x: x, y: y, tile: tile))
                canvas.paint(upscaled, size: size, x: x * scale, y: y * scale,
                             feather: Self.overlap * scale, left: column > 0, bottom: row > 0)
                done += 1
                progress?(Double(done) / Double(total))
            }
        }
        let picture = canvas.image(colorSpace: space)
        return colourMatch ? matched(picture, to: source, bounds: bounds) : picture
    }

    /// One tile: CIImage `tile`² → tensor → model → RGBA8 (`tile`·4)², top row first.
    private func run(_ crop: CIImage) async throws(UpscaleError) -> [UInt8] {
        let count = tile * tile
        var bytes = [UInt8](repeating: 0, count: count * 4)
        bytes.withUnsafeMutableBytes {
            context.render(crop, toBitmap: $0.baseAddress!, rowBytes: tile * 4,
                           bounds: CGRect(x: 0, y: 0, width: tile, height: tile),
                           format: .RGBA8, colorSpace: space)
        }
        let values = TileTensor.planar(rgba: bytes, count: count, signed: signed)
        let shape = [1, 3, tile, tile]
        let input = halfPrecision
            ? NDArray(scalars: values.map { Float16($0) }, shape: shape)
            : NDArray(scalars: values, shape: shape)
        let outCount = count * scale * scale
        let result: [Float]
        do {
            var outputs = try await function.run(inputs: [inputName: input])
            guard let array = outputs.remove(outputName)?.ndArray else {
                throw UpscaleError.inference("the model returned no \(outputName)")
            }
            result = try Self.floats(array, count: 3 * outCount)
        } catch let error as UpscaleError {
            throw error
        } catch {
            throw .inference("\(error)")
        }
        return TileTensor.rgba(planar: result, count: outCount, signed: signed)
    }

    /// An output array's values as Float, whatever its precision.
    private static func floats(_ array: NDArray, count: Int) throws(UpscaleError) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        switch array.scalarType {
        case .float16:
            array.view(as: Float16.self).withUnsafePointer { pointer, _, _ in
                for i in 0..<count { out[i] = Float(pointer[i]) }
            }
        case .float32:
            array.view(as: Float.self).withUnsafePointer { pointer, _, _ in
                out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: pointer, count: count) }
            }
        default:
            throw .inference("unexpected output precision \(array.scalarType)")
        }
        return out
    }

    /// `upscaled` with each channel's mean and spread matched to a plain
    /// Lanczos resize of the source — how AdcSR was measured.
    private func matched(_ upscaled: CIImage, to source: CIImage, bounds: CGRect) -> CIImage {
        let reference = source.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": Double(scale)])
            .cropped(to: bounds)
        let sample = 512
        func stats(_ image: CIImage) -> [(mean: Double, deviation: Double)] {
            let small = image.applyingFilter("CILanczosScaleTransform",
                                             parameters: ["inputScale": Double(sample) / max(bounds.width, bounds.height)])
            let w = max(1, Int(small.extent.width)), h = max(1, Int(small.extent.height))
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            bytes.withUnsafeMutableBytes {
                context.render(small, toBitmap: $0.baseAddress!, rowBytes: w * 4,
                               bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: space)
            }
            return ColourMatch.statistics(rgba: bytes)
        }
        let map = ColourMatch.transfer(from: stats(upscaled), to: stats(reference))
        // The statistics are sRGB bytes; CIColorMatrix works in the linear
        // working space. Leave it for sRGB, apply the map, come back.
        guard let encoded = upscaled.matchedFromWorkingSpace(to: space) else { return upscaled }
        let corrected = encoded.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(map[0].gain), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(map[1].gain), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(map[2].gain), w: 0),
            "inputBiasVector": CIVector(x: CGFloat(map[0].bias), y: CGFloat(map[1].bias), z: CGFloat(map[2].bias), w: 0),
        ])
        return (corrected.matchedToWorkingSpace(from: space) ?? corrected).cropped(to: bounds)
    }
}
