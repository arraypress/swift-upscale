# swift-upscale

On-device **4× super-resolution** via **Real-ESRGAN** (BSD-3) — recovers real
detail (hair, texture, edges) rather than just sharpening. The "AI upscale" look.

- `RealESRGANUpscaler` — the Core ML model is a fixed 256×256 → 1024×1024 tile;
  `upscale(_:progress:)` tiles an arbitrary image, runs each tile 4×, and
  feather-blends the seams (no visible tile boundaries).

```swift
let upscaler = try RealESRGANUpscaler(modelURL: modelURL)
let big = upscaler.upscale(image) { p in print("\(Int(p * 100))%") }   // 4× the input
```

Model: `LocalMuseAI/coreml-realesrgan-x4plus` (RealESRGAN-x4plus, ~33 MB;
variants: UltraSharp / x4v3 / x4v3-denoise / MangaJPEGLQ). Weights BSD-3.
Fast enough for **photos** (seconds); **video** is an export-time pass (per-frame,
minutes for short clips). Requirements: macOS 26 / iOS 26, Swift 6.2.

## License

MIT — see [LICENSE](LICENSE).

Bundled or downloaded models keep their own licences; see the notes above where a model is named.
