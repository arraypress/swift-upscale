//
//  Tiling.swift
//  Upscale
//
//  Created by David Sherlock on 2026.
//
//  Fixed-tile models see an image as a grid of overlapping tiles, painted in
//  scan order into a TileCanvas. Only the incoming tile ramps, and only on the
//  sides that face already-painted content (left and bottom): the blend is
//  tile·m + acc·(1−m) over full-weight pixels, so total weight is always 1.
//  Ramping both sides of a seam under-weighted the band (t + (1−t)² = 0.75 at
//  its centre), which showed as a 25% brightness dip along every seam.
//

import CoreImage

/// The tile grid and its seam masks.
enum Tiling {

    /// Tile origins along one axis: the fewest `tile`-wide tiles that keep at
    /// least `overlap` px shared with each neighbour, spread evenly — the first
    /// at 0, the last flush with the far edge.
    static func origins(_ length: Int, tile: Int, overlap: Int) -> [Int] {
        if length <= tile { return [0] }
        let step = tile - overlap
        let count = Int(ceil(Double(length - tile) / Double(step))) + 1
        return (0..<count).map { Int((Double($0) * Double(length - tile) / Double(count - 1)).rounded()) }
    }

    /// The image moved to the origin and cropped to whole pixels.
    static func normalised(_ image: CIImage) -> (image: CIImage, width: Int, height: Int)? {
        let extent = image.extent.integral
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else { return nil }
        let width = Int(extent.width), height = Int(extent.height)
        let moved = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return (moved, width, height)
    }

    /// One `tile`-square crop at `(x, y)`, edges extended, moved to the origin.
    static func crop(_ image: CIImage, x: Int, y: Int, tile: Int) -> CIImage {
        image.clampedToExtent()
            .cropped(to: CGRect(x: x, y: y, width: tile, height: tile))
            .transformed(by: CGAffineTransform(translationX: -CGFloat(x), y: -CGFloat(y)))
    }
}
