//
//  CatalogAndTilingTests.swift
//  UpscaleTests
//
//  Created by David Sherlock on 2026.
//
//  The parts that need no model: where every model comes from and on what
//  terms, the tile grid, the tensor round trip and the colour match.
//

import CoreImage
import Foundation
import Testing
@testable import Upscale

@Suite("Catalogue")
struct CatalogueTests {

    @Test("Every model comes from an arraypress repository, pinned to a commit")
    func ownedAndPinned() {
        for model in UpscaleModel.allCases {
            #expect(model.repository.hasPrefix("arraypress/"), "\(model.rawValue) comes from \(model.repository)")
            #expect(model.revision.count == 40 && model.revision.allSatisfy(\.isHexDigit),
                    "\(model.rawValue) revision \(model.revision)")
            #expect(!model.path.isEmpty)
        }
    }

    @Test("The defaults the bake-off chose")
    func defaults() {
        #expect(UpscaleModel.default == .swinir)
        #expect(UpscaleModel.fast == .x4plus)
        #expect(UpscaleModel.detail == .adcsr)
        #expect(UpscaleModel.swinir.usesCoreAI && UpscaleModel.adcsr.usesCoreAI)
        #expect(!UpscaleModel.x4plus.usesCoreAI)
    }

    @Test("MangaJPEGLQ is a 1× Core AI clean-up model; the rest enlarge 4×")
    func scales() {
        // 2.0 ran the 1× model as 4× and `upscale --variant manga` segfaulted.
        #expect(UpscaleModel.manga.scale == 1)
        #expect(UpscaleModel.manga.usesCoreAI)
        #expect(UpscaleModel.manga.path.hasSuffix(".aimodel"))
        for model in UpscaleModel.allCases where model != .manga { #expect(model.scale == 4, "\(model.rawValue)") }
    }

    @Test("The factory runs a Core ML file on Core ML and refuses a Core ML 1× build")
    func factoryByFileType() async {
        // A 0.2-era `x4plus.mlpackage` must not reach the Core AI runner; a stale Core ML
        // manga build must fail with a message, not crash.
        await #expect(throws: UpscaleError.self) {
            _ = try await UpscaleModel.manga.upscaler(at: URL(fileURLWithPath: "/nonexistent/ESRGAN-MangaJPEGLQ.mlpackage"))
        }
        await #expect(throws: UpscaleError.self) {
            _ = try await UpscaleModel.x4plus.upscaler(at: URL(fileURLWithPath: "/nonexistent/x4plus.mlpackage"))
        }
    }

    @Test("Non-commercial and invented-detail models say so")
    func restrictions() {
        #expect(Set(UpscaleModel.allCases.filter(\.isNonCommercial)) == [.ultrasharp, .manga])
        #expect(UpscaleModel.ultrasharp.licence == "CC BY-NC-SA 4.0")
        #expect(UpscaleModel.allCases.filter(\.inventsDetail) == [.adcsr])
        #expect(!UpscaleModel.swinir.isNonCommercial && !UpscaleModel.swinir.inventsDetail)
    }
}

@Suite("Tiling")
struct TilingTests {

    @Test("Tiles cover the axis with at least the overlap between neighbours", arguments: [1, 100, 128, 129, 256, 1000, 4000])
    func origins(_ length: Int) {
        let tile = 128, overlap = 16
        let xs = Tiling.origins(length, tile: tile, overlap: overlap)
        #expect(xs.first == 0)
        if length > tile {
            #expect(xs.last == length - tile, "the last tile sits flush with the far edge")
            for (a, b) in zip(xs, xs.dropFirst()) { #expect(b - a <= tile - overlap && b > a) }
        } else {
            #expect(xs == [0])
        }
    }

    @Test("Overlapping tiles of one colour leave it unchanged at every seam")
    func noSeamDip() {
        // Four 8-px tiles of the same grey in a 2 × 2 grid overlapping by 4 px:
        // a wrong blend weight shows as a dip (or bump) along the seams.
        let canvas = TileCanvas(width: 12, height: 12)
        let tile = [UInt8](repeating: 0, count: 8 * 8 * 4).enumerated().map { $0.offset % 4 == 3 ? 255 : 128 }
        for (row, y) in [0, 4].enumerated() {
            for (column, x) in [0, 4].enumerated() {
                canvas.paint(tile.map(UInt8.init), size: 8, x: x, y: y, feather: 4, left: column > 0, bottom: row > 0)
            }
        }
        var bytes = [UInt8](repeating: 0, count: 12 * 12 * 4)
        CIContext().render(canvas.image(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!), toBitmap: &bytes,
                           rowBytes: 48, bounds: CGRect(x: 0, y: 0, width: 12, height: 12),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            #expect(abs(Int(bytes[i]) - 128) <= 1 && bytes[i + 3] == 255, "pixel \(i / 4): \(bytes[i]), alpha \(bytes[i + 3])")
        }
    }

    @Test("A later tile ramps in only on its painted sides, bottom-up coordinates")
    func ramps() {
        let canvas = TileCanvas(width: 8, height: 4)
        let black = [UInt8](repeating: 0, count: 4 * 4 * 4).enumerated().map { $0.offset % 4 == 3 ? 255 : 0 }
        let white = [UInt8](repeating: 255, count: 4 * 4 * 4)
        canvas.paint(black.map(UInt8.init), size: 4, x: 0, y: 0, feather: 4, left: false, bottom: false)
        canvas.paint(white, size: 4, x: 4, y: 0, feather: 4, left: true, bottom: false)
        var bytes = [UInt8](repeating: 0, count: 8 * 4 * 4)
        CIContext().render(canvas.image(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!), toBitmap: &bytes,
                           rowBytes: 32, bounds: CGRect(x: 0, y: 0, width: 8, height: 4),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let firstRow = (0..<8).map { bytes[$0 * 4] }
        #expect(firstRow[0...3].allSatisfy { $0 == 0 }, "the first tile is untouched: \(firstRow)")
        #expect(firstRow[4] < firstRow[5] && firstRow[5] < firstRow[6] && firstRow[6] < firstRow[7],
                "the second tile ramps in across its left edge: \(firstRow)")
    }
}

@Suite("Pixels and tensors")
struct TensorTests {

    @Test("Planar values round-trip in both ranges", arguments: [false, true])
    func roundTrip(_ signed: Bool) {
        let count = 4
        let rgba: [UInt8] = [0, 128, 255, 255, 10, 20, 30, 255, 200, 100, 50, 255, 1, 2, 3, 255]
        let planar = TileTensor.planar(rgba: rgba, count: count, signed: signed)
        #expect(planar.count == 3 * count)
        #expect(planar.min()! >= (signed ? -1 : 0) && planar.max()! <= 1)
        let back = TileTensor.rgba(planar: planar, count: count, signed: signed)
        for i in 0..<count { for c in 0..<3 { #expect(back[i * 4 + c] == rgba[i * 4 + c]) } }
    }

    @Test("Out-of-range model output is clamped, not wrapped")
    func clamps() {
        let back = TileTensor.rgba(planar: [-0.5, 1.5, 0.5], count: 1, signed: false)
        #expect(Array(back.prefix(3)) == [0, 255, 128])
    }

    @Test("The colour match maps one set of statistics onto another")
    func colourMatch() {
        // Source: channel 0 values 50 and 150 (mean 100, sd 50); target mean 120, sd 25.
        let source = [(mean: 100.0, deviation: 50.0), (mean: 0.0, deviation: 1.0), (mean: 0.0, deviation: 1.0)]
        let target = [(mean: 120.0, deviation: 25.0), (mean: 0.0, deviation: 1.0), (mean: 0.0, deviation: 1.0)]
        let map = ColourMatch.transfer(from: source, to: target)
        #expect(abs(map[0].gain - 0.5) < 1e-9)
        #expect(abs((50 * map[0].gain + map[0].bias * 255) - 95) < 1e-6, "50 → 120 − 25")
        let stats = ColourMatch.statistics(rgba: [50, 0, 0, 255, 150, 0, 0, 255])
        #expect(stats[0].mean == 100 && abs(stats[0].deviation - 50) < 1e-9)
    }
}

@Suite("Core AI upscaler")
struct CoreAIUpscalerTests {

    /// `$UPSCALE_SWINIR_MODEL`, or the copy the `upscale` tool installs.
    private var swinir: URL? {
        let named = ProcessInfo.processInfo.environment["UPSCALE_SWINIR_MODEL"].map { URL(fileURLWithPath: $0) }
        let installed = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/upscale/" + UpscaleModel.swinir.path)
        return [named, installed].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @Test("A Core ML model is refused by the Core AI runner")
    func refusesCoreML() async {
        await #expect(throws: UpscaleError.self) {
            _ = try await CoreAIUpscaler(model: .x4plus, url: URL(fileURLWithPath: "/nonexistent"))
        }
    }

    @Test("SwinIR-L: exactly 4×, colour kept, across tile seams")
    func swinirFourTimes() async throws {
        guard let url = swinir else { print("[skip] no SwinIR-L model; set UPSCALE_SWINIR_MODEL"); return }
        let upscaler = try await CoreAIUpscaler(model: .swinir, url: url)
        // 200 × 150 needs a 2 × 2 grid of 128-px tiles: seams in both directions.
        let source = CIImage(color: CIColor(red: 0.8, green: 0.3, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 150))
        let result = try #require(try await upscaler.upscale(source, isCancelled: nil, progress: nil))
        #expect(Int(result.extent.width) == 800 && Int(result.extent.height) == 600)
        var buffer = [UInt8](repeating: 0, count: 800 * 600 * 4)
        CIContext().render(result, toBitmap: &buffer, rowBytes: 800 * 4, bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        // A GAN upscaler adds faint grain even to a flat field: PyTorch's own
        // SwinIR-L turns (204, 77, 51) into a mean of (200.6, 77.1, 53.2) with a
        // mean deviation of 3.5/255 (this runner: 200.2, 77.2, 53.2 and 3.8).
        // So the colour must hold on average and the grain stay small.
        let expected: [Double] = [204, 77, 51]
        var sums = [Double](repeating: 0, count: 3), deviation = 0.0, n = 0.0
        for y in Swift.stride(from: 0, to: 600, by: 3) {
            for x in Swift.stride(from: 0, to: 800, by: 3) {
                let i = (y * 800 + x) * 4
                for c in 0..<3 {
                    sums[c] += Double(buffer[i + c])
                    deviation += abs(Double(buffer[i + c]) - expected[c]) / 3
                }
                n += 1
            }
        }
        for c in 0..<3 { #expect(abs(sums[c] / n - expected[c]) < 6, "channel \(c) mean \(sums[c] / n)") }
        #expect(deviation / n < 6, "mean deviation \(deviation / n)/255")
    }

    @Test("Cancelling between tiles returns nil")
    func cancels() async throws {
        guard let url = swinir else { print("[skip] no SwinIR-L model"); return }
        let upscaler = try await CoreAIUpscaler(model: .swinir, url: url)
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 300))
        let result = try await upscaler.upscale(source, isCancelled: { true }, progress: nil)
        #expect(result == nil)
    }
}
