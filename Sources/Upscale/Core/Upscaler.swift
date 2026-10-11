//
//  Upscaler.swift
//  Upscale
//
//  Created by David Sherlock on 2026.
//

import CoreImage

/// Anything that enlarges a picture 4×, tile by tile.
public protocol Upscaler: Sendable {

    /// The fixed magnification.
    var scale: Int { get }

    /// The picture 4× larger, origin at (0, 0); `nil` when `isCancelled`
    /// returned `true` between tiles. `progress` reports 0…1 over the tiles.
    func upscale(_ image: CIImage,
                 isCancelled: (@Sendable () -> Bool)?,
                 progress: (@Sendable (Double) -> Void)?) async throws(UpscaleError) -> CIImage?
}
