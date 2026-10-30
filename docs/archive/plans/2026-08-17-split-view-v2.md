# Split View v2 (Synchronized Zoom + Gap) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Split’s right pane also zoomable and keep both panes fully synchronized (same scale/offset, gestures on either pane affect both) and replace the 1pt `Divider` between panes (and between HUD and viewer) with an 8pt black gap so the full image stays visible with no dividing line.

**Architecture:** No new files/targets. `ImageDisplayView`’s `Split` branch changes from `HStack(spacing:0){ Left Zoomable | Divider | Right Fit (fixed 1×) }` to `HStack(spacing:8){ Left Zoomable(shared bindings) | Right Zoomable(shared bindings, same scale/offset) }` with no `Divider`; outer `HStack` for HUD also goes from `HUD 240 + Divider + SplitViewer` to `HUD 240 + gap 8 + SplitViewer` (so HUD→viewer also shows gap, not line). `ScrubView` and `AppState` unchanged (zoom state already hoisted in `ScrubView` as 4 bindings, resets on `phase`/`viewMode` already cover Split).

**Tech Stack:** Swift 5, SwiftUI Observation (`@Observable`, `@Binding`, `@State`), `GeometryReader`, `Divider` removal, `ZoomableImageView` reuse, `XCTest`, `xcodebuild` + `xcrun xctest`.

## Global Constraints

- Requires Xcode 16+ on macOS 14+ (README Build).
- Swift language version 5.0, deployment target 14.0.
- No new targets; synchronized folders (no `.pbxproj` edit).
- Split shows current + next side-by-side in `HStack(spacing:8)` with **no `Divider`** between panes (and between HUD and viewer), 8pt `Color.black` gap via spacing; both panes remain fully visible side-by-side.
- Both panes share the hoisted `ScrubView` zoom bindings (`zoomScale/zoomLastScale/zoomOffset/zoomLastOffset`); left and right are both `ZoomableImageView` using same bindings — fully synchronized: pinch/double-click/drag on either pane updates shared `scale`/`offset` and both panes reflect instantly; `fileID` `onChange` still recenters shared `offset` for new pair (use leftFile’s id as pair id).
- Right pane is zoomable (not fit-only `opacity 0.92`); left keeps `FlagBadge` top-trailing, right has no badge/HUD (HUD still left file only, not right).
- Placeholder at last index still `ZStack { Color.black; VStack { Image(systemName:"photo.slash"); Text("No next image") } }` with no zoom (rightFile==nil).
- Navigation `←/→` shifts both by 1 overlapping, filmstrip highlight stays on left/current; `↑/↓` jumps by 10 similarly.
- HUD sidebar 240 + gap 8 left of viewer (not overlay), hidden by default, resets on `phase==.empty|decoding` and `viewMode` toggle.
- Build harness flags: every `xcodebuild` needs `CODE_SIGNING_ALLOWED=NO` and `OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'` when run in sandbox; `derivedDataPath /tmp/qc-dd`.

---

## File Structure

```
quickcull/
└── QuickCull/ImageDisplayView.swift      # Split HStack spacing 0+Divider → spacing:8 no Divider; right Fit → Zoomable shared bindings
```

---

### Task 1: Remove Divider, keep gap (HUD + split)

**Files:**
- Modify: `QuickCull/ImageDisplayView.swift:35-77`

**Interfaces:**
- Consumes: `ScrubView.hudVisible`, `ImageDisplayView` outer `HStack`, `SplitViewer` inner `HStack`, `Divider`.
- Produces: Outer `HStack(spacing:8)` when `hudVisible` (HUD 240 + gap 8 + SplitViewer) and inner `HStack(spacing:8)` for panes with no `Divider` (gap via spacing and black background).

- [ ] **Step 1: Read current HUD + split Dividers**

Read `QuickCull/ImageDisplayView.swift:35-77` to confirm current `HStack(spacing:0){ if hudVisible { MetadataHUDView 240; Divider() } HStack(spacing:0){ Left; if rightFile != nil { Divider() } Right } }`.

- [ ] **Step 2: Replace outer HUD+viewer Divider with gap and inner pane Divider with gap**

Edit `QuickCull/ImageDisplayView.swift:35-54`:

```swift
HStack(spacing: 8) { // was spacing:0 with Divider() after HUD
    if hudVisible, let file = currentFile, let lcg = leftCG {
        MetadataHUDView(file: file, cgImage: lcg)
            .frame(width: 240)
            .background(.ultraThinMaterial)
            .transition(.move(edge: .leading).combined(with: .opacity))
        // Divider() removed — gap via HStack spacing 8 + Color.black background
    }
    HStack(spacing: 8) { // was spacing:0, gap replaces Divider
        // Left — current, zoomable shared
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = leftCG, let file = currentFile {
                    ZoomableImageView(cgImage: img, fileID: file.id, scale: $zoomScale, lastScale: $zoomLastScale, offset: $zoomOffset, lastOffset: $zoomLastOffset)
                        .overlay(alignment: .topTrailing) { FlagBadgeOverlay(file: file) }
                } else { Color.black }
            }.frame(width: geo.size.width, height: geo.size.height)
        }.clipped()
        // Right — next, also zoomable shared (Task 2 will replace Fit)
        // (Keep current right placeholder logic for now; Task 2 will change to Zoomable)
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = rightCG {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: fittedSize(for: img, in: geo.size).width, height: fittedSize(for: img, in: geo.size).height)
                        .opacity(0.92)
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
```

For Task 1, keep right as `Fit` (still `opacity 0.92`) — only remove `if rightFile != nil { Divider() }` line and change outer/inner spacing to `8`, remove `Divider()` after `MetadataHUDView` and between panes. `HStack` spacing now provides 8pt `Color.black` (outer `ZStack Color.black`) gap.

- [ ] **Step 3: Build the app**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual verify gap**

In Single with HUD hidden → image full width. `Show Metadata` → left 240 HUD + 8pt gap (black) + image (shrinks but fully visible, no line). In Split with HUD hidden → left/right with 8pt black gap (no line), both fully visible. With HUD visible → HUD 240 + gap 8 + split pair (left/right gap 8). No `Divider` lines anywhere.

- [ ] **Step 5: Commit**

```bash
git add QuickCull/ImageDisplayView.swift
git commit -m "fix: remove dividers but keep 8pt gap between HUD/viewer and split panes (full image visible)"
```

---

### Task 2: Synchronized zoom both panes

**Files:**
- Modify: `QuickCull/ImageDisplayView.swift:56-72` (right pane)

**Interfaces:**
- Consumes: `ScrubView` hoisted `zoomScale/lastScale/offset/lastOffset` (shared), `leftFile/rightFile`, `leftCG/rightCG`, `ZoomableImageView` (existing with `fileID`, `scale`, `lastScale`, `offset`, `lastOffset` bindings, `magnificationGesture`/`dragGesture`/`handleDoubleClick`/`fileID onChange`/`container onChange`/`fittedSize`/`clampedOffset`).
- Produces: Right pane also `ZoomableImageView` sharing same bindings, so pinch/double/drag on either zooms/pans both.

- [ ] **Step 1: Replace right fit-only image with ZoomableImageView sharing bindings**

Edit `QuickCull/ImageDisplayView.swift:56-72` right `GeometryReader` block:

Before (fit):
```swift
GeometryReader { geo in
    ZStack {
        Color.black
        if let img = rightCG {
            Image(decorative: img, scale:1).resizable().aspectRatio(contentMode:.fit)
                .frame(width: fittedSize(for: img, in: geo.size).width, height: fittedSize(for: img, in: geo.size).height)
                .opacity(0.92)
        } else { placeholder }
    }.frame(width:geo.size.width,height:geo.size.height)
}.clipped()
```

After:
```swift
GeometryReader { geo in
    ZStack {
        Color.black
        if let img = rightCG, let file = rightFile {
            // Use leftFile.id as pair id so both recentre together on new pair
            ZoomableImageView(cgImage: img, fileID: currentFile?.id, scale: $zoomScale, lastScale: $zoomLastScale, offset: $zoomOffset, lastOffset: $zoomLastOffset)
        } else if rightFile == nil {
            VStack(spacing:8){ Image(systemName:"photo.slash").font(.title2).foregroundStyle(.secondary)
                               Text("No next image").font(.caption).foregroundStyle(.secondary) }
        } else {
            // rightFile exists but rightCG not yet loaded (thumb pending)
            Color.black
        }
    }.frame(width: geo.size.width, height: geo.size.height)
}.clipped()
```

Remove `opacity 0.92` (both panes now same visual, no dim); right has no `FlagBadge` (keep left badge only). Both panes now have gestures; `fileID` for right uses `currentFile?.id` (left’s id) so `onChange(fileID)` recenters both together when pair changes. Keep left’s `ZoomableImageView` as is (already uses `currentFile.id`).

If `ZoomableImageView`’s `fileID` `onChange` is shared, a single `leftFile.id` change will reset shared `offset` once — sufficient for pair. Right’s `ZoomableImageView` will also have same `fileID` (left’s id), so its `onChange` will also reset same shared offset (second reset is idempotent). Acceptable.

- [ ] **Step 2: Remove helper `fittedSize` duplication if now unused for right**

The helper `private func fittedSize(for:in:)` at `ImageDisplayView.swift:99-105` was only for right fit pane. After both panes use `ZoomableImageView`, that helper is still needed for `ZoomableImageView`'s own `fittedSize` (inside that struct), but the outer `ImageDisplayView.fittedSize` becomes unused and can be removed. However keep it if still used elsewhere (Single’s right placeholder not needed). Remove if unused to avoid dead code.

Check if outer `fittedSize` still used: Single branch uses `ZoomableImageView` only, not outer. After change, outer `fittedSize` is unused — delete it:

```swift
// Delete:
// private func fittedSize(for image: CGImage, in container: CGSize) -> CGSize { ... }
```

Keep `ZoomableImageView`’s own `fittedSize`/`clampedOffset`.

- [ ] **Step 3: Build the app**

Run same build command as Task 1 Step 3.
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual verify synchronized zoom**

In `Split` with 2+ images:
- Pinch on left → both zoom 1×…4× together; pinch on right → both zoom; double-click either → both toggle fit↔200%; drag either when zoomed → both pan together (same offset, clamped per pane).
- `→` with zoomed → new pair `(1,2)` recenters shared offset to zero at same scale (pair change recenters both).
- HUD visible: outer gap 8, inner gap 8, no lines, both panes fully visible.

- [ ] **Step 5: Run tests (no regression)**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build-for-testing && xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -5
```
Expected: `Executed 116 tests, with 0 failures` (114 baseline + 2 split AppState tests).

- [ ] **Step 6: Commit**

```bash
git add QuickCull/ImageDisplayView.swift
git commit -m "feat: synchronized zoom both panes in split (shared bindings, pinch/drag/double-click on either affects both)"
```

---

## Self-Review

**Spec coverage:**
- Remove dividing line but keep space (8pt black gap via HStack spacing:8, no Divider between panes and between HUD and viewer) → Task 1.
- Full image still visible even with info open (HUD 240 + gap 8 left of split viewer, split viewer flex with both panes fully visible) → Task 1 outer HStack and Task 2 viewer layout.
- Synchronized zoom both panes in Split (shared ScrubView zoom bindings, both ZoomableImageView, gestures on either, fileID pair recentering) → Task 2.
- Toolbar Metadata separate from Trash far right already (no change) — verified not regressed.

**Placeholder scan:** No TBD/TODO; every step has exact file paths, code blocks, and commands.

**Type consistency:** `zoomScale: Binding<CGFloat>` etc. already hoisted in `ScrubView` and consumed by `ImageDisplayView`/`ZoomableImageView` — Task 2 reuses same types, no new state; `fileID: String?` shared for pair, `Divider` removal changes are type-less layout.

