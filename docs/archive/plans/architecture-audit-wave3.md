# QuickCull Major Architecture Audit — Implementation Plan

- **Status:** draft
- **Date:** 2026-10-19
- **Slug:** `architecture-audit-wave3`
- **Brief:** `docs/plans/architecture-audit-wave3.brief.md`
- **Implementation started:** _not started_

## 1. Context

QuickCull has shipped v1, Refactor Wave 1 (consolidation/hardening), and Refactor
Wave 2 (dead-code, duplication, and hot-path cleanup). Wave 2 was a
full-codebase cleanup, but not a boundary-level risk review. The next refactor
wave needs a ranked, evidence-backed input instead of an ad-hoc list of smells.

This plan executes the audit described in the brief. It is **read-only for
production code**: the audit adds a Markdown report and diagnostic test files
only. It does not fix Wave 3 defects, change app behavior, or write the Wave 3
plan.

Baseline established on 2026-10-19 at commit `c5f892c`:

- Xcode 26.3 (build 17C529), Swift 6.2.4 compiler, Swift 5 language mode.
- `xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing` — succeeded.
- `xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest` — **207 tests, 0 failures, 80.715s**.
- Targeted form verified: `xcrun xctest -XCTest QuickCullCoreTests.WindowPolicyTests /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest` — 8 tests, 0 failures.
- Git status: only `docs/plans/` is untracked (the brief). No production changes.
- The README says 205 tests; the suite contains 207 test methods. The audit
  records this drift rather than silently fixing it.

A confirmed anchor finding is already visible: `ImageWindow.gridThumbnails`
uses `WindowPolicy(radius: files.count)`, so every grid cell is inside the
policy window and `WindowPolicy.toEvict` never evicts a loaded grid thumbnail
(`QuickCullCore/Window/ImageWindow.swift:334-338`,
`QuickCullCore/Window/WindowPolicy.swift:51-54`). The images dictionary thus
grows with the shoot. The README describes retaining scrolled-past cells
(`README.md:11`), but the brief records the maintainer's decision that grid
residency must be bounded.

## 2. Goal and success criteria

- **Goal:** Produce a decision-shaped, evidence-ranked audit of QuickCull's
  major architecture points that recommends a defensible Wave 3 scope.

- **Success criteria:**
  - [ ] Baseline, environment, and verification commands are recorded in the
        report — proven by the commands in section 8.
  - [ ] The report scores all eight major architecture points with a verdict,
        file:line evidence, and a disposition — proven by the report review
        checklist in 3.2.
  - [ ] Ranked findings state severity, confidence, effort, type
        (refactor/fix), and disposition — proven by the report table review.
  - [ ] The top 3–5 findings that could change the Wave 3 ranking have either a
        diagnostic test that fails when enabled, or a recorded "no test seam"
        note — proven by the targeted `xctest` runs in Phase 2.
  - [ ] The grid-residency diagnostic test fails when enabled (resident count
        > 61) and is skipped by default — proven by
        `GridResidencyAuditTests`.
  - [ ] The recommended Wave 3 scope maps every candidate workstream to ranked
        finding IDs and separates behavior changes from refactors — proven by
        the report review checklist.
  - [ ] The audit changes no production file and the full suite stays green —
        proven by `git diff --name-only` and the full suite command.
  - [ ] The maintainer accepts the report and recommended scope — proven by the
        approval question in 3.3.

## 3. Non-goals

- No production code changes during the audit; no Wave 3 fixes.
- No runtime benchmarks, Instruments traces, or real photo-shoot measurements.
- No feature work, UI redesign, format support changes, or decode-quality work.
- No detailed Wave 3 design or task sequencing; that is a separate `/plan`
  invocation on the recommended scope.
- No Swift 6 strict-concurrency migration as part of this audit.
- No security, licensing, signing, notarization, or distribution audit beyond
  what directly affects the eight architecture points.
- No commits, pushes, or PRs unless the maintainer explicitly asks.

## 4. Decisions and assumptions

| Decision | Choice | Rationale |
| --- | --- | --- |
| Audit artifact | One report at `docs/audits/2026-10-19-architecture-audit.md` | Keeps audit artifacts separate from feature specs and plans. |
| Production code | Read-only; docs and test files only | The audit must not destabilize the app or pre-empt Wave 3. |
| Broad screen shape | Eight points, grouped into four screening tasks | Keeps each task 45–90 minutes and avoids eight shallow passes. |
| Phase 1 execution | Sequential; all screen tasks update the same report | Avoids merge conflicts in the shared scorecard; the screen is fast enough. |
| Ranking lens | Data safety/correctness → memory/performance → maintainability | Destructive trash/move and correctness failures outrank cleanup. |
| Tie-break | Likelihood × impact ÷ effort | Prevents high-effort but low-impact findings from crowding the top. |
| Deep dives | Top 3–5 findings only | The brief's stopping rule; the rest remain screened hypotheses. |
| Proof tests | Diagnostic tests, skipped by default with a finding ID | Preserves red evidence without breaking the 207-test regression bar. |
| Grid cap | Provisional 61, mirroring the filmstrip | Concrete enough to prove the defect; `/plan` confirms the final constant. |
| Test runner | `xcodebuild build-for-testing` + `xcrun xctest` | Matches the README and was verified on the baseline. |
| Test count | 207 actual; README says 205 | Record the drift; do not silently edit README. |
| Report status | `Status: accepted` added only after user acceptance | Keeps the handoff explicit. |
| Commits | None unless requested | Grill/plan guardrail. |

**Assumptions:**

- The baseline 207-test suite remains green throughout; any new failure is
  caused by the audit and must be investigated before proceeding.
- The grid-residency defect is real and can be proven with a 100-file synthetic
  fixture; no real photo library is needed.
- The other top findings can be expressed as unit or integration tests. If one
  cannot, the report records "no test seam" and Wave 3 must add the seam first;
  the audit does not implement a no-seam behavior change.
- The maintainer reviews the ranking. Ranking is a judgment call; the report
  labels confidence and unproven risks instead of pretending to be exhaustive.
- The report uses relative paths and synthetic fixture descriptions only; no
  personal data, secrets, or absolute home paths.
- No `AGENTS.md`/`CONTRIBUTING.md` exists; repository conventions come from the
  README, existing specs/plans, and the surrounding code.

## 5. Approach

### Audit flow

1. **Baseline and scaffold (Phase 0).** Capture the environment, suite result,
   commands, and git state. Create the report with the severity rubric, finding
   template, and eight-point scorecard so later work is decision-shaped from
   the start.
2. **Broad screen (Phase 1).** Four tasks cover eight points:
   - state/projection/destructive actions (AppState, Session, Trash/Move);
   - decode/cache/metadata pipeline;
   - window/residency/memory;
   - concurrency/module/build/test boundaries.
   Each task records findings in a consistent template: evidence, impact,
   likelihood, confidence, effort, type, disposition, and proof-test idea.
   Findings are candidate-level here; ranking happens after all four screens.
3. **Rank and select (Phase 2.1).** Merge duplicates, assign stable `AUD-*` IDs,
   score and rank, then select the top 3–5 findings that could change the Wave 3
   decision. Every selected finding gets a proof-test spec or a "no seam" note.
4. **Prove (Phase 2.2–2.5).** Add diagnostic tests under
   `QuickCullCoreTests/Audit/`. Each test is run unskipped to capture the red
   failure, then guarded with `XCTSkip("<finding ID>: ...")` so the normal suite
   stays green. No production file changes.
5. **Report and handoff (Phase 3).** Write the final ranked report and
   recommended Wave 3 scope, run the full verification, and ask the maintainer
   to accept it. Do not start Wave 3.

### Report shape

`docs/audits/2026-10-19-architecture-audit.md` contains:

1. Executive summary and a one-paragraph recommendation.
2. Method, scope, baseline, and evidence standard.
3. Eight-point architecture scorecard.
4. Ranked findings table with IDs, severity, confidence, effort, type, and
   disposition.
5. Deep dives for the top 3–5 findings, including red evidence.
6. Recommended Wave 3 scope: workstreams mapped to finding IDs, with
   fix/refactor labels, dependencies, rough effort, and risk.
7. Accepted tradeoffs and explicit "no action" items.
8. Unproven risks and open questions.
9. Appendix A: commands and red/green evidence.
10. Appendix B: documentation drift, including the 205/207 test-count mismatch.

### Severity, confidence, effort, and disposition

| Field | Values | Meaning |
| --- | --- | --- |
| Severity | P0 | Data loss or destructive-operation failure. |
| | P1 | User-visible correctness failure or corrupted state. |
| | P2 | Memory/perf degradation or resource growth. |
| | P3 | Maintainability/change-friction only. |
| Confidence | High / Medium / Low | High = proven by test or direct code path; Medium = strong static evidence; Low = hypothesis. |
| Effort | S / M / L | S < 1 hour, M 1–4 hours, L > 4 hours (rough Wave 3 estimate). |
| Type | Refactor / Fix | Behavior-preserving vs behavior-changing. |
| Disposition | Deep dive / Defer / Accept / No action | Whether it enters Phase 2, is deferred, or is an accepted tradeoff. |

### Candidate proof-test specs

These are seeds for Phase 2.1; only selected findings get tests.

- **AUD-GRID-01 (confirmed):** Given 100 files and a grid window, when every
  grid cell is ensured, then resident images stay at or below 61; today
  `images.count == 100` because the grid policy radius is the file count.
- **AUD-SELECT-01 (candidate):** Given a ghost grid selection that is no longer
  visible after a filter switch, when a batch flag action runs, then the
  invisible file must not be mutated; today `AppState.handle` passes
  `gridSelection` to `Session.toggleFlags`, which accepts any ID in `allFiles`.
- **AUD-CACHE-01 (candidate):** Given a cache wipe while a decode is in flight,
  when the decode completes, then no cache entry may survive the wipe; today
  the wipe is fire-and-forget and `DecodeEngine` only checks cancellation
  between files. This may need a seam; if so, record "no seam" for Wave 3.
- **AUD-STATE-01 (candidate):** Given identical trash/move flows, when one
  state machine is changed, then the other must not silently diverge. This is a
  refactor observation, not a red test; a characterization test can document the
  current duplicate transitions if it changes the ranking.
- **AUD-CONC-01 (candidate):** Synchronous `RawDecoding` inside `TaskGroup`
  workers blocks cooperative-pool threads. This is unproven without runtime
  measurement; mark confidence Low/Medium and do not claim a failure.

### Test strategy (TDD)

- **Acceptance examples:**
  - Given the completed report, when a reader selects any scorecard row, then
    the row states a verdict, file:line evidence, and a disposition.
  - Given two findings with different severity tiers, when the ranking is read,
    then data-safety/correctness findings outrank memory/performance findings,
    which outrank maintainability findings.
  - Given a 100-file session and the grid window, when every grid cell is
    ensured, then `ImageWindow.images.count <= 61`; today it reaches 100.
  - Given the default test run after the audit, when the audit tests are
    skipped, then the existing 207 tests pass and the commands are unchanged.
  - Given the recommended Wave 3 scope, when a finding is a confirmed defect,
    then it is labeled a behavior change with a red test; refactors are labeled
    behavior-preserving.
- **Test levels and seams:**
  - Unit/policy: `WindowPolicy`, `Session`, `CullKeyMap`,
    `DropdownClickPolicy`, `WindowHitTest`, `FlagBadgeLogic`.
  - Integration: `ImageWindow` with a real temporary `ImageCacheStore`, tiny
    JPEG fixtures, and stub loaders; `DecodeEngine` with `StubDecoder`/
    `SlowStubDecoder`; `TrashCommit`/`MoveCommit` with stubs and temp dirs.
  - App/state: `AppState` with a real temp cache and injected decoder/trasher/
    mover.
  - No UI or end-to-end automation; the app target has no test bundle and the
    audit does not add one.
- **Fixtures and test data:**
  - `TestFixtures.makeTempDir(name:)`, `writeJPEG(color:width:height:to:)`,
    `makeCGImage`, `makeTempCache()`.
  - 100 tiny JPEGs for the grid-residency proof test, written to a temp cache
    so `ImageWindow.gridThumbnails` can decode them.
  - Existing raw fixtures under `QuickCullCoreTests/Fixtures/raws/` for any
    decoder-boundary tests; no new real-world photo data.
  - Stub/gated decoders, trashers, and movers already in the test target.
- **Red command:**
  `xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing`
  then
  `xcrun xctest -XCTest QuickCullCoreTests.<AuditTestClass> /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest`
- **Green command:** same targeted command with the `XCTSkip` guard in place;
  expected one skipped test.
- **Full suite:**
  `xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest`
- **Regression protection:** the existing 207 tests must keep passing; the
  documented build/test commands and target layout must keep working;
  user-visible flows, formats, decode quality, trash/move semantics, and the
  no-new-dependency constraint are the Wave 3 contract.
- **TDD exceptions:** Phase 0 baseline/scaffold, Phase 1 screen tasks, Phase 2.1
  ranking, and Phase 3 report/verification/handoff are non-behavioral analysis
  and documentation. No failing test starts them; the existing suite and report
  review are the checks. Diagnostic test tasks do have red/green evidence even
  though they change no production behavior.
- **Behavioral exceptions:** none. The audit implements no production behavior
  change. Diagnostic tests are test-only evidence. Any Wave 3 behavior change is
  out of scope for this plan and must be planned separately with tests first; if
  it has no seam, that later plan must record an approved no-seam exception with
  user approval and a follow-up.
- **Non-testable scope:** ranking judgment, report usefulness, whether a missed
  risk mattered, and whether the provisional grid cap is the right UX/memory
  tradeoff. These are reviewed by the maintainer and labeled with confidence,
  not asserted as tests.

## 6. Work breakdown

### Phase 0 — Baseline and report scaffold

**Outcome:** The environment, suite baseline, commands, and report structure
are recorded; every later task has a place to put evidence.

- [ ] **0.1 Capture baseline and create the report**
  - **Files:** `docs/audits/2026-10-19-architecture-audit.md`
  - **Changes:** Create the report with a baseline table: date, commit
    `c5f892c`, Xcode/Swift versions, build command, full-suite result
    (207 tests, 0 failures, 80.715s), targeted-command verification, git status,
    and the 205/207 README drift. Add a one-sentence audit purpose.
  - **TDD exception:** Non-behavioral measurement and documentation; no
    failing test applies. Existing checks: the build and full-suite commands
    recorded in the table.
  - **Verify:** `xcodebuild ... build-for-testing`; `xcrun xctest ...`; `git status --short`.
  - **Depends on:** none

- [ ] **0.2 Add method, rubric, scorecard, and finding template**
  - **Files:** `docs/audits/2026-10-19-architecture-audit.md`
  - **Changes:** Add method/scope, the severity/confidence/effort/type/
    disposition rubric from section 5, the eight-point scorecard, the ranked
    findings table placeholder, the recommended-scope placeholder, and the
    appendices. Add the finding template:
    `ID | Title | Evidence | Impact | Likelihood | Confidence | Effort | Type | Disposition | Proof-test idea`.
  - **TDD exception:** Documentation-only; no behavior change. Existing checks:
    read-back checklist that all sections and eight scorecard rows exist.
  - **Verify:** Read the report and confirm all eight points, all rubric values,
    and all finding-template fields are present.
  - **Depends on:** 0.1

### Phase 1 — Broad screen

**Outcome:** All eight major architecture points have a verdict, cited evidence,
and candidate findings; no ranking is final yet.

- [ ] **1.1 Screen state, projection, and destructive actions**
  - **Files to read:** `QuickCullCore/App/AppState.swift`,
    `QuickCullCore/Session/Session.swift`,
    `QuickCullCore/Session/CullFilter.swift`,
    `QuickCullCore/Session/FlagColor.swift`,
    `QuickCullCore/Commit/TrashCommit.swift`,
    `QuickCullCore/Commit/MoveCommit.swift`,
    `QuickCull/ScrubView.swift`, `QuickCull/GridView.swift`,
    `QuickCull/FilmstripView.swift`,
    `QuickCullCoreTests/AppStateTests.swift`,
    `QuickCullCoreTests/App/AppStateCommitLifecycleTests.swift`,
    `QuickCullCoreTests/App/AppStateMoveTests.swift`,
    `QuickCullCoreTests/App/AppStateTricolorTests.swift`,
    `QuickCullCoreTests/SessionTests.swift`,
    `QuickCullCoreTests/Session/TricolorSessionTests.swift`,
    `QuickCullCoreTests/TrashCommitTests.swift`,
    `QuickCullCoreTests/Commit/MoveCommitTests.swift`
  - **Changes:** Fill the scorecard rows for AppState, Session, and
    Trash/Move; add candidate findings using the 0.2 template.
  - **Checklist:**
    - Single source of truth for phase, session, windows, selection, commit
      state; any second owner or stale state.
    - Duplicate trash/move state machines: `pending*`, `last*`, failure arrays,
      revision counters, completion, cancel/new-session behavior; can they
      diverge?
    - Ghost grid selection after a filter change; can a batch flag mutate an
      invisible file? Empty-projection fallback differences between
      `setFilter`, `toggleFlag`, and `toggleFlags`.
    - Empty-state transitions: unsupported import early return, all-failed,
      commit-all, new session; any session/windows left behind.
    - Commit/move outcomes: per-file success/failure, failed flags retained,
      removal from session, UI enable/disable, error visibility.
    - Existing tests that already protect or intentionally preserve the
      behavior.
  - **TDD exception:** Non-behavioral code analysis; no failing test applies.
    Existing checks: the cited tests and report review.
  - **Verify:** The report rows are complete; every claim cites file:line or a
    test; at least five candidate findings or an explicit "sound" verdict with
    evidence.
  - **Depends on:** 0.2

- [ ] **1.2 Screen decode, cache, and metadata pipeline**
  - **Files to read:** `QuickCullCore/Engine/DecodeEngine.swift`,
    `QuickCullCore/Engine/DecodeLimiter.swift`,
    `QuickCullCore/Decoding/RawDecoding.swift`,
    `QuickCullCore/Decoding/LibRawDecoder.swift`,
    `QuickCullCore/Decoding/ImageIODecoder.swift`,
    `QuickCullCore/Storage/ImageCacheStore.swift`,
    `QuickCullCore/App/AppState.swift` (import/wipe paths),
    `QuickCull/QuickCullApp.swift`,
    `QuickCullCore/Metadata/ImageMetadataProvider.swift`,
    `QuickCullCore/Metadata/RawHistogram.swift`,
    `QuickCull/MetadataHUDView.swift`,
    `QuickCullCoreTests/DecodeEngineTests.swift`,
    `QuickCullCoreTests/DecodeLimiterTests.swift`,
    `QuickCullCoreTests/LibRawDecoderTests.swift`,
    `QuickCullCoreTests/ImageIODecoderTests.swift`,
    `QuickCullCoreTests/ImageCacheStoreTests.swift`,
    `QuickCullCoreTests/ImageMetadataProviderTests.swift`,
    `QuickCullCoreTests/RawHistogramTests.swift`
  - **Changes:** Fill the decode/cache/metadata scorecard rows and add
    candidate findings.
  - **Checklist:**
    - Worker pool, memory formula, `TaskGroup`, synchronous decoder calls,
      cancellation granularity, progress stream, error taxonomy, dead benchmark
      API.
    - Cache ownership: writes through the actor vs reads through `cacheURL`;
      atomic write; wipe fire-and-forget; wipe vs in-flight decode; swallowed
      errors; sidecar corruption vs absence; test-only delete APIs.
    - Metadata/histogram placement: view-level fallback, cache-URL construction
      in the view, detached I/O, missing provider seam, histogram stats.
    - Test seams and fixtures that cover or miss each path.
  - **TDD exception:** Non-behavioral code analysis; existing checks are the
    cited tests and report review.
  - **Verify:** Scorecard rows complete; every claim cites file:line or a test;
    at least five candidate findings or an explicit "sound" verdict.
  - **Depends on:** 0.2

- [ ] **1.3 Screen window, residency, and memory**
  - **Files to read:** `QuickCullCore/Window/ImageWindow.swift`,
    `QuickCullCore/Window/WindowPolicy.swift`,
    `QuickCull/ImageDisplayView.swift`, `QuickCull/ZoomableImageView.swift`,
    `QuickCull/GridView.swift`, `QuickCull/FilmstripView.swift`,
    `QuickCullCore/App/AppState.swift` (window installation/sync),
    `QuickCullCoreTests/ImageWindowTests.swift`,
    `QuickCullCoreTests/WindowPolicyTests.swift`,
    `QuickCullCoreTests/App/AppStateWindowRetargetTests.swift`,
    `README.md` (memory claims and grid wording)
  - **Changes:** Fill the window/residency scorecard rows and add candidate
    findings, including the confirmed grid defect and its evidence.
  - **Checklist:**
    - Confirm grid policy radius = file count, empty `toEvict`, images never
      evicted; `pruneEnsuredIndices` bounds bookkeeping only; quantify with
      100/1,000 synthetic files.
    - Filmstrip/display bounds, tiering, upgrade policy, retarget, in-flight
      loads, stale completions, cancellation.
    - README memory claims (1.2 GB / 2.3 GB) vs actual full/half-res counts;
      global decode limiters and `UserDefaults` knobs.
    - UI behavior: visible-cell lazy loads, placeholder/re-decode after
      eviction, grid scroll memory.
    - Test coverage gap: no test exercises the grid factory's bound.
  - **TDD exception:** Non-behavioral code analysis; existing checks are the
    cited tests and report review.
  - **Verify:** Scorecard rows complete; grid finding cites the factory,
    policy, eviction path, and README contradiction; every other claim cites
    file:line or a test.
  - **Depends on:** 0.2

- [ ] **1.4 Screen concurrency, module, build, and test boundaries**
  - **Files to read:** `QuickCullCore/App/AppState.swift`,
    `QuickCullCore/Window/ImageWindow.swift`,
    `QuickCullCore/Engine/DecodeEngine.swift`,
    `QuickCullCore/Engine/DecodeLimiter.swift`,
    `QuickCull/MetadataHUDView.swift`, `QuickCull/QuickCullApp.swift`,
    `QuickCull.xcodeproj/project.pbxproj`,
    `QuickCull.xcodeproj/xcshareddata/xcschemes/QuickCullCore.xcscheme`,
    `Scripts/build-libraw.sh`, `Scripts/copy-test-fixtures.sh`,
    `QuickCullCoreTests/TestFixtures.swift`,
    `QuickCullCoreTests/TestDoubles.swift`, `README.md`,
    `docs/superpowers/specs/2026-08-16-refactor-wave1-design.md`,
    `docs/superpowers/specs/2026-08-27-refactor-wave2-design.md`
  - **Changes:** Fill the concurrency/boundary scorecard rows and add candidate
    findings.
  - **Checklist:**
    - Isolation: MainActor state, actors, detached tasks, `@unchecked
      Sendable`, `NSLock`, global limiters, Swift 5 assumptions, main-thread
      I/O.
    - App/Core boundary: dependency direction, AppKit/Darwin/ImageIO/
      UserDefaults/FileManager coupling, portability vs testability.
    - Build: manual `.pbxproj`, synchronized groups, LibRaw build phase,
      universal dylib, schemes, fixture copy script, absence of CI.
    - Test architecture: 207 tests, fixture realism, real cache vs fakes,
      missing protocols/seams, test runtime, coverage gaps.
    - Documentation drift: test count, memory narrative, grid retention
      wording, prior-wave claims.
  - **TDD exception:** Non-behavioral code analysis; existing checks are the
    cited tests and report review.
  - **Verify:** Scorecard rows complete; every claim cites file:line or a test;
    documentation drift is recorded in Appendix B.
  - **Depends on:** 0.2

### Phase 2 — Rank, select, and prove

**Outcome:** The top 3–5 decision-relevant findings are ranked and each has
either a skipped diagnostic test with recorded red evidence or a "no seam"
note.

- [ ] **2.1 Consolidate, rank, and select the top findings**
  - **Files:** `docs/audits/2026-10-19-architecture-audit.md`
  - **Changes:** Merge duplicate candidate findings; assign stable `AUD-*` IDs;
    score severity, confidence, effort, type, and disposition; rank by data
    safety/correctness → memory/performance → maintainability, with
    likelihood × impact ÷ effort as the tie-break. Select the top 3–5 findings
    that could change the Wave 3 decision. For each selected finding, write a
    proof-test spec: test class/file, given/when/then, assertion, expected red
    failure, and seam; or record "no test seam" and exclude it from Phase 2.2–
    2.5. Record deferred/accepted findings and why.
  - **TDD exception:** Analysis and ranking; no behavior change. Existing
    checks: every row cites evidence and the selection rationale is recorded.
  - **Verify:** Ranked table has no missing evidence; every selected finding has
    a proof-test spec or a no-seam note; every deferred finding has a reason.
  - **Depends on:** 1.1, 1.2, 1.3, 1.4

- [ ] **2.2 Diagnostic proof test: grid residency (AUD-GRID-01)**
  - **Files:** `QuickCullCoreTests/Audit/GridResidencyAuditTests.swift`,
    `docs/audits/2026-10-19-architecture-audit.md`
  - **Test first:** Add `testGridThumbnailResidencyIsBounded`. Use
    `TestFixtures.makeTempCache()` so the cache base directory exists; build 100
    synthetic `SessionFile`s with nonexistent source paths, compute each
    `await cache.cacheURL(for:)`, and write a tiny JPEG there with
    `TestFixtures.writeJPEG(color:width:height:to:)` (64×40 is enough). Construct
    `ImageWindow.gridThumbnails(files:cache:)`; call
    `ensureLoaded(indices: Array(0..<100))`; await
    `waitUntilSettled(timeout: 10)`; assert
    `window.images.count <= 61`. It fails today because the grid policy radius
    is the file count and no image is evicted.
  - **Verify (red):** Build for testing, then
    `xcrun xctest -XCTest QuickCullCoreTests.GridResidencyAuditTests /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest`.
    Expected failure: `XCTAssertLessThanOrEqual failed: ("100") is greater than ("61")`.
    Record the command and output in the report.
  - **Implement:** Add a guard at the start of the test:
    `throw XCTSkip("AUDIT-GRID-01: unbounded grid residency; enable when Wave 3 fixes the cap")`.
    No production code changes.
  - **Verify (green):** Rebuild; run the targeted test (expected: 1 skipped);
    run the full suite (expected: 207 existing pass, 0 failures, 1 skipped).
  - **Acceptance:** The test proves the defect when enabled, is skipped by
    default, and the report links the finding to the test and the code path.
  - **Refactor:** none.
  - **Depends on:** 2.1

- [ ] **2.3 Diagnostic proof test B for the highest-ranked remaining finding**
  - **Files:** `QuickCullCoreTests/Audit/<FindingID>AuditTests.swift`,
    `docs/audits/2026-10-19-architecture-audit.md`
  - **Test first:** Implement the exact spec recorded by 2.1 for the
    highest-ranked selected finding that has a seam. Example if selected:
    `AUD-SELECT-01` — given a ghost selection no longer visible after a filter
    switch, when a batch flag action runs, then the invisible file's flag must
    not change. Use `AppState` with stub decoder/trasher, temp cache, and real
    `SessionFile`s; assert the invisible file's flag is unchanged. Expected red:
    the current `handle(.toggleFlag)` path mutates the ghost ID.
  - **Verify (red):** Build; run the targeted class; record the exact failure
    and why it proves the finding.
  - **Implement:** Add the test; after the red run, add
    `throw XCTSkip("<finding ID>: ...")`. No production code changes.
  - **Verify (green):** Targeted test skipped; full suite green.
  - **Acceptance:** The red failure matches the ranking rationale; the skip ID
    matches the report.
  - **Refactor:** none.
  - **Depends on:** 2.1
  - **If 2.1 marks this finding "no seam":** Do not add a test; record the
    no-seam note and why the finding remains in the report. Mark this task
    complete with that evidence.

- [ ] **2.4 Diagnostic proof test C for the next-ranked selected finding**
  - **Files:** `QuickCullCoreTests/Audit/<FindingID>AuditTests.swift`,
    `docs/audits/2026-10-19-architecture-audit.md`
  - **Test first:** Implement the exact spec recorded by 2.1 for the
    next-ranked selected finding with a seam. Use the smallest integration that
    exercises the real boundary (prefer `AppState`, `ImageWindow`,
    `ImageCacheStore`, or commit stubs over a pure unit test when the finding is
    a cross-layer failure).
  - **Verify (red):** Build; run the targeted class; record the exact failure.
  - **Implement:** Add the test; after the red run, add an `XCTSkip` with the
    finding ID. No production code changes.
  - **Verify (green):** Targeted test skipped; full suite green.
  - **Acceptance:** Red evidence matches the finding; skip ID matches the
    report.
  - **Refactor:** none.
  - **Depends on:** 2.1
  - **If 2.1 marks this finding "no seam":** Record the no-seam note; do not add
    a test.

- [ ] **2.5 Optional diagnostic proof tests D–E (0–2) or recorded no-seam notes**
  - **Files:** Up to two files under `QuickCullCoreTests/Audit/`,
    `docs/audits/2026-10-19-architecture-audit.md`
  - **Test first:** For each remaining selected finding with a seam, implement
    the 2.1 spec, run it unskipped, record the red failure, then add an
    `XCTSkip` with the finding ID. If there are fewer than five selected
    findings, or a finding has no seam, record that in the report and completion
    notes instead of adding a test.
  - **Verify (red/green):** Same targeted/full-suite pattern as 2.2–2.4.
  - **Acceptance:** The report has 3–5 selected findings; each has a red/green
    test or an explicit no-seam note; the full suite is green.
  - **TDD exception (only for the no-test branch):** The decision to omit a test
    is non-behavioral analysis; the reason is recorded. The test branch still
    records red/green.
  - **Depends on:** 2.1

### Phase 3 — Final report, verification, and handoff

**Outcome:** The report is complete, ranked, verified, and accepted by the
maintainer; Wave 3 is not started.

- [ ] **3.1 Write the recommended Wave 3 scope and final report**
  - **Files:** `docs/audits/2026-10-19-architecture-audit.md`
  - **Changes:** Finalize the ranked table and deep dives. Write a recommended
    Wave 3 scope of 3–6 workstreams, each mapped to finding IDs, labeled
    `Fix` or `Refactor`, with dependencies, rough effort, risk, and a test-first
    outline. Add accepted tradeoffs/no-action items, unproven risks, open
    questions, Appendix A (commands and red evidence), and Appendix B
    (documentation drift, including 205/207).
  - **TDD exception:** Documentation and synthesis; no behavior change.
    Existing checks: report review checklist and the full suite.
  - **Verify:** Every workstream maps to at least one finding ID; every P0/P1
    fix is labeled behavior-changing and has a test-first outline; every
    accepted tradeoff has a reason; no production code changed.
  - **Depends on:** 2.2, 2.3, 2.4, 2.5

- [ ] **3.2 Final verification and diff audit**
  - **Files:** `docs/audits/2026-10-19-architecture-audit.md`,
    `QuickCullCoreTests/Audit/*`
  - **Changes:** Run the full suite and targeted audit tests; inspect
    `git status --short` and `git diff --name-only`; confirm only `docs/audits/`,
    `docs/plans/`, and `QuickCullCoreTests/Audit/` changed; grep the report for
    absolute home paths, secrets, and TODO placeholders; confirm the test count
    and skipped count; re-read the README claims cited in the report.
  - **TDD exception:** Verification task; no behavior change. Existing checks:
    the full suite and diff inspection.
  - **Verify:** Full suite green (207 existing + N skipped audit tests); no
    production files in the diff; report has no secrets or absolute home paths.
  - **Depends on:** 3.1

- [ ] **3.3 User acceptance and handoff**
  - **Files:** `docs/audits/2026-10-19-architecture-audit.md`
  - **Changes:** Present a compact summary: method, top findings, recommended
    Wave 3 scope, proof-test evidence, and open risks. Ask the maintainer with
    the `question` tool: "Accept the audit report and recommended Wave 3
    scope?" Options: `Accept` (Recommended), `Revise`, `Keep auditing`,
    `Stop here`. On accept, set the report status to `accepted` and recommend
    `/plan <wave3-slug>`. On revise, update the report and ask again. On stop,
    leave the report as draft. Do not implement Wave 3.
  - **TDD exception:** Manual review/decision; no behavior change.
  - **Verify:** The maintainer's answer is recorded; the report status matches
    the decision.
  - **Depends on:** 3.2

## 7. Parallelization

| Batch | Tasks | Why they can run together |
| --- | --- | --- |
| A | 0.1 | Baseline must be captured first. |
| B | 0.2 | Depends on the baseline. |
| C | 1.1, 1.2, 1.3, 1.4 | Independent analyses, but run **sequentially** because all update the same report scorecard. |
| D | 2.1 | Ranking needs the complete screen. |
| E | 2.2, 2.3, 2.4, 2.5 | Independent test files under `QuickCullCoreTests/Audit/`; can run in parallel after 2.1. |
| F | 3.1, 3.2, 3.3 | Sequential: report synthesis → verification → acceptance. |

## 8. Verification

- [ ] TDD evidence: every Phase 1/0/3 task records its TDD exception; every
      Phase 2 proof-test task records a red run before the `XCTSkip` and a green
      targeted/full-suite run after it.
- [ ] Targeted tests:
      `xcrun xctest -XCTest QuickCullCoreTests.GridResidencyAuditTests /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest`
      plus each additional audit test class.
- [ ] Full test suite:
      `xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest`
      — expected 207 existing tests passing, 0 failures, plus the audit tests
      skipped.
- [ ] Build:
      `xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing`
- [ ] Lint/typecheck: no separate lint/typecheck is configured; the Xcode build
      is the typecheck. Record "N/A — no lint target" in the report.
- [ ] Manual smoke test: read the report end to end; verify the scorecard,
      ranking rubric, finding IDs, proof-test links, and recommended scope. No
      app launch is required because production behavior is unchanged.
- [ ] No test was weakened, skipped, or deleted to obtain green. The diagnostic
      skips are intentional, documented, and tied to finding IDs; existing tests
      are untouched.
- [ ] All success criteria in section 2 pass.

## 9. Risks and mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| The report is comprehensive but not decision-shaped | Wave 3 scope is chosen ad hoc anyway | Enforce the severity/confidence/effort/type/disposition table; every finding ends in a disposition; the recommended scope maps workstreams to finding IDs. |
| Proof tests are dismissed as synthetic | Top findings lose credibility | Use realistic file counts (100), state fixture assumptions, and point to the exact code path as well as the test. |
| Broad screen misses a cross-cutting issue | A real risk is absent from the ranking | Screen all eight points, cross-check prior wave docs, and keep an "unproven risks" section. |
| Scope creep | The audit never finishes | Four screen tasks, 3–5 proof tests, explicit stopping rule; everything else is deferred with a reason. |
| A P0 data-safety defect is found | It must not wait for the report | Surface it immediately in chat and the report; do not fix it without a separate decision. |
| Async proof test is flaky | Red/green evidence is unreliable | Use `waitUntilSettled(timeout:)`, tiny deterministic JPEGs, and a real temp cache; record the timeout and fixture size. |
| New test file is not picked up | Red/green command fails to find the class | The project uses folder-synchronized groups; rebuild with `build-for-testing` and verify the class is discovered. |
| Test count drift confuses verification | Wrong regression baseline | Record 207 actual vs 205 README in Appendix B; never silently edit the README. |
| Xcode/SDK version differs from the README | Build instructions look stale | Record the actual Xcode 26.3/Swift 6.2.4 environment in the baseline. |

## 10. Security and data

- **Data created, stored, or exposed:** A Markdown audit report and diagnostic
  test files. The report contains relative repository paths, code references,
  synthetic fixture descriptions, and command output only.
- **Auth, privacy, and retention:** No authentication, network, user photo
  library, production cache, or personal data is accessed. No secrets or
  credentials are recorded. Test fixtures are already in the repository or
  generated in temp directories.
- **Abuse and failure exposure:** Trash/move is the highest-risk data path. The
  audit reasons about partial commits, failed-file flag retention, collision
  auto-rename, and TOCTOU without executing destructive operations on real
  files. Any confirmed data-safety defect is ranked P0 and surfaced immediately.
- **Report hygiene:** No absolute home paths, no environment variables, no
  `.env` contents, no user file names beyond synthetic fixtures.

## 11. Rollout and rollback

Not applicable as a production rollout: this is a local, docs-and-tests-only
change. There is no migration, feature flag, or deployment.

- Rollback: delete `docs/audits/2026-10-19-architecture-audit.md` and the
  `QuickCullCoreTests/Audit/` files; the suite returns to its previous state.
- The report and test files are additive; no existing production or test file
  is modified.
- No commits, pushes, or PRs without the maintainer's explicit request.

## 12. Open items

None block the audit; each is resolved or explicitly recorded during execution.

- [ ] Confirm the final grid-residency cap in Wave 3; the audit uses 61 as a
      provisional proof constant.
- [ ] Confirm which 3–5 findings are selected after Phase 1; this is deliberately
      decided by 2.1, not pre-committed.
- [ ] Decide whether the diagnostic tests remain as a permanent
      architecture-fitness suite or are retired after Wave 3.
- [ ] Decide whether Swift 6 strict-concurrency migration is a Wave 3 candidate
      or a separate effort; the audit records it but does not schedule it.
- [ ] Decide whether to commit the audit artifacts; the plan does not commit
      automatically.

## 13. Completion notes

### Progress

- _Not started._

### TDD evidence

| Task | Test | Red (command and failure) | Green (command and result) |
| --- | --- | --- | --- |
| 2.2 | `QuickCullCoreTests/Audit/GridResidencyAuditTests.swift` | _to be recorded_ | _to be recorded_ |

### Implementation

- **Summary:** _Not started._
- **TDD exceptions:** _To be recorded per analysis task._
- **Behavioral exceptions:** None anticipated; the audit changes no production
  behavior.
- **Commands:** _To be recorded._
- **Deviations:** _To be recorded._
- **Follow-ups:** _To be recorded._

### Review

`docs/reviews/architecture-audit-wave3.md` _(added by the review skill)_
