# QuickCull

A native macOS app for fast photo culling: decode raws from every major camera
manufacturer (plus JPEG, PNG, HEIC) to high-quality previews, scrub with the
arrow keys, flag rejects with Z, commit to Trash.

See `docs/superpowers/specs/` for the design.

## How it works

1. **Select photos.** Multi-select with the file picker. Unsupported formats
   are listed in a dismissible banner instead of vanishing from the count.
2. **Decode all.** Raws are demosaiced at full resolution with LibRaw; JPEG,
   PNG, and HEIC go through ImageIO. Everything lands in the local cache as a
   q75 JPEG. Decoding finishes before scrubbing starts, so the arrow keys
   never wait on a decode.
3. **Scrub.** Step through with the keyboard. Only a ±30-file window around
   the current photo stays in memory. Files that fail to decode are skipped
   and listed in the banner.
4. **Commit.** Flag rejects with `Z`, then commit to Trash. Every flagged
   file is moved to the macOS Trash; files that fail are kept, still flagged,
   so you can retry.

## Supported formats

Raw (decoded via LibRaw): Canon (CR2, CR3), Nikon (NEF, NRW), Sony (ARW, SRF,
SR2), Fujifilm (RAF), Olympus/OM System (ORF), Panasonic (RW2), Pentax (PEF,
DNG), Leica/Ricoh (DNG), Hasselblad (3FR, FFF), Phase One (IIQ), Sigma (X3F),
Samsung (SRW), Kodak (DCR, KDC), Epson (ERF).

Common formats (decoded via ImageIO, EXIF orientation baked in): JPEG
(JPG/JPEG), PNG, HEIC/HEIF.

## Controls

| Key            | Action                                      |
| -------------- | ------------------------------------------- |
| `←` / `→`      | Previous / next photo                       |
| `↑` / `↓`      | Jump back / forward 10 photos               |
| `Z`            | Toggle the reject flag (red corner triangle) |

Click a filmstrip thumbnail to jump straight to that photo.

## Run

`./start.sh` builds a Release copy and launches it (quitting any running
instance first). `./stop.sh` quits the app.

## Cache

Decoded photos are full-resolution q75 JPEGs in
`~/Library/Application Support/QuickCull/cache`, keyed by file path. The cache
is wiped on launch (and best-effort on quit), so every session decodes from
the originals.

## Build

Requires Xcode (16+) on macOS 14+. The first build downloads and compiles
LibRaw 0.22.1 into `Build/libraw/` automatically (universal arm64 + x86_64
dylib); a clean rebuild takes a few minutes.

    xcodebuild -project QuickCull.xcodeproj -scheme QuickCull build

## Test

Build the test bundle, then run it directly with `xcrun xctest`:

    xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore \
      -configuration Debug -destination 'platform=macOS' \
      -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing

    xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest

69 tests cover the decoder, cache, session, windows, key map, commit, and the
full import pipeline.

### Fixtures

`QuickCullCoreTests/Fixtures/raws/` holds pinned raw samples (one per brand,
plus deliberately truncated files for error-path tests). Regenerate or
restore them with:

    Scripts/fetch-fixtures.sh

It downloads from the public sample sources and checks every file against its
pinned sha256.

## Licensing

QuickCull dynamically links LibRaw (LGPL-2.1) to decode raw files. The
library is shipped unmodified and may be replaced with your own build; see
[`NOTICE`](NOTICE) for details.

## Out of scope for v1

- Zoom / pan inside the viewer
- Undo of a Trash commit
- Persistent flags across sessions
