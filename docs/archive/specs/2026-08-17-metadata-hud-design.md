# Metadata HUD — Design

Date: 2026-08-17 (amended for sidebar + Metadata button)
Status: approved design (pre-plan) — v2: sidebar not overlay, Metadata text button separate from Trash

## Purpose

Add a left-side metadata HUD beside the image in Single view. Photographers can glance at Full EXIF + file info for the current photo without leaving culling. The HUD is a fixed sidebar to the **left of the viewer** (not an overlay), hidden by default, toggled via a toolbar **Metadata** text button that is visually separate from the destructive Trash button, and when visible the **full image remains visible** (image shrinks/re-centers in remaining width).

## Background

Single view today is `ImageDisplayView` (fit-to-window zoomable `CGImage` on black, `FlagBadge` top-trailing, pinch 1×…4× + double-click 2×, drag pan) + `FilmstripView` (100×64 thumbs + filename titles, height 102). `GridView` is a separate adaptive `LazyVGrid`. `ScrubView` owns `phase`/`viewMode`/`gridSelection` + zoom state hoisted (resets on `phase==.empty|decoding` and `viewMode` toggle), toolbar `New Session | Single/Grid | Filter | Trash` + `Metadata` (previously eye), and alerts. `SessionFile` is `url + id` only; `ImageWindow` caches downsampled `CGImage`s; `ImageIODecoder`/`LibRawDecoder` produce `RawBitmap`; `ImageCacheStore` holds q75 JPEGs keyed by path. EXIF is not currently surfaced — `CGImageSourceCopyProperties` can provide it on demand from the original file URL (no new decode path), plus `FileManager` for size and already-decoded `CGImage` dimensions. Refinement request: info must be **separate from Delete** (not next to Trash) and **full image must stay visible** even with info open, plus button should say **Metadata** (text, not eye icon).

## Approach (approved)

**Option B — Sidebar pushing image (chosen for v2).**

`ImageDisplayView` becomes an `HStack(spacing:0)` when HUD visible: fixed 240-pt `MetadataHUDView` + `Divider` (1pt) + remaining-width viewer (`ZoomableImageView`). HUD is a vertical `ScrollView` of key/value rows with `.ultraThinMaterial` background (or `Color(NSColor.windowBackgroundColor)` if material undesired over black). Image stays centered in remaining viewer width via its own `GeometryReader` `fittedSize` recomputation — no occlusion, full image visible, zoom `fittedSize`/`clampedOffset` recompute on reduced container width. Hidden by default (`@State hudVisible=false` hoisted in `ScrubView` like zoom, reset on `phase`/`viewMode`/`startNewSession`). Toolbar **Metadata** text button at **far left** (first item) is visually separate from `Move Flagged to Trash` at far right.

Rejected: (A) Overlay panel (v1) — HUD floats over image left 240pt, occludes ~10% even translucent, violates “full image visible”; also eye button was last item next to Trash — easy misclick, not separate. (C) Popover anchored to toolbar — violates “on the left of the image” and not glanceable while scrubbing.

## Architecture

- No new targets. 2 files changed (same 3-file set as v1, but with sidebar layout).
- `QuickCullCore/Metadata/ImageMetadataProvider.swift` — unchanged, pure helper to read/synthesize `ImageMetadata` from file URL + `CGImage` dimensions (already implemented).
- `QuickCull/ImageDisplayView.swift` — change from overlay to `HStack` sidebar: add `hudVisible: Bool` binding + conditional `HStack` with `MetadataHUDView` leading, `Divider`, then `ZoomableImageView` trailing; `GeometryReader` per viewer measures remaining width for correct zoom.
- `QuickCull/ScrubView.swift` — hoist `hudVisible` state, replace eye `ToolbarItem` (last after Trash) with `Metadata` text button **first** before `New Session` (or before `View` picker but after `New Session` — see UI), pass binding, reset on phase/viewMode/new session.
- Nothing else (`Session`, `ImageWindow`, `DecodeEngine`, `TrashCommit`, `GridView`, `FilmstripView`) changes.

```
ScrubView (toolbar: Metadata | New Session | Single/Grid | Filter | Trash)
  └─ .scrub → HStack(spacing:0) [if hudVisible: MetadataHUDView(240) | Divider | ImageDisplayView flex ]
        ImageDisplayView(hudVisible: Binding) — HSplit-like
          ├─ if hudVisible: MetadataHUDView (240pt, ScrollView rows ← Provider async)
          ├─ Divider (visible when hudVisible)
          └─ ZoomableImageView (remaining width, centered, pinch/double/drag clamped)
             └─ FlagBadgeOverlay (topTrailing, unchanged)
```

## Model — `QuickCullCore/Metadata/ImageMetadataProvider`

Unchanged from v1 (already implemented in `e450da0`):

```swift
public struct ImageMetadata: Equatable, Sendable {
    public let filename: String            // lastPathComponent with extension
    public let filePath: String            // standardizedFileURL.path (for tooltip)
    public let dimensions: String?         // "6000×4000" from CGImage or nil
    public let fileSize: String?           // "24.3 MB" via FileManager attributes
    public let camera: String?             // make + model
    public let lens: String?               // lensModel
    public let iso: String?                // "ISO 400"
    public let aperture: String?           // "f/2.8"
    public let shutter: String?            // "1/1000s" or "30s"
    public let focalLength: String?        // "50 mm"
    public let dateTaken: String?          // localized string from EXIF DateTimeOriginal / file creation
    public let exposureBias: String?       // "+0.7 EV"
    public let whiteBalance: String?       // "Auto" / "Manual"
}

public enum ImageMetadataProvider {
    public static func metadata(for file: SessionFile, cgImage: CGImage?) -> ImageMetadata
}
```

- EXIF keys: `kCGImagePropertyExifDictionary` (FNumber, ExposureTime, FocalLength, ISOSpeedRatings, DateTimeOriginal, ExposureBiasValue, WhiteBalance), `kCGImagePropertyTIFFDictionary` (Make, Model, LensModel), `kCGImagePropertyPixelWidth/Height` fallback.
- Threading: synchronous but may do file I/O; `ImageDisplayView` calls inside `Task.detached(priority:.utility)` + `@State` keyed by `file.id+dimensions` so rapid scrub only latest wins.

## UI — `QuickCull/ScrubView` (toolbar)

```swift
@State private var hudVisible = false // hidden by default, Single only

// Toolbar order: Metadata (far left, separate) | New Session | Single/Grid | Filter | Trash (far right)
ToolbarItem(placement: .primaryAction) {
    Button(hudVisible ? "Hide Metadata" : "Show Metadata") { hudVisible.toggle() }
        .help(hudVisible ? "Hide metadata" : "Show metadata")
        .disabled(appState.isCommitting)
}
ToolbarItem(placement: .primaryAction) {
    Button("New Session") { showNewSessionConfirm = true }.disabled(appState.isCommitting)
}
// ... View picker, Filter picker ...
ToolbarItem(placement: .primaryAction) {
    Button { appState.requestCommit() … } label: { Label("Move Flagged to Trash", systemImage:"trash") }
        .disabled(appState.session?.flaggedCount == 0 || appState.isCommitting)
}
```

- `Metadata` is **text only** (no `Label`/`eye` icon), first item, maximally distant from destructive `Trash` last item — satisfies “separate from delete”.
- Hidden by default; reset on `phase==.empty||isDecoding` and `viewMode` toggle (`old!=new` → `hudVisible=false`, also `zoom` reset), and `startNewSession` via `phase`.

## UI — `QuickCull/ImageDisplayView` (sidebar, not overlay)

Previous v1 overlay: `ZoomableImageView.overlay(alignment:.leading){ if hudVisible { HStack{ MetadataHUDView 240; Spacer } } }` — occluded image.

Becomes sidebar sibling:

```swift
@Binding var hudVisible: Bool

var body: some View {
  let index = …
  let currentFile = …
  ZStack {
    Color.black
    if files.isEmpty { Color.black }
    else if let cgImage {
      HStack(spacing: 0) {
        if hudVisible, let file = currentFile {
          MetadataHUDView(file: file, cgImage: cgImage)
            .frame(width: 240)
            .background(.ultraThinMaterial) // or Color(NSColor.controlBackgroundColor)
            .transition(.move(edge: .leading).combined(with: .opacity))
          Divider() // 1pt separator, visible only when HUD shown
        }
        // Viewer takes remaining width, always fully visible
        GeometryReader { geo in
          ZStack {
            Color.black
            ZoomableImageView(cgImage: cgImage, fileID:…, scale:…, offset:…, containerSize: geo.size) // fittedSize uses geo.size (remaining width)
          }
          .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipped()
      }
      .overlay(alignment: .topTrailing) { FlagBadgeOverlay(file: currentFile) }
      .animation(.easeInOut(duration: 0.2), value: hudVisible)
    } else { ProgressView() }
  }
}
```

- When `hudVisible==true`, `HStack` is `HUD 240 | Divider 1 | Viewer flex`; viewer `GeometryReader` now measures **remaining width**, so `ZoomableImageView.fittedSize` recomputes to fit the shrunken container — image stays centered and **fully visible** (no occlusion), letterboxed within remaining width.
- When `hudVisible==false`, `HStack` collapses to single viewer filling full width.
- `MetadataHUDView` unchanged from v1 (240pt `ScrollView` `VStack` rows, `.caption2` label secondary, `.caption` value primary, `lineLimit 1` middle truncation, `help` full value / filePath for File row, `.task(id: "\(file.id)-\(cgImage?.width ??0)x\(cgImage?.height ??0)")` detached utility).
- `Divider` only visible when HUD shown, provides clear separation.
- Filmstrip below spans full width (outside `HStack`, in `ScrubView` `VStack` below `ImageDisplayView`).

## Data Flow

```
ScrubView Metadata button (far left) toggle → ScrubView.hudVisible (default false)
  → ImageDisplayView(hudVisible: Binding)
    → HStack: [if hudVisible: MetadataHUDView(240)+Divider | Viewer GeometryReader]
      → Viewer: ZoomableImageView (scale/offset, fittedSize on remaining width, clamped)
      → MetadataHUDView(file, cgImage) → Task.detached { Provider.metadata } → rows
  On index change: currentFile.id+dimensions changes → MetadataHUDView .task reloads
  On phase/viewMode/startNewSession: ScrubView onChange resets hudVisible=false (+zoom)
```

## Edge Cases

| Case | Behavior |
|------|----------|
| Hidden by default (launch, after New Session, after grid round-trip) | `hudVisible` false; `onChange(phase)` and `onChange(viewMode)` reset |
| HUD visible + window resize | Viewer `GeometryReader` remeasures remaining width, `fittedSize` + `clampedOffset` recompute via `onChange(container.width/height)` |
| HUD visible + zoomed | Zoom stays in viewer’s remaining width; pan clamped to reduced container, still fully visible |
| Filter yields empty / commit shrink | Viewer `Color.black`, HUD not shown (no currentFile) |
| Placeholder before thumb decode | Dimensions via provider fallback to source props; HUD still shows filename/size |
| Rapid scrub | `.task(id: compound)` cancels prior, only latest wins |
| Grid view | HUD not rendered (`ImageDisplayView` only in `.scrub` branch) |
| isCommitting true | Metadata button disabled |
| Full image visible guarantee | Sidebar pushes viewer, never overlays — image re-centers, divider separates |

## Testing

- **Unit — `ImageMetadataProviderTests.swift`** (existing 4, unchanged): filename/size, dimensions, EXIF parse, missing file minimal.
- **Manual QA (updated):**
  - `Metadata` text button at far left, `Trash` at far right — visually separate, not adjacent.
  - Click `Metadata` (shows `Metadata` → `Hide Metadata`?) Actually text toggles `Show Metadata` / `Hide Metadata` — panel slides from left, `Divider` visible, image shrinks to remaining width but stays fully visible and centered, badge top-trailing in viewer, pinch/drag on image area works, drag on HUD scrolls HUD not image.
  - Click again hides, image expands to full width.
  - Hidden by default after launch / New Session / Single→Grid→Single.
  - Arrow keys while HUD visible → rows update, no stale.
  - Long filename middle-truncated with full path tooltip on File row.

## Out of Scope

- Grid HUD, resizable HUD width, persisting hudVisible across launches, histogram/peaking inside HUD, keyboard shortcut.
