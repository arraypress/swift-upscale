//
//  TileCanvas.swift
//  Upscale
//
//  Created by David Sherlock on 2026.
//
//  The upscaled picture, painted tile by tile straight into one RGBA8 buffer.
//  Up to 2.0 each tile was a Core Image blend over the whole canvas, so the
//  final render evaluated one nested blend per tile for every pixel: fine for
//  100 tiles, minutes and gigabytes for the ~950 of a 12 MP photo. Here a tile
//  costs the same whatever the canvas size, and the picture is made once.
//
//  The seams follow Tiling's rule: only the incoming tile ramps, from 0 to 1
//  over `feather` px, on the sides facing already-painted tiles (left and
//  bottom in scan order), so the total weight is always 1.
//

import CoreImage
import Foundation

/// An RGBA8 picture assembled from fixed-size tiles.
final class TileCanvas {

    let width: Int
    let height: Int
    private let pixels: UnsafeMutablePointer<UInt8>

    /// A transparent canvas `width` × `height`.
    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = .allocate(capacity: width * height * 4)
        pixels.initialize(repeating: 0, count: width * height * 4)
    }

    deinit { pixels.deallocate() }

    /// Paints a `size`² tile — RGBA8, top row first, as Core Image renders
    /// and as the models return — with its bottom-left corner at
    /// (`x`, `y`) in Core Image's bottom-up canvas coordinates.
    func paint(_ tile: [UInt8], size: Int, x: Int, y: Int, feather: Int, left: Bool, bottom: Bool) {
        let f = Float(max(1, feather))
        // Canvas row (top first) of the tile's top row.
        let topRow = height - y - size
        tile.withUnsafeBufferPointer { source in
            for ty in 0..<size {
                let row = topRow + ty
                guard row >= 0, row < height else { continue }
                // Distance from the tile's bottom edge, at the pixel centre.
                let fromBottom = Float(size - 1 - ty) + 0.5
                let vertical: Float = bottom ? min(1, fromBottom / f) : 1
                for tx in 0..<size {
                    let column = x + tx
                    guard column >= 0, column < width else { continue }
                    let horizontal: Float = left ? min(1, (Float(tx) + 0.5) / f) : 1
                    let m = vertical * horizontal
                    let s = (ty * size + tx) * 4, d = (row * width + column) * 4
                    if m >= 1 {
                        pixels[d] = source[s]; pixels[d + 1] = source[s + 1]
                        pixels[d + 2] = source[s + 2]; pixels[d + 3] = source[s + 3]
                    } else {
                        for c in 0..<4 {
                            let blended = Float(source[s + c]) * m + Float(pixels[d + c]) * (1 - m)
                            pixels[d + c] = UInt8(max(0, min(255, blended + 0.5)))
                        }
                    }
                }
            }
        }
    }

    /// The finished picture. The canvas hands its buffer over without a copy.
    func image(colorSpace: CGColorSpace) -> CIImage {
        let count = width * height * 4
        let copy = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        copy.copyMemory(from: pixels, byteCount: count)
        let data = Data(bytesNoCopy: copy, count: count, deallocator: .custom { pointer, _ in pointer.deallocate() })
        return CIImage(bitmapData: data, bytesPerRow: width * 4,
                       size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: colorSpace)
    }
}
