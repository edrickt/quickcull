# QuickCull code-quality audit — round 2 (2026-10-28)

- **Status:** executed, fixes landed, suite green
- **Baseline commit:** `cbe8cac` (post-1.0.1, post-QA-01…QA-40 wave)
- **Scope:** deferred rows from `2026-10-28-code-quality-audit.md §3` and
  `2026-10-24-code-audit.md §3`, plus a fresh read of every file that wave
  touched (`AppState`, `ImageWindow`, `ImageCacheStore`, `DecodeEngine`,
  `MoveCommit`, `KeyRouter`, `KeyboardMonitor`, grid/filmstrip/scrub views)
- **Method:** parent-run audit (no subagent tool in this session): re-read the
  two prior reports, re-verified each deferred row against the current tree,
  fixed every accepted finding with a regression test whose failure was
  checked against the pre-fix code, then `xcodebuild` Debug + Release and the
  full `xctest` suite.
- **Not re-reported:** the 40 findings of the 10-28 wave and the 31 of the
  10-24 wave are closed. Rows below that stay deferred keep the reasoning
  recorded here.

## 1. Baseline and final state

| | Baseline `cbe8cac` | Final (working tree) |
| --- | --- | --- |
| `QuickCullCore` Debug build | success | success |
| `QuickCull` Release build | success | success |
| Test suite | 262 tests, 0 failures | 264 tests, 0 failures |
| README / AGENTS claim | 262 tests | 264 tests |

Commands (same as prior waves):

```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Release \
  -derivedDataPath Build/Release build
```

Both new regression tests were observed red on the pre-fix code and green
after: the symlink-identity test failed with
`"/var/.../link.cr2" != "/var/.../target.cr2"`, and the benchmarks test
failed with `5 != 3`. Final `build-for-testing` + `xctest` reports 264
tests, 0 failures; Debug and Release build clean with no new warnings.

## 2. Ranked findings

Severity: P0 data loss or wrong files acted on; P1 user-visible correctness;
P2 memory/perf/honesty; P3 maintainability, tests, docs.

| ID | Sev | Finding | Evidence | Status |
| --- | --- | --- | --- | --- |
| QB-01 | P2 | A symlinked alias entered a session twice. `fileID` was the standardized path, so one photo picked through an alias and via its target had two identities, two cache entries, and two cells. | `Models/RawFileIdentity.swift:fileID`, `App/AppState.swift:importFiles` | Fixed: identity resolves symlinks; import dedupes by identity. `testFileIDResolvesSymlinksSoAnAliasIsNotADuplicate`. The five call sites that compared `.path` to an identity (`StubDecoder`/`StubTrasher` failIDs, `StubMover`, `TrashCommitTests`, `DecodeEngineTests`) now use `fileID(for:)` |
| QB-02 | P3 | `DecodeEngine.benchmarks()` grew one record per file for the life of the process and had no caller: ten re-imports of a 500-file shoot held 5,000 records. | `Engine/DecodeEngine.swift:benchmarkAccum` | Fixed: the accumulator drains at the start of every `decodeAll`, so it reflects the latest import. `testBenchmarksReflectOnlyTheLatestImport` (2 → 3, not 2 → 5) |
| QB-03 | P1 | Closing the window that opened a Trash/Move confirm left the app-wide pending slot taken with no dialog to clear it: every remaining window's Trash/Move menus stayed disabled until relaunch. | `ScrubView.swift` alerts (per-window `show*`) vs `AppState` app-wide `pending*` | Fixed: `ScrubView.onDisappear` cancels this window's own pending request (`showCommitConfirm`/`showMoveConfirm` are per-window, so a background window's disappear cannot cancel another window's dialog) |
| QB-04 | P1 | The hardened sheet check still missed one shape: `systemOwnsKeys` and the `KeyRouter` call site only tested `keyWindow?.isSheet`, but a `.fileImporter` sheet may hang off the key window (`attachedSheet`) rather than be it. Arrows/Space were then consumed as cull keys while the panel was open. | `KeyboardMonitor.swift:systemOwnsKeys/route` | Fixed: both paths treat any window with `isSheet` or a non-nil `attachedSheet` (plus `modalWindow`) as system-owned |
| QB-05 | P3 | `ImageCacheStore.defaultBaseURL()` force-unwrapped the Application Support lookup: a missing directory (managed/locked-down volume) crashed on first launch instead of falling back. | `Storage/ImageCacheStore.swift` | Fixed: falls back to `temporaryDirectory`; the cache is disposable by design |
| QB-06 | P2 | Grid opened at the shoot's first photo with no mark for where the user was (QA-40, deferred for product/UX + visual verification). | `GridView.swift`, QA-40 | Fixed (safe half, same pattern as the filmstrip's appear-scroll): entering grid scrolls to the current photo via `ScrollViewReader` + `.task(id: currentID)`. No selection or index change: position only |
| QB-07 | P3 | `toggleSelection` carried a stale plan comment (`"Plan says gridAnchorID = id but test expects …"`) that invited a "fix" of correct Finder semantics. | `App/AppState.swift:toggleSelection` | Fixed: comment states the rule (Cmd-click toggles without moving the Shift anchor) with no plan reference |

## 3. Accepted and deferred

| Item | Why not now |
| --- | --- |
| Cache size cap / free-space preflight before an import | Still product behavior (threshold + dialog policy), not a bug fix. `cannotStorePreview` keeps the failure honest |
| Swift 6 strict concurrency migration | Still out of scope by the wave-3 brief. `@unchecked Sendable` in `DecodeLimiter`/`LockedAccumulator` is lock-backed and correct |
| Keyboard-only access to Trash/Move menus | Still a UX decision (which chord for which colour), not a bug fix |
| Filmstrip re-keys all cells on every scrub/flag | Deliberate (preempted render passes dropped badges); changing it needs visual verification of that regression |
| Raw histogram black pedestal | Still needs a raw with a known black level; no fixture has one |
| Display/thumbnail limiter decode bodies on the cooperative pool | Still measured-symptom-free (100–400 ms JPEG decodes at limit 3 + 4; demosaic itself is already off-pool via `offCooperativePool`) |
| Monochrome-raw guard (QA-09) has no test | Still no mono-DNG fixture; the rendered-fallback it selects is covered |
| Live repro of sheet keys / grid scroll on a running GUI | No GUI session in this pass. Both changes widen an existing tested condition (system-owns-keys; scroll-to-current mirrors the filmstrip's proven appear-scroll) and the scrub window is never a sheet |
| `startNewSession` wipe vs a racing re-import | Investigated, no change: the wipe enqueues before any user-driven re-import (file-panel round trip), the actor serializes it ahead of the new stores, and launch/quit wipes are authoritative. A theoretical same-tick race would surface as honest `cannotStorePreview`, not silent corruption |
| Session `stashedCurrentID` surviving the removal of its own file | Investigated, no change: the dangling id falls back to index 0 through the same `?? 0` path a cleared stash takes, so the observable landing is identical |

## 4. Notes for the next pass

- `fileID` is now symlink-aware. Any new path-keyed state (selection sets, window identities, cache keys) must key on `fileID(for:)` or `SessionFile.id`, never on `url.path` or `standardizedFileURL`, or the alias-duplicate returns.
- `benchmarks()` is per-import diagnostics. If it ever gains a caller (import-speed UI), read it before the next `decodeAll`, which drains it.
- `ScrubView`'s alerts are per-window, the pending slot is app-wide. Any new destructive flow through `request*` needs the same `onDisappear` cancel its dialog owns, and must include the pending counts in its disabled state.
- `KeyboardMonitor.systemOwnsKeys` and the `KeyRouter` call site must stay in sync: any new system-owned surface (panel, sheet, editor) is added in both places.
