# Full-Resolution Viewer Window — Design Spec

Date: 2026-08-25 (rev 2: memory-bounded radius after 8GB-machine measurement; rev 3: default ±15; rev 4: asymmetric +20/−10 per product decision)
Status: implemented (decision supersedes the 2×-screen display cap)
Related: `ImageWindow.swift`, `ImageDisplayView.swift` (LoupeView), `2026-08-16-quickcull-design.md` (v1 pipeline)

## Problem

The Space loupe badges itself "100%" and renders with `.interpolation(.none)`
for a "true pixel view", but it crops the **display-limited** CGImage, not the
file's full resolution. The main viewer (`ImageWindow.display`) decoded cache
JPEGs with `maxPixelSize = max(screen w, h) × 2` (3840 on a 1080p display),
so for a 9504×6336 raw the display image is ~3840×2560 and every loupe pixel
is ~2.5 source pixels averaged — blocky, and the "100%" claim is false.
Images smaller than the limit were already true 1:1, which is why the bug only
showed on large raws.

The naive fix (full-res decode for the loupe) was deliberately rejected while
it meant one extra 135-180MB decode; the display cap was the memory-flatness
invariant. Rev 1 (superseded) shipped radius 30 full-res; real-machine
measurement killed it (see "Measured reality" below).

## Change

1. **`ImageWindow.display` — full-res decode, memory-bounded window.** The
   main-viewer window decodes at full resolution via `loadJPEGFullRes(at:)`
   (reads the cache JPEG's own header dimensions and asks the thumbnail API
   for exactly that long edge; nothing is ever downsampled). The window is
   asymmetric — `displayFullResBehind` (−10) and `displayFullResAhead`
   (+20) by default, 31 images — because culling moves forward, so the
   ahead side pre-loads more. Tunable via
   `defaults write com.quickcull displayFullResBehind N` /
   `displayFullResAhead N`. `WindowPolicy` gained asymmetric
   `behind`/`ahead` support (symmetric `init(radius:)` preserved for the
   filmstrip/grid). `displayPixelLimit()` and the 2×-screen cap are
   deleted.

2. **Throttled fills.** All display windows share one process-wide
   `DecodeGate` (DispatchSemaphore, limit 3); a fill decodes at most three
   images at once, current-first via the existing `loadOrder`.

3. **Loupe — no code change, now honest.** `LoupeView.croppedImage` crops
   the display CGImage at 1:1 backing pixels around the cursor; the current
   image is a full-res decode, so the crop is genuine source-pixel 1:1 and
   the "100%" badge is exact at any image size. Comments updated.

4. **Neighbors beyond the window.** They are not decoded by the display
   window; the view falls back to the filmstrip 320px thumb and the image
   decodes full-res on landing (~90ms at 20MP — faster than the old 3840-cap
   path, which measured ~180ms because it full-decodes then downscales).

5. **Filmstrip/grid unchanged.** 320px thumbnails (`thumbnails`,
   `gridThumbnails` factories).

## Measured reality (2026-08-25, 8GB Apple M1)

- Full-res decode of a 5240×3912 cache JPEG: **~90ms**. Decode speed is not
  the bottleneck.
- Rev 1's 61-image full-res window: 61 × ~62MB = **~3.8GB** of bitmaps.
  Running app footprint reached **4.4GB with 4.3GB swapped** on the 8GB
  machine; every scrub step faulted pages in/out and scrub stalled to
  seconds per step. CoreAnimation additionally held ~26 full-res textures
  (~2GB) for recently rendered images.
- Conclusion: a 61-image full-res window cannot fit 8GB machines. The
  bounded window keeps every property that matters — loupe true 1:1,
  instant scrubbing — at a cost the machine can bear: +20/−10 is
  ~1.9GB at 20MP and ~4.2GB at 45MP, with user-controlled knobs for
  headroom or pressure.

## Memory accounting (+20/−10, honest numbers)

| Source | Full-res bitmap | 31-image window |
| --- | --- | --- |
| 12MP (4000×3000) | ~36MB | ~1.1GB |
| 20MP (5240×3912) | ~62MB | ~1.9GB |
| 45MP (8256×5504) | ~136MB | ~4.2GB |
| 60MP (9504×6336) | ~181MB | ~5.6GB |

Decodes are 8-bit RGB (no alpha); macOS pages bitmap memory under pressure.
README "Memory stays flat" states the bound and the knobs explicitly.
+20/−10 was chosen as the product compromise: instant scrubbing across a
wide forward neighborhood (~1.9GB at 20MP, fits 8GB machines for typical
shoots) while keeping 45MP+ shoots at ~4.2GB — usable with headroom,
tunable via the knobs if pressure shows up.

## Tradeoffs accepted

- **Far jumps show a thumb briefly**: landing beyond the window falls back
  to the 320px thumb for ~90-150ms until the full-res decode lands (parity
  with the old radius-1 design, which waited ~180ms for the 3840-cap
  decode).
- **Scrubbing backward hits the shorter side**: −10 behind means a rapid
  backward mash hits the window edge after 10 steps (a ~90ms hitch per
  crossing); forward gets 20 steps. Both sides are knob-adjustable.
- **Absolute memory**: the window is ~31 full-res bitmaps (~1.1-5.6GB),
  bounded by the policy, never by shoot size. A 500-file shoot uses the
  same memory as a 50-file one.

## Out of scope

- Tiled/pyramid cache (rejected: ingest time + disk + format change).
- Memory-adaptive radius (auto-shrink under pressure) — the knob covers the
  need; revisit only if pressure measurements demand it.
- Persistent cache, HEIF cache format (see import-speed spec).
