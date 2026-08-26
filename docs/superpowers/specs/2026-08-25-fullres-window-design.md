# Full-Resolution Viewer Window — Design Spec

Date: 2026-08-25 (rev 2: memory-bounded radius after 8GB-machine measurement; rev 3: default ±15; rev 4: asymmetric +20/−10; rev 5: full-res tier −5/+10 with half-size outer ring)
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

1. **`ImageWindow.display` — full-res tier + half-size ring.** The window
   extent stays asymmetric — `displayExtentBehind` (−10) /
   `displayExtentAhead` (+20), 31 slots. Inside it, a **full-res tier**
   (`displayFullResBehind` −5 / `displayFullResAhead` +10 by default,
   16 images) decodes at full resolution via `loadJPEGFullRes(at:)`; the
   outer ring (−10…−6, +11…+20) decodes at **half size** via
   `loadJPEGHalfRes(at:)` (ImageIO DCT subsampling: measured ~25-70ms vs
   ~144ms full for 20MP, at ~1/4 the bitmap memory). Tier knobs:
   `defaults write com.quickcull displayFullResBehind N` /
   `displayFullResAhead N`.
   `ImageWindow` gained a general tier mechanism (`reducedLoader` +
   `upgradePolicy` + `degradedIndices`): indices outside the tier load the
   reduced loader, and the **upgrade pass** in `setCurrent` re-runs them at
   full resolution the moment they enter the tier — i.e. when the user
   lands on them — so the loupe is always true 1:1. `WindowPolicy` keeps
   asymmetric `behind`/`ahead` support (symmetric `init(radius:)` for the
   filmstrip/grid). `displayPixelLimit()` and the 2×-screen cap are
   deleted.

2. **Throttled fills.** All display windows share one process-wide
   `DecodeGate` (DispatchSemaphore, limit 3); a fill decodes at most three
   images at once, current-first via the existing `loadOrder`.

3. **Loupe — no code change, now honest.** `LoupeView.croppedImage` crops
   the display CGImage at 1:1 backing pixels around the cursor; the current
   image is always full-res (in-tier by construction, upgraded on landing),
   so the crop is genuine source-pixel 1:1 and the "100%" badge is exact at
   any image size. Comments updated.

4. **Neighbors beyond the window.** They are not decoded by the display
   window; the view falls back to the filmstrip 320px thumb and the image
   decodes full-res on landing (~90-150ms at 20MP).

5. **Filmstrip/grid unchanged.** 320px thumbnails (`thumbnails`,
   `gridThumbnails` factories).

## Measured reality (2026-08-25, 8GB Apple M1)

- Full-res decode of a 5240×3912 cache JPEG: **~144ms**; half-size via
  `maxPixelSize = max(w,h)/2` (true DCT subsample): **~25-70ms** at exactly
  half dimensions. (Rounded-up sizes like 2620 on a 4912-wide image miss
  the DCT boundary and fall back to full decode — use the exact half.)
- Rev 1's 61-image full-res window: 61 × ~62MB = **~3.8GB** of bitmaps.
  Running app footprint reached **4.4GB with 4.3GB swapped** on the 8GB
  machine; every scrub step faulted pages in/out and scrub stalled to
  seconds per step.
- Conclusion: full-res memory must stay bounded; the tier keeps the loupe
  true 1:1 and near-instant scrubbing while the ring sits at half size.

## Memory accounting (tier −5/+10, extent −10/+20, honest numbers)

| Source | Full-res bitmap | Half-size bitmap | Tier (16) + ring (15) |
| --- | --- | --- | --- |
| 12MP (4000×3000) | ~36MB | ~9MB | ~710MB |
| 20MP (5240×3912) | ~62MB | ~15.5MB | ~1.2GB |
| 45MP (8256×5504) | ~136MB | ~34MB | ~2.7GB |
| 60MP (9504×6336) | ~181MB | ~45MB | ~3.6GB |

Decodes are 8-bit RGB (no alpha); macOS pages bitmap memory under pressure.
README "Memory stays flat" states the bound and the knobs explicitly.
Full-res images the user has visited linger (full tier + trailing
stragglers) until they slide out of the window extent.

## Tradeoffs accepted

- **Landing on the ring shows half-size briefly**: a ring index is shown at
  half resolution until its full-res upgrade lands (~150ms); the loupe
  during that window is transiently half-res.
- **Far jumps show a thumb briefly**: landing beyond the window extent falls
  back to the 320px thumb for ~90-150ms until the full-res decode lands.
- **Scrubbing backward hits the shorter side**: −5 behind means a rapid
  backward mash hits the tier edge after 5 steps (full-res decode on
  landing per step); forward gets 10. Both sides are knob-adjustable.
- **Absolute memory**: bounded by the window extent (16 full + 15 half),
  never by shoot size. A 500-file shoot uses the same memory as a 50-file
  one.

## Out of scope

- Tiled/pyramid cache (rejected: ingest time + disk + format change).
- Memory-adaptive radius (auto-shrink under pressure) — the knob covers the
  need; revisit only if pressure measurements demand it.
- Persistent cache, HEIF cache format (see import-speed spec).
