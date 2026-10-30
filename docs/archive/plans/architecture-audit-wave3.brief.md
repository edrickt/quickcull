# QuickCull Major Architecture Audit — Wave 3 Input

- **Slug:** `architecture-audit-wave3`
- **Date:** 2026-10-19
- **Status:** grilled
- **Source:** conversation

## Idea

Run a read-only, evidence-based audit of QuickCull's major architecture points
across the whole repository, then produce a ranked report that recommends the
scope of the next refactor wave (Wave 3).

## Problem and motivation

QuickCull grew from a working v1 into a feature-rich app, then through Wave 1
(consolidation/hardening) and Wave 2 (dead-code, duplication, and hot-path
cleanup). Wave 2 was a full-codebase cleanup, but it was not a boundary-level
risk review: it did not ask which architectural seams, ownership rules, or
failure modes most endanger the next stage of the product.

Without a shared, ranked view, Wave 3 would be chosen ad hoc — whichever smell
is most recent or most annoying. The audit exists to replace that with a
decision-shaped report: screen every major architecture point, prove the few
risks that could change the ranking, and state what Wave 3 should do first.

A concrete example already visible in the code: grid-thumbnail residency is not
bounded. `ImageWindow.gridThumbnails` builds a policy with
`WindowPolicy(radius: files.count)` (`QuickCullCore/Window/ImageWindow.swift:334-338`),
so `WindowPolicy.toEvict` has an empty eviction set
(`QuickCullCore/Window/WindowPolicy.swift:51-54`) and `ImageWindow.images`
retains every grid cell ever loaded. `pruneEnsuredIndices` bounds only the
bookkeeping, not the images (`QuickCullCore/Window/ImageWindow.swift:284-302`).
The README describes the grid as keeping "the thumbnails of the cells you have
actually scrolled past" (`README.md:11`), which is a deliberate-sounding UX
choice but an unbounded memory cost. The maintainer has confirmed this is a
defect: grid residency must be bounded by a fixed cap, not by shoot size.

## Goals and success criteria

- Given the completed report, when a reader inspects any major architecture
  point, then it has a verdict (sound / risky / defect / accepted tradeoff),
  evidence, and a disposition.
- Given a ranked finding, when it is read, then it states severity, confidence,
  rough effort, whether it is a behavior-preserving refactor or a behavior
  change, and the evidence behind it.
- Given the recommended Wave 3 scope, when it is handed to `/plan`, then each
  workstream maps to one or more ranked findings, and confirmed defects are
  separated from refactors.
- Given the 3–5 findings that could change the ranking, when their diagnostic
  tests are enabled, then each fails for the stated reason; by default those
  tests are skipped so the existing suite stays green.
- Given the audit is complete, when the documented test command runs, then the
  existing suite passes unchanged and no production code has been modified.
- Must not regress: all existing user-visible flows and keys, format support
  and decode quality, trash/move semantics, the documented build/test commands,
  and the no-new-third-party-dependency constraint.

## Users and use cases

- **Primary user:** the maintainer (solo developer working with an agent) who
  must choose what Wave 3 should tackle.
- **Critical path:** read the ranked report → compare the top findings and
  recommended scope → choose Wave 3 workstreams → run `/plan` on that scope.
- **Smallest valuable version:** a full-screen report over every major
  architecture point, with 3–5 deep-dived/proven top findings and a recommended
  Wave 3 scope. Not every finding needs a proof test.

## Scope

**In scope**

- Whole repository, runtime-weighted: `QuickCull/`, `QuickCullCore/`,
  `QuickCullCoreTests/`, `QuickCull.xcodeproj`, `Scripts/`, and docs.
- These major architecture points, at minimum:
  1. `AppState` orchestration and the destructive-action state machines.
  2. `Session` projection, filtering, selection, and empty-state semantics.
  3. Decode pipeline, worker model, cancellation, and decoder boundaries.
  4. `ImageWindow` residency, tiering, eviction, and grid memory.
  5. Cache lifecycle, ownership, and read/write encapsulation.
  6. Trash/move commit correctness, TOCTOU behavior, and error semantics.
  7. Concurrency/isolation model, including actor boundaries, detached tasks,
     process-wide limits, `@unchecked Sendable`, and Swift 5 assumptions.
  8. Target/module/test/build boundaries, including the app/Core split, LibRaw
     integration, fixtures, schemes, and missing test seams.
- One broad screen of every point, then deep dives and proof tests only for the
  3–5 findings that could change the Wave 3 ranking.
- A ranked report at `docs/audits/2026-10-19-architecture-audit.md`.
- Diagnostic proof tests committed in the test target, skipped by default with
  a finding ID.
- Reconcile documentation drift encountered during the audit (for example, the
  README says 205 tests while the suite contains 207 `func test…` declarations).

**Out of scope**

- Production code changes during the audit. The audit may add docs and test
  files only.
- Runtime benchmarks, Instruments traces, or measurements on real photo shoots.
  Static evidence plus targeted proof tests is the chosen evidence standard.
- Detailed Wave 3 design or task sequencing; that is `/plan`'s job.
- Feature work, UI redesign, or format support changes.
- Security, licensing, signing, notarization, and distribution review beyond
  what directly affects the architecture points above.
- Making Swift 6 strict concurrency a goal of this audit. Swift 5 assumptions
  may be reported as a finding, but migration is a separate decision.

**Non-goals**

- Proving every finding. Only the top 3–5 that could change the Wave 3 ranking
  get executable evidence.
- Producing a target architecture from scratch or rewriting the app/Core split.
- Fixing defects found during the audit. Fixes are recommended and sequenced
  separately.
- Establishing permanent architecture-fitness tests for every invariant; the
  diagnostic tests are seeds for Wave 3, not a new test framework.
- Auditing the visual quality of the UI or the accuracy of the histogram
  algorithm beyond its architectural placement and error handling.

## Decisions

| Decision | Choice | Rationale |
| --- | --- | --- |
| Purpose | Guide the next refactor wave | The deliverable must end in a scope decision, not just observations. |
| Trigger | Broad discovery | No single known pain; find the highest-risk points across the repo. |
| Scope weight | Whole repo, runtime-weighted | Build/test/project boundaries matter, but runtime architecture is the priority. |
| Evidence | Static file:line evidence + targeted proof tests | Memory/race claims are weak without executable evidence; runtime measurement was rejected as too slow. |
| Ranking lens | Data safety and correctness → memory/performance → maintainability | Destructive trash/move operations and correctness failures outrank cleanup. |
| Deliverable | Ranked findings + recommended Wave 3 scope | Gives `/plan` a defensible input without duplicating the plan stage. |
| Fix appetite | Fixes allowed, separated from refactors | Confirmed defects should not be deferred, but they must not hide inside a cleanliness wave. |
| Proof tests | Committed, skipped by default with a finding ID | Evidence survives; the normal suite stays green; the fix unskips the red test. |
| Grid retention | Defect; residency must be bounded | Retaining every scrolled-past grid cell makes memory scale with shoot size. |
| Report location | `docs/audits/2026-10-19-architecture-audit.md` | Keeps audit artifacts separate from feature specs and plans. |
| Stopping rule | Full-screen report, 3–5 proven top findings | Prevents an endless audit while keeping the ranking evidence-backed. |
| Audit regression bar | Existing suite green; production untouched | The audit is analysis, so it must not destabilize the app. |
| Preserve | Flows, formats, trash/move semantics, build commands, no new deps | These are the product/engineering contracts Wave 3 must not break. |
| Pre-mortem mitigation | Every finding ends in a disposition and maps to a candidate workstream | Prevents a comprehensive but decision-useless report. |

## Alternatives considered

- **Static evidence only** — rejected because claims about unbounded memory,
  cache races, or cancellation would remain arguments from code shape.
- **Runtime measurement (Instruments/real shoots)** — rejected for this audit:
  slower, needs representative photo libraries, and the maintainer chose proof
  tests as the evidence standard.
- **Deep-dive a shortlist from the start** — rejected because broad discovery
  is the trigger; a shortlist risks missing cross-cutting issues.
- **Full review with production fixes** — rejected because the decision about
  Wave 3 should come before implementation, and `/plan` owns sequencing.
- **Findings only, no recommendation** — rejected because the purpose is to
  choose Wave 3; an unranked list recreates the ad-hoc-scope problem.
- **Findings plus a full Wave 3 plan** — rejected as overlapping with `/plan`
  and prematurely fixing design decisions.
- **Report first, prove later** — rejected because the top findings would lose
  credibility and the TDD seeds would be deferred again.

## Constraints and assumptions

- **Constraints:**
  - The audit is read-only for production code. Only docs and test files may be
    added.
  - No new third-party dependencies, project generators, or changes to the
    documented build/test commands.
  - The app remains macOS 14+, Xcode 16+, Swift 5 language mode during the
    audit.
  - Proof tests use local temp directories and synthetic fixtures; no real photo
    libraries, no production data, no network.
  - The audit must not run destructive trash/move operations against real user
    files; tests use temp fixtures and stubs.
  - Notification, commit, and push only if the maintainer explicitly asks; the
    grill guardrails still apply.
- **Assumptions:**
  - The repository is the source of truth; README/spec claims are evidence to
    verify, not facts.
  - The existing suite is the regression bar, even though the README count and
    the number of test methods currently disagree.
  - A focused pass can screen all eight major points and deep-dive 3–5; if a
    newly discovered P0 data-loss risk appears, it may pre-empt the planned
    deep dives and be surfaced immediately.
  - "Major architecture point" means a boundary, ownership rule, state machine,
    concurrency model, or integration seam whose failure would affect
    correctness, data safety, memory, or the ability to change the app safely —
    not every stylistic preference.
  - The report is an input to `/plan`, not the Wave 3 plan itself.

## Current state and integration points

QuickCull is a native macOS SwiftUI/AppKit app with three targets:

- `QuickCull/` — SwiftUI/AppKit views and app lifecycle.
- `QuickCullCore/` — `@MainActor @Observable` state (`AppState`, `Session`,
  `ImageWindow`), an actor-based decode pipeline and cache, decoders, commit
  logic, metadata/histogram code, and pure policy types.
- `QuickCullCoreTests/` — 207 test methods by grep (README says 205), covering
  the decoder, cache, session, windows, key map, commit, move, and import
  pipeline.

Key integration facts:

- `QuickCullApp` creates one `AppState` and injects it into the environment;
  `RootView` switches on `AppState.phase`.
- `AppState` is the dependency-injection point for `RawDecoding`,
  `ImageCacheStore`, `Trashing`, and `Moving`, and owns import, phase
  transitions, window installation, filtering, grid selection, view mode,
  loupe state, commit, and move.
- `Session` is in-memory only; flags are not persisted. It owns the filtered
  projection, current-index preservation, flag mutation, and post-commit
  removal.
- `DecodeEngine` is an actor with a bounded `TaskGroup` worker pool; decoders
  are synchronous; progress is delivered through an `AsyncStream`.
- `ImageWindow` is a main-actor observable identity-addressed window with
  full/half-res tiering for the viewer and lazy loads for the grid/filmstrip.
- `ImageCacheStore` is a concrete actor, not a protocol; it owns cache writes
  and wipe, but consumers read `cacheURL` directly and call ImageIO themselves.
- `TrashCommit` and `MoveCommit` use injected `Trashing`/`Moving` protocols and
  return per-file outcomes.
- The project uses folder-synchronized Xcode groups, a manual `.pbxproj`, a
  LibRaw build phase, and a separate `QuickCullCore` test scheme.
- Docs live under `docs/superpowers/specs/` and `docs/superpowers/plans/`;
  prior waves are `2026-08-16-refactor-wave1-design.md` and
  `2026-08-27-refactor-wave2-design.md`.

Candidate hypotheses to test during the audit (not findings yet):

- `AppState` duplicates a commit state machine for trash and move and mixes too
  many responsibilities.
- `Session` empty-projection/fallback behavior differs by mutation path, and
  grid selection can outlive the projection.
- Cache wipe is fire-and-forget and can race with an in-flight decode.
- `ImageCacheStore` encapsulates writes but leaks reads through `cacheURL`.
- `RawDecoding` is synchronous inside `TaskGroup` workers, blocking
  cooperative-pool threads.
- Process-wide decode limiters and `UserDefaults` reads limit testability.
- `ImageMetadataProvider` is a static enum with no seam.
- The app/Core split is testability-driven, not a portability boundary.

## Data and security

- **Data created, stored, or exposed:** the audit produces a Markdown report and
  test code. It reads source, docs, fixtures, and test outputs. It does not read
  user photo libraries or production caches.
- **Auth, privacy, and retention:** no authentication or network is involved.
  No secrets, credentials, personal data, or production data may appear in the
  report or tests. Test fixtures are public/synthetic samples already in the
  repository.
- **Abuse and failure exposure:** the highest-risk data operations are Trash and
  Move. The audit must reason about failure exposure (partial commits, failed
  files retaining flags, auto-rename collisions, TOCTOU) without executing
  destructive operations on real files. Any confirmed data-safety defect is
  ranked P0 and surfaced before the rest of the report is finished.

## Failure modes and edge cases

- **A finding is a hypothesis, not proven** — label it as unproven and give it
  lower confidence; do not let it drive the top of the ranking without evidence.
- **A proof test is flaky or synthetic** — use deterministic loaders and
  `waitUntilSettled(timeout:)`; record the fixture size and why it represents
  the failure; skipped tests must fail for the stated reason when enabled.
- **The audit misses a cross-cutting issue** — screen all eight points, and
  cross-check findings against the repo's test seams and prior wave docs.
- **Scope creep** — stop at 3–5 proven top findings; list the rest as screened
  hypotheses.
- **The default suite breaks** — diagnostic tests are skipped by default and
  are test-only; if a skip mechanism is unavailable, the audit stops and asks
  before adding the test.
- **Documentation is stale** — record drift as evidence, but do not rewrite
  product docs during the audit.
- **A P0 defect is found in trash/move** — surface it immediately in the report
  and in chat; do not wait for the full audit or fix it without approval.
- **A proposed fix has no test seam** — do not silently recommend it; record the
  missing seam as part of the finding, and require an approved no-seam
  exception during `/plan`.

## Test strategy (TDD)

- **Acceptance examples:**
  - Given the completed report, when a reader selects any row in the major-point
    scorecard, then the row states a verdict, the evidence (file:line), and a
    disposition.
  - Given two findings with different severity tiers, when the ranking is read,
    then data-safety/correctness findings outrank memory/performance findings,
    which outrank maintainability findings; ties are broken by likelihood ×
    impact ÷ effort.
  - Given a 100-file session and the grid window, when every grid cell is
    ensured, then resident grid images stay at or below a fixed cap (provisional
    cap: 61, mirroring the filmstrip; `/plan` confirms the final constant);
    today `ImageWindow.images.count` reaches 100 because the grid policy's
    radius is the file count.
  - Given the default test run after the audit, when the diagnostic tests are
    skipped, then the existing suite passes and the documented commands are
    unchanged.
  - Given the recommended Wave 3 scope, when a finding is a confirmed defect,
    then it is labeled a behavior change with a red test; refactors are labeled
    behavior-preserving and keep the suite green.
  - Given a finding whose fix would have no test seam, when it is recommended,
    then the missing seam is recorded and an approved no-seam exception is
    required before `/plan` schedules it.
- **First failing test:**
  - File: `QuickCullCoreTests/Audit/GridResidencyAuditTests.swift`
  - Test: `testGridThumbnailResidencyIsBounded`
  - Behavior: build a 100-file session with tiny JPEG fixtures in a temp cache,
    construct `ImageWindow.gridThumbnails(files:cache:)`, call
    `ensureLoaded(indices: Array(0..<100))`, await
    `waitUntilSettled(timeout:)`, then assert `images.count <= 61`.
  - Why it fails today: `gridThumbnails` uses
    `WindowPolicy(radius: files.count)`, so every index is inside the window;
    `toEvict` returns an empty set and no image is ever removed. The test is
    skipped by default with `throw XCTSkip("AUDIT-GRID-01: unbounded grid
    residency; enable when Wave 3 fixes the cap")`; unskipping it reproduces the
    failure. The red run belongs to the Wave 3 fix, not the audit itself.
- **Test levels and seams:**
  - Unit/policy: `WindowPolicy`, `Session`, `CullKeyMap`, `DropdownClickPolicy`,
    `WindowHitTest`, `FlagBadgeLogic`; no mocks.
  - Integration: `ImageWindow` with a real temporary `ImageCacheStore`, small
    JPEG fixtures, and stub loaders; `DecodeEngine` with `StubDecoder`/
    `SlowStubDecoder`; `TrashCommit`/`MoveCommit` with stub trashers/movers and
    temp directories.
  - App/state: `AppState` tests with real temp cache and injected decoder/
    trasher/mover.
  - No UI or end-to-end automation; the app target has no test bundle and the
    audit does not add one.
- **Fixtures and test data:**
  - `TestFixtures.makeTempDir()`, `writeJPEG(color:to:)`, `makeCGImage`, and
    `makeTempCache()` for synthetic images/cache.
  - 100 tiny JPEGs for the grid-residency proof test.
  - Existing raw fixtures under `QuickCullCoreTests/Fixtures/raws/` for any
    decoder-boundary findings; no new real-world photo data.
  - Stub/gated decoders, trashers, and movers already in the test target.
- **Verification commands:**
  - Build for testing:
    `xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing`
  - Targeted audit test:
    `xcrun xctest -XCTest QuickCullCoreTests.GridResidencyAuditTests /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest`
    (or `xcodebuild test-without-building ... -only-testing:QuickCullCoreTests/GridResidencyAuditTests`)
  - Full suite:
    `xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest`
  - The audit records the exact command and output for each proof test in the
    report appendix.
- **Regression protection:**
  - The existing suite must stay green at every audit step.
  - The documented build/test commands and target layout must keep working.
  - User-visible flows, formats, decode quality, trash/move semantics, and the
    no-new-dependency constraint are the Wave 3 regression contract.
  - The README test count (205) and the 207 test methods found by grep will be
    reconciled in the report; the audit does not silently "fix" the number.
- **Non-testable scope:**
  - Whether the ranking is the right prioritization, whether the report is
    useful, whether a missed risk mattered, and architectural taste. These are
    judgment calls reviewed by the maintainer, not automatable assertions.
  - Whether the provisional grid cap (61) is the right UX/memory tradeoff;
    `/plan` and implementation decide the constant, with the audit recording the
    assumption.
  - Whether all possible failure modes were imagined; the audit mitigates this
    with a broad screen, explicit confidence labels, and an "unproven risks"
    section.
- **TDD exceptions:**
  - The audit report, ranking, and architecture scorecard are non-behavioral
    analysis. No failing test starts the audit itself; the existing suite and
    the report review are the checks.
  - Documentation-only updates (test-count reconciliation, audit report) are
    non-behavioral and covered by review.
  - The diagnostic tests are test-only evidence, not production behavior
    changes; they are skipped until Wave 3.
- **Behavioral exceptions:**
  - Trivial-fix exceptions: none anticipated at audit stage. If a Wave 3 fix is
    genuinely trivial (for example, a constant or wording change), `/plan` must
    record the trivial-fix exception with a before/after reproduction or an
    existing test as the substitute.
  - Approved no-seam exceptions: none for the audit. If a confirmed Wave 3
    behavior change has no test seam, it must be approved with the `question`
    tool during `/plan`, with a follow-up to add the seam; it cannot be recorded
    as a TDD exception.

## Rollout and rollback

- This is a local, docs-and-tests-only change. No migration, feature flag, or
  production rollout applies.
- The audit report is additive; deleting it restores the previous docs state.
- Diagnostic tests are skipped by default; deleting the new test file restores
  the suite exactly as it was.
- No commits, pushes, or PRs without the maintainer's explicit request.
- If a P0 data-safety finding appears, the report and chat surface it
  immediately; any fix still requires a separate decision and `/plan`.

## Risks and open questions

- **Risk:** the report is comprehensive but not decision-shaped — mitigation:
  every finding has severity, confidence, effort, and a disposition; the top
  findings map to candidate Wave 3 workstreams, and accepted tradeoffs are
  explicit.
- **Risk:** proof tests are dismissed as synthetic — mitigation: use realistic
  file counts, state the fixture assumptions, and show the failure mechanism in
  code as well as in the test.
- **Risk:** broad scope misses a cross-cutting issue — mitigation: screen all
  eight points and cross-check against prior wave docs and test seams.
- **Risk:** scope creep or an unfinished report — mitigation: stopping rule of
  3–5 proven top findings; everything else is a screened hypothesis.
- **Risk:** a P0 trash/move or cache defect changes the priority order —
  mitigation: surface it immediately; do not let the planned report structure
  delay a data-safety warning.
- **Pre-mortem:** if this fails, the most likely reason is that the report was
  comprehensive but not decision-shaped, so Wave 3 scope was chosen ad hoc
  anyway. Mitigation is the disposition column, the recommended-scope section,
  and the requirement that every top finding maps to a workstream.
- **Open:** the final grid-residency cap (provisional 61) and whether the cap is
  per-window or process-wide.
- **Open:** which other findings deserve proof tests after the broad screen; the
  audit will choose based on ranking impact, not completeness.
- **Open:** whether Swift 6 strict concurrency is a Wave 3 candidate or a
  separate effort; the audit may report it but must not schedule it.
- **Open:** whether the diagnostic tests should remain as a permanent
  architecture-fitness suite after Wave 3 or be retired once fixed.

## Codebase context

- `QuickCullCore/App/AppState.swift` — central coordinator; import, phase,
  window installation, filtering, selection, commit/move state machines.
- `QuickCullCore/Session/Session.swift` — in-memory projection, flags, filter
  fallback, current-index preservation, post-commit removal.
- `QuickCullCore/Engine/DecodeEngine.swift` — actor-based bounded worker pool,
  progress stream, cancellation, decode outcomes.
- `QuickCullCore/Decoding/RawDecoding.swift` — synchronous decoder seam.
- `QuickCullCore/Window/ImageWindow.swift` — identity-addressed residency,
  tiering, eviction, factories, decode limiters.
- `QuickCullCore/Window/WindowPolicy.swift` — pure window math and eviction set;
  the grid-policy defect is visible here.
- `QuickCullCore/Storage/ImageCacheStore.swift` — cache writes, wipe, histogram
  sidecars, `cacheURL` read leak.
- `QuickCullCore/Commit/TrashCommit.swift` and `MoveCommit.swift` — per-file
  outcomes, auto-rename, TOCTOU retry.
- `QuickCullCore/Metadata/ImageMetadataProvider.swift` and `RawHistogram.swift`
  — metadata/histogram policy and its view coupling.
- `QuickCullCoreTests/TestFixtures.swift` and `TestDoubles.swift` — fixture and
  fake seams for proof tests.
- `QuickCull.xcodeproj/project.pbxproj` — synchronized groups, LibRaw build
  phase, Swift 5 language mode, scheme/test wiring.
- `Scripts/build-libraw.sh` — pinned LibRaw build/integration.
- `README.md` — product claims, memory narrative, build/test commands, test
  count; a source of claims to verify, including the grid-retention wording.
- `docs/superpowers/specs/2026-08-16-refactor-wave1-design.md` and
  `2026-08-27-refactor-wave2-design.md` — prior wave intent and non-goals.

## Recommended next step

Run `/plan architecture-audit-wave3` to turn this brief into an executable audit
plan, including the broad-screen checklist, the deep-dive selection rule, the
proof-test workflow, and the report template.
