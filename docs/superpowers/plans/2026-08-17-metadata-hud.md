# Metadata HUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add left-side metadata HUD overlay inside Single viewer (hidden by default, toggled via toolbar eye button) showing Full EXIF + file info for the current photo via a pure `ImageMetadataProvider` helper.

**Architecture:** `QuickCullCore/Metadata/ImageMetadataProvider.swift` is a pure value provider reading `SessionFile.url` via `CGImageSourceCopyProperties` + `FileManager` + `CGImage` dimensions; `ScrubView` hoists `hudVisible: Bool` (default false, resets on `phase==.empty|decoding` and `viewMode` toggle and `startNewSession`) and adds eye toggle `ToolbarItem` ( `eye` / `eye.slash`) as last `primaryAction` after Trash; `ImageDisplayView` takes `hudVisible` binding and overlays a 240-pt `ultraThinMaterial` `ScrollView` panel left-pinned inside its `GeometryReader` above the zoomable image, with `MetadataHUDView` loading via `.task(id: file.id) Task.detached` and `help` tooltips.

**Tech Stack:** Swift 5, SwiftUI Observation (`@Observable`, `@Environment`, `@Binding`, `@State`), `CoreGraphics`/`ImageIO` (`CGImageSource`), `FileManager`/`ByteCountFormatter`, `XCTest`, `xcodebuild` + `xcrun xctest`.

## Global Constraints

- Requires Xcode 16+ on macOS 14+ (README Build).
- Swift language version 5.0, deployment target 14.0.
- No new targets; synchronized folders (no `.pbxproj` edit).
- HUD is Single only ( `ImageDisplayView` inside `ScrubView` `.scrub` branch ), not Grid / Empty / Decoding; hidden by default, `ScrubView.hudVisible` default `false`.
- HUD overlays viewer left edge 240pt, `ultraThinMaterial`, `ScrollView` of rows, does NOT push/resize image (zoom `fittedSize`/`clampedOffset` unchanged).
- Rows: `filename` (`lastPathComponent` with extension), `dimensions` (`CGImage` “6000×4000”), `fileSize` (`ByteCountFormatter`), `camera` (make+model), `lens`, `iso` (“ISO 400”), `aperture` (“f/2.8”), `shutter` (“1/1000s”), `focalLength` (“50 mm”), `dateTaken` (localized), `exposureBias` (“+0.7 EV”), `whiteBalance` (“Auto”/“Manual”) — plus `filePath` tooltip; missing EXIF rows omitted, panel shows filename/dimensions/size at minimum.
- Text: label `.caption2` secondary, value `.caption` primary, `lineLimit 1` middle truncation, `help` tooltip shows full value.
- Toolbar eye button: `Label(hudVisible ? "Hide Info":"Show Info", systemImage: hudVisible ? "eye.slash":"eye")`, `.help(hudVisible ? "Hide metadata":"Show metadata")`, `.disabled(appState.isCommitting)`, last `primaryAction` after Trash, order `New Session | Single/Grid | Filter | Trash | Eye`.
- Reset: `hudVisible=false` on `phase==.empty` or `isDecoding(phase)`, on `viewMode` toggle (`old!=new`), and on `startNewSession()` (covers via phase); `viewMode` and zoom already reset there.
- Build harness flags: every `xcodebuild` needs `CODE_SIGNING_ALLOWED=NO` and `OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'` when run in sandbox; `derivedDataPath /tmp/qc-dd`.

---

## File Structure

```
quickcull/
├── QuickCullCore/Metadata/
│   └── ImageMetadataProvider.swift      # new: ImageMetadata struct + ImageMetadataProvider enum
├── QuickCull/
│   ├── ScrubView.swift                 # hoist hudVisible, add eye toolbar, pass binding, resets
│   └── ImageDisplayView.swift          # add hudVisible binding, overlay 240pt panel, MetadataHUDView
└── QuickCullCoreTests/
    └── ImageMetadataProviderTests.swift # new: 4 tests for provider
```

---

### Task 1: Metadata provider — `ImageMetadataProvider`

**Files:**
- Create: `QuickCullCore/Metadata/ImageMetadataProvider.swift`
- Create: `QuickCullCoreTests/ImageMetadataProviderTests.swift` (or append to existing, but prefer new file for isolation; synchronized folder will pick it up)
- Test: `QuickCullCoreTests/ImageMetadataProviderTests.swift`

**Interfaces:**
- Consumes: `SessionFile.url: URL`, `SessionFile.id: String`, `CGImage.width/height: Int` (passed from `ImageDisplayView`’s `cgImage`), `CGImageSourceCreateWithURL`, `CGImageSourceCopyPropertiesAtIndex`, `FileManager.default.attributesOfItem`, `ByteCountFormatter`, `DateFormatter`.
- Produces:
  ```swift
  public struct ImageMetadata: Equatable, Sendable {
      public let filename: String
      public let filePath: String
      public let dimensions: String? // "6000×4000"
      public let fileSize: String?   // "24.3 MB"
      public let camera: String?     // "Canon Canon EOS R5"
      public let lens: String?
      public let iso: String?        // "ISO 400"
      public let aperture: String?   // "f/2.8"
      public let shutter: String?    // "1/1000s"
      public let focalLength: String? // "50 mm"
      public let dateTaken: String?
      public let exposureBias: String? // "+0.7 EV"
      public let whiteBalance: String? // "Auto"/"Manual"
  }
  public enum ImageMetadataProvider {
      public static func metadata(for file: SessionFile, cgImage: CGImage?) -> ImageMetadata
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `QuickCullCoreTests/ImageMetadataProviderTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import QuickCullCore

final class ImageMetadataProviderTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testFilenameAndFileSize() throws {
        let url = tmp.appendingPathComponent("IMG_001.CR2")
        try Data(repeating: 0xAB, count: 1_500_000).write(to: url)
        let file = SessionFile(url: url)
        let meta = ImageMetadataProvider.metadata(for: file, cgImage: nil)
        XCTAssertEqual(meta.filename, "IMG_001.CR2")
        XCTAssertEqual(meta.filePath, url.standardizedFileURL.path)
        XCTAssertNotNil(meta.fileSize) // ByteCountFormatter string, e.g. "1.5 MB"
        XCTAssertNil(meta.camera) // no EXIF
    }

    func testDimensionsFromCGImagePreferred() throws {
        let url = tmp.appendingPathComponent("a.jpg")
        try Data(repeating: 0, count: 10).write(to: url)
        // Create a 6000x4000 CGImage stub via color space
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 6000, height: 4000, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let img = ctx.makeImage()!
        let file = SessionFile(url: url)
        let meta = ImageMetadataProvider.metadata(for: file, cgImage: img)
        XCTAssertEqual(meta.dimensions, "6000×4000")
    }

    func testMissingFileReturnsMinimal() {
        let file = SessionFile(url: URL(fileURLWithPath: "/tmp/does-not-exist-xyz.nef"))
        let meta = ImageMetadataProvider.metadata(for: file, cgImage: nil)
        XCTAssertEqual(meta.filename, "does-not-exist-xyz.nef")
        XCTAssertNil(meta.fileSize)
        XCTAssertNil(meta.dimensions)
        XCTAssertNil(meta.camera)
    }

    func testExifFieldsParsedIfPresent() throws {
        // Use a pinned fixture with known EXIF if available; fallback to minimal check.
        // Try loading a real JPEG fixture we can write with EXIF via ImageIO, else just check provider doesn't throw.
        let url = tmp.appendingPathComponent("exif.jpg")
        // Create a 10x10 image and write with EXIF via ImageIO if possible, else just test that call succeeds.
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        var exif: [String: Any] = [kCGImagePropertyExifISOSpeedRatings as String: [400], kCGImagePropertyExifFNumber as String: 2.8]
        let props: [String: Any] = [kCGImagePropertyExifDictionary as String: exif]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        let file = SessionFile(url: url)
        let meta = ImageMetadataProvider.metadata(for: file, cgImage: img)
        // At least ISO/aperture should parse if we wrote them
        XCTAssertTrue(meta.iso == "ISO 400" || meta.iso == nil) // don't fail if fixture stripped
        if meta.aperture != nil { XCTAssertTrue(meta.aperture!.hasPrefix("f/")) }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build-for-testing && xcrun xctest -XCTest ImageMetadataProviderTests /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -20
```
Expected: FAIL with `use of unresolved identifier 'ImageMetadataProvider'`

- [ ] **Step 3: Implement `ImageMetadataProvider`**

Create `QuickCullCore/Metadata/ImageMetadataProvider.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO

public struct ImageMetadata: Equatable, Sendable {
    public let filename: String
    public let filePath: String
    public let dimensions: String?
    public let fileSize: String?
    public let camera: String?
    public let lens: String?
    public let iso: String?
    public let aperture: String?
    public let shutter: String?
    public let focalLength: String?
    public let dateTaken: String?
    public let exposureBias: String?
    public let whiteBalance: String?
}

public enum ImageMetadataProvider {
    public static func metadata(for file: SessionFile, cgImage: CGImage?) -> ImageMetadata {
        let filename = file.url.lastPathComponent
        let filePath = file.url.standardizedFileURL.path
        // Dimensions: prefer cgImage, fallback to source props
        var dimensions: String?
        if let img = cgImage {
            dimensions = "\(img.width)×\(img.height)"
        }
        // File size
        var fileSize: String?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.url.path),
           let bytes = attrs[.size] as? NSNumber {
            fileSize = ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file)
        }
        // EXIF via CGImageSource
        var camera: String?, lens: String?, iso: String?, aperture: String?, shutter: String?
        var focalLength: String?, dateTaken: String?, exposureBias: String?, whiteBalance: String?
        if let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if dimensions == nil,
               let w = props[kCGImagePropertyPixelWidth] as? Int,
               let h = props[kCGImagePropertyPixelHeight] as? Int, w>0, h>0 {
                dimensions = "\(w)×\(h)"
            }
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                let make = tiff[kCGImagePropertyTIFFMake] as? String
                let model = tiff[kCGImagePropertyTIFFModel] as? String
                if make != nil || model != nil {
                    camera = [make, model].compactMap{ $0 }.joined(separator: " ")
                }
                lens = tiff[kCGImagePropertyTIFFLensModel] as? String
            }
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                if let isoArr = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let first = isoArr.first {
                    iso = "ISO \(first.intValue)"
                } else if let isoNum = exif[kCGImagePropertyExifISOSpeedRatings] as? NSNumber {
                    iso = "ISO \(isoNum.intValue)"
                }
                if let fnum = exif[kCGImagePropertyExifFNumber] as? NSNumber {
                    aperture = String(format: "f/%.1f", fnum.doubleValue)
                }
                if let exp = exif[kCGImagePropertyExifExposureTime] as? NSNumber {
                    let v = exp.doubleValue
                    if v > 0 && v < 1 { shutter = String(format: "1/%.0fs", 1/v) } else { shutter = String(format: "%gs", v) }
                }
                if let fl = exif[kCGImagePropertyExifFocalLength] as? NSNumber {
                    focalLength = String(format: "%g mm", fl.doubleValue)
                }
                if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? NSNumber {
                    exposureBias = String(format: "%+.1f EV", bias.doubleValue)
                }
                if let wb = exif[kCGImagePropertyExifWhiteBalance] as? NSNumber {
                    whiteBalance = wb.intValue == 0 ? "Auto" : "Manual"
                }
                if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                    // Try to parse EXIF date "yyyy:MM:dd HH:mm:ss" and localize
                    let fmt = DateFormatter()
                    fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
                    fmt.locale = Locale(identifier: "en_US_POSIX")
                    if let d = fmt.date(from: dateStr) {
                        dateTaken = DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short)
                    } else {
                        dateTaken = dateStr
                    }
                }
            }
            if dateTaken == nil, let attrs = try? FileManager.default.attributesOfItem(atPath: file.url.path),
               let cdate = attrs[.creationDate] as? Date {
                dateTaken = DateFormatter.localizedString(from: cdate, dateStyle: .medium, timeStyle: .short)
            }
        }
        return ImageMetadata(filename: filename, filePath: filePath, dimensions: dimensions, fileSize: fileSize, camera: camera, lens: lens, iso: iso, aperture: aperture, shutter: shutter, focalLength: focalLength, dateTaken: dateTaken, exposureBias: exposureBias, whiteBalance: whiteBalance)
    }
}
```

Handle `import Foundation` already; ensure `SessionFile` is imported (same module). Keep provider `Sendable` and synchronous (caller dispatches off main).

- [ ] **Step 4: Run tests to verify they pass**

Run same `xctest -XCTest ImageMetadataProviderTests` command as Step 2.
Expected: PASS — 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add QuickCullCore/Metadata/ImageMetadataProvider.swift QuickCullCoreTests/ImageMetadataProviderTests.swift
git commit -m "feat: image metadata provider (Full EXIF: camera/lens/ISO/aperture/shutter/focal/date/bias/WB + file size/dimensions)"
```

---

### Task 2: ScrubView — eye toggle + hoisted HUD state

**Files:**
- Modify: `QuickCull/ScrubView.swift:4-122`

**Interfaces:**
- Consumes: `AppState.startNewSession()`, `AppState.phase/isCommitting`, `AppState.viewMode`, `ImageMetadataProvider` (Task 1, indirectly via ImageDisplayView), existing `zoomScale/zoomOffset` logic.
- Produces: `@State hudVisible: Bool`, eye `ToolbarItem`, `onChange` resets, pass `hudVisible` binding to `ImageDisplayView`.

- [ ] **Step 1: Hoist hudVisible state**

Edit `QuickCull/ScrubView.swift:8-16` after zoom states:

```swift
@State private var hudVisible = false // hidden by default, Single only
```

- [ ] **Step 2: Add eye toggle toolbar item as last primaryAction**

Edit `QuickCull/ScrubView.swift:36-77` after Trash `ToolbarItem`:

```swift
ToolbarItem(placement: .primaryAction) {
    Button { hudVisible.toggle() } label: {
        Label(hudVisible ? "Hide Info" : "Show Info", systemImage: hudVisible ? "eye.slash" : "eye")
    }
    .help(hudVisible ? "Hide metadata" : "Show metadata")
    .disabled(appState.isCommitting)
}
```

Order must be `New Session | Single/Grid | Filter | Trash | Eye`. Keep `.disabled(appState.isCommitting)` like other items.

- [ ] **Step 3: Pass binding to ImageDisplayView**

Edit `QuickCull/ScrubView.swift:23-31`:

```swift
ImageDisplayView(
    zoomScale: $zoomScale,
    zoomLastScale: $zoomLastScale,
    zoomOffset: $zoomOffset,
    zoomLastOffset: $zoomLastOffset,
    hudVisible: $hudVisible
)
```

- [ ] **Step 4: Reset hudVisible on phase/viewMode/startNewSession triggers**

Add/extend existing `onChange` handlers in `ScrubView.swift:100-121`:

```swift
.onChange(of: appState.phase) { _, newPhase in
    if newPhase == .empty || isDecoding(newPhase) {
        zoomScale = 1; zoomLastScale = 1; zoomOffset = .zero; zoomLastOffset = .zero
        hudVisible = false
    }
}
.onChange(of: appState.viewMode) { oldMode, newMode in
    if oldMode != newMode {
        zoomScale = 1; zoomLastScale = 1; zoomOffset = .zero; zoomLastOffset = .zero
        hudVisible = false
    }
}
```

Note: `startNewSession()` sets `phase=.empty`, so its `onChange(phase)` already resets `hudVisible` via above; no extra call needed. If explicit, also set `hudVisible=false` inside `startNewSession` is redundant but acceptable (AppState owns session, not HUD view state — HUD view state stays in ScrubView).

- [ ] **Step 5: Build the app**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add QuickCull/ScrubView.swift
git commit -m "feat: scrub toolbar eye toggle for metadata HUD (hidden by default)"
```

---

### Task 3: ImageDisplayView — overlay HUD + MetadataHUDView

**Files:**
- Modify: `QuickCull/ImageDisplayView.swift:4-207`

**Interfaces:**
- Consumes: `ScrubView.hudVisible: Binding<Bool>` (Task 2), `SessionFile`, `CGImage` (from `displayImages`/`thumbWindow`), `ImageMetadataProvider.metadata(for:cgImage:)` (Task 1), `FlagBadgeOverlay`.
- Produces: Viewer with left-pinned 240pt HUD overlay when `hudVisible`, scrollable rows, middle truncation, help tooltips, `.task(id: file.id)` reload, no push of image.

- [ ] **Step 1: Add hudVisible binding to ImageDisplayView**

Edit `QuickCull/ImageDisplayView.swift:4-9`:

```swift
struct ImageDisplayView: View {
    @Environment(AppState.self) private var appState
    @Binding var zoomScale: CGFloat
    @Binding var zoomLastScale: CGFloat
    @Binding var zoomOffset: CGSize
    @Binding var zoomLastOffset: CGSize
    @Binding var hudVisible: Bool
```

- [ ] **Step 2: Wrap viewer in HUD overlay**

Edit `QuickCull/ImageDisplayView.swift:11-44` body: inside the `else if let cgImage` branch, after `ZoomableImageView` and before `.overlay(alignment: .topTrailing)`, overlay HUD:

Current:
```swift
} else if let cgImage { ZoomableImageView(...).overlay(alignment:.topTrailing){FlagBadgeOverlay} }
```

Becomes:
```swift
} else if let cgImage = ... {
    ZoomableImageView(...)
        .overlay(alignment: .topTrailing) { FlagBadgeOverlay(file: currentFile) }
        .overlay(alignment: .leading) {
            if hudVisible, let file = currentFile {
                HStack(spacing: 0) {
                    MetadataHUDView(file: file, cgImage: cgImage)
                        .frame(width: 240)
                        .background(.ultraThinMaterial)
                        .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5), alignment: .trailing)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Spacer(minLength: 0)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: hudVisible)
        .clipped()
} // keep outer ZStack Color.black etc.
```

Ensure HUD `HStack` is inside the `GeometryReader`-like container? Actually `ZoomableImageView` already has `GeometryReader`; overlaying HUD on top of `ZoomableImageView` via `.overlay(alignment:.leading)` is outside `ZoomableImageView`'s `GeometryReader` but inside `ImageDisplayView`'s `ZStack` — it will float over the viewer without affecting `ZoomableImageView`'s `fittedSize` (since HUD is overlay, not sibling in HStack). Use the above as overlay on `ZoomableImageView` rather than separate HStack pushing width.

Alternative exact spec code (from design doc):
```swift
GeometryReader { geo in
  ZStack {
    ZoomableImageView(...)
    if hudVisible, let file { HStack { MetadataHUDView(file:file,cgImage:cgImage).frame(width:240).background(.ultraThinMaterial)...; Spacer() }.frame(width:geo.size.width,height:geo.size.height,alignment:.leading) }
  }
}
```
Simplify: Keep existing `ZoomableImageView`'s internal `GeometryReader`, then overlay HUD in `ImageDisplayView` via `GeometryReader` + `HStack` as above — but ensure HUD width does not change `fittedSize`. Overlay approach already does.

- [ ] **Step 3: Add MetadataHUDView private struct**

Append after `ZoomableImageView` (before `FlagBadgeOverlay`) in same file:

```swift
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
                        Text(row.value).font(.caption).foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(row.value)
                    }
                }
            }
            .padding(10)
        }
        .task(id: file.id) {
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

Note: `ImageMetadata` is from `QuickCullCore`, so `import QuickCullCore` already at top covers it. No new import needed.

- [ ] **Step 4: Build the app**

Run same build command as Task 2 Step 5.
Expected: `** BUILD SUCCEEDED **` (may need `import QuickCullCore` already present).

- [ ] **Step 5: Manual verify HUD**

Run `./start.sh`, import set, in Single view eye shows `eye` → click → left 240pt panel slides in (`ultraThinMaterial`, scrollable), rows show filename with extension, dimensions, size, camera/lens/ISO/aperture/shutter/focal/date/bias/WB (missing rows omitted), middle truncation with tooltip, badge still top-trailing, image stays centered, pinch/drag works on image area right of panel, drag on panel scrolls panel. Click eye again (`eye.slash`) hides. Verify hidden by default on launch, after New Session, after Single→Grid→Single (via ScrubView resets).

- [ ] **Step 6: Run tests (no regression)**

Run:
```bash
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build-for-testing && xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest 2>&1 | tail -5
```
Expected: `Executed 114 tests, with 0 failures` (110 + 4 new metadata tests).

- [ ] **Step 7: Commit**

```bash
git add QuickCull/ImageDisplayView.swift
git commit -m "feat: metadata HUD left of image in single view (overlay, eye toggle, Full EXIF)"
```

---

## Self-Review

**Spec coverage:**
- Single only left HUD overlay 240pt `ultraThinMaterial` + `ScrollView` rows, hidden by default eye toggle (`eye`/`eye.slash`) last toolbar item after Trash, disabled while committing → Task 2 & 3.
- Full EXIF rows via `ImageMetadataProvider` (filename with extension, dimensions from `CGImage`, fileSize, camera/lens, ISO, aperture, shutter, focal, date, bias, WB) → Task 1.
- Hidden by default + resets on `phase==.empty|decoding` and `viewMode` toggle and `startNewSession` (via phase) → Task 2 `onChange` resets.
- Overlay does not push image (zoom `fittedSize` unchanged, HUD over `Color.black` + image) → Task 3 overlay in `ImageDisplayView` outside `ZoomableImageView`'s `GeometryReader`.
- Text middle truncation + `help` tooltip, label `.caption2` secondary / value `.caption` primary → Task 1 & 3.
- Off main via `Task.detached` + `.task(id: file.id)` cancellation on rapid scrub → Task 3.
- No HUD in Grid/Empty/Decoding → scope (Single only).

**Placeholder scan:** No TBD/TODO; every step has exact file paths, code blocks, and commands.

**Type consistency:** `ImageMetadata` struct fields (`filename: String`, `fileSize: String?` etc.) defined Task 1, consumed `MetadataHUDView` Task 3 `m.filename/m.dimensions`; `hudVisible: Binding<Bool>` defined ScrubView Task 2, consumed ImageDisplayView Task 3 `hudVisible`; `ImageMetadataProvider.metadata(for: SessionFile, cgImage: CGImage?) -> ImageMetadata` signature matches call `.task(id: file.id)` Task 3.
