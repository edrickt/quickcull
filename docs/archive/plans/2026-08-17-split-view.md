# Split View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Split as a third view mode showing current image and next (image+1) side-by-side in an HSplit with divider — left is current (flag/HUD/zoom target), right is next preview fit-only dimmed, with both shifting by 1 on navigation and placeholder at end.

**Architecture:** Extend `AppState.ViewMode` to `.split`, make `ScrubView` picker `Single|Split|Grid`, keep existing `phase`/`isCommitting` guards and `onChange` resets. Reuse existing `ImageWindow` display cache (radius 1 already covers current±1) — no new window. Refactor `ImageDisplayView` to branch on `viewMode`: `Single` keeps existing single viewer, `Split` renders a new `SplitViewer` (`HStack` with HUD sidebar 240+Divider + HSplit of two panes, each `GeometryReader` → `Fit/Zoomable`, `Divider` between panes only when both present, right placeholder `No next image`).

**Tech Stack:** Swift 5, SwiftUI Observation (`@Observable`, `@Environment`, `@Binding`, `@State`), `CoreGraphics`/`ImageIO`, `XCTest`, `xcodebuild` + `xcrun xctest`.

## Global Constraints

- Requires Xcode 16+ on macOS 14+ (README Build).
- Swift language version 5.0, deployment target 14.0.
- No new targets; synchronized folders (no `.pbxproj` edit).
- View picker must be `Single | Split | Grid` with `Split` middle, `pickerStyle(.segmented)`, `.fontWeight(.light)`, `.disabled(appState.isCommitting)`, order `Metadata | New Session | Single/Split/Grid | Filter | Trash`.
- Split shows current + next side-by-side in `HStack(spacing:0)` with `Divider` between panes (visible only when both present); left pane is current (flag `Z` target, `FlagBadge` top-trailing, `MetadataHUD` left file, `ZoomableImageView` with existing `zoomScale/offset` bindings); right pane is next preview `fit` only (`scale 1`, no zoom/pan/flag/badge/HUD), `opacity 0.92` dimmed, placeholder `ZStack { Color.black; VStack { Image(systemName:"photo.slash"); Text("No next image") } }` at last index.
- Navigation `←/→` shifts both by 1 overlapping: `(0,1)→(1,2)→…`, `↑/↓` jumps by 10 still shifts by 10 (left becomes `current+10`), but both still shift together; filmstrip highlight stays on left/current `currentIndex`.
- Hidden metadata HUD sidebar: when `hudVisible` true, outer `HStack { Metadata 240 | Divider | SplitViewer flex }` — HUD leftmost, then split viewer flex; image pair shrinks to `full-241` but both panes remain fully visible; hidden by default, resets on `phase==.empty|decoding` and `viewMode` toggle (existing `ScrubView` onChange covers Split).
- Toolbar `Metadata` text button stays far left separate from `Trash` far right (not next to each other).
- Build harness flags: every `xcodebuild` needs `CODE_SIGNING_ALLOWED=NO` and `OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'` when run in sandbox; `derivedDataPath /tmp/qc-dd`.

---

## File Structure

```
quickcull/
├── QuickCullCore/App/AppState.swift      # extend ViewMode to .split, ensure syncWindows covers next, setViewMode allows split
├── QuickCull/ScrubView.swift             # picker Single|Split|Grid
└── QuickCull/ImageDisplayView.swift      # branch Single vs Split; extract FitImage for right pane; HStack sidebar handling for Split+HUD
```

---

### Task 1: AppState — ViewMode split + syncWindows

**Files:**
- Modify: `QuickCullCore/App/AppState.swift:18-30`
- Test: `QuickCullCoreTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `AppState.viewMode: ViewMode`, `AppState.session: Session?`, `Session.currentIndex: Int`, `Session.files: [SessionFile]`, `ImageWindow.setCurrent(_:)`, `WindowPolicy` (existing).
- Produces: `enum ViewMode: Equatable { case scrub, split, grid }` (split maps to UI tag `Split`), `var splitSecondIndex: Int?` helper (or view computes), `func setViewMode(_:)` allows `.split`, `private func syncWindows()` ensures both `currentIndex` and `currentIndex+1` are covered by `displayImages` window.

- [ ] **Step 1: Write the failing test**

Append to `QuickCullCoreTests/AppStateTests.swift` after last `testStartNewSession` test:

```swift
func testSplitViewModeToggleAndShift() async throws {
    let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
    let b = try TestFixtures.makeRawFile(named: "b.cr2", in: tempDir)
    let c = try TestFixtures.makeRawFile(named: "c.cr2", in: tempDir)
    let state = makeState()
    state.importFiles(urls: [a, b, c])
    await waitForScrubbing(state)
    XCTAssertEqual(state.viewMode, .scrub)
    state.setViewMode(.split)
    XCTAssertEqual(state.viewMode, .split)
    // Split second index is current+1 when exists
    XCTAssertEqual(state.session?.currentIndex, 0)
    let second = state.session!.files.indices.contains(1) ? state.session!.files[1].id : nil
    XCTAssertNotNil(second)
    // Both shift by 1 overlapping
    state.handle(.next) // current 0→1
    XCTAssertEqual(state.session?.currentIndex, 1)
    // Right preview now c (index 2)
    XCTAssertEqual(state.session?.files[state.session!.currentIndex + 1].url.lastPathComponent, "c.cr2")
    // At last, right should be nil placeholder (view computes)
    state.handle(.next) // 1→2 last
    XCTAssertEqual(state.session?.currentIndex, 2)
    // Next beyond last clamps (move does not exceed)
    state.handle(.next)
    XCTAssertEqual(state.session?.currentIndex, 2)
    // Toggle Split disabled while committing
    state.requestCommit()
    // Simulate isCommitting true via flagged commit path? Just test setViewMode guard:
    // isCommitting is false initially; after requestCommit without confirm, still false so not testable here.
}

func testSplitViewModeResetOnNewSession() async throws {
    let a = try TestFixtures.makeRawFile(named: "a.cr2", in: tempDir)
    let state = makeState()
    state.importFiles(urls: [a])
    await waitForScrubbing(state)
    state.setViewMode(.split)
    XCTAssertEqual(state.viewMode, .split)
    state.startNewSession()
    XCTAssertEqual(state.viewMode, .scrub) // AppState.startNewSession resets to scrub
    XCTAssertEqual(state.phase, .empty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build-for-testing && xcrun xctest -XCTest AppStateTests.testSplitViewModeToggleAndShift /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -20
```
Expected: FAIL with `value of type 'AppState.ViewMode' has no member 'split'`

- [ ] **Step 3: Extend ViewMode and syncWindows**

In `QuickCullCore/App/AppState.swift:18-19`:

```swift
public enum ViewMode: Equatable, Sendable { case scrub, split, grid }
```

Keep raw value mapping to UI: `.scrub` → `Single` tag still works (no change to tag strings).

In `QuickCullCore/App/AppState.swift:247-251` `syncWindows()`:

```swift
private func syncWindows() {
    guard let session else { return }
    thumbWindow?.setCurrent(session.currentIndex)
    displayImages?.setCurrent(session.currentIndex)
    // Ensure right pane (current+1) is also in-flight when in Split and at edge
    // (radius 1 already covers current±1, but at last index right is nil; no extra work needed)
    // Optional: if radius were tight, ensureLoaded would be called, but radius 1 suffices.
}
```

No new stored `splitSecondIndex` needed in AppState; view computes `files.indices.contains(currentIndex+1)`.

Ensure `setViewMode` already checks `phase==.scrubbing` and `viewMode!=mode` — it will now allow `.split`.

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build-for-testing && xcrun xctest -XCTest AppStateTests /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -20
```
Expected: PASS — both new tests + 114 baseline.

- [ ] **Step 5: Commit**

```bash
git add QuickCullCore/App/AppState.swift QuickCullCoreTests/AppStateTests.swift
git commit -m "feat: app state split view mode (Single|Split|Grid) with overlapping shift"
```

---

### Task 2: ScrubView — picker Single|Split|Grid

**Files:**
- Modify: `QuickCull/ScrubView.swift:43-58`

**Interfaces:**
- Consumes: `AppState.viewMode: ViewMode`, `AppState.setViewMode(_:)`, existing toolbar pickers.
- Produces: `Picker "View"` with 3 segments `Single|Split|Grid` where `Split` tag `.split`.

- [ ] **Step 1: Modify picker to add Split**

Edit `QuickCull/ScrubView.swift:43-58`:

```swift
Picker("View", selection: Binding(
    get: { appState.viewMode },
    set: { appState.setViewMode($0) }
)) {
    Text("Single").tag(AppState.ViewMode.scrub)
    Text("Split").tag(AppState.ViewMode.split)
    Text("Grid").tag(AppState.ViewMode.grid)
}.pickerStyle(.segmented).fontWeight(.light).disabled(appState.isCommitting)
```

Order `Single | Split | Grid`, `Split` middle. Keep `.pickerStyle(.segmented)`, `.fontWeight(.light)`, `.disabled(appState.isCommitting)` and existing `onChange(viewMode)` reset logic (covers Split round-trip).

- [ ] **Step 2: Build the app**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Manual verify picker**

Run `./start.sh`, import set, in toolbar verify `Single | Split | Grid` (Split middle), light weight, disabled while Trash spinner. Click `Split` → viewer shows split (Task 3 will render, but picker alone should switch and not crash; currently ImageDisplayView still shows Single until Task 3).

- [ ] **Step 4: Commit**

```bash
git add QuickCull/ScrubView.swift
git commit -m "feat: view picker Single|Split|Grid (Split middle)"
```

---

### Task 3: ImageDisplayView — SplitViewer (current + next) with HUD sidebar

**Files:**
- Modify: `QuickCull/ImageDisplayView.swift:12-64`
- Test: manual QA + `xcodebuild` build; no new unit tests (reuse Existing window logic)

**Interfaces:**
- Consumes: `ScrubView` hoisted `zoomScale/zoomOffset/hudVisible` bindings, `AppState.session/files/currentIndex/viewMode`, `displayImages/thumbWindow`, `ImageMetadataProvider`, `MetadataHUDView`, `FlagBadgeOverlay`, `ZoomableImageView` (existing), `SessionFile`.
- Produces: `SplitViewer` when `viewMode==.split`: `HStack { [if hudVisible: Metadata 240|Divider] | HSplit Left+Right }` where Left is `ZoomableImageView` (current, flag/HUD target) and Right is fit-only preview or placeholder.

- [ ] **Step 1: Read current ImageDisplayView branching**

Read `QuickCull/ImageDisplayView.swift:12-64` to confirm single `HStack { if hudVisible: Metadata 240|Divider | GeometryReader Zoomable }` branch.

- [ ] **Step 2: Replace body branching to handle Split**

Edit `QuickCull/ImageDisplayView.swift:12-64` to:

```swift
var body: some View {
    let index = appState.session?.currentIndex ?? 0
    let currentFile = (appState.session?.files.indices.contains(index) ?? false) ? appState.session?.files[index] : nil
    let rightIndex = index + 1
    let rightFile: SessionFile? = (appState.session?.files.indices.contains(rightIndex) ?? false) ? appState.session?.files[rightIndex] : nil
    let leftCG = appState.displayImages?.image(at: index) ?? appState.thumbWindow?.image(at: index)
    let rightCG = rightFile != nil ? (appState.displayImages?.image(at: rightIndex) ?? appState.thumbWindow?.image(at: rightIndex)) : nil

    ZStack {
        Color.black
        if appState.session?.files.isEmpty == true {
            Color.black
        } else if appState.viewMode == .split {
            HStack(spacing: 0) {
                if hudVisible, let file = currentFile, let lcg = leftCG {
                    MetadataHUDView(file: file, cgImage: lcg)
                        .frame(width: 240)
                        .background(.ultraThinMaterial)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider()
                }
                HStack(spacing: 0) {
                    // Left — current, zoomable, flag target
                    GeometryReader { geo in
                        ZStack {
                            Color.black
                            if let img = leftCG, let file = currentFile {
                                ZoomableImageView(cgImage: img, fileID: file.id, scale: $zoomScale, lastScale: $zoomLastScale, offset: $zoomOffset, lastOffset: $zoomLastOffset)
                                    .overlay(alignment: .topTrailing) { FlagBadgeOverlay(file: file) }
                            } else { Color.black }
                        }.frame(width: geo.size.width, height: geo.size.height)
                    }.clipped()
                    if rightFile != nil { Divider() }
                    // Right — next preview, fit only, dimmed
                    GeometryReader { geo in
                        ZStack {
                            Color.black
                            if let img = rightCG {
                                Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                                    .frame(width: fittedSize(for: img, in: geo.size).width, height: fittedSize(for: img, in: geo.size).height)
                                    .opacity(0.92)
                                    .clipped()
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "photo.slash").font(.title2).foregroundStyle(.secondary)
                                    Text("No next image").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.frame(width: geo.size.width, height: geo.size.height)
                    }.clipped()
                }
            }
            .overlay(alignment: .topTrailing) { /* no right badge */ }
            .animation(.easeInOut(duration: 0.2), value: hudVisible)
            .animation(.easeInOut(duration: 0.15), value: appState.viewMode)
        } else if let cgImage = leftCG { // Single (existing)
            HStack(spacing: 0) {
                if hudVisible, let file = currentFile {
                    MetadataHUDView(file: file, cgImage: cgImage).frame(width: 240).background(.ultraThinMaterial).transition(.move(edge:.leading).combined(with:.opacity))
                    Divider()
                }
                GeometryReader { geo in
                    ZStack {
                        Color.black
                        ZoomableImageView(cgImage: cgImage, fileID: currentFile?.id, scale: $zoomScale, lastScale: $zoomLastScale, offset: $zoomOffset, lastOffset: $zoomLastOffset)
                    }.frame(width: geo.size.width, height: geo.size.height)
                }.clipped()
            }
            .overlay(alignment: .topTrailing) { FlagBadgeOverlay(file: currentFile) }
            .animation(.easeInOut(duration: 0.2), value: hudVisible)
        } else {
            ProgressView().controlSize(.large)
        }
    }
}

// Helper for right pane fit (reuse Zoomable's fittedSize logic, scale 1)
private func fittedSize(for image: CGImage, in container: CGSize) -> CGSize {
    guard container.width>0, container.height>0 else { return .zero }
    let imageAspect = CGFloat(image.width)/CGFloat(image.height)
    let containerAspect = container.width/container.height
    if imageAspect > containerAspect { let w=container.width; return CGSize(width:w,height:w/imageAspect) }
    else { let h=container.height; return CGSize(width:h*imageAspect,height:h) }
}
```

Keep existing `ZoomableImageView` (with its own `fittedSize`/`clampedOffset`/`magnificationGesture`/`dragGesture`/`fileID onChange`) and `MetadataHUDView`/`FlagBadgeOverlay` private structs unchanged in same file. Ensure right pane does NOT use zoom bindings (fixed `scale 1`). Ensure HUD is still leftmost when visible in Split (so split viewer shrinks to `full-241` but both panes remain fully visible side-by-side).

- [ ] **Step 3: Build the app**

Run same build command as Task 2 Step 2.
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual verify Split**

- Import 3 files, `ScrubView` picker `Single` (single viewer) → `Split` → left shows `a` current with badge if flagged, right shows `b` dimmed fit, `Divider` between panes, no HUD.
- `→` → left `b` (was right), right `c`; at last `c` → right placeholder `No next image` black with icon, no divider after left.
- `Z` flags left only (filmstrip left highlight, count +1); HUD toggle `Metadata` (far left) shows left 240 + divider left of split, image pair shrinks but both fully visible; hide returns full width.
- Zoom pinch/double/drag only left pane; right fit only.
- `Filter` with 1 file → left shows file, right placeholder; filter empty → black.
- `Grid` toggle still works, zoom/hud reset on viewMode change.

- [ ] **Step 5: Run tests (no regression)**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build-for-testing && xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -5
```
Expected: `Executed 114 tests, with 0 failures` (or 116 after Task 1 additions) — Split is view-only.

- [ ] **Step 6: Commit**

```bash
git add QuickCull/ImageDisplayView.swift
git commit -m "feat: split view current+next side-by-side (left zoomable, right fit, placeholder at end)"
```

---

## Self-Review

**Spec coverage:**
- Single|Split|Grid picker Split middle, light weight, disabled while committing → Task 2.
- ViewMode `.split` extended, `syncWindows` covers both indices (radius 1 already) → Task 1.
- Split HSplit left current (zoomable, flag/HUD/badge left only) + right next fit dimmed, Divider between panes only when both, placeholder `No next image` at last → Task 3.
- Both shift by 1 overlapping via existing `move(by:1)` on `currentIndex` → left becomes previous right → Task 3 derives right as `current+1`.
- HUD sidebar 240+Divider left of split viewer, not overlay → outer HStack in Split branch, full image pair visible → Task 3.
- Filmstrip highlight stays on left/current, HUD shows left file → Task 3.

**Placeholder scan:** No TBD/TODO; every step has exact file paths, code blocks, and commands.

**Type consistency:** `ViewMode.split` defined Task 1, consumed `Tag(AppState.ViewMode.split)` Task 2 and `if viewMode==.split` Task 3; `splitSecondIndex` helper optional, view derives `files.indices.contains(currentIndex+1)`; `ZoomableImageView` bindings `scale/lastScale/offset/lastOffset` reused for left only; `MetadataHUDView` signature unchanged.

