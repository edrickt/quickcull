# QuickCull — Refactor Wave 2: Audit Cleanup & Optimization

Date: 2026-08-27
Status: **implemented** (2026-08-27 — behavior-preserving; suite 176 green)

## Purpose

Full-codebase audit found dead code, duplication, and a few real hot paths.
This wave is behavior-preserving cleanup plus targeted optimization — no new
features, no UI changes, no format changes, no window-tiering or
decode-option changes. The 176-test suite is the safety net.

## Non-Goals

- No new features or format support.
- No UI/UX changes (visuals, keys, flow stay identical).
- No changes to window tiering defaults, decode options, or the cache format.
- No DecodeGate rework (bounded at 3, adequate).

## Wave 1 — Dead code

- Deleted `FlagBadgeOverlay` (unused private view in ImageDisplayView.swift).
- Deleted `ImageWindow.thumbnails(files:cache:)` (zero call sites; AppState
  installs `gridThumbnails` for both strip and grid).
- Dropped `DecodeEngine.Benchmark` never-populated fields
  (`openMs/unpackMs/processMs/encodeMs`); kept `fileID/totalMs/width/height`.
- Removed dead `.overlay(alignment: .topTrailing) { /* no right badge */ }`.
- `ImageWindow.startLoad` binds `reducedLoader` with `if let` (no `!`).
- README test count synced (162 → 176).
- Audit correction: the trailing `syncWindows()` in `AppState.handle` was
  initially flagged redundant but is load-bearing — `installWindows` ends
  with `thumbs.setCurrent(0)`, so the trailing sync re-positions rebuilt
  windows at the preserved current index (and is the only sync for move
  actions). Kept.

## Wave 2 — Duplication consolidation

- **AppState**: `resetTransientState()` (pending*/failures/isCommitting/
  isMoving resets — was duplicated 4×) and `transitionToEmptySession()`
  (session/windows nil, phase .empty, viewMode .scrub — was 3×).
  `confirmCommit`/`confirmMove` route their empty-transition through the
  helper but keep their own minimal pending-clears: the shared reset also
  clears the *other* flow's pending state, which the originals never
  touched — exactness over dedup there. Public `TrashOutcome`/`MoveOutcome`
  signatures unchanged.
- **DecodeEngine**: one generic `LockedAccumulator<Element>` replaces
  `AtomicOutcomeAccumulator` + `AtomicBenchmarkAccum`. `JobQueue` dequeues
  O(1) via reversed storage + `popLast()` (was O(n) `removeFirst()`).
- **ImageWindow**: eviction routes through the tested
  `WindowPolicy.toEvict` in both `setCurrent` and `ensureLoaded`; the
  two-pass `pruneEnsuredIndices` collapses into one LRU-cap function; the
  three JPEG decoders unify into `decodeJPEG(at:maxPixelSize:)` with thin
  size-computing wrappers.
- **ImageMetadataProvider**: single `dateTaken` file-attr fallback (was
  written twice), one shared pixel-dimensions helper, static cached
  `DateFormatter`.
- **Views**: new `QuickCull/ImportFailuresBanner.swift` replaces the
  verbatim banner+summary copies in EmptyStateView and ScrubView; ScrubView
  computes flagged counts once per body (was ~10 `flaggedCount` calls);
  MetadataHUDView computes histogram stats once per histogram value and
  shares one stat-row helper; `ImageDisplayView.swift` (785 lines) splits
  into ImageDisplayView, ZoomableImageView, LoupeView, MetadataHUDView,
  HistogramViews (shared Canvas draw helper). Synchronized groups — no
  pbxproj edit.

## Wave 3 — Performance

- **`Session.flagRevision`**: monotonic counter bumped on every flag
  mutation (`toggleFlag`, `toggleFlags`, `remove`), unchanged on
  `move`/`setIndex`/`setFilter`. `FilmstripView.stripKey` becomes
  `id#flagRevision#currentIndex` — O(n log n) sort+join of all flagged ids
  per scrub step becomes O(1). The full re-key strategy is preserved,
  including the deliberate index-in-key behavior (an index change re-keys
  the whole strip, guarding the highlight border against dropped in-place
  updates); only the version source changes.
- **ThumbnailCell** receives `image`/`isCurrent` as plain values from the
  parent element list (GridView pattern) — removes per-cell observation of
  `thumbWindow.images` and `session.currentIndex` (every visible strip cell
  re-rendered on each thumbnail arrival / index change). The unused
  `hasImage` element field is gone.
- **Session**: `idPositions` (id → position in `allFiles`, rebuilt on
  init/remove) serves `position`, `nearestMatchIndex`, `remove` and
  `toggleFlags` — O(n²) filter-fallback lookups become O(n), and `remove`
  no longer rebuilds a positions dictionary per call. `toggleFlags`
  intersects against the map instead of allocating a full id array.
- **MetadataHUDView**: histogram means/clipping computed once per value
  (`HistogramStats`), not per render.
- **LibRawDecoder.rawHistogram**: 2×2 Bayer channel LUT derived from
  `filters` outside the pixel loop.

## Wave 4 — Hardening

- `AppState` stores the import decode `Task` (`importTask`) and cancels it
  at the top of `startNewSession()`/`importFiles()`, and the stream loop
  breaks on cancellation — a stale decode stream can no longer write
  phase/windows if a second import ever becomes reachable. DecodeEngine's
  existing `onTermination` cancellation chains through.
- New tests (`FlagRevisionTests`, 6): revision starts at 0, bumps once per
  flag mutation (single/batch/remove), never on move/setIndex/setFilter;
  idPositions rebuilt after remove. Suite total 182.

## Sequencing

1. Wave 1 → suite green → commit.
2. Wave 2 (AppState, engine, window, metadata, views) → suite green → commit.
3. Wave 3 (flagRevision, cell values, Session dictionaries, LUT) → suite green → commit.
4. Wave 4 (import-task cancellation, final verify) → commit.
