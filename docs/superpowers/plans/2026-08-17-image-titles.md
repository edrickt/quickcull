# Image Titles Below Thumbs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show filename with extension as a one-line truncated caption below each thumbnail in both the single-view filmstrip and the grid, with hover tooltip for the full name.

**Architecture:** `FilmstripView.ThumbnailCell` and `GridView.GridCell` each wrap the existing pure `BadgedThumbnailView` in a `VStack` with a `Text(file.url.lastPathComponent)` caption (`.caption2` secondary, `lineLimit 1`, `tail` truncation, `help` tooltip). No changes to `BadgedThumbnailView`, `Session`, `AppState`, or `ImageWindow`. Filmstrip container height grows from 86 to 102 to fit the caption.

**Tech Stack:** Swift 5, SwiftUI (Observation), XCTest, `xcodebuild` + `xcrun xctest` on macOS 14+.

## Global Constraints

- Requires Xcode 16+ on macOS 14+ (README Build).
- Swift language version 5.0, deployment target 14.0.
- No new targets; synchronized folders (no `.pbxproj` edit).
- Titles are `file.url.lastPathComponent` (with extension) only — no full path, no EXIF.
- Single-line tail truncation, `.caption2` secondary, centered, `help` tooltip shows full name.
- Badge invariant: `FlagBadgeLogic.shouldShow(isFlagged:hasImage)` — badge on image, never on placeholder/title.
- Selection border stays on thumbnail only, not title; taps on title also select/navigate (outer `contentShape` + `onTapGesture`).
- Titles visible even before thumb decode (placeholder case).
- Existing `ImageWindow` / `Session` / `AppState` behavior unchanged; filter/commit/window logic unaffected.
- Build harness flags: every `xcodebuild` needs `CODE_SIGNING_ALLOWED=NO` and `OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'` when run in sandbox; `derivedDataPath /tmp/qc-dd`.

---

## File Structure

```
quickcull/
├── QuickCull/
│   ├── FilmstripView.swift   # ThumbnailCell adds VStack + Text title, height 86→102
│   ├── GridView.swift        # GridCell adds VStack + Text title
│   └── BadgedThumbnailView.swift # unchanged (still image+badge only)
├── QuickCullCore/            # unchanged for this feature
└── docs/superpowers/specs/2026-08-17-image-titles-design.md  # (already committed)
```

---

### Task 1: Filmstrip titles below thumbs

**Files:**
- Modify: `QuickCull/FilmstripView.swift:89-110`
- Test: manual QA + `xcodebuild` build; no new unit tests (pure view)

**Interfaces:**
- Consumes: `SessionFile.url: URL`, `ThumbnailCell.file: SessionFile`, `ThumbnailCell.isFlagged: Bool`, `AppState.thumbWindow?.image(at:)`, `BadgedThumbnailView(image:isFlagged:size:badgeSize:)`, `FlagBadgeLogic`.
- Produces: `ThumbnailCell` renders `VStack { BadgedThumbnailView(100×64); Text(lastPathComponent) }` with tooltip and tap.

- [ ] **Step 1: Read current ThumbnailCell**

Read `QuickCull/FilmstripView.swift:89-110` to confirm current `ThumbnailCell` body (BadgedThumbnailView + overlay + contentShape + onTapGesture) and parent `FilmstripView:61` height 86.

- [ ] **Step 2: Modify ThumbnailCell to add title**

Edit `QuickCull/FilmstripView.swift:89-110`:

```swift
struct ThumbnailCell: View {
    let index: Int
    let file: SessionFile
    let isFlagged: Bool
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 3) {
            BadgedThumbnailView(
                image: appState.thumbWindow?.image(at: index),
                isFlagged: isFlagged,
                size: CGSize(width: 100, height: 64),
                badgeSize: 24
            )
            .overlay(
                Rectangle().strokeBorder(
                    index == appState.session?.currentIndex ? Color.accentColor : .clear,
                    lineWidth: 2)
            )
            Text(file.url.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 100, alignment: .center)
                .help(file.url.lastPathComponent)
        }
        .contentShape(Rectangle())
        .onTapGesture { appState.setCurrentIndex(index) }
        .help(file.url.lastPathComponent) // tooltip when hovering thumb as well
    }
}
```

- [ ] **Step 3: Bump filmstrip container height**

Edit `QuickCull/FilmstripView.swift:61`:

```swift
.frame(height: 102) // was 86; adds room for caption (64 thumb + 3 spacing + ~13 caption + 12 padding)
```

Keep `.background(.thinMaterial)` and `ScrollViewReader` logic unchanged.

- [ ] **Step 4: Build the app**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manual verify filmstrip titles**

Run `./start.sh` (or open built app), import 2+ RAWs + 1 JPEG, verify in Single view:
- Each thumb shows filename with extension centered below thumb in `.caption2` secondary, single line tail-truncated.
- Hovering thumb or title shows tooltip with full name.
- Tap on title navigates (same as thumb).
- Selection border stays on thumb only.
- Placeholder (slow thumb) still shows title.
- Flag badge remains top-trailing on image, not title.

- [ ] **Step 6: Run tests (no regression)**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build-for-testing && xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -5
```
Expected: `Executed 108 tests, with 0 failures`

- [ ] **Step 7: Commit**

```bash
git add QuickCull/FilmstripView.swift
git commit -m "feat: filmstrip titles below thumbs (filename, caption2, tail truncate)"
```

---

### Task 2: Grid titles below thumbs

**Files:**
- Modify: `QuickCull/GridView.swift:71-83`
- Test: manual QA + build; no new unit tests

**Interfaces:**
- Consumes: `GridCell.file: SessionFile`, `GridCell.isSelected/isFlagged/image`, `BadgedThumbnailView`, `AppState.gridSelection/gridThumbs`, `SessionFile.url`.
- Produces: `GridCell` renders `VStack { BadgedThumbnailView(160×108); Text }` with same styling.

- [ ] **Step 1: Read current GridCell**

Read `QuickCull/GridView.swift:71-83` to confirm current `GridCell` (BadgedThumbnailView + overlay + contentShape, no Text).

- [ ] **Step 2: Modify GridCell to add title**

Edit `QuickCull/GridView.swift:71-83`:

```swift
private struct GridCell: View {
    let index: Int; let file: SessionFile; let isSelected: Bool; let isFlagged: Bool; let image: CGImage?
    var body: some View {
        VStack(spacing: 4) {
            BadgedThumbnailView(
                image: image,
                isFlagged: isFlagged,
                size: CGSize(width: 160, height: 108),
                badgeSize: 24
            )
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
            Text(file.url.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 160, alignment: .center)
                .help(file.url.lastPathComponent)
        }
        .contentShape(Rectangle())
        .help(file.url.lastPathComponent)
    }
}
```

Note: Remove `contentShape`/`overlay` from inner thumbnail only; keep outer `VStack` `contentShape` for larger tap target? Actually keep as above: inner overlay stays on thumbnail, outer `VStack` gets `contentShape` and `help`. The `GridView.swift:44-58` `onTapGesture` handling (Cmd/Shift/double-click) is on the `GridCell` view modifier outside — it will still fire when tapping the title because `contentShape` covers VStack.

- [ ] **Step 3: Build the app**

Run same build command as Task 1 Step 4.
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual verify grid titles**

In Grid view (`Single` → `Grid` picker), verify:
- Each cell shows same `.caption2` secondary title below 160×108 thumb, tail-truncated, tooltip on hover shows full name.
- Selection border stays on thumbnail only; title not bordered.
- Cmd/Shift multi-select still works when clicking title area (outer contentShape).
- Double-click on title area still jumps to scrub at that photo (since `onTapGesture` is on cell, not just thumb).
- Empty filter (`Flagged` with 0) still shows placeholder, no titles.
- Flag badge still top-trailing on image.

- [ ] **Step 5: Run tests (no regression)**

Run same test command as Task 1 Step 6.
Expected: `Executed 108 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add QuickCull/GridView.swift
git commit -m "feat: grid titles below thumbs (filename, caption2, tail truncate)"
```

---

## Self-Review

**Spec coverage:**
- Filename with extension via `lastPathComponent` → Task 1 & 2 Text.
- Truncate with ellipsis (single line tail, help tooltip) → both tasks `.lineLimit(1)`, `.truncationMode(.tail)`, `.help`.
- Small secondary caption centered → `.font(.caption2)`, `.foregroundStyle(.secondary)`, `frame(width:…, alignment:.center)`.
- Filmstrip below thumbs + height bump 86→102 → Task 1.
- Grid below thumbs + VStack spacing 4 → Task 2.
- Titles visible on placeholder → Text outside `if let image` (VStack always).
- Badge/selection on thumb only → overlay stays on `BadgedThumbnailView`, not title.
- Data flow `file.url.lastPathComponent` derived, no new state → no AppState/Session changes.

**Placeholder scan:** No TBD/TODO; every step has exact file paths, code blocks, and commands.

**Type consistency:** `file: SessionFile`, `file.url.lastPathComponent: String`, `help(_: String)`, `font(.caption2)`, `frame(width: 100/160)` match spec; no new types introduced.

**Risks checked:** LazyHStack/LazyVGrid virtualization unaffected (Text lightweight); parent-body `elements` pattern keeps observation cheap; contentShape on outer VStack ensures title taps navigate/select.
