//
//  ModelCatalog.swift
//  Upscale
//
//  Created by David Sherlock on 2026.
//
//  Where each upscaler is published and on what terms. Every model is fetched
//  from an arraypress repository pinned to a commit: the Core ML builds once
//  came from a third party's mirror, which labelled two CC BY-NC-SA models
//  BSD-3. The licences here are the authors' own. The four 4× ESRGAN models
//  stay Core ML: Core AI exports from the authors' weights matched them (63–73 dB)
//  but ran 1.5–1.7× slower on an M3 Max (x4plus 6.6 s vs 4.0 s for 1024→4096).
//  MangaJPEGLQ is Core AI — exported from bunzero's 1×, greyscale original.
//

/// One model's publication record.
struct ModelRecord: Sendable {
    let repository: String
    let revision: String
    /// The model folder inside the repository.
    let path: String
    let licence: String
    let approximateMegabytes: Int
    let nonCommercial: Bool
    let inventsDetail: Bool
    let summary: String
    /// How the model runs.
    let engine: UpscaleEngine
}

/// The runtime a model needs.
enum UpscaleEngine: Sendable, Equatable {
    /// A Core ML package with a fixed 256 → 1024 tile.
    case coreML
    /// A Core AI asset with a fixed tile and magnification; input and output
    /// names; pixels in `[-1, 1]` when `signed`, else `[0, 1]`; `colourMatch`
    /// corrects each channel's mean and spread to a plain resize of the source
    /// afterwards.
    case coreAI(tile: Int, scale: Int, input: String, output: String, halfPrecision: Bool, signed: Bool, colourMatch: Bool)
}

/// The publication records.
enum ModelCatalog {

    static let realesrgan = (repository: "arraypress/upscale-realesrgan",
                             revision: "34c71b5fd20656423aaadb6ab59d7a836c12bce7")
    static let nonCommercial = (repository: "arraypress/upscale-nc",
                                revision: "57e8f83d745a23d2ea8b7396e8993fcdb2c2fd1c")

    static func record(_ model: UpscaleModel) -> ModelRecord {
        switch model {
        case .swinir:
            return ModelRecord(
                repository: "arraypress/upscale-swinir-l-real", revision: swinirRevision,
                path: "swinir-l-real-x4-128-float16.aimodel", licence: "Apache-2.0",
                approximateMegabytes: 59, nonCommercial: false, inventsDetail: false,
                summary: "the default — faithful detail; best fidelity in the bake-off",
                engine: .coreAI(tile: 128, scale: 4, input: "x", output: "output", halfPrecision: true, signed: false, colourMatch: false))
        case .x4plus:
            return coreML("RealESRGAN-x4plus.mlpackage", 33, "the fast option — about 5–10× quicker, a little painterly")
        case .x4v3:
            return coreML("RealESRGAN-x4v3.mlpackage", 3, "small and fast; slightly softer")
        case .x4v3Denoise:
            return coreML("RealESRGAN-x4v3-denoise.mlpackage", 3, "x4v3 that also removes noise and JPEG blocks")
        case .ultrasharp:
            return coreML("RealESRGAN-UltraSharp.mlpackage", 33, "crisper edges; can look etched", nc: true)
        case .manga:
            // MangaJPEGLQ is 1×: it cleans JPEG blocks out of greyscale manga and line
            // art without enlarging. Up to 2.0 it was run as if it were 4× and crashed
            // (`upscale --variant manga`, exit 139).
            return esrgan("ESRGAN-MangaJPEGLQ.aimodel", 10, "cleans JPEG blocks out of manga and line art (1×, greyscale)",
                          nc: true, scale: 1)
        case .adcsr:
            return ModelRecord(
                repository: "arraypress/upscale-adcsr", revision: "3a65b94017d263a35328528a6359456ae06f6182",
                path: "adcsr_x4_float32.aimodel", licence: "Apache-2.0 + CreativeML Open RAIL++-M",
                approximateMegabytes: 1825, nonCommercial: false, inventsDetail: true,
                summary: "adds detail that was not in the original — for generated or casual pictures, not photos you need to trust",
                engine: .coreAI(tile: 128, scale: 4, input: "lr", output: "sr", halfPrecision: false, signed: true, colourMatch: true))
        }
    }

    /// The SwinIR-L repository commit the asset was published at.
    static let swinirRevision = "5f65a3473ee5febe885c6cb267adcf5ba1dc5d65"

    private static func coreML(_ path: String, _ megabytes: Int, _ summary: String, nc: Bool = false) -> ModelRecord {
        let home = nc ? nonCommercial : realesrgan
        return ModelRecord(repository: home.repository, revision: home.revision, path: path,
                           licence: nc ? "CC BY-NC-SA 4.0" : "BSD-3-Clause",
                           approximateMegabytes: megabytes, nonCommercial: nc, inventsDetail: false,
                           summary: summary, engine: .coreML)
    }

    /// An ESRGAN-family model, exported to Core AI from its authors' weights with
    /// SwinIR-L's contract: `x` in, `output` out, [0, 1] RGB, a 256-px tile.
    private static func esrgan(_ path: String, _ megabytes: Int, _ summary: String,
                               nc: Bool = false, scale: Int = 4) -> ModelRecord {
        let home = nc ? nonCommercial : realesrgan
        return ModelRecord(repository: home.repository, revision: home.revision, path: path,
                           licence: nc ? "CC BY-NC-SA 4.0" : "BSD-3-Clause",
                           approximateMegabytes: megabytes, nonCommercial: nc, inventsDetail: false,
                           summary: summary,
                           engine: .coreAI(tile: 256, scale: scale, input: "x", output: "output",
                                           halfPrecision: true, signed: false, colourMatch: false))
    }
}
