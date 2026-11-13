# QuickCull code-quality audit, round 4 (2026-11-12)

- **Status:** executed. Fixes and this report are committed locally on `main`;
  nothing was pushed, tagged or released, and version files were not touched.
- **Repository:** `/Users/etm1air/Files/Github/quickcull`
- **Baseline commit:** `49356ae` (docs: add codebase map for agent exploration),
  working tree clean
- **Environment:** macOS 26.0.1 (25A362), Apple silicon (8 cores, 8 GiB visible
  to `DecodeEngine.workerCount`), Xcode 26.3 (17C529), Swift 6.2.4
  (swiftlang-6.2.4.1.4). The built app is still 1.0.4 (build 6): the release
  version bump is pending and owned by the Lead.
- **Audit date:** 2026-11-12, America/Detroit
- **Scope:** the whole repository at runtime weight, as in round 3 — import,
  dedupe and the early-view handoff, commit and move (including their overlap
  with the background decode), the culling session and tricolor flag/filter
  model, the decoders, cache, metadata and histograms, the decode engine,
  scheduler and limiter, image-window residency, the viewer surfaces (grid,
  filmstrip, scrub, zoom, loupe, HUD, badges, dropdowns, keyboard), the app
  shell and dialog lifecycle, `Scripts/`, and the test suite's own reliability.
- **Method:** read `AGENTS.md`, `docs/README.md`, `docs/agents/codebase-map.md`
  and the round-3 report first, then every Swift source in `QuickCull/`,
  `QuickCullCore/` and `QuickCullCoreTests/`, every script in `Scripts/`, and
  the newest feature commit (`8644c35`, cull before the import finishes
  decoding). Each candidate finding was verified at `file:line` against this
  tree before it was accepted. Accepted findings were fixed with a regression
  test. For the two core files the pre-fix red run restored the file from
  `HEAD` and rebuilt; for the app-target key rule the pre-fix rule was reverted
  in place and rebuilt; the flaky test's red evidence is its failure in this
  audit's first full-suite run. Then the full suite and both build
  configurations were run.
- **Not re-reported:** the five findings of the 2026-11-08 round 3 and its §6
  follow-up are closed; nothing below repeats them. Prior deferred items are
  carried in §4.

## 1. Baseline and final state

| | Baseline `49356ae` | Final (audit commits) |
| --- | --- | --- |
| `QuickCullCore` Debug `build-for-testing` | success | success |
| `QuickCull` Release app build | success | success |
| Test suite | 296 tests, 0 failures, 107.0 s | 302 tests, 0 failures, 119.4 s |
| README / AGENTS / map claim | 296 tests | 302 tests |

Commands, all from the repo root:

```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest

xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Release \
  -derivedDataPath Build/Release build
```

The test build does not compile the `QuickCull` app target; the only app-target
change in this pass (`KeyboardMonitor.swift`) is covered by the Release gate.

## 2. Findings fixed

Severity follows the earlier reports: P0 data loss or wrong files acted on, P1
user-visible correctness or a documented workflow that does not work,
P2 memory/perf/honesty/reliability, P3 maintainability, tests, docs.

| ID | Sev | Confidence | Location (post-fix) | Finding / impact | Evidence (pre-fix) | Fix | Regression test |
| --- | --- | --- | --- | --- | --- | --- | --- |
| QC4-01 | P2 | High | `QuickCullCore/App/AppState.swift:62`, `:72`, `:218-238`, `:237`, `:462` | A Space-loupe hold outlived the activation context it started in. `isLoupeActive` was cleared only by the phase/view-mode transitions and an explicit release, but the states that make `canActivateLoupe` false (a pending Trash/Move dialog, and a filter projection that empties) never cleared it. Hold Space over an image, open the Trash dialog with the mouse, release Space while the sheet owns the keys, then cancel: the loupe and the hidden cursor come back with no key held. | `QuickCullCore/App/AppState.swift:60` (`pendingCommitCount`), `:68` (`pendingMoveCount`), `:430` (`installWindows`), `:213` (`setLoupeActive`); `QuickCull/KeyboardMonitor.swift:39-45` returns the key-up unconsumed whenever the predicate is false, so a release never reaches `setLoupeActive(false)` | `releaseLoupeHold()` called from `didSet` on `pendingCommitCount`/`pendingMoveCount` and from `installWindows` when the projection is empty; `canActivateLoupe` also requires both pending counts to be zero | `AppStateLoupeTests.testAPendingTrashDialogReleasesAHeldLoupe`, `testAPendingMoveDialogReleasesAHeldLoupe`, `testAnEmptyFilterProjectionReleasesAHeldLoupe` |
| QC4-02 | P2 | High | `QuickCullCore/App/AppState.swift:218-238`; `QuickCullCore/Keys/KeyRouter.swift:74-89`; `QuickCull/KeyboardMonitor.swift:33-60` | `canActivateLoupe`'s contract (and the round-3 report) says "scrubbing with a rendered image", but it only checked that the projection was non-empty. During the early-view background decode a photo whose preview has not landed shows the viewer's loading state; Space over it was swallowed and produced no loupe — the QC3-03 failure class, reintroduced by the early-view feature. Relatedly, the monitor decided the key-up with the same rule, so a release arriving after the context disappeared (image left the preload window, a commit started, a sheet appeared) was not consumed and never cleared a live hold. | `QuickCullCore/App/AppState.swift:205-211` (predicate), `QuickCull/KeyboardMonitor.swift:39-49`, `QuickCullCore/Keys/KeyRouter.swift:68-77` (pre-fix rule); the early-view handoff at `AppState.swift:323-337` can leave the viewer on its spinner for seconds on a long shoot | Predicate requires the viewer's own fallback chain — `displayImages.image(at:)` or `thumbWindow.image(at:)` for the current index. `consumesLoupeSpace` takes `isKeyUp`/`isLoupeActive` and consumes the release of a live hold; the monitor passes both and calls `setLoupeActive(false)` on release | `AppStateLoupeTests.testCanActivateLoupeRequiresARenderedImage`; `LoupeSpaceRoutingTests.testASpaceReleaseEndsALiveHoldWhereANewHoldCouldNotStart` |
| QC4-03 | P3 | High | `QuickCullCore/Window/ImageWindow.swift:70`, `:145`, `:192`, `:436-437`, `:646` | A discarded image window kept decoding. `ImageWindow` had no teardown: `transitionToEmptySession` and the re-import rebuild drop the three windows, but their in-flight and queued load tasks kept running (the display window queues its whole extent current-first) — results no window can show, competing with the session that replaced it for decode-limiter slots, CPU and image memory. | `QuickCullCore/Window/ImageWindow.swift:55` (`taskByID`), `:522-557` (`display` queues the extent), and no `deinit` in the file | The same tasks are tracked in a small `LoadTasks` reference box so `deinit` can cancel them; the window's own bookkeeping stays main-actor isolated | `ImageWindowTests.testDiscardingAWindowCancelsItsInFlightLoads` |
| QC4-04 | P3 | High | `QuickCullCoreTests/App/AppStateEarlyViewTests.swift:231`, `:342` | A test could not observe what it asserts. `testDismissedFailuresAreNotResurrectedByLaterFailures` assumed it reads the banner exactly at the handoff turn and that the "late" failure (`files[8]`) lands after it. Neither holds: the decode event stream is buffered and the import loop can drain many events in one main-actor turn, and `SlowStubDecoder` holds its lock across the simulated decode, so completion order is not import order. Flaky, not deterministic: it passed the baseline run and failed this audit's first full-suite run. | `QuickCullCoreTests/App/AppStateEarlyViewTests.swift:225-255` (pre-fix test; `lateBad` `:228`, threshold `:232`, handoff assertion `:237`); `QuickCullCoreTests/Support/TestDoubles.swift:49-94` (`SlowStubDecoder` lock held across the delay); failure output: at the handoff the banner held both failures (`[…e000.cr2, …e008.cr2]` vs `[…e000.cr2]`), then the resurface and completed-event assertions failed too | The late failure is gated: `GatedMidDecodeDecoder` gained `failIDs` and `gatedError`; the test waits for the early failure to be reported, dismisses, then opens the gate, so the ordering the test names is true by construction | The test itself; the class passed three consecutive runs and the full suite is green |

### 2.1 QC4-01, a loupe that outlived its Space press

The loupe is a hold: the app-wide monitor sets `isLoupeActive` on the Space
key-down and clears it on the key-up, and `ZoomableImageView` renders and hides
the cursor from that flag. A key-up only reaches the monitor's logic when the
event reaches the app at all, and when a sheet is up (`systemOwnsKeys`) the
monitor deliberately passes the key through. The release path had no other
reader, so the sequence "hold Space, click Trash, release Space, cancel the
dialog" left `isLoupeActive == true` with no key down; the next hover then
showed the loupe and hid the cursor for a hold the user had already ended.

The fix keeps one invariant: every transition that makes `canActivateLoupe`
false ends a live hold. The pending commit/move counts and an emptied
projection now clear it where the state changes, instead of relying on a future
key-up that the monitor may never see. The regression tests drive each
transition from a live hold (set, then the transition, then assert the hold is
gone and that returning to the normal state does not restore it).

### 2.2 QC4-02, Space consumed where the loupe cannot render

`canActivateLoupe`'s doc comment and the round-3 report both describe
"scrubbing with a rendered image", but the predicate only checked that the
projection was non-empty. That was close enough before the early-view feature:
after the handoff every preview existed, so the viewer's spinner lasted a
decode latency. With the handoff, a photo navigated to before its preview
lands can show the loading state for seconds, and Space over it was consumed
with no loupe and no way to activate a focused control.

The predicate now asks the viewer's own fallback chain whether there is an
image to magnify (`ImageDisplayView` draws `displayImages.image(at:)` and falls
back to the filmstrip thumbnail). One consequence needed a companion rule: with
`canActivateLoupe` able to go false between the key-down and the key-up (the
photo's image leaving the preload window, a commit starting, a sheet appearing),
the key-up must still be consumed to end the live hold — `consumesLoupeSpace`
asks for the key phase and the hold state and consumes the release of a live
hold even where a new hold could not start. The table-driven router tests pin
both directions.

### 2.3 QC4-03, a discarded window kept decoding

`ImageWindow` owns every load task it starts. When a session is torn down (New
Session, a commit that empties the session, a re-import rebuilding the windows)
the windows are dropped, but a `Task` is not tied to its creator's lifetime: the
display window queues its whole extent current-first, and those tasks kept
decoding full-resolution JPEGs that no window could ever show, while the
session that replaced it competed for the shared decode limiter.

`deinit` now cancels the tasks still registered. That cannot be done from the
window's main-actor-isolated dictionary, so the tasks are mirrored into a small
locked `LoadTasks` box that `deinit` can read; entries are removed when a load
settles or when a `retarget(ids:)` drops the identity (whose task completion
returns early at the stale-token guard and so cannot untrack itself), keeping
the box bounded by the loads the window still owns. The regression test
parks a loader on a gate, drops the window, releases the gate, and requires the
loader to observe cancellation.

### 2.4 QC4-04, a test that observed the wrong moment

The dismissed-failure test is a state-machine test: the early failure is
reported at the handoff, the user dismisses it, a later failure re-surfaces the
banner with only itself, and the completed event must not resurrect the
dismissed entry. It implemented the "late" half with `SlowStubDecoder(delay:
20 ms)` and assumed the handoff observation happened at the handoff turn. Two
facts make that assumption false: the import loop consumes a buffered
`AsyncStream` and can drain many events in one main-actor turn (the test's poll
runs on the same actor), and `SlowStubDecoder` holds its lock across the
simulated decode, so the index-8 failure is not ordered after the two successes
that open culling. The run in this audit saw both failures at the handoff
assertion, then failed the resurface and completed-event assertions.

The late failure is now gated: the decoder blocks on a semaphore and the test
opens it only after dismissing the banner. The early failure is awaited rather
than assumed, and the handoff-moment assumption is gone. The class passed three
consecutive runs and the full suite is green.

## 3. Lanes reviewed without a new finding

| Lane | What was checked | Result |
| --- | --- | --- |
| Import, dedupe, early view | identity dedupe and sort, unsupported-only path, threshold handoff and progress, mid-view failure pruning, commit/move overlapping the background decode, dismissed-banner bookkeeping, session-generation guards, preview discard for a file removed mid-decode | no new defect; the order-dependence in the dismissal test is QC4-04 |
| Session and filters | projection invariants under `toggleFlag`/`toggleFlags`/`remove`/`setFilter`, stashed current photo, nearest-match tie-break, empty placeholder fallback, flag revision | no new defect |
| Decoders and cache | LibRaw/ImageIO routing, error taxonomy, cache key derivation, atomic store and replace, wipe generation guards, histogram sidecars, full/half-res decodes | no new defect |
| Engine and limiter | worker rule, FIFO job queue, cancellation, per-file/progress/completed ordering, benchmark reset, off-pool demosaic | no new defect |
| Image windows | residency bounds, retarget preservation, in-flight supersession and tokens, viewport bounds, refresh/retry, tier upgrade | the missing teardown is QC4-03 |
| Metadata and histograms | cache-JPEG dimension precedence, EXIF parsing, rendered-vs-RAW labelling, clipping/mean math, sidecar shape validation | no new defect |
| Viewer surfaces | single/split/grid/filmstrip badges, HUD lifecycle, zoom and pan clamps, loupe honesty, dropdown click-through | no new defect |
| Keyboard and focus | key map (keyCode and printed letter), modifier/sheet/text passthrough, Space routing, quit-time key state | hold lifetime and rendered-image gap are QC4-01/02 |
| App shell and dialogs | phase machine, New Session gating, alert lifecycle, quit wipe, one-shot monitor and launch wipe | no new defect |
| Scripts and docs | working directories and documented invocations of `start.sh`, `stop.sh`, `install.sh`, `gen-compile-db.sh`, fixture scripts; README/AGENTS/map claims and test counts | no new defect; counts and map anchors refreshed |

## 4. Deferred, observed, not fixed

| Item | Why not now |
| --- | --- |
| Verification-script drift (carried): `Scripts/verify-dropdown.swift` mirrors `DropdownMenu` without the QA-15 host-window guard, and `Scripts/verify-control-bar.swift` omits the "Filter" label `ScrubView` renders between the view picker and the filter segments | The documented `swift Scripts/verify-*.swift` invocation still cannot run here: it fails with a SwiftUI symbol dump and `JIT session error: Symbols not found: [ ___isPlatformVersionAtLeast ]` (reproduced this pass). Editing hand-maintained mirrors blind trades one unverified file for another; needs a GUI/toolchain pass |
| One-frame stale metadata when the HUD's file changes in place (viewer and split right pane) | Needs a rendered check; likely `.id(file.id)` on the HUD call sites. No GUI session in this pass |
| Grid keyboard scrolling (carried) | QC3-03 returns Space to the scroll view, but arrows are still not consumed in grid by design; deciding they should scroll is UX, not a bug fix |
| Cache size cap / free-space preflight before an import (carried) | Product decision on threshold and dialog; `cannotStorePreview` keeps the failure honest |
| Keyboard-only access to the Trash/Move menus (carried) | Which chord for which colour is a UX decision |
| Filmstrip re-keys all cells on every scrub/flag (carried) | Deliberate; changing it needs visual verification of the stale-badge regression it prevents |
| Raw histogram black pedestal (carried) | No fixture with a known black level to verify against |
| Monochrome raw guard (`filters == 0`) has no test (carried) | No mono DNG fixture; the rendered-histogram fallback it selects is covered |
| Launch/New-Session wipe racing a decode that finishes afterwards | `ImageCacheStore`'s generation guard stops stores that *began* before the wipe, but a decode already past its cancellation check can call `storeJPEG` after the wipe and write its preview into the fresh cache. Impact is orphan disk only (the key is recomputed, the window is gone, and the next wipe removes it), not a stale preview; the minimal fix is to snapshot the cache generation at decode start rather than at store time |
| `ImageWindow` full-res upgrade retries indefinitely if a full-res decode fails while a reduced placeholder is resident | The completion re-runs `startLoad` because `degradedIDs` still contains the identity. Not reachable with the ImageIO decoders in this tree (both tiers fail together), but it is an unbounded loop if a future loader can fail one tier only |
| `AppState.resolvedPreviewURLs` stats every flagged file on the main actor at commit start | A very large "All Flagged" commit pays one stat per file before the detached commit. Bounded by the shoot size and not measured as a symptom; noted only |

## 5. Verification

- `build-for-testing`: success.
- Full suite: **302 tests, 0 failures, 119.4 s** (`xcrun xctest
  /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest`; 296 at the
  baseline).
- Release: **success** (`xcodebuild … -configuration Release
  -derivedDataPath Build/Release build`). Bundle checks: `codesign --verify
  --deep --strict` exit 0; `QuickCull` and `libraw.dylib` are universal
  (x86_64 + arm64); `libraw.dylib` is embedded at
  `QuickCullCore.framework/Versions/A/Frameworks/libraw.dylib`;
  `Resources/Licenses/LGPL-2.1.txt` and `Resources/NOTICE` are present. The
  built app is still 1.0.4 (build 6); `Build/libraw/` was not rebuilt (the
  version marker was valid).
- Red then green:
  - QC4-01 / QC4-02 (predicate) / QC4-03: restored `AppState.swift` and
    `ImageWindow.swift` from `HEAD` and rebuilt. Four new
    `AppStateLoupeTests` cases failed (pending Trash, pending Move, empty
    filter, rendered image) and `ImageWindowTests
    .testDiscardingAWindowCancelsItsInFlightLoads` failed with "a discarded
    window must cancel its in-flight decode". Restored the fixes: green.
  - QC4-02 (release rule): reverted `if isKeyUp, isLoupeActive { return true }`
    to the pre-fix rule and rebuilt; `LoupeSpaceRoutingTests
    .testASpaceReleaseEndsALiveHoldWhereANewHoldCouldNotStart` failed both
    release assertions. Restored: green.
  - QC4-04: the pre-fix test failed in this audit's first full-suite run on
    this machine (output quoted in §2, QC4-04). The rewritten test passed
    three consecutive class runs and the full suite.
- New warnings: none. The pre-existing warnings are unchanged (the
  "tasks in 'Copy Headers' are delayed by unsandboxed script phases"
  project warning, the AppIntents metadata skip, and the test-target warnings
  in `ImageCacheStoreTests`, `SessionTests`, `TricolorSessionTests`,
  `TestDoubles`, `TestFixtures`, `ImageIODecoderTests`, `AppStateTests`,
  `TrashCommitTests` and `ImageWindowTests`).
- Not run: live GUI checks (real key events through the monitor, loupe/zoom
  rendering, New Session mid-fill) because this pass had no GUI session. The
  routing decisions are unit-tested; the changed app-target code is a thin
  adapter over them, so the monitor still wants an eyes-on pass.

## 6. Notes: files changed

| File | Change |
| --- | --- |
| `QuickCullCore/App/AppState.swift` | loupe hold invalidation on the pending/empty transitions, predicate requires a rendered image and no pending dialog, `releaseLoupeHold` |
| `QuickCullCore/Keys/KeyRouter.swift` | Space key-up rule for a live hold |
| `QuickCull/KeyboardMonitor.swift` | passes the key phase and the hold state, clears the hold on release |
| `QuickCullCore/Window/ImageWindow.swift` | `LoadTasks` registry and `deinit` cancellation of queued loads |
| `QuickCullCoreTests/App/AppStateLoupeTests.swift` | four new cases; setup settles the windows the predicate now reads |
| `QuickCullCoreTests/Keys/LoupeSpaceRoutingTests.swift` | one new case for the release rule |
| `QuickCullCoreTests/Window/ImageWindowTests.swift` | one new case for discard-time cancellation |
| `QuickCullCoreTests/App/AppStateEarlyViewTests.swift` | deterministic dismissal test (gated late failure) |
| `AGENTS.md`, `README.md` | test count 296 → 302 |
| `docs/agents/codebase-map.md` | 302 tests; refreshed `AppState`/`ImageWindow` line anchors; `Verified against` bumped to the fix commit |
| `docs/audits/2026-11-12-code-quality-audit.md` | this report |

Two local commits on `main`: `fix: address code-quality audit findings` and
`docs: add 2026-11-12 audit report`. No version files were edited (still
1.0.4/build 6), nothing was pushed, and no tag or release was created.
