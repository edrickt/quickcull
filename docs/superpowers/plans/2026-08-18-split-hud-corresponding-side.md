# Split HUD Corresponding Side — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In split view show metadata on the corresponding side — left HUD for left photo, right HUD for right photo (outer mirrored), empty placeholder when no next image.

**Architecture:** Modify `QuickCull/ImageDisplayView.swift` split `HStack(spacing:8)` to render trailing `MetadataHUDView(file:rightFile, cgImage:rightCG, cache:appState.cache)` outer right (240pt, `.ultraThinMaterial`, `.move(edge:.trailing)`) alongside existing leading left HUD; when `rightFile==nil` show empty 240pt `photo.slash + "No next image"` placeholder. Reuse `MetadataHUDView` and `appState.cache`/`rightFile`/`rightCG` already resolved; single `hudVisible` controls both; single view mode unchanged.

**Tech Stack:** Swift 5.10+, SwiftUI (`HStack`, `GeometryReader`, `transition`, `animation`), QuickCullCore `MetadataHUDView`/`RawHistogram`, xcodebuild

## Global Constraints

* Spec: `docs/superpowers/specs/2026-08-18-split-hud-corresponding-side-design.md` (approved 2026-08-18).
* Outer mirrored split: `HStack(spacing:8){ leading HUD 240 (leftFile/leftCG) | HStack(spacing:8){LeftImage | RightImage} | trailing HUD 240 (rightFile/rightCG or empty placeholder) }` with `.background(.ultraThinMaterial)` and `.transition(.move(edge:.leading).combined(.opacity))` / `.move(edge:.trailing).combined(.opacity)` + `.animation(.easeInOut(duration:0.2), value:hudVisible)` as today.
* `MetadataHUDView` reuse: `init(file: SessionFile, cgImage: CGImage?, cache: ImageCacheStore)` with `task(id:"\(file.id)-\(w)x\(h)")` + `Task.detached(utility){ cache.loadHistogram ?? DisplayHistogram.compute }` + `histogram=nil` at task start; no change to that view.
* `rightFile`/`rightCG` from `ImageDisplayView.body` `let rightIndex=index+1; let rightFile=files.indices.contains(rightIndex) ? files[rightIndex] : nil; let rightCG=rightFile != nil ? (displayImages?.image(at:rightIndex) ?? thumbWindow?.image(at:rightIndex)) : nil` as existing lines 25-30.
* Right outer cases: `if hudVisible && rightFile!=nil && rightCG != nil` → `MetadataHUDView` (shows rows/histogram or Loading if cgImage nil but file exists); `else if hudVisible && rightFile==nil` → empty `VStack{ Image(systemName:"photo.slash").font(.title2); Text("No next image").font(.caption) }.frame(width:240).frame(maxHeight:.infinity).background(.ultraThinMaterial).transition(.move(edge:.trailing)…)`.
* Single mode unchanged: `HStack(spacing:8){ if hudVisible { MetadataHUDView(current, cgImage, cache) 240 } ; Zoomable }`.
* No new targets, no model/storage changes, `RawHistogram`/`ImageCacheStore`/`DecodeEngine`/`ScrubView` unchanged.
* Build: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build` must pass. Tests: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS'` must pass `134/0`.

---

## File Structure

* **Modify:** `QuickCull/ImageDisplayView.swift:37-76` — split branch `HStack` to add trailing right HUD + empty placeholder, with correct transitions/animations, preserving left HUD and inner `HStack(spacing:8)` image panes and `overlayFlagBadge`.

---

### Task 1: Add outer right HUD in split view

**Files:**
* Modify: `QuickCull/ImageDisplayView.swift:37-76` (split `HStack` structure)
* Test: `xcodebuild build` + `xcodebuild test -scheme QuickCullCore` manual QA

**Interfaces:**
* Consumes: `appState.session?.files`, `appState.displayImages`/`thumbWindow`, `appState.cache`, `currentFile: SessionFile?`, `rightFile: SessionFile?`, `leftCG: CGImage?`, `rightCG: CGImage?`, `hudVisible: Bool`, `MetadataHUDView(file:cgImage:cache:)`, `ZoomableImageView(cgImage:fileID:scale:...)`, `FlagBadgeLogic`.
* Produces: Split view renders `[LeftHUD? | LeftImage|RightImage | RightHUD-or-Empty?]` outer mirrored, controlled by single `hudVisible`.

- [ ] **Step 1: Verify current split HUD is left-only**

Run: `grep -n "MetadataHUDView\|rightFile\|rightCG\|hudVisible" QuickCull/ImageDisplayView.swift | head -40`
Expected: `MetadataHUDView` appears once in split branch at line ~40 with `file:file, cgImage:lcg`, and once in single branch at ~81; `rightFile`/`rightCG` defined at ~26-30; no trailing HUD in split.

- [ ] **Step 2: Implement trailing right HUD + empty placeholder**

Edit `QuickCull/ImageDisplayView.swift` — replace split branch `HStack(spacing:8)` (lines 37-76) with:

```swift
HStack(spacing: 8) {
    if hudVisible, let file = currentFile, let lcg = leftCG {
        MetadataHUDView(file: file, cgImage: lcg, cache: appState.cache)
            .frame(width: 240)
            .background(.ultraThinMaterial)
            .transition(.move(edge: .leading).combined(with: .opacity))
    }
    HStack(spacing: 8) {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = leftCG, let file = currentFile {
                    ZoomableImageView(cgImage: img, fileID: file.id, scale: $zoomScale, lastScale: $zoomLastScale, offset: $zoomOffset, lastOffset: $zoomLastOffset)
                        .overlay(alignment: .topTrailing) { FlagBadgeOverlay(file: file) }
                } else { Color.black }
            }.frame(width: geo.size.width, height: geo.size.height)
        }.clipped()
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = rightCG, rightFile != nil {
                    ZoomableImageView(cgImage: img, fileID: currentFile?.id, scale: $zoomScale, lastScale: $zoomLastScale, offset: $zoomOffset, lastOffset: $zoomLastOffset)
                } else if rightFile == nil {
                    VStack(spacing: 8) { Image(systemName:"photo.slash").font(.title2).foregroundStyle(.secondary)
                                         Text("No next image").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Color.black
                }
            }.frame(width: geo.size.width, height: geo.size.height)
        }.clipped()
    }
    if hudVisible {
        if let rFile = rightFile, let rcg = rightCG {
            MetadataHUDView(file: rFile, cgImage: rcg, cache: appState.cache)
                .frame(width: 240)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if rightFile == nil {
            VStack(spacing: 8) {
                Image(systemName: "photo.slash").font(.title2).foregroundStyle(.secondary)
                Text("No next image").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 240)
            .frame(maxHeight: .infinity, alignment: .center)
            .background(.ultraThinMaterial)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            // rightFile exists but rightCG still nil (thumb pending) — show Loading HUD via MetadataHUDView with nil cgImage
            if let rFile = rightFile {
                MetadataHUDView(file: rFile, cgImage: nil, cache: appState.cache)
                    .frame(width: 240)
                    .background(.ultraThinMaterial)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }
}
.overlay(alignment: .topTrailing) { /* no right badge */ }
.animation(.easeInOut(duration: 0.2), value: hudVisible)
.animation(.easeInOut(duration: 0.15), value: appState.viewMode)
```

Notes:
* The `else if rightFile == nil` empty placeholder mirrors spec; the final `else` (rightFile != nil && rightCG == nil) ensures right HUD still shows loading metadata even before thumb decodes — `MetadataHUDView(file:rFile, cgImage:nil, cache:)` will display "Loading…" rows until `rightCG` arrives and `task(id:)` reruns. If you prefer to wait for `rightCG`, you may fold this into `if let rFile=rightFile { MetadataHUDView(file:rFile, cgImage:rightCG, cache:...) }` (cgImage may be nil) — both are valid; choose one and keep `empty placeholder` only for `rightFile==nil`.
* Keep outer `HStack(spacing:8)` and inner `HStack(spacing:8)` exactly as spec; preserve existing `FlagBadgeOverlay` only on left pane.
* Preserve `.animation` modifiers for `hudVisible` and `viewMode`.

- [ ] **Step 3: Build the app**

Run: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build 2>&1 | tail -20`
Expected: PASS (warnings pre-existing only).

- [ ] **Step 4: Run full QuickCullCore test suite**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS' 2>&1 | grep -E "Executed|PASS|FAIL" | tail -20`
Expected: PASS — `Executed 134 tests, 0 failures`. No histogram/logic tests broken (ImageDisplayView change is UI-only).

- [ ] **Step 5: Manual QA**

Run: `./start.sh` → import `QuickCullCoreTests/Fixtures/raws/` + one `JPEG` → test:
* Single + HUD → left 240 HUD only.
* Split + HUD off → no HUDs, two images.
* Split + HUD on, first photo → left HUD shows left file (filename differs from right HUD's filename), right HUD shows right file; both histograms visible, verify filenames in HUD rows.
* Split + HUD on, last photo → left HUD normal, right outer 240 placeholder `photo.slash + "No next image"` (not HUD), right image pane also shows center "No next image".
* Split + HUD on, cold import immediate → right HUD shows "Loading…" then histogram when rightCG arrives.
* Rapid `→/←` with HUD on → both HUDs update without stale flash.
* Narrow window → fixed 240 HUDs, images shrink but stay letterboxed, no overlap.

- [ ] **Step 6: Commit**

```bash
git add QuickCull/ImageDisplayView.swift
git commit -m "feat: split HUD on corresponding sides (outer mirrored, empty placeholder at end)"
```

---

## Self-Review

**Spec coverage:**
* Outer mirrored split `HStack` with leading left HUD 240 + inner images + trailing right HUD 240 + empty placeholder `photo.slash` when `rightFile==nil` — Task 1 Step 2.
* `MetadataHUDView` reuse with `file/cgImage/cache`, `task(id:)` per HUD, `Task.detached` → Task 1 Step 2 trailing `if let rFile, let rcg` branch.
* Single `hudVisible` controls both, single mode unchanged — Task 1 Step 2.
* Build + 134 tests green, manual QA checklist — Task 1 Steps 3-5.

**Placeholder scan:** No TBD/TODO; every step has concrete Swift code with exact `frame(240)`, `.ultraThinMaterial`, transitions, `xcodebuild` commands.

**Type consistency:** `MetadataHUDView(file:SessionFile, cgImage:CGImage?, cache:ImageCacheStore)` 3-arg init used identically for left and right; `currentFile: SessionFile?`/`rightFile: SessionFile?`/`leftCG/rightCG: CGImage?`/`appState.cache: ImageCacheStore`/`hudVisible: Bool` match `ImageDisplayView.body` locals at lines 22-30; `ZoomableImageView` bindings `scale/lastScale/offset` preserved as `Binding<CGFloat/CGSize>`.

