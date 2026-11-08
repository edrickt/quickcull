# QuickCull code-quality audit, round 3 (2026-11-08)

- **Status:** executed, fixes landed in the working tree (uncommitted); a
  verification follow-up (§6) tightened the fixes after independent review
- **Baseline commit:** `bdbcb97` (docs: add main screenshot to README)
- **Scope:** the whole repository at runtime weight: import/dedupe/commit
  (move and trash), the culling session and tricolor flag/filter model, the
  decoders, cache, metadata and histograms, the decode engine, scheduler and
  limiter, the image-window residency policy, the viewer surfaces (grid,
  filmstrip, scrub, zoom, loupe, HUD, badges, dropdowns, keyboard), the app
  shell and dialog lifecycle, and `Scripts/`
- **Method:** read `README.md`, `AGENTS.md`, `docs/README.md` and the three
  prior audit reports, then map the feature lanes and read every Swift source
  and every script in the tree. Each candidate finding was verified at
  `file:line` against the current code before it was accepted. Each accepted
  finding was fixed with a regression test. For QC3-01 the red run used the
  actual pre-fix script. For QC3-02 and QC3-03 the pre-fix logic lives in the
  app target or was inlined in it, so the red run used a temporary shim that
  reproduced it (the structured-group race and the old monitor rule); the shims
  are not in the tree. Then the full suite and both build configurations were
  run.
- **Not re-reported:** the 31 findings of `2026-10-24-code-audit.md`, the 40 of
  `2026-10-28-code-quality-audit.md` and the 7 of its round 2 are closed. The
  rows below are new or were still open in this tree.

## 1. Baseline and final state

| | Baseline `bdbcb97` | Final (working tree) |
| --- | --- | --- |
| `QuickCullCore` Debug build | success | success |
| `QuickCull` Debug app build | success | success |
| `QuickCull` Release build | success | success |
| Test suite | 264 tests, 0 failures, 95.5 s | 272 tests, 0 failures, 99.5 s |
| README / AGENTS claim | 264 tests | 272 tests |

Commands, all from the repo root:

```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest

xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/qc-app-dd CODE_SIGNING_ALLOWED=NO build
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Release \
  -derivedDataPath Build/Release build
```

The two `xcodebuild` app builds are needed because the test build does not
compile the `QuickCull` target, which is where QC3-02 and QC3-03 change code.
The table records the first pass; the verification follow-up in §6 raises the
suite to 282 tests and keeps the same builds green.

## 2. Findings fixed

Severity follows the earlier reports: P0 data loss or wrong files acted on,
P1 user-visible correctness or a documented workflow that does not work, P2
memory/perf/honesty/reliability, P3 maintainability, tests, docs.

| ID | Sev | Confidence | Finding | Evidence (pre-fix) | Fix | Regression test |
| --- | --- | --- | --- | --- | --- | --- |
| QC3-01 | P1 | High | `Scripts/start.sh`, the documented development loop, could not build: the repo tidy that moved it into `Scripts/` left its `cd` pointing at `Scripts/` while `xcodebuild` was still given the repo-root-relative `QuickCull.xcodeproj`. | `Scripts/start.sh:10` (`cd "$(dirname "$0")"`), `Scripts/start.sh:30` (`xcodebuild -project QuickCull.xcodeproj`); introduced by `0410427`; compare `install.sh` / `gen-compile-db.sh`, which use `/..` | `Scripts/start.sh:12` now `cd "$(dirname "$0")/.."`, usage comment corrected | `QuickCullCoreTests/Scripts/ScriptsContractTests.swift`, red before: "start.sh runs from Scripts but names QuickCull.xcodeproj, which is not there", green after |
| QC3-02 | P2 | High | The quit-time cache wipe's deadline could never fire. `withTaskGroup` + `cancelAll` waits for every child, and `ImageCacheStore.wipe()` does blocking `FileManager` calls with no cancellation checks, so a stalled volume kept Quit waiting past the documented "a few seconds". | `QuickCull/QuickCullApp.swift:41-48`; `QuickCullCore/Storage/ImageCacheStore.swift:49-57` (no cancellation checks in the wipe) | `QuickCullCore/Concurrency/AsyncTimeout.swift:16-53` (deadline clamp and unstructured race; timer cancelled on win) and `:59-97` (one-shot resume; the work is abandoned at the deadline); `QuickCull/QuickCullApp.swift:42-44` uses it | `QuickCullCoreTests/Concurrency/AsyncTimeoutTests.swift`: deadline case red first (the old group shape never returned; the suite was killed by an external 25 s alarm), green after |
| QC3-03 | P2 | High | The app-wide Space monitor consumed every bare Space in every state, but the loupe only activates while scrubbing outside the grid. In the importer, the decoding screen and the grid the key was swallowed with no effect: a focused button could not be activated with Space and the grid's scroll view could not page. | `QuickCull/KeyboardMonitor.swift:33-45`; the state guard that made the consumption pointless is the pre-fix `setLoupeActive` in `QuickCullCore/App/AppState.swift:168-176` | One predicate `AppState.canActivateLoupe` (scrubbing, non-grid, a rendered image, no commit/move in flight) shared by `setLoupeActive` and the monitor; pure rule `KeyRouter.consumesLoupeSpace(..., canActivateLoupe:)`; §6 tightened the rule after review | `QuickCullCoreTests/Keys/LoupeSpaceRoutingTests.swift` (4 cases), red before for the importer/grid cases, green after |
| QC3-04 | P3 | High | Test-hygiene drift left tests unable to catch what their names claim: two tests branched on a `Fixtures/raws/canon_eos6d.cr2` file that has never existed (dead fallback branches, plus one assertion that was true by construction), a test named `testSuperCCDAndXTransNowHaveHistogram` asserted `nil`, and the decode-determinism test compared only the first 1 KB of a ~25 MB buffer. | `QuickCullCoreTests/Decoding/LibRawDecoderTests.swift` (pre-fix lines 130, 147-169), `QuickCullCoreTests/Engine/DecodeEngineTests.swift` (pre-fix lines 192-206) | Dead branches removed; test renamed `testSuperCCDFallsBackToTheRenderedHistogram`; determinism compares the whole buffer; the old and explicit `.v1` decode paths compare unwrapped pixels | The tests themselves are the deliverable; both classes pass (`LibRawDecoderTests` 9 tests, `DecodeEngineTests` 13 tests) and the full-buffer equality holds on the CR2 fixture |
| QC3-05 | P3 | High | Documentation drift: README and AGENTS still claimed 264 tests, and `docs/README.md` did not mention the new `docs/audits/` tree. | `README.md:120`, `AGENTS.md:17`, `docs/README.md:7` | Counts updated to 272; `docs/audits/` documented in the docs index | no test (docs) |

### 2.1 QC3-01, the broken development loop

The repo tidy commit moved `start.sh` and `stop.sh` from the root into
`Scripts/` without changing `start.sh`'s `cd`. `stop.sh` only needs `pgrep` and
`osascript`, so it survived; `start.sh` builds and launches with paths relative
to the project root, so it failed before `xcodebuild` even started:

```
$ ./Scripts/start.sh
...
xcodebuild: error: 'QuickCull.xcodeproj' does not exist.
```

`ScriptsContractTests` is a path contract, not a hard-coded expectation: it
models the two `cd` spellings the scripts use, fails loudly on any other form,
and asserts that every repo-root-relative path a script names in code (the
project and the bridging header) resolves from the script's working directory.
A future move that forgets the `cd`, or a reintroduced form such as
`cd "$(dirname "$0")" || exit 1`, fails the contract instead of silently
defaulting to the repo root. The test also asserts `start.sh` stays executable,
because the documented invocation is `Scripts/start.sh`.

### 2.2 QC3-02, the deadline that could not fire

The quit path relies on a deadline: the cache can be gigabytes, and deleting it
from a stalled network volume must not freeze Quit. The previous implementation
raced a sleep against the wipe inside a structured task group:

```swift
await withTaskGroup(of: Void.self) { group in
    group.addTask { try? await cache.wipe() }
    group.addTask { try? await Task.sleep(...) }
    await group.next()
    group.cancelAll()
}
```

`group.cancelAll()` marks the wipe child cancelled, but `ImageCacheStore.wipe()`
runs `FileManager.removeItem` and `createDirectory` without checking
cancellation, so the syscall runs to completion; and the group scope waits for
every child before it returns. The deadline therefore never shortened the wait,
which contradicted the function's documentation.

`AsyncTimeout.run(seconds:operation:)` runs the operation in an unstructured
task and resumes the caller from the first of "operation finished" / "deadline
reached", guarded by a lock-backed one-shot continuation. The abandoned wipe
keeps running in the process until termination (it cannot be safely aborted),
which is the same outcome as before for a healthy volume and the launch wipe
covers the leftovers. The regression test exercises both orders: operation
first, deadline first with an operation that never resumes. The follow-up (§6)
then clamped the seconds-to-nanoseconds conversion (infinite, NaN or very large
values would trap `UInt64`), cancelled the timer when the operation wins, and
made the one-shot continuation safe if a fire ever lands before install.

### 2.3 QC3-03, Space stolen where the loupe cannot start

`AppState.setLoupeActive` gates the loupe, and the Space monitor had no such
gate, so it consumed the key in the importer (where Space activates the focused
"Choose Files" button for full-keyboard-access users), during decoding, and in
the grid (where Space is the scroll view's page key). The first fix filtered
only "scrubbing and not grid", which left three states swallowed: while a
commit or move was in flight, and in a filtered-empty projection, where
`setLoupeActive` refuses but the monitor still consumed. The follow-up (§6)
removed that drift by making one predicate the source of truth:

```swift
// AppState
public var canActivateLoupe: Bool {
    phase == .scrubbing && !isMoving && !isCommitting
        && viewMode != .grid && !(session?.files.isEmpty ?? true)
}

// KeyRouter
consumesLoupeSpace(..., systemOwnsKeys:, canActivateLoupe:)
```

`setLoupeActive` and the monitor both use it, so Space is consumed exactly when
a loupe can start and otherwise reaches the focused control, scroll view, or
system. `AppStateLoupeTests` pins the five states (scrub, grid, filtered-empty,
committing, moving) and `LoupeSpaceRoutingTests` pins the monitor rule.

### 2.4 QC3-04, tests that could not fail

`testLibRawDecoderProducesIdenticalPixelsAcrossDecodes` and
`testDecodeOptionsV1IsDefaultAndSourceCompatible` both preferred a
`canon_eos6d.cr2` fixture that the fixture set does not contain. Their fallback
branches were dead, one of them contained an assertion that was true by
construction (`fileExists(canon) || fileExists(url)` after `url` was
`XCTUnwrap`-ed), and the determinism test compared a 1 KB prefix, so
nondeterminism later in the frame was invisible. A third test's name claimed an
X-Trans histogram "now" exists while its body asserts nil; the only non-Bayer
fixture is a super-CCD, so the follow-up (§6) renamed it for what it exercises
and notes that no X-Trans fixture exists. The three are corrected; the
strengthened comparisons pass, which also confirms the decoder is
byte-deterministic on the pinned CR2.

## 3. Lanes reviewed without a new finding

| Lane | What was checked | Result |
| --- | --- | --- |
| Import, dedupe, commit | `AppState.importFiles` (identity dedupe, sort, unsupported-only path, failed-file removal), the snapshot and session-generation guards in `confirmCommit`/`confirmMove`, preview cleanup, `MoveCommit` same-directory identity, collision suffix, TOCTOU retry, `TrashCommit` per-file isolation | the AUD/QA contracts still hold; no new defect |
| Session and filters | `allFiles`/`files` projection invariants under every mutation, stashed current photo, nearest-match and forward tie-break, batch toggles, removal under filters, `flagRevision` | invariants hold; no new defect |
| Decoders and cache | stale-generation wipe guard, atomic store and unique temp names, key derivation (path + size + mtime), histogram sidecar validation, orientation round trip, worker-count rule | no new defect |
| Engine and limiter | cancellation of a running import, import-order outcomes, benchmark drain, FIFO slot hand-off, off-pool demosaic | no new defect |
| Image windows | residency bounds (strip cap, grid viewport), identity retarget, tier upgrade, in-flight supersession, viewport cancellation | no new defect |
| Metadata and histogram | cache-JPEG dimensions over displayed thumbnails, camera/lens trimming and make dedupe, rendered vs RAW labelling, clipping math, sampling edge | no new defect |
| Viewer surfaces | badge pinning and placeholder rule, zoom and pan clamps, loupe honesty (`isFullResolution`), HUD clear-on-change, grid/filmstrip identity keys and scroll-to-current, accessibility traits and actions | no new defect |
| App shell and dialogs | pending-slot exclusivity, per-window `onDisappear` cancel, sheet/modal/text key ownership, quit wipe, menu enablement, second-window behaviour | no new defect |
| Scripts | `start.sh`, `stop.sh`, `install.sh`, `build-libraw.sh`, `fetch-fixtures.sh`, `copy-test-fixtures.sh`, `gen-compile-db.sh`, `bench-decode.sh` and their documented invocations | QC3-01 found and fixed; the rest are consistent with `Scripts/README.md` |

## 4. Deferred, observed, not fixed

| Item | Why not now |
| --- | --- |
| Verification-script drift (P3): `Scripts/verify-dropdown.swift` mirrors `DropdownMenu` without the host-window guard added by QA-15, and `Scripts/verify-control-bar.swift` omits the "Filter" label `ScrubView` renders between the view picker and the filter segments | The documented `swift Scripts/verify-*.swift` invocation cannot run in this harness: `swift` exits 255 with a SwiftUI generic symbol dump, so a mirror edit could not be validated here. Editing a hand-maintained mirror blind trades one unverified file for another; this needs a GUI/toolchain pass |
| One-frame stale metadata when the HUD's file changes in place (viewer and split right pane). `MetadataHUDView` clears `metadata`/`histogram` inside `.task(id:)`, so the first body render after the file changes still shows the previous file's rows until the task starts | Needs a rendered check; the likely fix is `.id(file.id)` on the HUD call sites so SwiftUI resets its state with the file. No GUI session in this pass |
| Grid keyboard scrolling. QC3-03 returns Space to the scroll view, but arrow keys are still consumed in grid because QA-08 deliberately made them not move the invisible current index | Deciding that arrows should scroll the grid is a UX change, not a bug fix, and needs rendered verification |
| Cache size cap / free-space preflight before an import | Carried over unchanged from the earlier reports: product decision on threshold and dialog. `cannotStorePreview` keeps the failure honest in the meantime |
| Keyboard-only access to the Trash/Move menus | Carried over: which chord for which colour is a UX decision |
| Filmstrip re-keys all cells on every scrub/flag | Carried over: deliberate, and changing it needs visual verification of the stale-badge regression it prevents |
| Raw histogram black pedestal | Carried over: no fixture with a known black level to verify against |
| Decode bodies still run the limiter's body on the cooperative pool | Carried over: measured-symptom free (100 to 400 ms JPEG decodes at limits 3 and 4) |
| Monochrome raw guard (`filters == 0`) has no test | Carried over: no mono DNG fixture; the rendered-histogram fallback it selects is covered |
| Launch wipe racing a same-tick re-import | Carried over: the failure is an honest `cannotStorePreview`, not silent corruption |

## 5. Verification

- `build-for-testing`: success.
- Full suite: **272 tests, 0 failures, 99.5 s** (`xcrun xctest
  /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest`).
- `QuickCull` Debug app build: success.
- `QuickCull` Release build: success. Bundle checks: `codesign --verify
  --deep --strict` exit 0, app and `libraw.dylib` are universal
  (arm64 + x86_64), `libraw.dylib` is embedded inside
  `QuickCullCore.framework/Versions/A/Frameworks/`, and `Resources/Licenses/
  LGPL-2.1.txt` plus `Resources/NOTICE` are present, matching the README and
  NOTICE claims.
- Red then green: `ScriptsContractTests` failed on the actual pre-fix
  `start.sh` with the wrong-directory message. For QC3-02 and QC3-03 the
  pre-fix code is in the app target and cannot be imported by the test bundle,
  so the red run used temporary shims reproducing it: the deadline case hung
  until the suite was killed by an external alarm, and the router cases failed.
  The follow-up in §6 repeated the red check with the reintroduced bad `cd`
  form, which the tightened parser caught.
- Pre-existing `xcodebuild` warnings are unchanged (AppIntents metadata
  skipped, unsandboxed script phases in `Copy Headers`).
- Not run: live GUI checks (real key routing, loupe/zoom rendering, quit with a
  stalled cache volume) because this pass had no GUI session. Their decision
  logic is unit-tested; the rendered results still need an eyes-on pass.

## 6. Verification follow-up (after independent review)

An independent verifier reviewed the round-3 fixes: it found no regressions in
QC3-01 to QC3-05, and 272 tests plus both builds were green after the Lead's
1.0.3 / build 5 release bump. It found residual gaps and claim-precision
issues, fixed here. Version files and the release zip were left to the Lead.

| Item | What was wrong | Fix | Coverage |
| --- | --- | --- | --- |
| Space rule drift (P2, real residual bug) | The monitor's rule filtered only "scrubbing and not grid", so it still swallowed Space while a commit or move was in flight and in a filtered-empty projection, states where `setLoupeActive` refuses and no loupe can appear | Single `AppState.canActivateLoupe` (scrubbing, non-grid, rendered image, no commit or move in flight) used by both `setLoupeActive` and the monitor; `KeyRouter.consumesLoupeSpace` takes `canActivateLoupe` | `AppStateLoupeTests` (5: scrub, grid, filtered-empty, committing, moving) plus the updated `LoupeSpaceRoutingTests` (4) |
| ScriptsContractTests blind spot | The parser recognized only two exact `cd` spellings and silently defaulted to the repo root for anything else, so `cd "$(dirname "$0")" || exit 1` reintroducing the original bug would pass; it also matched paths in comments and depended on the tracked fixture directory | The contract fails loudly on an unrecognized `cd` form, scans code lines only, and checks the project and bridging header (not the fixture directory) | 2 new tests: unrecognized form throws, commented paths are not contracts. Red verified by temporarily restoring `cd "$(dirname "$0")" || exit 1` in `start.sh`: the test failed with the loud message, and passed again after restore |
| AsyncTimeout hardening | `UInt64(max(0, seconds) * 1e9)` traps for infinite, NaN or very large deadlines; the losing timer kept sleeping; the one-shot continuation would lose a fire that preceded install | Deadline clamped to `0...24 h`; the timer task is cancelled when the operation wins; `SingleResume` remembers a fire before install | 3 new tests: clamp table, huge/infinite/NaN run without trapping, fire-before-install; the fast path now asserts elapsed under 0.5 s, so an always-wait implementation fails |
| Test polish | `testDecodeOptionsV1IsDefaultAndSourceCompatible` compared optional `Data?` values (a both-nil pass was possible), and the non-Bayer histogram test claimed X-Trans although the only fixture is a super-CCD | Both decode blobs `XCTUnwrap`-ed and compared; test renamed `testSuperCCDFallsBackToTheRenderedHistogram` with a note that no X-Trans fixture exists | `DecodeEngineTests` (13) and `LibRawDecoderTests` (9) pass |
| Docs and precision | `Scripts/stop.sh` usage still said `./stop.sh`; `Scripts/README.md` said all scripts run from the repo root; several report claims were imprecise (red-first method, the script contract's genericity, the loupe rule, and the "no version bump" close) | Usage and wording fixed; §1, §2.1, §2.2, §2.3 and §5 corrected above; test counts moved to 282 | docs only |

Follow-up verification, same commands as §1:

- `build-for-testing`: success.
- Full suite: **282 tests, 0 failures, 98.0 s**.
- `QuickCull` Debug app build: success.
- Release was not rebuilt in this follow-up: the Lead built the 1.0.3 release
  zip, and version files plus the project file were not touched here.

No new dependencies, no version edits, no commit, push or tag.

No commit, push or tag was made; this audit pass left version files untouched.
The Lead separately applied the 1.0.3 / build 5 release bump and built the
release zip after this pass.
