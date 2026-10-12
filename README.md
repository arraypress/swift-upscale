# swift-upscale

On-device **4× super-resolution** — recovers real detail (hair, texture, edges) rather than just
sharpening. Three upscalers, chosen by a measured bake-off:

| Model | `UpscaleModel` | Runs on | Licence | What it is for |
|---|---|---|---|---|
| **SwinIR-L real-world** | `.swinir` (`.default`) | Core AI | Apache-2.0 | faithful detail — the default |
| Real-ESRGAN x4plus | `.x4plus` (`.fast`) | Core ML | BSD-3 | about 6× quicker, a little painterly |
| AdcSR | `.adcsr` (`.detail`) | Core AI | Apache-2.0 + OpenRAIL++-M | **adds detail that was not there** — generated or casual pictures, not photos you need to trust |
| Real-ESRGAN x4v3 / x4v3-denoise | `.x4v3`, `.x4v3Denoise` | Core ML | BSD-3 | small and fast; denoise also removes JPEG blocks |
| 4x-UltraSharp | `.ultrasharp` | Core ML | **CC BY-NC-SA 4.0 — non-commercial** | crisper edges |
| MangaJPEGLQ | `.manga` | Core AI, **1×** | **CC BY-NC-SA 4.0 — non-commercial** | cleans JPEG blocks out of greyscale manga; doesn't enlarge — run a 4× model after it |

```swift
import Upscale

let model = UpscaleModel.default                         // SwinIR-L
// model.repository / .revision / .path: where to fetch it (arraypress, pinned)
let upscaler = try await CoreAIUpscaler(model: model, url: modelURL)
let big = try await upscaler.upscale(image, isCancelled: nil) { p in print(p) }   // 4× the input

let quick = try RealESRGANUpscaler(modelURL: x4plusURL)   // Core ML, the fast option
```

Every model is published in an **arraypress** repository pinned to a commit — `UpscaleModel` carries
the repository, revision, path, licence and flags (`isNonCommercial`, `inventsDetail`); the CLIs
download through CLIKit. Before 2.0 the Core ML builds came from a third party's mirror, which
labelled the two CC BY-NC-SA models BSD-3.

## Measured (M3 Max, macOS 27)

- **Bake-off** (×4 shrink-and-back, 5 generated + 5 stock photos, LPIPS lower is better):
  SwinIR-L 0.185 / 0.208 (generated / real), Real-ESRGAN x4plus 0.195 / 0.236, AdcSR 0.181 / 0.241
  (with blur, noise and JPEG damage, AdcSR is best on real photos at 0.262 — by inventing detail).
- **SwinIR-L on Core AI:** float16 matches PyTorch float32 at **66–68 dB PSNR** per tile; 128-px tiles
  had the lowest cost per new pixel; seams measured invisible (tiled vs whole-picture PyTorch: the seam
  bands match as well as the rest, 41.8 vs 41.6 dB). **1024 → 4096 in 25–29 s** (about 0.25–0.34 s per 128-px tile); a 12 MP photo (4000×3000 → 16000×12000, ~970 tiles) runs in about 5½ minutes on an unloaded GPU. 1.x painted each tile as a Core Image blend over the whole canvas, and that same photo took **40.6 minutes**; 2.0 paints tiles straight into one buffer.
- **Real-ESRGAN x4plus:** 1024 → 4096 in 4.5 s (Core ML, CPU + Neural Engine).
- **AdcSR:** 1024 → 4096 in 26.6 s; its raw output drifts in colour, so `CoreAIUpscaler` matches each
  channel's mean and spread to a plain resize afterwards, as the bake-off measured it.

Tiles overlap and are painted in scan order with ramped seams (total weight always 1). Requirements:
**macOS 27 / iOS 27** (Core AI) since 2.0, Swift 6.2. 1.x stays on macOS 26 with Real-ESRGAN only.

## Core ML or Core AI (2.1)

Every ESRGAN-family model was exported to Core AI from its authors' original weights and checked
against them (PSNR vs PyTorch float32, six stock-photo tiles each: x4plus 69.3 dB, x4v3 73.4, x4v3
denoise 64.1, UltraSharp 68.8, MangaJPEGLQ 61.0). On an M3 Max the **Core ML builds stay faster for the
four 4× models** — 1024→4096: x4plus 4.0 s vs 6.6 s, x4v3 0.79 s vs 1.21 s, UltraSharp 4.2 s vs about
6.6 s (a 512-px Core AI tile was slower still, 10 s) — so they stay Core ML. **MangaJPEGLQ moved to Core
AI**: it is a 1× greyscale model, the Core ML build was run as 4× (`upscale --variant manga` segfaulted
in 2.0), and the new asset is exported from bunzero's original weights (RGB → luma → model → RGB).
`UpscaleModel.scale` says which models enlarge; `upscaler(at:)` picks the runner by the file you give
it, so a Core ML file installed by 2.0 or earlier still runs on Core ML.

## License

MIT — see [LICENSE](LICENSE).

Bundled or downloaded models keep their own licences; see the notes above where a model is named.
