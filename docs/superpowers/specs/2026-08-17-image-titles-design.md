# Image Titles Below Thumbs — Design

Date: 2026-08-17
Status: approved design (pre-plan)

## Purpose

Add filename titles below thumbnails in both surfaces where thumbs appear: Single view filmstrip and Grid. Photographers can identify files (IMG_1234.CR2) without hovering or switching to Finder, while keeping the culling speed (arrow keys, Z flag, Trash) unchanged.

## Background

Today `FilmstripView.ThumbnailCell` (100×64 `BadgedThumbnailView` in `LazyHStack`, container height 86) and `GridView.GridCell` (160×108 `BadgedThumbnailView` in `LazyVGrid` adaptive 160-200) show only the image + red `FlagBadge` + selection border. `file.url.lastPathComponent` is available on `SessionFile` but never rendered; `accessibilityLabel` already uses it in `GridView.swift:60`. The request is to surface it visibly as a one-line caption below each thumb.

## Approach (approved)

**Option A — Lightweight wrapper (chosen).**

Keep `BadgedThumbnailView` pure (image+badge invariant via `FlagBadgeLogic.shouldShow`). In each cell, wrap the existing thumbnail and a new `Text(file.url.lastPathComponent)` in a `VStack(spacing: 3-4)`. No shared-component API change; 2 files touched.

Rejected alternatives: (B) Enhance `BadgedThumbnailView` with optional `title` prop — couples generic thumbnail to file-name concern, touches shared component; (C) Dedicated per-context title components — over-engineered for identical styling (YAGNI). Chosen approach matches current pattern where `FilmstripView` and `GridView` compute `elements` in parent body to avoid per-cell observation.

## Architecture

- No new targets. 2 files changed, 0 new.
- `QuickCull/FilmstripView.swift` — `ThumbnailCell` adds title.
- `QuickCull/GridView.swift` — `GridCell` adds title.
- Nothing else (`BadgedThumbnailView`, `Session`, `AppState`, `ImageWindow`, `DecodeEngine`, `TrashCommit`) changes.

```
ScrubView (toolbar owns filter/viewMode)
  ├─ .scrub → ImageDisplayView (zoomable, unchanged) + FilmstripView (LazyHStack)
  │            └─ ThumbnailCell: VStack { BadgedThumbnailView(100×64); Text(filename) }
  └─ .grid  → GridView (LazyVGrid)
               └─ GridCell: VStack { BadgedThumbnailView(160×108); Text(filename) }
Session.files → file.url.lastPathComponent (String, lastPathComponent with extension)
```

## UI — FilmstripView (`QuickCull/FilmstripView.swift:89`)

Current `ThumbnailCell`:
```swift
BadgedThumbnailView(image:…, isFlagged:…, size:100×64, badgeSize:24)
  .overlay(selectionBorder)
  .contentShape(Rectangle())
  .onTapGesture { setCurrentIndex }
```

Becomes:
```swift
VStack(spacing: 3) {
  BadgedThumbnailView(image:…, isFlagged:…, size:100×64, badgeSize:24)
    .overlay(selectionBorder)
  Text(file.url.lastPathComponent)
    .font(.caption2)
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .truncationMode(.tail)
    .frame(width: 100, alignment: .center)
    .help(file.url.lastPathComponent) // tooltip on hover shows full name
}
.contentShape(Rectangle())
.onTapGesture { setCurrentIndex } // on outer VStack so title tap also navigates
```

- Container height `86 → 102` (6 padding top + 64 thumb + 3 spacing + ~13 caption + 6 padding bottom + thinMaterial background). Horizontal `LazyHStack(spacing: 3)` unchanged.
- Border stays on thumbnail only (not title) to avoid visual jump when title length varies.
- Title shows even when `image == nil` (placeholder `Rectangle` case in `BadgedThumbnailView`), so filenames are visible before decode lands.
- Tooltip via `.help` on `Text` (and outer VStack for hover anywhere on cell).

## UI — GridView (`QuickCull/GridView.swift:71`)

Current `GridCell`:
```swift
BadgedThumbnailView(image:…, isFlagged:…, size:160×108, badgeSize:24)
  .overlay(selectionBorder)
```

Becomes:
```swift
VStack(spacing: 4) {
  BadgedThumbnailView(image:…, isFlagged:…, size:160×108, badgeSize:24)
    .overlay(selectionBorder)
  Text(file.url.lastPathComponent)
    .font(.caption2)
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .truncationMode(.tail)
    .frame(width: 160, alignment: .center)
    .help(file.url.lastPathComponent)
}
.contentShape(Rectangle())
```

- `LazyVGrid(columns: [.adaptive(minimum:160, maximum:200)], spacing: 8)` unchanged; row height auto-grows ~16pt for title, still virtualized.
- Same font/truncation/help as filmstrip for consistency. Selection border on thumbnail only; title does not affect selection hit-test (outer `VStack` `onTapGesture` with `NSEvent` modifier handling unchanged).
- Empty state (`files.isEmpty` → `Text("No photos in this filter")`) unchanged.
- `accessibilityLabel` remains `file.url.lastPathComponent`; `Text` also provides visible label so VoiceOver reads once (no duplicate).

## Data Flow

```
Launch → prepareForLaunch → Import → Session(files: [SessionFile(url:…)]) → DecodeEngine
  → Scrubbing: AppState.session.files (filtered projection)
  → FilmstripView/GridView reads session.files, builds elements = (index,file,…,image)
  → Each cell reads file.url.lastPathComponent for Text; image from thumbWindow/gridThumbs via index
  → Title updates automatically when session.files changes (filter/commit/new import)
```

No new state in `Session`/`AppState`; title is derived from `SessionFile.url` (value type, stable id via `RawFileIdentity.fileID`). Filtering does not affect title.

## Edge Cases

| Case | Behavior |
|------|----------|
| Long filename > 100/160px | Tail truncation `IMG_123...CR2` (`.lineLimit(1)`, `.truncationMode(.tail)`); full name in `.help` tooltip on hover |
| Placeholder (image == nil) | Title still shows (VStack always renders Text) |
| Empty session / all decodes failed | `phase == .empty`, filmstrip/grid not shown — no titles |
| Filter yields empty | `Text("No photos in this filter")` — no grid titles |
| Rapid flag toggle / commit | `stripKey`/`elements` recompute already handles flag changes; title is file-name, unaffected |
| Flagged badge + title | Badge on image top-trailing via `FlagBadgeLogic`, title below — no overlap |
| Grid selection 500+ photos | `LazyVGrid` virtualization unchanged; `Text` is lightweight |

## Accessibility & Performance

- `help` tooltip provides full name on hover for truncated titles.
- `accessibilityLabel` on grid cell + visible `Text` — no duplicate VoiceOver (SwiftUI merges); filmstrip cell inherits title as accessible name plus `isSelected` trait.
- No new `ImageWindow` loads; titles are `Text` only, negligible memory/CPU. Parent-body `elements` pattern keeps per-cell observation cheap.

## Testing

- No new unit tests for logic (title = `lastPathComponent`, pure derivation). Existing `SessionTests`/`AppStateTests`/`ImageWindowTests` must still pass; title does not affect window math.
- Manual QA checklist:
  - Filmstrip shows centered `.caption2` secondary titles below each 100px thumb, tail-truncated, tooltip shows full name on hover, border stays on thumb, tap on title navigates.
  - Grid shows titles below each 160px thumb in `VStack`, same style, truncated, tooltip, selection border on thumb, `Cmd/Shift` multi-select still works, double-click still jumps to scrub.
  - Placeholder state (before thumbs decode) shows title.
  - Filter `Flagged`/`Keepers` updates titles correctly.

## Out of Scope

- Full path or metadata title (EXIF/IPTC) — only `lastPathComponent` with extension.
- Wrapping to 2 lines or middle truncation — single-line tail only.
- Editable titles, renaming, or showing titles in main `ImageDisplayView` (fit-to-window viewer).
- Sorting by filename or searching titles.
- Customizable font/style or hiding titles via preference.
