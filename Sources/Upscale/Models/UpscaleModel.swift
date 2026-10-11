//
//  UpscaleModel.swift
//  Upscale
//
//  Created by David Sherlock on 2026.
//

/// The upscalers on offer, by the name a person types.
///
/// Chosen by a bake-off (LPIPS on a ×4 shrink-and-back of 5 generated and 5
/// stock photos, clean and degraded): SwinIR-L is the faithful default,
/// Real-ESRGAN x4plus the fast one, AdcSR the opt-in that invents detail.
/// Where each lives and under what licence is in ``UpscaleModel/repository``
/// and friends.
public enum UpscaleModel: String, CaseIterable, Sendable {
    /// SwinIR-L real-world GAN on Core AI — the default.
    case swinir
    /// Real-ESRGAN x4plus on Core ML — the fast option.
    case x4plus
    /// Real-ESRGAN general x4v3 — small and fast, slightly softer.
    case x4v3
    /// x4v3 that also removes noise and JPEG blocks.
    case x4v3Denoise = "x4v3-denoise"
    /// 4x-UltraSharp — crisper; NON-COMMERCIAL (CC BY-NC-SA 4.0).
    case ultrasharp
    /// MangaJPEGLQ — line art and manga scans; NON-COMMERCIAL (CC BY-NC-SA 4.0).
    case manga
    /// AdcSR one-step diffusion on Core AI — adds detail that was not there.
    case adcsr
}
