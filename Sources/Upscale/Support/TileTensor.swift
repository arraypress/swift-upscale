//
//  TileTensor.swift
//  Upscale
//
//  Created by David Sherlock on 2026.
//
//  Pixels to a model's planar tensor and back. The models want [1, 3, T, T]
//  with each channel a plane, in [0, 1] or [-1, 1]; images are interleaved
//  RGBA bytes.
//

/// Planar tensor values from interleaved RGBA bytes.
enum TileTensor {

    /// `[R plane, G plane, B plane]` from RGBA8, mapped to `[0, 1]`, or to
    /// `[-1, 1]` when `signed`.
    static func planar(rgba: [UInt8], count: Int, signed: Bool) -> [Float] {
        var out = [Float](repeating: 0, count: 3 * count)
        let scale: Float = signed ? 2.0 / 255.0 : 1.0 / 255.0
        let offset: Float = signed ? -1 : 0
        for i in 0..<count {
            out[i] = Float(rgba[i * 4]) * scale + offset
            out[count + i] = Float(rgba[i * 4 + 1]) * scale + offset
            out[2 * count + i] = Float(rgba[i * 4 + 2]) * scale + offset
        }
        return out
    }

    /// RGBA8 (opaque) from planar values in `[0, 1]`, or `[-1, 1]` when
    /// `signed`, clamped.
    static func rgba(planar values: [Float], count: Int, signed: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: 4 * count)
        @inline(__always) func byte(_ v: Float) -> UInt8 {
            let unit: Float = signed ? (v + 1) / 2 : v
            return UInt8(max(0, min(255, unit * 255 + 0.5)))
        }
        for i in 0..<count {
            out[i * 4] = byte(values[i])
            out[i * 4 + 1] = byte(values[count + i])
            out[i * 4 + 2] = byte(values[2 * count + i])
        }
        return out
    }
}
