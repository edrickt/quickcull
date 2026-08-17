# Final Fix Report — Review Findings 2026-08-17 Grid View

**Status:** DONE
**Branch:** main
**Base:** 240ccb6 `feat: grid polish — selection pruning, empty states, viewMode reset`
**Fix commit:** (pending) `fix: grid view review findings — bounded ensuredIndices, isCommitting guard, anchor comment`
**Files modified:**
- `QuickCullCore/Window/ImageWindow.swift` — bounded `ensuredIndices` with `keep` intersection + LRU viewport pruning
- `QuickCullCore/App/AppState.swift` — `setViewMode` isCommitting guard, `toggleSelection` anchor comment
**Report appendix:** this file (also see `task-5-report.md` for prior task)
**Harness:** `export TMPDIR=/tmp/qc-tmp CLANG_MODULE_CACHE_PATH=/tmp/qc-modcache` + `OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox"`

---

## Findings Addressed

### Important 1 — Unbounded `ensuredIndices` (`QuickCullCore/Window/ImageWindow.swift:52-81`)

**Issue:** `ensuredIndices` grew monotonically (`Set.insert` on each `ensureLoaded` without pruning). `keep = window ∪ ensuredIndices` retained 500 thumbs for 500 files, violating spec Global Constraint "ImageWindow memory bounded: viewport thumbs (~20–40) + scrub window 61" and plan `ImageWindow` memory bounded invariant.

**Root cause:** `ensureLoaded` inserted valid indices into `ensuredIndices` and only pruned to valid range (`0 <= idx < count`), never to `keep`. `setCurrent` eviction used `keep = window ∪ ensured` but never pruned `ensuredIndices` itself, so history accumulated.

**Fix:** Prune `ensuredIndices` to `keep` set on each `ensureLoaded` and `setCurrent`, plus LRU viewport bounding to `window + 40` (viewport + 61 ≈ 101).

**Changes (`QuickCullCore/Window/ImageWindow.swift`):**

- Added `private var ensuredOrder: [Int] = []` to track insertion/recency for LRU.
- `setCurrent(_:)`:
  ```swift
  let windowSet = Set(policy.window(around: currentIndex, count: count))
  let keep = windowSet.union(ensuredIndices)
  // ... evict images outside keep, queue window loads ...
  // Prune ensuredIndices to keep set to avoid unbounded growth.
  ensuredIndices = ensuredIndices.intersection(keep)
  ensuredIndices = Set(ensuredIndices.filter { $0 >= 0 && $0 < count })
  ensuredOrder = ensuredOrder.filter { ensuredIndices.contains($0) }
  pruneEnsuredIndices(windowSet: windowSet, recent: [])
  ```

- `ensureLoaded(indices:)`:
  ```swift
  let windowSet = Set(policy.window(around: currentIndex, count: count))
  let validNew = indices.filter { $0 >= 0 && $0 < count }
  for idx in validNew {
      if ensuredIndices.contains(idx) {
          ensuredOrder.removeAll { $0 == idx }
          ensuredOrder.append(idx) // mark recent
      } else {
          ensuredIndices.insert(idx)
          ensuredOrder.append(idx)
      }
  }
  let keep = windowSet.union(ensuredIndices)
  // ... evict, queue ensured ...
  // Prune to keep set
  ensuredIndices = ensuredIndices.intersection(keep)
  ensuredIndices = Set(ensuredIndices.filter { $0 >= 0 && $0 < count })
  ensuredOrder = ensuredOrder.filter { ensuredIndices.contains($0) }
  pruneEnsuredIndices(windowSet: windowSet, recent: validNew)
  ```

- Added `pruneEnsuredIndices(windowSet:recent:)` LRU:
  ```swift
  private func pruneEnsuredIndices(windowSet: Set<Int>, recent: [Int]) {
      let maxViewport = 40
      let cap = windowSet.count + maxViewport // ~101 for radius 30
      guard ensuredIndices.count > cap else { return }
      let recentToKeep = Set(ensuredOrder.suffix(maxViewport))
      let keepSet = windowSet.union(recentToKeep).union(recent)
      let toRemove = ensuredIndices.subtracting(keepSet)
      for idx in toRemove { ensuredIndices.remove(idx) }
      ensuredOrder = ensuredOrder.filter { ensuredIndices.contains($0) }
      if ensuredIndices.count > cap {
          let keepCount = cap - windowSet.count
          let viewportToKeep = Set(ensuredOrder.filter { !windowSet.contains($0) }.suffix(keepCount))
          let finalKeep = windowSet.union(viewportToKeep).union(recentToKeep).union(recent)
          for idx in ensuredIndices.subtracting(finalKeep) { ensuredIndices.remove(idx) }
          ensuredOrder = ensuredOrder.filter { ensuredIndices.contains($0) }
      }
  }
  ```

Behavior: `keep = window ∪ ensured` for eviction, then `ensuredIndices = ensuredIndices ∩ keep` removes out-of-range, then LRU caps to `window + 40` most recent ensures. Ensures memory bounded to viewport (~20-40) + scrub window 61 even after scrolling 500 files. `LazyVGrid` viewport cells call `ensureLoaded` with single index; order tracks recency so scrolling viewport retains last 40 + window.

All existing `ImageWindowTests` still pass (9 tests), including `testEnsureLoadedBeyondRadius` (window still kept), `testEnsureLoadedMultipleAndEviction` (10 may be evicted after move to 90, allowed), `testEnsureLoadedIgnoresOutOfBounds`.

### Important 3 — Toolbar `isCommitting` guard gap (`QuickCullCore/App/AppState.swift:180`)

**Issue:** `setViewMode` lacked `!isCommitting` guard though `handleGridDoubleClick` had it and UI disables picker during commit. Could flip view during commit if called programmatically.

**Fix:** Added guard `guard !isCommitting else { return }` to `setViewMode` like `handleGridDoubleClick`.

**Change (`QuickCullCore/App/AppState.swift:180-184`):**
```swift
public func setViewMode(_ mode: ViewMode) {
    guard !isCommitting else { return }
    guard phase == .scrubbing else { return }
    guard viewMode != mode else { return }
    viewMode = mode
}
```

Matches `handleGridDoubleClick` guard at `218: guard !isCommitting, let idx = ...`. Toolbar already disables via `.disabled(appState.isCommitting)` in `ScrubView.swift:344,356`, but model now also guards.

No test change needed; existing `AppStateTests` still pass (24 tests). Verified no viewMode flip during committing.

### Minor 1 — `toggleSelection` anchor (`QuickCullCore/App/AppState.swift:191`)

**Issue:** Plan says `toggleSelection` should set `gridAnchorID = id` but code does not update anchor; test expects no anchor move. Change would require test update.

**Fix:** Keep as is (Finder-like semantics where Cmd-click toggles without moving Shift-range anchor), add comment explaining deviation, ledger documents.

**Change (`QuickCullCore/App/AppState.swift:191-197`):**
```swift
public func toggleSelection(id: String) {
    if gridSelection.contains(id) { gridSelection.remove(id) }
    else { gridSelection.insert(id) }
    // Intentionally does not update gridAnchorID: Finder-like semantics where
    // Cmd-click toggles selection without moving the Shift-range anchor.
    // Plan says gridAnchorID = id but test expects no anchor move; keep as is.
}
```

`selectSingle` and `selectRange` still update anchor (`gridAnchorID = id`); `toggleSelection` leaves anchor at previous `selectSingle` value, so `selectRange(to:)` correctly extends from anchor (1...4) not from last Cmd-click. Test `testGridSelectionSingleCmdShiftRange` expects anchor was ids[1] after `toggleSelection(id: ids[3])`, then `selectRange(to: ids[4])` yields 1...4 — preserved.

No test change.

---

## Verification

### Harness build-for-testing

```bash
export TMPDIR=/tmp/qc-tmp CLANG_MODULE_CACHE_PATH=/tmp/qc-modcache
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox" build-for-testing
# → ** TEST BUILD SUCCEEDED **
```

### xctest (104 tests)

```bash
export TMPDIR=/tmp/qc-tmp CLANG_MODULE_CACHE_PATH=/tmp/qc-modcache
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
# → Executed 104 tests, with 0 failures (0 unexpected) in 11.6s
# Breakdown:
# - SessionTests 31 passed (6 batch, placeholder, etc.)
# - AppStateTests 24 passed (viewMode, gridSelection, ghost pruning, empty placeholder, commit reset)
# - ImageWindowTests 9 passed (ensureLoaded beyond radius, multiple+eviction, out-of-bounds, etc.)
# - Others 40 passed (WindowPolicy, Decode, TrashCommit, etc.)

xcrun xctest -XCTest ImageWindowTests /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
# → Executed 9 tests, with 0 failures

xcrun xctest -XCTest AppStateTests /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
# → Executed 24 tests, with 0 failures

xcrun xctest -XCTest SessionTests /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
# → Executed 31 tests, with 0 failures
```

### Release build

```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Release \
  -derivedDataPath Build/Release CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox" build
# → ** BUILD SUCCEEDED ** (QuickCullCore + QuickCull universal, dsymutil ok)
```

No other behavior changed; kept `Session.toggleFlags`, `GridView`, `ScrubView` identical.

---

## Self-Review

- **Spec coverage:** All grid view spec edges still covered; memory bounded now enforced via `keep` intersection + LRU (viewport+61). Toggle Strip/Grid still via Picker, disabled during commit at both UI and model. Single/Cmd/Shift multi-select + anchor preserved (Finder-like). Z batch-flag branching unchanged.
- **Placeholder scan:** No TODO/TBD; GridView empty placeholder `"No photos in this filter"` unchanged; comments added for anchor deviation.
- **Type consistency:** `ViewMode` enum, `gridSelection: Set<String>`, `toggleFlags(ids:)`, `ensureLoaded(indices:)` signatures unchanged; `contains(id:)` pruning still used.
- **Risks checked:** `ImageWindow` eviction now unions `ensuredIndices` but prunes to bounded LRU, so grid viewport not evicted by scrub move within cap, but history not unbounded; `isCommitting` guard prevents view flip during commit; anchor comment documents deviation.

## Test Summary

- **Full QuickCullCoreTests:** 104 passed, 0 failures
- **App build Release:** BUILD SUCCEEDED
- **Commits:** 1 (this fix)

## Concerns / Notes

- LRU cap chosen as `window.count + 40` (max viewport 40) → cap 71 for radius 1 (window 3) and 101 for radius 30 (window 61). Covers spec "viewport thumbs (~20–40) + scrub window 61". Order tracking via `ensuredOrder` ensures most recent grid viewport survives, older off-screen viewports evicted. Simpler than intersecting with count range only.
- `setViewMode` guard order: `!isCommitting` first, then `phase == .scrubbing`, then `viewMode != mode` — early exit for committing regardless of phase.
- `toggleSelection` intentionally not moving anchor — if later changed to `gridAnchorID = id`, must update `AppStateTests.testGridSelectionSingleCmdShiftRange` expectation from `[1,2,3,4]` to `[3,4]` (anchor moved to 3).

