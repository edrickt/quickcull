# Metadata HUD v2 (Sidebar + Metadata Button) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the metadata HUD a 240-pt sidebar to the left of the viewer (not an overlay) so the full image stays visible, and move the toggle from an eye icon next to Trash to a text “Metadata” button at the far left of the toolbar, separate from Delete.

**Architecture:** Keep `ImageMetadataProvider` and `MetadataHUDView` unchanged. `ScrubView` moves the HUD toggle `ToolbarItem` from last `primaryAction` (eye) to first `primaryAction` with `Button("Show Metadata"/"Hide Metadata")` text only, `Trash` stays last. `ImageDisplayView` changes from `ZStack` + `.overlay(alignment:.leading)` (240pt overlay with `GeometryReader` + `Spacer.allowsHitTesting(false)`) to `HStack(spacing:0)` sibling sidebar (`MetadataHUDView` 240pt + `Divider` 1pt) + flex viewer `GeometryReader` that measures *remaining* width so `ZoomableImageView.fittedSize`/`clampedOffset` recompute and image stays centered and fully visible.

**Tech Stack:** Swift 5, SwiftUI Observation (`@Observable`, `@Binding`, `@State`), `GeometryReader`, `Divider`, `ScrollView`, `XCTest`, `xcodebuild` + `xcrun xctest`.

## Global Constraints

- Requires Xcode 16+ on macOS 14+ (README Build).
- Swift language version 5.0, deployment target 14.0.
- No new targets; synchronized folders (no `.pbxproj` edit).
- HUD is Single only (`ImageDisplayView` inside `ScrubView` `.scrub` branch), not Grid/Empty/Decoding; hidden by default (`ScrubView.hudVisible` default `false`).
- HUD is sidebar left of viewer: `HStack { 240pt MetadataHUDView + Divider(1pt) + Viewer flex }` inside `ImageDisplayView`, not overlay; image re-centers in remaining width and stays fully visible (no occlusion).
- HUD width 240 fixed, `ultraThinMaterial` background, `ScrollView` rows, `Divider` visible only when HUD shown; `transition(.move(edge:.leading).combined(with:.opacity))` on HUD and `animation(.easeInOut(duration:0.2), value:hudVisible)` on outer.
- Toolbar order `Metadata | New Session | Single/Grid | Filter | Trash` — `Metadata` text button far left (first `primaryAction`), `Trash` far right (last `primaryAction`), separate.
- Button: `Button(hudVisible ? "Hide Metadata" : "Show Metadata")` text only, no `Label`/`eye` icon, `.help(hudVisible ? "Hide metadata" : "Show metadata")`, `.disabled(appState.isCommitting)`.
- Reset: `hudVisible=false` on `phase==.empty` or `isDecoding(phase)`, on `viewMode` toggle (`old!=new`), and on `startNewSession()` (via `phase`); zoom already resets there.
- Metadata provider unchanged: rows `filename` (with extension) + `dimensions`/`fileSize`/`camera`/`lens`/`iso`/`aperture`/`shutter`/`focalLength`/`dateTaken`/`exposureBias`/`whiteBalance` plus `filePath` tooltip on File row; label `.caption2` secondary / value `.caption` primary, `lineLimit 1` middle truncation, `help` full value; missing rows omitted.
- Build harness flags: every `xcodebuild` needs `CODE_SIGNING_ALLOWED=NO` and `OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'` when run in sandbox; `derivedDataPath /tmp/qc-dd`.

---

## File Structure

```
quickcull/
├── QuickCull/
│   ├── ScrubView.swift           # move Metadata button to first primaryAction, text only
│   └── ImageDisplayView.swift    # change overlay → HStack sidebar + Divider, viewer GeometryReader on remaining width
├── QuickCullCore/Metadata/
│   └── ImageMetadataProvider.swift # unchanged (already correct)
└── QuickCullCoreTests/           # no new tests (provider 4 remain)
```

---

### Task 1: ScrubView — Metadata text button separate from Trash

**Files:**
- Modify: `QuickCull/ScrubView.swift:36-84`

**Interfaces:**
- Consumes: `ScrubView.hudVisible: Bool`, `AppState.isCommitting`, `AppState.phase/viewMode` resets.
- Produces: Toolbar `Metadata` text button first, `Trash` last, correct labels/help/disabled.

- [ ] **Step 1: Read current toolbar**

Read `QuickCull/ScrubView.swift:36-84` to confirm current order `New Session | View | Filter | Trash | Eye` with `Eye` last (`Label eye/eye.slash`).

- [ ] **Step 2: Replace eye icon with Metadata text and move to front**

Edit `QuickCull/ScrubView.swift:36-84`:

```swift
.toolbar {
    ToolbarItem(placement: .primaryAction) {
        Button(hudVisible ? "Hide Metadata" : "Show Metadata") { hudVisible.toggle() }
            .help(hudVisible ? "Hide metadata" : "Show metadata")
            .disabled(appState.isCommitting)
    }
    ToolbarItem(placement: .primaryAction) {
        Button("New Session") { showNewSessionConfirm = true }
            .disabled(appState.isCommitting)
    }
    ToolbarItem(placement: .primaryAction) {
        Picker("View", selection: Binding(
            get: { appState.viewMode },
            set: { appState.setViewMode($0) }
        )) {
            Text("Single").tag(AppState.ViewMode.scrub)
            Text("Grid").tag(AppState.ViewMode.grid)
        }.pickerStyle(.segmented).disabled(appState.isCommitting)
    }
    ToolbarItem(placement: .primaryAction) {
        Picker("Filter", selection: Binding(
            get: { appState.session?.filter ?? .all },
            set: { appState.setFilter($0) }
        )) {
            Text("All").tag(CullFilter.all)
            Text("Flagged (\(appState.session?.flaggedCount ?? 0))").tag(CullFilter.flagged)
            Text("Keepers (\(appState.session.map { $0.totalCount - $0.flaggedCount } ?? 0))")
                .tag(CullFilter.keepers)
        }
        .pickerStyle(.segmented)
        .disabled(appState.isCommitting)
    }
    ToolbarItem(placement: .primaryAction) {
        Button {
            appState.requestCommit()
            showCommitConfirm = true
        } label: {
            if appState.isCommitting {
                ProgressView().controlSize(.small)
            } else {
                Label("Move Flagged to Trash", systemImage: "trash")
            }
        }
        .disabled(appState.session?.flaggedCount == 0 || appState.isCommitting)
    }
}
```

Verify no `eye` icon remains, `Metadata` is first, `Trash` last.

- [ ] **Step 3: Keep existing resets unchanged**

Confirm `ScrubView.swift:110-130` still has:

```swift
.onChange(of: appState.phase) { _, newPhase in if newPhase == .empty || isDecoding(newPhase) { hudVisible=false; zoom... } }
.onChange(of: appState.viewMode) { old,new in if old!=new { hudVisible=false; zoom... } }
```

No new reset logic needed for button label change.

- [ ] **Step 4: Build the app**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manual verify toolbar separation**

Run `./start.sh`, in Single view verify toolbar left→right `Metadata | New Session | Single/Grid | Filter | Trash` with `Metadata` far left, `Trash` far right, not adjacent. Click `Show Metadata` → text toggles to `Hide Metadata`, tooltip toggles. Disabled while Trash spinner.

- [ ] **Step 6: Commit**

```bash
git add QuickCull/ScrubView.swift
git commit -m "fix: move Metadata button to far left as text (separate from Trash)"
```

---

### Task 2: ImageDisplayView — sidebar pushing viewer (full image visible)

**Files:**
- Modify: `QuickCull/ImageDisplayView.swift:40-59` (HUD from overlay to HStack) + `MetadataHUDView` unchanged

**Interfaces:**
- Consumes: `hudVisible: Binding<Bool>` (ScrubView), `currentFile: SessionFile?`, `cgImage: CGImage`, `zoomScale/offset` bindings, `ImageMetadataProvider`, `MetadataHUDView`.
- Produces: `HStack { if hudVisible: MetadataHUDView 240 + Divider | Viewer(GeometryReader) }` with animation, viewer `fittedSize` on remaining width, no occlusion.

- [ ] **Step 1: Read current overlay implementation**

Read `QuickCull/ImageDisplayView.swift:40-59` to confirm current `.overlay(alignment:.leading){ if hudVisible { GeometryReader{ HStack{MetadataHUDView 240 + Spacer} } } }` overlay.

- [ ] **Step 2: Replace overlay with HStack sidebar**

Edit `QuickCull/ImageDisplayView.swift:22-64` body `else if let cgImage` branch:

```swift
} else if let cgImage = appState.displayImages?.image(at: index) ?? appState.thumbWindow?.image(at: index) {
    HStack(spacing: 0) {
        if hudVisible, let file = currentFile {
            MetadataHUDView(file: file, cgImage: cgImage)
                .frame(width: 240)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .leading).combined(with: .opacity))
            Divider() // 1pt separator, only when HUD shown
        }
        GeometryReader { geo in
            ZStack {
                Color.black
                ZoomableImageView(
                    cgImage: cgImage,
                    fileID: currentFile?.id,
                    scale: $zoomScale,
                    lastScale: $zoomLastScale,
                    offset: $zoomOffset,
                    lastOffset: $zoomLastOffset
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipped()
    }
    .overlay(alignment: .topTrailing) { FlagBadgeOverlay(file: currentFile) }
    .animation(.easeInOut(duration: 0.2), value: hudVisible)
} else {
```

Remove previous `.overlay(alignment:.leading)` `GeometryReader` + `Spacer.allowsHitTesting` logic entirely. Remove `HStack` Spacer; Divider replaces border. Keep `FlagBadgeOverlay` as outer overlay on `HStack` (still topTrailing of whole viewer). Keep `MetadataHUDView` definition (`ImageDisplayView.swift:212-260`) unchanged (already has `ScrollView`, `.task(id: compound)`, `help` filePath).

Ensure `ZoomableImageView` still has its internal `GeometryReader` for `fittedSize` — now it measures remaining width after HUD (not full width), so zoom stays correct and image stays centered and fully visible.

- [ ] **Step 3: Build the app**

Run same build command as Task 1 Step 4.
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual verify sidebar + full image**

In Single view with HUD hidden: image fills full viewer width (existing). Click `Show Metadata` (first button): left 240pt panel slides from leading with `Divider`, image shrinks to `full-241` width but stays fully visible and centered in remaining space (no left edge occluded). Check:
- Divider visible between panel and image.
- Pinch double-click and drag on image area still works (panel no longer intercepts image gestures via `Spacer`).
- Drag on panel scrolls HUD `ScrollView`, not image.
- Hide (`Hide Metadata`) → panel slides away, image expands to full width.

- [ ] **Step 5: Run tests (no regression)**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build-for-testing && xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -5
```
Expected: `Executed 114 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add QuickCull/ImageDisplayView.swift
git commit -m "fix: metadata HUD as left sidebar (HStack + Divider) so full image stays visible"
```

---

## Self-Review

**Spec coverage:**
- Metadata button text `Show/Hide Metadata` far left separate from Trash far right → Task 1.
- HUD sidebar 240pt + Divider left of viewer, `HStack(spacing:0)`, `ultraThinMaterial`, `transition` slide+fade, `animation` on `hudVisible` → Task 2.
- Full image visible (viewer `GeometryReader` measures remaining width, `fittedSize`/`clampedOffset` on reduced width) → Task 2.
- Hidden by default + resets on `phase`/`viewMode` → already in ScrubView, unchanged.
- Single only, overlay removed → Task 2 removes old overlay.

**Placeholder scan:** No TBD/TODO; every step has exact file paths, code blocks, and commands.

**Type consistency:** `hudVisible: Binding<Bool>` same in `ScrubView` Task 1 and `ImageDisplayView` Task 2; `ImageMetadata`/`MetadataHUDView` unchanged; `Label` eye icon removed, `Button(String)` used.
