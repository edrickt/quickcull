# QuickCull

A native macOS app for fast photo culling. It decodes RAWs from every major camera maker plus JPEG, PNG and HEIC into full-resolution previews, lets you scrub with the arrow keys, flag with three colors, filter by color, and move the flagged ones to Trash or another folder.

See `docs/superpowers/specs/` for the full design.

## Highlights

- **True RAW histogram, not a preview.** FastRawViewer-style linear counts taken before white balance and gamma. Each Bayer photosite counts once by color, so R is about 1/4 of pixels, G about 1/2, B about 1/4. Sensor maximum is recorded per camera (for example 4095 on CR2/NEF, 16383 on CR3). You see clipping percent, mean, and overall luminance in two 72pt log-y panels. X-Trans and Fuji super-CCD fall back to a rendered 255 histogram (computed from a 1024px sample, not the full-resolution bitmap).
- **Decode first, scrub without waiting.** LibRaw demosaics every RAW at full resolution, ImageIO handles JPEG, PNG and HEIC, everything lands as a q75 JPEG in the local cache. The app finishes decoding before you can scrub, so the arrow keys never stall on a decode.
- **Memory stays flat.** The viewer decodes the current image plus −5/+10 at full resolution — so the Space loupe is true source-pixel 1:1 at any image size and scrubbing within the tier is instant — while the rest of the −10/+20 window pre-loads at half size (DCT-subsampled, ~4× less memory) and upgrades to full-res the moment you land on it. Both the viewer window and the thumbnails are bounded by a fixed viewport, never by shoot size: the strip keeps at most 61 × 320px thumbnails, and the grid keeps at most 61 as well, the most recent cells you scrolled to. Where the loupe lands on a half-size placeholder it says `preview` instead of claiming 100%. Thumbnail and display decodes are throttled, and a superseded decode is cancelled, so a fast scrub or a grid fill can never fire hundreds at once. 16 full-res + 15 half-size 20MP images ≈ 1.2GB (fits 8GB machines for typical shoots; ~2.3GB at 45MP), tunable with `defaults write com.quickcull displayFullResBehind N` and `displayFullResAhead N` (clamped to the window extent).
- **Three ways to look.** Single shows one image fit to window. Split shows current and next side by side with an 8pt gap and no divider, and both panes share the same zoom and pan. Grid shows adaptive 160 to 200pt thumbnails, selection by file id so it survives filters, and batch flag with Z/X/C.
- **Metadata where you need it.** A 240pt sidebar slides in without covering the image. It shows file name and path, dimensions, file size, camera and lens, ISO, aperture, shutter, focal length, date taken, exposure bias and white balance, plus the histogram above the rows.
- **Titles under every thumb.** Each filmstrip and grid thumbnail shows the file name, single line, tail truncated, with the full name in a tooltip.
- **Three colors, not one flag.** `Z` is red, `X` is yellow, `C` is green. Each photo holds at most one color; hit the same key to clear it, hit a different key to replace it. The badge is a corner triangle tinted to match. Filter to All, R, Y, G, or Unflagged with live counts. Trash and Move are dropdown menus with per-color choices (R, Y, G, All Flagged) that disable when that color has nothing flagged or while a commit is running. Move picks a folder each time with a system picker, moves flat, and auto-renames to `name 1.ext` when the destination exists. Grid batch works too: select a few thumbs and `Z` turns them all red at once.
- **Zoom and pan that track your fingers.** Pinch 1x to 4x, double-click to toggle fit and 2x, drag to pan when zoomed, two-finger scroll pans synchronously and only when the cursor is over that pane. No async tick, no dead zone, no animation lag. Pan is clamped so the image never leaves the viewport.

## How it works

1. **Select photos.** Multi-select in the file picker. Unsupported formats appear in a dismissible banner instead of quietly disappearing from the count.
2. **Decode all.** RAWs go through LibRaw at full resolution, standard formats through ImageIO with EXIF orientation baked in. The cache holds full-resolution q75 JPEGs. Scrubbing is blocked until every file is decoded.
3. **Scrub.** Step with the keyboard. The current image decodes at full resolution first (the −5/+10 tier pre-loads full-res; the outer window ring pre-loads half-size and upgrades the moment you land on it); hold `Space` at fit for the 100% loupe — genuine source-pixel 1:1 at any image size.
4. **Flag and commit.** Tap `Z`/`X`/`C` to flag red/yellow/green, filter to `R`/`Y`/`G`/`Unflagged` if you want to review just that color, then pick Trash or Move from its dropdown and choose a color or All Flagged. Files that fail stay flagged so you can retry. `File > New Session` (⇧⌘N) wipes flags and the cache and returns to the importer.

## Supported formats

Raw decoded with LibRaw: Canon CR2, CR3; Nikon NEF, NRW; Sony ARW, SRF, SR2; Fujifilm RAF; Olympus and OM System ORF; Panasonic RW2; Pentax PEF, DNG; Leica and Ricoh DNG; Hasselblad 3FR, FFF; Phase One IIQ; Sigma X3F; Samsung SRW; Kodak DCR, KDC; Epson ERF.

Standard formats decoded with ImageIO: JPEG (JPG, JPEG), PNG, HEIC and HEIF. Orientation is baked into pixels.

## Controls

| Key | Action |
| --- | --- |
| `←` / `→` | Previous and next photo |
| `↑` / `↓` | Jump back and forward 10 photos |
| `Z` | Toggle red flag, red corner triangle; same press again clears it |
| `X` | Toggle yellow flag; replaces red or green if one is set |
| `C` | Toggle green flag; replaces red or yellow if one is set |
| `Space` (hold) | 100% loupe at fit: a 280pt lens of true 1:1 source pixels that follows the cursor |

Flags are exclusive: a photo can be red, yellow, green, or unflagged, never two at once. In grid, with a selection, `Z`/`X`/`C` apply to every selected id and the selection clears after.

Filter bar has five segments: `All | R (n) | Y (n) | G (n) | Unflagged (n)` with live counts. When a filter matches nothing you get an empty placeholder, not a fallback. Toggling a flag under a non-All filter drops that photo out of view; if the filter empties it falls back to All.

Commit controls are two dropdowns:

- **Move Flagged to Trash** → `Trash R (n)`, `Trash Y (n)`, `Trash G (n)`, `Trash All Flagged (n)`. Each runs a per-file trash to macOS Trash and reports failures. Failed files keep their color.
- **Move Flagged** → `Move R (n)`, `Move Y (n)`, `Move G (n)`, `Move All Flagged (n)`. Opens a folder picker (you can create a folder there), then moves flat with auto-rename on collision. Same per-file success handling as Trash.

Both menus disable their items when that bucket is empty and disable entirely while a move or trash is in flight. View, filter, and flag input block during that time too.

Click a filmstrip thumbnail to jump to that photo. In grid, click to select, Cmd-click to toggle, Shift-click for a range, double-click to jump to single and show that photo.

## Run

`./start.sh` builds a Release copy and launches it, quitting any running instance first. `./stop.sh` quits the app.

To install it like a regular Mac app (so you can double-click it from Finder, Spotlight, or the Dock):

    ./Scripts/install.sh              # builds Release and installs to /Applications/QuickCull.app (needs admin)
    ./Scripts/install.sh --user       # installs to ~/Applications/QuickCull.app
    ./Scripts/install.sh --no-build   # reinstall the last build without rebuilding

The app is ad-hoc signed for local use, so on first launch Finder may warn about an unverified developer — right-click → Open → Open once, then it opens normally.

## Cache

Decoded photos are full-resolution q75 JPEGs in `~/Library/Application Support/QuickCull/cache`, keyed by file path, size and modification time. The cache is wiped on launch and best-effort on quit, so each session decodes from the originals.

## Build

Requires Xcode 16 or later on macOS 14 or later. The first build downloads and compiles LibRaw 0.22.1 into `Build/libraw/` automatically as a universal arm64 plus x86_64 dylib. A clean rebuild takes a few minutes.

    xcodebuild -project QuickCull.xcodeproj -scheme QuickCull build
    # or: ./Scripts/install.sh  — builds and copies to /Applications/QuickCull.app

## Test

Build the test bundle, then run it directly with `xcrun xctest`:

    xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore \
      -configuration Debug -destination 'platform=macOS' \
      -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing

    xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest

227 tests cover the decoder, cache, session, windows, key map, commit, move, and the full import pipeline.

### Fixtures

`QuickCullCoreTests/Fixtures/raws/` holds pinned raw samples, one per brand, plus deliberately truncated files for error-path tests. Regenerate or restore them with:

    Scripts/fetch-fixtures.sh

It downloads from the public sample sources and checks each file against its pinned sha256.

## Licensing

QuickCull dynamically links LibRaw, LGPL-2.1, to decode raw files. The library is shipped unmodified as `libraw.dylib` in `QuickCull.app/Contents/Frameworks/` and you may replace it with your own build of the same version. See [`NOTICE`](NOTICE) for details.

## Out of scope for v1

- Undo of a Trash or Move commit
- Persistent flags across sessions
