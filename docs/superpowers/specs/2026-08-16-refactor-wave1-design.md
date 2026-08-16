# QuickCull — Refactor Wave 1: Consolidation & Hardening

Date: 2026-08-16
Status: approved design (pre-plan)

## Purpose

QuickCull v1 works and ships: 65 tests green, all features live. This wave
is behavior-preserving cleanup and hardening — no new features, no UI
changes, no format changes. The 65-test suite is the safety net: it must
stay green at every step.

## Non-Goals

- No new features or format support.
- No UI/UX changes (visuals, keys, flow stay identical).
- No API surface changes visible to the app target beyond what the wave
  itself requires (the window classes are internal to the refactor).
- No performance work outside the decode-worker memory bound.

## Workstream 1 — Unify the window layer, slim AppState

`SlidingWindow` (radius 30, 320 px thumbnails) and `DisplayImageProvider`
(radius 1, 2× screen) are two copies of the same machine: eviction, in-flight
dedupe, current-first async loading, stale-completion discard, and a
waitUntilSettled poll. Replace both with one type:

- `@MainActor @Observable final class ImageWindow`
  - `init(radius: Int, count: Int, loader: @escaping (Int) async -> CGImage?)`
  - `setCurrent(_ index: Int)`, `image(at index: Int) -> CGImage?`,
    `waitUntilSettled(timeout:) async`, `images: [Int: CGImage]`
  - Identical invariants: resident ⊆ window(current) by induction; eviction
    immediate; stale completions discarded; loads deduped via inFlight set.
- Two static factories owning the app's sizes and cache plumbing:
  - `ImageWindow.thumbnails(files:cache:)` — radius 30, maxPixel 320.
  - `ImageWindow.display(files:cache:)` — radius 1, maxPixel 2× screen long
    edge (current `displayPixelLimit` logic moves here).
- `AppState` keeps public names `thumbWindow` / `displayImages` (views
  unchanged) but drops the loader closures and window construction:
  one private `installWindows(for files: [SessionFile])` used by both the
  decode-finish path and the post-commit rebuild path.

Behavioral deltas folded in (from the parked final-review items):

- **waitUntilSettled**: track load `Task`s and await them instead of the
  5 ms busy-poll; accept an optional `timeout` (nil = wait forever). The
  current infinite-loop-on-cancellation hazard disappears with it.
- **Eviction mutation-during-iteration**: iterate a materialized
  `Set(images.keys)` before removing (the technically-UB-but-safe pattern
  becomes plainly safe).

## Workstream 2 — Robustness (parked items, remainder)

- **Atomic cache replace**: `ImageCacheStore.storeJPEG` uses
  `FileManager.replaceItemAt(_:withItemAt:)` instead of remove-then-move,
  so a failed encode can never lose the previous cache entry.
- **Commit off the main actor**: `AppState.confirmCommit()` becomes async.
  `TrashCommit.commit` runs on a background task; `commitFailures` and
  `session.remove(succeeded)` are applied back on the main actor; the
  commit toolbar button disables and shows progress while the move runs.
  `Trashing` gains `Sendable` conformance (FileManagerTrasher is stateless;
  the test stub becomes a locked final class).
- **DecodeEngine cooperative cancellation**: workers check
  `Task.isCancelled` between files and stop draining; `onTermination`
  cancellation now actually short-circuits the queue. No UI wiring in this
  wave (nothing cancels yet); it makes the existing contract honest.

## Workstream 3 — Memory-bounded decode workers

`DecodeEngine` spawns `activeProcessorCount` workers (8 on an 8 GB MacBook
Air); parallel 45MP decodes (≈300 MB/worker transient) can push small-RAM
machines into swap. New rule:

```
workers = min(activeProcessorCount, max(1, physicalMemory / 512MB))
```

- 8 GB → 4 workers; 16 GB → 8; 32 GB → 16, capped at core count.
- The limit is injectable: `DecodeEngine.init(decoder:cache:workerLimit:)`
  with `nil` = auto rule, so tests pin a deterministic limit.
- Memory-per-worker basis (512 MB) is the estimate of LibRaw unpack +
  demosaic + RGB8 mem image + JPEG encode buffers for a 45 MP raw; it is a
  documented constant, not a measurement.

## Workstream 4 — Test helper consolidation

One `QuickCullCoreTests/TestFixtures.swift` owning the copy-pasted helpers:

- `makeTempDir()`, `makeRawFile(named:)`, `makeFiles(names:)`,
  `writeJPEG(color:to:)`, `makeCGImage(width:height:)`, `makeTempCache()`.

Six test files stop redefining them. Same assertions, same test count (plus
new tests for the worker limit and any new API).

## Sequencing

1. Workstream 1 (window unification; absorbs its robustness items).
2. Workstream 2 (atomic replace, async commit, engine cancellation).
3. Workstream 3 (worker memory bound).
4. Workstream 4 (test helpers).
5. README + plan sync, full clean-state verification.

Each step ends with the suite green and a commit.

## Interfaces (before → after)

- `SlidingWindow`/`DisplayImageProvider` → `ImageWindow` (internal swap;
  `AppState` public property names unchanged).
- `ImageCacheStore.storeJPEG` — same signature; atomic replace inside.
- `TrashCommit`/`Trashing` — same signatures; `Trashing: Sendable`.
- `AppState.confirmCommit()` → `confirmCommit() async` (the only call site
  is ScrubView's button action, which becomes a Task).
- `DecodeEngine` — `init` gains optional `workerLimit: Int? = nil`.

## Testing

- Existing 65 tests stay green throughout.
- New tests: ImageWindow invariants (≤ 2r+1, eviction, stale discard,
  observability) replacing the SlidingWindow/DisplayImageProvider tests;
  waitUntilSettled timeout behavior; worker-limit rule
  (auto formula with injected memory, explicit limit honored, min 1);
  commit-while-running state transitions in AppStateTests.
- Commit-off-main-actor is covered by existing commit tests re-pointed at
  the async API.

## Risks

- **Window unification touches the most-tested concurrency in the app.**
  Mitigation: the new type keeps the same invariants, and the existing
  observation/eviction/stale-discard tests are re-targeted unchanged in
  spirit. Review the new type carefully before merging.
- **Async commit changes timing** of Trash moves; outcomes/flag semantics
  are identical.
- Worker-limit formula is a heuristic; the injectable parameter keeps it
  testable and adjustable without code churn.
