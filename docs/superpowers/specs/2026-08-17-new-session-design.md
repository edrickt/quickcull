# New Session Button — Design

Date: 2026-08-17
Status: approved design (pre-plan)

## Purpose

Add a New Session button to start a fresh culling session without quitting the app. It is the in-app equivalent of quitting and relaunching: the current session (flags, failures, windows, view state) is discarded, the decode cache is wiped, and the UI returns to the empty `Import` state where the user can choose new RAW files.

## Background

Today `QuickCull` starts in `EmptyStateView` (`phase==.empty` → “Choose RAW Files…”). `AppState.importFiles(urls:)` creates a `Session`, decodes via `DecodeEngine` → `ImageCacheStore`, then `phase==.scrubbing` shows `ScrubView` (`ImageDisplayView` + `FilmstripView` / `GridView`). Quitting triggers a best-effort `cache.wipe()`; `prepareForLaunch()` does the authoritative `cache.wipe()` on next launch. `RootView` switches on `phase`; `ScrubView` toolbar owns `Filter`/`ViewMode`/`Trash` and already resets zoom on `phase==.empty|decoding` and `viewMode` toggle. There is no explicit “new session” affordance — the only way to reset is to quit, wait for wipe, and relaunch, or import a new file selection (which replaces `session` but does not wipe cache or clear import/commit failures uniformly).

## Approach (approved)

**Option A — Single `AppState.startNewSession()` method (chosen).**

`AppState` owns the reset (same authoritative `Task { try? await cache.wipe() }` as `prepareForLaunch`). `ScrubView` adds a toolbar `New Session` button (visible only while scrubbing) that always shows a confirmation alert before calling it. `phase=.empty` drives `RootView` back to `EmptyStateView`; existing `onChange(phase)` zoom reset and `RootView` branching do the rest. No new targets, no fileImporter chaining.

Rejected: (B) reuse `importFiles([])` hack — conflates “no file” failure banner with reset; (C) auto-open fileImporter after reset from `RootView` — couples reset to import, diverges from “like quit/relaunch → empty state first”.

## Architecture

- No new targets. 2 files changed, 0 new.
- `QuickCullCore/App/AppState.swift` — add `func startNewSession()` (or `resetToEmpty()`) that is the single owner of the full-reset sequence.
- `QuickCull/ScrubView.swift` — add toolbar button + `showNewSessionConfirm` state + confirmation `alert` that calls `startNewSession()`.
- Nothing else (`EmptyStateView`, `RootView`, `Session`, `ImageWindow`, `DecodeEngine`, `TrashCommit`, `ImageCacheStore`) changes beyond being cleared via `AppState`.

```
RootView (phase switch)
  ├─ .empty    → EmptyStateView (Choose RAW Files…)
  ├─ .decoding → DecodingView
  └─ .scrubbing→ ScrubView (New Session | View | Filter | Trash)
                 └─ AppState.startNewSession() → wipe cache, nil session/windows,
                    clear failures/selection/viewMode, phase=.empty → RootView flips to Empty
```

## Model — `QuickCullCore/App/AppState`

```swift
/// Full reset equivalent to quit+relaunch. Single owner of the empty transition.
/// Always confirmed by the caller (ScrubView), so no flag-count guard here.
@MainActor
public func startNewSession() {
    // Authoritative cache wipe like prepareForLaunch, but awaited vs detached?
    // Use detached best-effort (like prepareForLaunch) so UI returns to Empty immediately;
    // wipe runs concurrently, next import will write fresh entries.
    Task { try? await cache.wipe() }
    session = nil
    thumbWindow = nil
    gridThumbs = nil
    displayImages = nil
    importFailures = []
    commitFailures = []
    pendingCommitCount = 0
    isCommitting = false // defensive: new session never committing
    gridSelection = []
    gridAnchorID = nil
    viewMode = .scrub
    phase = .empty
}
```

- Guard: none (caller already confirmed). If `phase != .scrubbing`, no-op or treat same as above (idempotent empty).
- Ordering: clear windows before `phase=.empty` so `RootView` unmounts `ScrubView` cleanly; `ScrubView`’s `onChange(phase)` zoom reset fires automatically.
- Cache: `Task { try? await cache.wipe() }` matches `prepareForLaunch:48` (detached, best-effort, covers crash leftovers; launch wipe remains authoritative). Alternative `await cache.wipe()` would block UI until disk delete finishes — not desired.
- No `pendingCommit` cancellation needed; `isCommitting` is false in scrubbing per `confirmCommit` guard, and `startNewSession` is disabled while committing.

## App Flow — `QuickCull/ScrubView`

```swift
@State private var showNewSessionConfirm = false

ToolbarItem(placement: .primaryAction) {
  Button { showNewSessionConfirm = true } label: { Label("New Session", systemImage: "plus.rectangle") }
    .disabled(appState.isCommitting) // also disable during .decoding? Only shown in scrubbing, so not needed
}
.alert("Start new session?", isPresented: $showNewSessionConfirm) {
  Button("Start New Session", role: .destructive) { appState.startNewSession() }
  Button("Cancel", role: .cancel) { }
} message: {
  Text("Current session — including flagged photos — will be discarded. The decode cache will be cleared.")
}
```

- Placement: `.primaryAction` toolbar, first item before `View` picker (leftmost), so `New Session | Single/Grid | Filter | Trash` left→right, matching “like quit” mental model (new session is a session-level action, not per-photo).
- Confirmation: **always** shown (per user choice), even when `flaggedCount==0`, with `destructive` primary button.
- Disabled while `isCommitting` (mirrors `Trash` button), preventing reset mid-`confirmCommit` detached `TrashCommit` work.
- Not shown while `phase==.decoding` (ScrubView not visible), and not needed in `EmptyStateView` (already empty).
- `RootView` requires no change: `phase=.empty` already shows `EmptyStateView`.

## Edge Cases

| Case | Behavior |
|------|----------|
| In Grid with multi-selection | `startNewSession` clears `gridSelection`/`gridAnchorID`; no ghost selection survives |
| Zoomed to 200% in Single | `phase=.empty` triggers `ScrubView.onChange(phase)` zoom reset to 1× (already exists) |
| Filter is Flagged/Keepers | `session` niled, `viewMode=.scrub`, `filter` resets via new `Session` on next import |
| Pending `importFailures`/`commitFailures` banner | Cleared to `[]`, banners disappear with session |
| Decoding in-flight (should not happen: button only in scrubbing) | If somehow called, `Task`-wiping still safe; `session.remove` race not possible because reset nils windows before `phase=.empty` |
| Commit in-flight (`isCommitting==true`) | Button disabled, alert cannot be presented; no reset until commit finishes |
| Cache wipe fails (disk error) | `try?` best-effort, same as `prepareForLaunch`; next launch wipe is authoritative, session still resets |
| Repeated New Session while already empty | Idempotent: second call sees `session==nil`, `phase==.empty`, re-wipes, no crash |

## Testing

### Unit — `QuickCullCoreTests/AppStateTests.swift`

- `testStartNewSessionResetsToEmpty` — import 2 files → wait for scrubbing → `setFilter(.flagged)`/flag one → `selectSingle` in grid + zoom state via ScrubView not needed → call `sut.startNewSession()` → assert `phase==.empty`, `session==nil`, `thumbWindow==nil && gridThumbs==nil && displayImages==nil`, `importFailures.isEmpty && commitFailures.isEmpty`, `gridSelection.isEmpty`, `viewMode==.scrub`, `pendingCommitCount==0`, `!isCommitting`. Also verify `cache.wipe()` was awaited? Use injected `ImageCacheStore(baseURL: tmp)` with a marker file and assert deleted after `startNewSession` settles (allow `Task` to run via `await Task.yield()` or make `startNewSession` async for testability — prefer `async` version if needed).

### Integration — AppState + RootView

- Existing `AppStateTests` for `importFiles`, `setFilter`, `commit` must still pass; `startNewSession` is additive, no existing path changes.

### Manual QA

- Import set → flag 1 → in Single zoomed 200% → click `New Session` → alert always → Cancel → still scrubbing, flag retained; → `New Session` → Confirm → `EmptyStateView` (Choose RAW Files), no banners, `phase==.empty`, cache dir empty (`ls ~/Library/Application Support/QuickCull/cache`).
- While `Trash` committing (flagged → Move to Trash spinner), `New Session` button disabled.
- From Grid with 2 selected, `New Session` → confirm → empty, grid selection cleared (reopen new import → grid empty).

## Out of Scope

- File menu `File > New Session (Cmd+N)` shortcut — toolbar only in v1 (menu can be added later behind same `AppState` call).
- New Session button in `EmptyStateView` (already empty) or `DecodingView` (button not visible during decode).
- Auto-opening fileImporter after reset (user lands on empty, clicks `Choose RAW Files…`).
- Undo of New Session (like undo Trash) — flags/cache discarded, no recovery.
- Persistent session history or recent imports list.
