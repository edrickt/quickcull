# First-Picture Preview — Design Spec

Date: 2026-08-25
Status: implemented
Related: `DecodeEngine.swift`, `AppState.swift`, `DecodingView.swift`, `2026-08-25-import-speed-design.md` (blocking model)

## Problem

The blocking model (spec: "Keep blocking model — option A. Progressive scrub
rejected") is the right call for consistency, but it makes the user stare at
a progress bar for the whole import: on a 267-file 20MP shoot that is tens
of seconds before any photo is visible. Time-to-first-picture is the whole
import wall-clock.

## Decision

Keep the blocking guarantee exactly as-is — no scrubbing, no flagging, no
view switching until `.completed` — but surface the **first picture** as
soon as its own cache JPEG lands on disk. The user sees photo #1 while the
rest of the import continues; input unlocks only when every file is decoded.

This is deliberately NOT progressive scrub: `AppState.handle` and
`setCurrentIndex` still guard on `phase == .scrubbing`, so no interaction
(keys, clicks, flags, filters) is possible during decode. The preview is a
passive view.

## Change

1. **`DecodeEngine.Event`** gains `fileDecoded(file: SessionFile,
   cacheURL: URL)`, yielded by `ProgressReporter.reportDecoded` immediately
   after `storeJPEG` succeeds (successful files only). Invariants preserved:
   `.progress` stays monotonic, `.completed` is still exactly one event and
   still last ("exactly one completed event with per-file outcomes").

2. **`AppState`** gains `decodePreview: CGImage?`. The decode event loop
   forwards every `.fileDecoded` to `handleDecodedFile`, which:
   - no-ops unless `phase == .decoding` and the file is the session's first
     (`session.files.first` — the deterministic "first picture"),
   - decodes the cache JPEG full-res off the main actor (reuses
     `ImageWindow.loadJPEGFullRes`), re-checking phase/preview state before
     publishing,
   - is dropped by `finishDecoding` (the display window owns the image once
     scrubbing starts; no double residency).

3. **`DecodingView`** shows `decodePreview` fitted behind the progress card,
   with a "First picture ready — input unlocks when all files are decoded"
   caption.

4. **Test seam**: `AppState.init(decodeWorkerLimit:)` bounds decode workers
   so tests can make the preview window deterministic (single worker + slow
   stub decoder).

## Why this keeps the blocking model honest

- Phase stays `.decoding` until every file has a cached q75 JPEG; the
  scrubbing gate (`phase == .scrubbing`) never opens early.
- The preview comes from the **real full-res decode** of the cache JPEG —
  no embedded-preview path, honoring "real raw decoded image only".
- The preview is the same bitmap the viewer will show, so the transition to
  scrubbing is seamless, and it is freed at the transition.

## Tests

- `DecodeEngineTests.testFileDecodedEventsPrecedeCompletedAndCarryLiveCacheURLs`
  — one `fileDecoded` per file in FIFO order, JPEG on disk when fired,
  `.completed` last.
- `AppStateTests.testFirstPicturePreviewAppearsWhileDecodingAndClearsAtScrubbing`
  — with a single worker and a 300ms-per-file stub decoder, the preview
  appears while `phase == .decoding(1, 3)` and is cleared at `.scrubbing`.

## Out of scope

- Progressive scrub / early scrubbing — explicitly rejected (consistency
  risk; the import-speed spec keeps the blocking model).
- Filmstrip population during decode — the strip fills at the transition;
  a live strip is a progressive-scrub cousin and stays rejected.
- Preview from embedded thumbnails — violates the real-raw invariant.
