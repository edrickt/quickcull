# Full-Resolution Viewer Window — Design Spec

Date: 2026-08-25
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
invariant. Decision (user-directed, 2026-08-25): the **whole ±30 viewer
window** decodes at full resolution — the displayed image *is* the full-res
pixels, so the loupe is true 1:1 with no second decode path at all.

## Change

1. **`ImageWindow.display` — radius 30, full-res decode.** The main-viewer
   window covers the same ±30 sliding window as the filmstrip and decodes
   every image at full resolution via the new `loadJPEGFullRes(at:)`, which
   reads the cache JPEG's own header dimensions and asks the thumbnail API
   for exactly that long edge. No image is ever downsampled for the viewer.
   `displayPixelLimit()` and the 2×-screen cap are deleted.

2. **Throttled fills.** A full window queues 61 full-res decodes; without a
   bound they would fire 61 parallel ~180MB decodes. All display windows
   share one process-wide `DecodeGate` (DispatchSemaphore, limit 3); a fill
   decodes at most three images at once, current-first via the existing
   `loadOrder`.

3. **Loupe — no code change, now honest.** `LoupeView.croppedImage` crops
   the display CGImage at 1:1 backing pixels around the cursor; the display
   image is now the full-res decode, so the crop is genuine source-pixel 1:1
   and the "100%" badge is exact at any image size. Comments updated to
   document the guarantee.

4. **Filmstrip/grid unchanged.** Thumbnails stay 320px (`thumbnails`,
   `gridThumbnails` factories) — full-res pixels are pointless at 160-200pt
   and would multiply window memory for no visible gain.

## Memory accounting (honest numbers)

Steady state is bounded by the window count (61), never by shoot size, so
"flat with respect to file count" still holds. The absolute bound changed:

| Source | Full-res bitmap | 61-image window |
| --- | --- | --- |
| 12MP (4000×3000) | ~36MB | ~2.2GB |
| 24MP (6000×4000) | ~72MB | ~4.4GB |
| 45MP (8256×5504) | ~136MB | ~8.3GB |
| 60MP (9504×6336) | ~181MB | ~11GB |

Decodes are 8-bit RGB (no alpha); macOS pages bitmap memory under pressure.
README "Memory stays flat" states the new bound explicitly.

## Tradeoffs accepted

- **Absolute memory**: a full 61-image window of large-sensor raws holds
  8-11GB of bitmaps (previously ~39MB × 61 with the cap). Bounded, paged,
  and only for the active session, but the README headline number changed.
- **Window fills slower**: a cold 61-image fill takes seconds (full-res
  decode ~100-400ms each, 3 at a time); the current image loads first, and
  the view falls back to filmstrip thumbs until each full-res frame lands.
- **Rebuilds re-decode**: filter changes / session start rebuild the window
  (61 full-res decodes per rebuild). Flag toggles in All mode do *not*
  rebuild (pinned by `testToggleFlagRebuildsWindowsOnlyWhenProjectionChanges`).

## Out of scope

- Tile/pyramid cache for strict flat-memory loupe (rejected: ingest time +
  disk + format change; the window-scale fix makes it unnecessary).
- Persistent cache, HEIF cache format (see import-speed spec).
- Lowering the decode gate or making it memory-aware — revisit only if
  pressure measurements demand it.
