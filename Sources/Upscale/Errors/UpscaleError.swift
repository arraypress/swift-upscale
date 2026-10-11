//
//  UpscaleError.swift
//  Upscale
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What can go wrong upscaling.
public enum UpscaleError: Error, LocalizedError, Sendable, Equatable {

    /// The model is missing, unreadable, or not the kind this upscaler runs.
    case modelUnavailable(String)

    /// A tile failed to run or came back in a shape it should not have.
    case inference(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let why): return "the upscaling model could not be loaded: \(why)"
        case .inference(let why): return "upscaling failed: \(why)"
        }
    }
}
