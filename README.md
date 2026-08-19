# QuickCull

A native macOS app for fast photo culling. It decodes RAWs from every major camera maker plus JPEG, PNG and HEIC into full-resolution previews, lets you scrub with the arrow keys, flag rejects with Z, and move them to Trash.

See `docs/superpowers/specs/` for the full design.

## Highlights

- **True RAW histogram, not a preview.** FastRawViewer-style linear counts taken before white balance and gamma. Each Bayer photosite counts once by color, so R is about 1/4 of pixels, G about 1/2, B about 1/4. Sensor maximum is recorded per camera (for example 4095 on CR2/NEF, 16383 on CR3). You see clipping percent, mean, and overall luminance in two 72pt log-y panels. X-Trans and Fuji super-CCD fall back to a rendered 255 histogram.
- **Decode first, scrub without waiting.** LibRaw demosaics every RAW at full resolution, ImageIO handles JPEG, PNG and HEIC, everything lands as a q75 JPEG in the local cache. The app finishes decoding before you can scrub, so the arrow keys never stall on a decode.
- **Memory stays flat.** The viewer keeps only the current image plus or minus 30 files, at most 61 JPEGs. The filmstrip throttles to the same window. Grid and strip share a viewport cache capped at 40 recent thumbnails. A 500-file shoot uses the same memory as a 50-file one.
- **Three ways to look.** Single shows one image fit to window. Split shows current and next side by side with an 8pt gap and no divider, and both panes share the same zoom and pan. Grid shows adaptive 160 to 200pt thumbnails, selection by file id so it survives filters, and batch flag with Z.
- **Metadata where you need it.** A 240pt sidebar slides in without covering the image. It shows file name and path, dimensions, file size, camera and lens, ISO, aperture, shutter, focal length, date taken, exposure bias and white balance, plus the histogram above the rows.
- **Titles under every thumb.** Each filmstrip and grid thumbnail shows the file name, single line, tail truncated, with the full name in a tooltip.
- **Flag, filter, commit.** Z toggles a red corner flag. Filter to All, Flagged or Unflagged. Commit moves only flagged files to macOS Trash per file, reports failures, keeps flags on files that failed, and lets you keep scrubbing. New Session wipes flags and the cache and returns to the importer.
- **Zoom and pan that track your fingers.** Pinch 1x to 4x, double-click to toggle fit and 2x, drag to pan when zoomed, two-finger scroll pans synchronously and only when the cursor is over that pane. No async tick, no dead zone, no animation lag. Pan is clamped so the image never leaves the viewport.

## How it works

1. **Select photos.** Multi-select in the file picker. Unsupported formats appear in a dismissible banner instead of quietly disappearing from the count.
2. **Decode all.** RAWs go through LibRaw at full resolution, standard formats through ImageIO with EXIF orientation baked in. The cache holds full-resolution q75 JPEGs. Scrubbing is blocked until every file is decoded.
3. **Scrub.** Step with the keyboard. The sliding window loads the current image first, then neighbors outward, and evicts the far edge.
4. **Commit.** Flag with `Z`, then move flagged files to Trash. Files that fail stay flagged so you can retry.

## Supported formats

Raw decoded with LibRaw: Canon CR2, CR3; Nikon NEF, NRW; Sony ARW, SRF, SR2; Fujifilm RAF; Olympus and OM System ORF; Panasonic RW2; Pentax PEF, DNG; Leica and Ricoh DNG; Hasselblad 3FR, FFF; Phase One IIQ; Sigma X3F; Samsung SRW; Kodak DCR, KDC; Epson ERF.

Standard formats decoded with ImageIO: JPEG (JPG, JPEG), PNG, HEIC and HEIF. Orientation is baked into pixels.

## Controls

| Key | Action |
| --- | --- |
| `←` / `→` | Previous and next photo |
| `↑` / `↓` | Jump back and forward 10 photos |
| `Z` | Toggle the reject flag, red corner triangle |

Click a filmstrip thumbnail to jump to that photo. In grid, click to select, Cmd-click to toggle, Shift-click for a range, double-click to jump to single and show that photo.

## Run

`./start.sh` builds a Release copy and launches it, quitting any running instance first. `./stop.sh` quits the app.

## Cache

Decoded photos are full-resolution q75 JPEGs in `~/Library/Application Support/QuickCull/cache`, keyed by file path, size and modification time. The cache is wiped on launch and best-effort on quit, so each session decodes from the originals.

## Build

Requires Xcode 16 or later on macOS 14 or later. The first build downloads and compiles LibRaw 0.22.1 into `Build/libraw/` automatically as a universal arm64 plus x86_64 dylib. A clean rebuild takes a few minutes.

    xcodebuild -project QuickCull.xcodeproj -scheme QuickCull build

## Test

Build the test bundle, then run it directly with `xcrun xctest`:

    xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore \
      -configuration Debug -destination 'platform=macOS' \
      -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing

    xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest

134 tests cover the decoder, cache, session, windows, key map, commit and the full import pipeline.

### Fixtures

`QuickCullCoreTests/Fixtures/raws/` holds pinned raw samples, one per brand, plus deliberately truncated files for error-path tests. Regenerate or restore them with:

    Scripts/fetch-fixtures.sh

It downloads from the public sample sources and checks each file against its pinned sha256.

## Licensing

QuickCull dynamically links LibRaw, LGPL-2.1, to decode raw files. The library is shipped unmodified as `libraw.dylib` in `QuickCull.app/Contents/Frameworks/` and you may replace it with your own build of the same version. See [`NOTICE`](NOTICE) for details.

## Out of scope for v1

- Undo of a Trash commit
- Persistent flags across sessions
