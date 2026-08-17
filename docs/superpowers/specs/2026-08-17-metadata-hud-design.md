# Metadata HUD — Design

Date: 2026-08-17
Status: approved design (pre-plan)

## Purpose

Add a left-side metadata HUD overlay inside Single view viewer. Photographers can glance at Full EXIF + file info for the current photo without leaving culling. The HUD floats over the left edge of the viewer, is hidden by default, and is toggled via a toolbar eye button.

## Background

Single view today is `ImageDisplayView` (fit-to-window zoomable `CGImage` on black, `FlagBadge` top-trailing, pinch 1×…4× + double-click 2×, drag pan) + `FilmstripView` (100×64 thumbs + filename titles, height 102). `GridView` is a separate adaptive `LazyVGrid`. `ScrubView` owns `phase`/`viewMode`/`gridSelection` + zoom state hoisted (resets on `phase==.empty|decoding` and `viewMode` toggle), toolbar `New Session | Single/Grid | Filter | Trash`, and alerts. `SessionFile` is `url + id` only; `ImageWindow` caches downsampled `CGImage`s; `ImageIODecoder`/`LibRawDecoder` produce `RawBitmap`; `ImageCacheStore` holds q75 JPEGs keyed by path. EXIF is not currently surfaced — `CGImageSourceCopyProperties` can provide it on demand from the original file URL (no new decode path), plus `FileManager` for size and already-decoded `CGImage` dimensions. Request is: HUD on left of image in Single view, able to be hidden, hidden by default, toolbar eye toggle, Full EXIF.

## Approach (approved)

**Option A — Overlay panel inside viewer (chosen).**

Keep `ImageDisplayView` centered. When HUD visible, overlay an `HStack` with a fixed 240-pt `ultraThinMaterial` panel pinned leading inside the viewer `GeometryReader` frame, above the zoomable image but below the `FlagBadge` top-trailing corner. Panel is `ScrollView` of key/value rows. HUD floats over the black letterbox left edge and over ~10% of the image when visible (translucent mitigates occlusion); it does not push/resize the image, so zoom `fittedSize`/`clampedOffset` and filmstrip layout stay unchanged. Hidden by default (`@State hudVisible=false` hoisted in `ScrubView` like zoom, reset on `phase`/`viewMode`/`startNewSession`). Toolbar eye button (`eye`/`eye.slash`) toggles it.

Rejected: (B) Sidebar pushing image — image jumps/resizes on toggle, disrupts muscle memory, complicates zoom math; (C) Popover anchored to toolbar — violates “on the left of the image” and not glanceable while scrubbing.

## Architecture

- No new targets. 3 files changed, 1 new.
- `QuickCullCore/Metadata/ImageMetadataProvider.swift` — new, pure helper to read/synthesize `ImageMetadata` from a file URL + current `CGImage` dimensions.
- `QuickCull/ImageDisplayView.swift` — add `hudVisible: Bool` binding + overlay panel.
- `QuickCull/ScrubView.swift` — hoist `hudVisible` state, add eye toggle `ToolbarItem`, pass binding to `ImageDisplayView`, reset on phase/viewMode/new session.
- Nothing else (`Session`, `ImageWindow`, `DecodeEngine`, `TrashCommit`, `GridView`, `FilmstripView`) changes beyond reading metadata.

```
ScrubView (toolbar: New Session | View | Filter | Trash | Eye)
  └─ .scrub → ImageDisplayView(hudVisible: Binding) — GeometryReader
               ├─ ZoomableImageView (centered, existing pinch/double-click/drag, clamped)
               ├─ HUD panel (if hudVisible) — HStack { 240pt ScrollView rows; Spacer }
               │     rows ← ImageMetadataProvider.metadata(for: SessionFile, cgImage: CGImage?) async
               └─ FlagBadgeOverlay (topTrailing, unchanged)
```

## Model — `QuickCullCore/Metadata/ImageMetadataProvider`

Pure value provider; no `@Observable`, no cache. Called from `ImageDisplayView` with `currentFile` + `cgImage`.

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
    // Additional Full EXIF fields if available:
    public let exposureTimeRaw: String?    // raw fraction before formatting
    public let fNumberRaw: Double?
    public let focalLengthRaw: Double?
    public let isorRaw: Int?
}

public enum ImageMetadataProvider {
    /// Reads EXIF + file attributes for `file` and current `cgImage` dimensions.
    /// Returns nil only if file url is nil; individual fields are optional.
    /// Runs synchronously off main via detached task; caller caches last result per fileID if desired.
    public static func metadata(for file: SessionFile, cgImage: CGImage?) -> ImageMetadata

    /// Helper: CGImageSourceCopyPropertiesAtIndex → [CFString:Any] traversal for EXIF/ TIFF keys.
    /// Uses kCGImagePropertyExifDictionary, TIFF, etc. with safe casting; unknown keys ignored.
    private static func exifString(_ dict: [CFString:Any], key: CFString) -> String?
}
```

- EXIF keys: `kCGImagePropertyExifDictionary` (FNumber, ExposureTime, FocalLength, ISOSpeedRatings, DateTimeOriginal, ExposureBiasValue, WhiteBalance), `kCGImagePropertyTIFFDictionary` (Make, Model, LensModel), `kCGImagePropertyPixelWidth/Height` fallback if `cgImage` nil.
- Formatting: aperture `f/%.1f`, shutter as fraction `1/250s` when <1s else `"%g s"`, focal `"%g mm"`, ISO `ISO %d`, exposureBias `"%+.1f EV"`, whiteBalance `0=Auto,1=Manual`, date via `DateFormatter.localizedString`, file size via `ByteCountFormatter` (file, not .count).
- Threading: provider is synchronous but may do file I/O (`CGImageSourceCreateWithURL` + `FileManager.attributesOfItem`); `ImageDisplayView` calls it inside `Task.detached(priority:.utility)` and stores result in `@State` to avoid blocking main. Result keyed by `file.id` so rapid scrub (arrow repeat) does not spam I/O — only latest wins.
- No persistence; filtering does not affect metadata.

## UI — `QuickCull/ScrubView` (toolbar)

```swift
@State private var hudVisible = false // default hidden, hoisted like zoom

ToolbarItem(placement: .primaryAction) {
    Button { hudVisible.toggle() } label: {
        Label(hudVisible ? "Hide Info" : "Show Info",
              systemImage: hudVisible ? "eye.slash" : "eye")
    }
    .help(hudVisible ? "Hide metadata" : "Show metadata")
    .disabled(appState.isCommitting) // mirrors Trash/View/Filter gating
}
```

- Order: `New Session | Single/Grid | Filter | Trash | Eye` (Eye last, closest to trailing, least culling-critical).
- Pass ` $hudVisible` to `ImageDisplayView(hudVisible: Binding<Bool>, ...)`.
- Reset: add `.onChange(of: appState.phase)` already resets zoom — extend to also `hudVisible=false` when `newPhase==.empty || isDecoding`; and `.onChange(of: appState.viewMode)` already resets zoom — also reset `hudVisible=false` when toggling to grid or back (so grid has no HUD and Single after grid lands hidden). `startNewSession()` also resets via phase.

## UI — `QuickCull/ImageDisplayView` (HUD overlay)

Current `ImageDisplayView` body: `ZStack { Color.black; if empty … else if cgImage { ZoomableImageView } }`.

Becomes (simplified, zoom bindings omitted for brevity):

```swift
@Binding var hudVisible: Bool

var body: some View {
  let index = …
  let currentFile = … // guarded file at currentIndex
  ZStack {
    Color.black
    if files.isEmpty { Color.black }
    else if let cgImage { 
      GeometryReader { geo in
        ZStack {
          Color.black
          ZoomableImageView(cgImage: cgImage, fileID:…, scale:…, offset:…) // existing
          if hudVisible, let file = currentFile {
            HStack(spacing: 0) {
              MetadataHUDView(file: file, cgImage: cgImage) // 240pt panel
                .frame(width: 240)
                .background(.ultraThinMaterial)
                .overlay(Rectangle().strokeBorder(.separator.opacity(0.2), lineWidth: 0.5)) // right edge
                .transition(.move(edge: .leading).combined(with: .opacity))
              Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .allowsHitTesting(true) // panel intercepts drags; spacer passes through
          }
        }
        .clipped()
      }
      .overlay(alignment: .topTrailing) { FlagBadgeOverlay(file: currentFile) }
    } else { ProgressView() }
  }
  .animation(.easeInOut(duration: 0.2), value: hudVisible)
}

private struct MetadataHUDView: View {
    let file: SessionFile
    let cgImage: CGImage?
    @State private var metadata: ImageMetadata?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.label) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.label).font(.caption2).foregroundStyle(.secondary)
                        Text(row.value).font(.caption).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                          .help(row.value) // full value tooltip
                    }
                }
            }
            .padding(10)
        }
        .task(id: file.id) { // reload when photo changes
            metadata = await Task.detached(priority: .utility) {
                ImageMetadataProvider.metadata(for: file, cgImage: cgImage)
            }.value
        }
    }
    private var rows: [(label:String, value:String)] {
        guard let m = metadata else { return [("Loading…","")] }
        var r: [(String,String)] = []
        r.append(("File", m.filename))
        if let v = m.dimensions { r.append(("Dimensions", v)) }
        if let v = m.fileSize { r.append(("Size", v)) }
        if let v = m.camera { r.append(("Camera", v)) }
        if let v = m.lens { r.append(("Lens", v)) }
        if let v = m.iso { r.append(("ISO", v)) }
        if let v = m.aperture { r.append(("Aperture", v)) }
        if let v = m.shutter { r.append(("Shutter", v)) }
        if let v = m.focalLength { r.append(("Focal", v)) }
        if let v = m.dateTaken { r.append(("Date", v)) }
        if let v = m.exposureBias { r.append(("Exposure Bias", v)) }
        if let v = m.whiteBalance { r.append(("White Balance", v)) }
        return r
    }
}
```

- Panel width 240, height = viewer height, pinned leading, `ScrollView` for overflow (Full EXIF may exceed height).
- Text: label `.caption2` secondary, value `.caption` primary, `lineLimit 1` middle truncation so extension visible.
- `help` on value shows full string if truncated; `file.filePath` tooltip on filename row.
- `animation` on `hudVisible` for slide+fade; viewer image stays centered under HUD (translucent shows image behind at 0.3 opacity if using `.ultraThinMaterial` over black).
- `allowsHitTesting`: panel blocks drag/pinch when hovering HUD; zoom still works on image area to the right.
- No HUD in `GridView` or `EmptyStateView`/`DecodingView`.

## Data Flow

```
ScrubView toolbar eye toggle → ScrubView.hudVisible (Bool, default false)
  → ImageDisplayView(hudVisible: Binding)
    → GeometryReader viewer
      → ZoomableImageView (scale/offset, fittedSize, clamped, fileID onChange)
      → if hudVisible → MetadataHUDView(file, cgImage) → Task.detached { Provider.metadata }
                          → @State metadata → rows → ScrollView
  On index change (arrow keys): currentFile.id changes → MetadataHUDView .task(id: file.id) reloads
  On phase/viewMode change: ScrubView onChange resets hudVisible=false (and zoom)
  On startNewSession: phase=.empty → RootView shows EmptyStateView, HUD hidden
```

## Edge Cases

| Case | Behavior |
|------|----------|
| Hidden by default (launch, after import, after grid round-trip) | `hudVisible` init `false`; `onChange(phase)` and `onChange(viewMode)` reset to `false` |
| Filter yields empty (`files.isEmpty` true) | Viewer shows `Color.black`, HUD not shown (no `currentFile`) |
| Placeholder before thumb decode (`cgImage == thumb` 320px) | Dimensions from thumb `CGImage` (320px) may be wrong; prefer EXIF PixelWidth/Height or file's cached full-res dimensions via `ImageMetadataProvider` reading source props fallback |
| Rapid scrub (key repeat) | `.task(id: file.id)` cancels previous detached provider task; only latest file's metadata wins; no I/O spam |
| Missing EXIF (PNG, stripped JPEG, truncated RAW) | Individual fields `nil` → row omitted; panel still shows filename/dimensions/size |
| File not readable / cache missing | Provider returns minimal metadata (filename only); no throw, no banner |
| Grid view | HUD not rendered (`ImageDisplayView` only in `.scrub` branch) |
| Decoding phase | `ScrubView` not visible (RootView shows `DecodingView`), eye button not visible |
| isCommitting true | Eye button disabled (mirrors Trash), HUD cannot be toggled mid-commit |
| Zoomed + HUD visible | Zoom `fittedSize` stays on container width (HUD overlays, does not shrink container); pan still clamped to container (HUD occludes left 240pt but pan limits unchanged) |

## Testing

- **Unit — `QuickCullCoreTests/ImageMetadataProviderTests.swift`** (new):
  - `testFilenameAndFileSize` — create temp file, assert `metadata.filename == lastPathComponent` and `fileSize` formatted via `ByteCountFormatter`.
  - `testDimensionsFromCGImagePreferred` — pass `cgImage` 6000×4000, assert `dimensions=="6000×4000"`.
  - `testExifFieldsParsed` — use pinned fixtures with known EXIF (e.g., DNG/CR2 with make/model/lens), assert `camera`, `iso`, `aperture` strings formatted.
  - `testMissingFileReturnsMinimal` — non-existent URL returns only `filename`/`filePath`, no throw.

- **Unit — `AppStateTests` no change**; HUD is view state (`ScrubView.hudVisible`), not `AppState`.

- **Manual QA:**
  - In Single view, eye button shows `eye` when hidden → click → panel slides from left (240pt, ultraThinMaterial, scrollable rows, filename with extension, dimensions, size, camera/lens/ISO/aperture/shutter/focal/date/bias/WB), badge still top-trailing, image stays centered, pinch/drag still works on image area right of panel, drag on panel scrolls panel not image.
  - Click eye again (`eye.slash`) → panel hides with slide, image reclaims left edge.
  - Hidden by default on launch, after `New Session`, after `Single→Grid→Single` (verify `ScrubView` resets).
  - Arrow keys while HUD visible → content updates to new file's metadata (no stale).
  - Long filename → middle-truncated but tooltip shows full; whiteBalance `Auto`/`Manual` appears when EXIF present.

## Out of Scope

- Grid `MetadataHUD` (Single only).
- Editing metadata, copying values, or exporting XMP.
- Keyboard shortcut for HUD (toolbar only in v1).
- Resizable/draggable HUD width, collapse to icons, or remembering width across sessions.
- Histogram, focus peaking, or exposure overlay inside HUD.
- Persisting `hudVisible` across launches (`UserDefaults`).
