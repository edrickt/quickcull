# QuickCull

Fast photo culling for macOS — scrub RAWs with the arrow keys, flag keepers in three colors, trash or move the rest.

[![Release](https://img.shields.io/github/v/release/edrickt/quickcull)](https://github.com/edrickt/quickcull/releases/latest) ![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![License: MIT](https://img.shields.io/badge/License-MIT-green)

<!-- Screenshot: docs/assets/screenshot-main.png — capture pending -->

- [Download](#download) · [How it works](#how-it-works) · [Highlights](#highlights) · [Supported formats](#supported-formats) · [Controls](#controls) · [For developers](#for-developers) · [Licensing](#licensing) · [Out of scope for v1](#out-of-scope-for-v1)

## Download

**Requirements:** macOS 14 (Sonoma) or later, Apple silicon or Intel. Nothing else to install — LibRaw ships inside the app.

Take the `QuickCull-…-macOS-universal.zip` asset from [Releases](https://github.com/edrickt/quickcull/releases/latest), unzip it, and drag `QuickCull.app` into `/Applications`.

QuickCull is ad-hoc signed, not notarized, so macOS refuses the first launch as an unverified developer. Approve it once:

1. Finder → Applications → right-click `QuickCull` → **Open** → **Open**.
2. Every launch after that is a normal double-click.

Or clear the download flag from Terminal instead of using the right-click path:

    xattr -dr com.apple.quarantine /Applications/QuickCull.app

**From source.** With Xcode 16 or later:

    git clone https://github.com/edrickt/quickcull.git
    cd quickcull
    ./Scripts/install.sh              # builds Release and installs to /Applications (needs admin)
    ./Scripts/install.sh --user       # installs to ~/Applications instead
    ./Scripts/install.sh --no-build   # reinstalls the last build without rebuilding

The build compiles LibRaw 0.22.1 into `Build/libraw/` the first time, which takes a few minutes.

## How it works

1. **Select photos.** Multi-select in the file picker. Unsupported formats appear in a dismissible banner instead of quietly disappearing from the count.
2. **Decode all.** RAWs go through LibRaw at full resolution, standard formats through ImageIO with EXIF orientation baked in. The cache holds full-resolution q75 JPEGs. Scrubbing is blocked until every file is decoded.
3. **Scrub.** Step with the keyboard; hold `Space` at fit for the 100% loupe — genuine source-pixel 1:1 at any image size.
4. **Flag and commit.** Tap `Z`/`X`/`C` to flag red/yellow/green, filter if you want to review just one color, then pick Trash or Move from its dropdown and choose a color or All Flagged. Files that fail stay flagged so you can retry. `File > New Session` (⇧⌘N) wipes flags and the cache and returns to the importer.

## Highlights

- **True RAW histogram.** Linear counts before white balance and gamma, with clipping percent, mean, and luminance.
- **Decode first, scrub without waiting.** Every file decoded up front at full resolution, so the arrow keys never stall.
- **Stays responsive on big shoots.** Pre-loads around the current photo and shows true 1:1 pixels in the `Space` loupe.
- **Three ways to look.** Single, side-by-side split with shared zoom and pan, and a grid with batch flagging.
- **Metadata where you need it.** Sliding sidebar with camera, lens, exposure, plus file name under every thumbnail.
- **Three colors, not one flag.** `Z` red, `X` yellow, `C` green — exclusive, same key clears; filter by color, then Trash or Move per color.

## Supported formats

Raw decoded with LibRaw: Canon CR2, CR3; Nikon NEF, NRW; Sony ARW, SRF, SR2; Fujifilm RAF; Olympus and OM System ORF; Panasonic RW2; Pentax PEF, DNG; Leica and Ricoh DNG; Hasselblad 3FR, FFF; Phase One IIQ; Sigma X3F; Samsung SRW; Kodak DCR, KDC; Epson ERF.

Standard formats decoded with ImageIO: JPEG (JPG, JPEG), PNG, HEIC and HEIF. Orientation is baked into pixels.

## Controls

| Key | Action |
| --- | --- |
| `←` / `→` | Previous and next photo |
| `↑` / `↓` | Jump back and forward 10 photos |
| `Z` | Toggle red flag; same press clears |
| `X` | Toggle yellow flag; replaces red or green |
| `C` | Toggle green flag; replaces red or yellow |
| `Space` (hold) | 100% loupe at fit: true 1:1 source pixels under the cursor |

Flags are exclusive — red, yellow, green, or unflagged. In grid, `Z`/`X`/`C` apply to the selection; with no selection they do nothing. Filter with `All` + `R`/`Y`/`G`/Unflagged segments, then Trash or Move per color (or All Flagged) from the two dropdowns. Failed files keep their color so you can retry. Click a filmstrip thumb to jump; in grid, click/Cmd-click/Shift-click to select, double-click to open in single.

## For developers

### Run

For the development loop, from a checkout:

    Scripts/start.sh   # builds Release and launches, quitting any running instance first
    Scripts/stop.sh    # quits the app

To keep a copy in Applications, use [Download](#download) instead.

### Cache

Decoded photos are full-resolution q75 JPEGs in `~/Library/Application Support/QuickCull/cache`, keyed by file path, size and modification time. The cache is wiped on launch and on quit (a forced quit is covered by the next launch), so each session decodes from the originals.

### Repository layout

    QuickCull/          app target: SwiftUI/AppKit views only
    QuickCullCore/      all logic (App, Commit, Decoding, Engine, Keys,
                        Metadata, Models, Session, Storage, Window)
    QuickCullCoreTests/ unit tests mirroring QuickCullCore, plus
                        Support/ helpers and Fixtures/ raw samples
    Assets/             Icon Composer package (AppIcon.icon)
    Scripts/            build, install, fixtures, benchmarks (see Scripts/README.md)
    docs/               index + assets; archive/ holds executed plans, specs, audits

### Build

Requires Xcode 16 or later on macOS 14 or later. The first build downloads and compiles LibRaw 0.22.1 into `Build/libraw/` automatically as a universal arm64 plus x86_64 dylib. A clean rebuild takes a few minutes.

    xcodebuild -project QuickCull.xcodeproj -scheme QuickCull build
    # or: ./Scripts/install.sh  — builds and copies to /Applications/QuickCull.app

### Test

Build the test bundle, then run it directly with `xcrun xctest`:

    xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore \
      -configuration Debug -destination 'platform=macOS' \
      -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing

    xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest

264 tests cover the decoder, cache, session, windows, key map, commit, move, and the full import pipeline.

#### Fixtures

`QuickCullCoreTests/Fixtures/raws/` holds pinned raw samples covering the major brands (Canon, Nikon, Sony, Fujifilm, Olympus, Panasonic, Pentax), plus deliberately truncated files for error-path tests. Regenerate or restore them with:

    Scripts/fetch-fixtures.sh

It downloads from the public sample sources and checks each file against its pinned sha256.

## Licensing

QuickCull is MIT-licensed. See [`LICENSE`](LICENSE).

QuickCull dynamically links LibRaw, LGPL-2.1, to decode raw files. The library is shipped unmodified as `libraw.dylib` inside `QuickCull.app/Contents/Frameworks/QuickCullCore.framework/Versions/A/Frameworks/`, and you may replace it with your own build of the same version. See [`NOTICE`](NOTICE) for third-party details.

## Out of scope for v1

- Undo of a Trash or Move commit
- Persistent flags across sessions
