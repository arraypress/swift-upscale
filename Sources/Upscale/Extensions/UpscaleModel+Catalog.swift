//
//  UpscaleModel+Catalog.swift
//  Upscale
//
//  Created by David Sherlock on 2026.
//

import Foundation

public extension UpscaleModel {

    /// The faithful default.
    static let `default`: UpscaleModel = .swinir
    /// The fast option.
    static let fast: UpscaleModel = .x4plus
    /// The opt-in that adds detail.
    static let detail: UpscaleModel = .adcsr

    /// The Hugging Face repository the model is published in.
    var repository: String { ModelCatalog.record(self).repository }
    /// The repository commit the model is pinned to.
    var revision: String { ModelCatalog.record(self).revision }
    /// The model folder inside the repository — also its installed name.
    var path: String { ModelCatalog.record(self).path }
    /// The model's licence, as its authors give it.
    var licence: String { ModelCatalog.record(self).licence }
    /// The download, roughly.
    var approximateMegabytes: Int { ModelCatalog.record(self).approximateMegabytes }
    /// `true` for models whose licence forbids commercial use.
    var isNonCommercial: Bool { ModelCatalog.record(self).nonCommercial }
    /// `true` for models that add detail the source did not have.
    var inventsDetail: Bool { ModelCatalog.record(self).inventsDetail }
    /// What it is for, in a phrase.
    var summary: String { ModelCatalog.record(self).summary }
    /// `true` when the model runs on Core AI (macOS 27 / iOS 27).
    var usesCoreAI: Bool { ModelCatalog.record(self).engine != .coreML }

    /// The magnification: 4, or 1 for a clean-up model (``manga``) that does
    /// not enlarge — run one of those before a 4× model.
    var scale: Int {
        if case let .coreAI(_, scale, _, _, _, _, _) = ModelCatalog.record(self).engine { return scale }
        return 4
    }

    /// The runner for a model file, chosen by what the file IS rather than by
    /// the catalogue: an `.aimodel` runs on ``CoreAIUpscaler``; an `.mlpackage`
    /// or `.mlmodelc` installed by 2.0 or earlier still runs on
    /// ``RealESRGANUpscaler`` (×4 ESRGAN builds only).
    func upscaler(at url: URL) async throws(UpscaleError) -> any Upscaler {
        switch url.pathExtension {
        case "mlpackage", "mlmodelc", "mlmodel":
            guard scale == 4 else {
                throw .modelUnavailable("\(url.lastPathComponent) is a Core ML build of a 1× model; fetch the Core AI asset")
            }
            do { return try RealESRGANUpscaler(modelURL: url) } catch {
                throw .modelUnavailable("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        default:
            return try await CoreAIUpscaler(model: self, url: url)
        }
    }
}
