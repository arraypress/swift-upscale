//
//  ColourMatch.swift
//  Upscale
//
//  Created by David Sherlock on 2026.
//
//  AdcSR's raw output drifts in colour; its asset says the host must correct
//  it. The bake-off that chose it measured it with this correction: each
//  channel's mean and spread matched to a plain resize of the source
//  (AdaIN-style), one linear map per channel for the whole picture.
//

/// Per-channel statistics and the linear map between two sets of them.
enum ColourMatch {

    /// Mean and standard deviation of each RGB channel of RGBA8 pixels,
    /// reading every `stride`-th pixel.
    static func statistics(rgba: [UInt8], stride: Int = 1) -> [(mean: Double, deviation: Double)] {
        var sum = [Double](repeating: 0, count: 3), squares = [Double](repeating: 0, count: 3)
        var n = 0.0
        var i = 0
        let pixels = rgba.count / 4
        while i < pixels {
            for c in 0..<3 {
                let v = Double(rgba[i * 4 + c])
                sum[c] += v
                squares[c] += v * v
            }
            n += 1
            i += max(1, stride)
        }
        return (0..<3).map { c in
            let mean = n > 0 ? sum[c] / n : 0
            let variance = n > 0 ? max(0, squares[c] / n - mean * mean) : 0
            return (mean, variance.squareRoot())
        }
    }

    /// Per channel, the `(gain, bias)` that maps `source` statistics onto
    /// `target`, in 0…1 units for a colour matrix.
    static func transfer(from source: [(mean: Double, deviation: Double)],
                         to target: [(mean: Double, deviation: Double)]) -> [(gain: Double, bias: Double)] {
        (0..<3).map { c in
            let gain = target[c].deviation / max(source[c].deviation, 1e-6)
            let bias = (target[c].mean - source[c].mean * gain) / 255
            return (gain, bias)
        }
    }
}
