# Progressive Scrub (90-file gate + embedded previews) — Design Spec

Date: 2026-08-25
Status: implemented (supersedes the import-speed spec's "progressive scrub rejected"; blocking model relaxed with a gate)
Related: `DecodeEngine.swift`, `AppState.swift`, `ImageWindow.swift`, `FastPreview.swift`, `LibRawDecoder.swift`, `2026-08-25-import-speed-design.md`

## Problem

Under the strict blocking model, the first picture appears only when the
whole import finishes (~2.2 min for 267 × 20MP on an 8GB M1, measured ~4s
decode per file). The user asked for the first picture sooner — with the
blocking relaxed ONLY after a threshold, and fast embedded previews as
placeholders for stragglers.

## Decision (user-directed, 2026-08-25)

- **Gate**: once `decodeUnlockThreshold` (default **90**) files are decoded,
  the session unlocks for scrubbing/flagging; the remaining files decode in
  the background. Shoots smaller than the threshold stay fully blocked
  (unchanged behavior). Knob:
  `defaults write com.quickcull decodeUnlockThreshold N`.
- **Placeholder**: an index whose cache JPEG does not exist yet shows the
  file's fast preview — the raw's **embedded camera JPEG** (LibRaw
  thumbnail path, ~10-50ms) or a capped ImageIO thumbnail for standard
  formats. When each background decode lands, `.fileDecoded` retries the
  window slots and the real render replaces the preview.
- **Persistent cache**: explicitly out of scope (user decision).

## Change

1. **`DecodeEngine.Event`** gains `fileDecoded(file: SessionFile,
   cacheURL: URL)`, yielded right after `storeJPEG` (successful files
   only). `.progress` stays monotonic; `.completed` stays exactly one
   event, last.

2. **`AppState`**:
   - `.progress` writes the phase only while still blocked; once
     `completed >= decodeUnlockThreshold` it sets `isBackgroundDecoding`
     and `finishDecoding` (installs windows, phase → `.scrubbing`).
   - `.fileDecoded` during background decode: `displayImages?.retry(index)`
     + `thumbWindow?.retry(index)` for the file's index.
   - `.completed`: removes failures as before; windows are rebuilt only if
     the files array changed (failed files removed) or the session never
     unlocked early — otherwise the already-installed windows stay put.

3. **`ImageWindow`**:
   - `retry(_ index:)` re-runs the loader for an index even if a
     placeholder is resident (no-op while a load is in flight).
   - The display loader returns `FastPreview.image(for: file.url)` when the
     cache JPEG does not exist; the thumbnail loaders do the same for
     strip/grid cells.

4. **`FastPreview`** (new): LibRaw files → `LibRawDecoder.embeddedPreview`
   (`libraw_unpack_thumb` + `libraw_dcraw_make_mem_thumb`; JPEG or bitmap
   thumbs, own handle per call — thread-safe); ImageIO files → capped
   1920px thumbnail. Transient by contract: replaced when the real decode
   lands.

## Invariants preserved

- Real-raw-only render: the placeholder is the camera's embedded JPEG, the
  *final* image is always the full LibRaw demosaic (or ImageIO decode) from
  the cache. No embedded preview is ever shipped as the cached image.
- `.completed` still exactly one event, last; progress monotonic.
- Flags/filters/commits operate on real decodes; nothing is flagged or
  moved on a preview.
- Metadata HUD dims stay correct for undecoded files:
  `ImageMetadataProvider` already prefers the cache JPEG header, then the
  source file's own header (via ImageIO props) — not the displayed CGImage.

## Known tradeoffs

- The loupe's "100%" badge applies to the placeholder's pixels while a
  preview is showing (transient; the preview is small and replaced within
  seconds).
- The strip/grid cells for undecoded files show embedded previews
  (camera JPEG quality) until their real thumbs land.
- At `.completed` with failures, the windows rebuild (indices shifted by
  removal) — a one-time churn, same as the pre-progressive path.

## Tests

- `LibRawDecoderTests.testEmbeddedPreviewExtractsCameraJPEG` /
  `testEmbeddedPreviewNilForTruncatedFiles`.
- `DecodeEngineTests.testFileDecodedEventsPrecedeCompletedAndCarryLiveCacheURLs`.
- `ImageWindowTests.testRetryReplacesPlaceholder`.
- `AppStateTests.testProgressiveUnlockAfterThresholdWithBackgroundDecode`
  (threshold 2 of 3: unlocks early, late decode populates the window via
  retry, phase stays scrubbing) and `testSmallShootStaysFullyBlocked`
  (threshold 90: small shoot stays blocked until done).
