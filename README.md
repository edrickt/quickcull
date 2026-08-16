# QuickCull

Native macOS app for fast raw-image culling. Culls raw files from all major
camera manufacturers: decode everything to high-quality JPEG, scrub with the
arrow keys, flag rejects with Z, commit to Trash.

See `docs/superpowers/specs/` for the design.

## How it works (v1 flow)

1. **Select raws** — select raw files via the file picker (multi-select).
   Supported extensions are recognized; unsupported formats are reported and
   skipped.
2. **Decode all** — every raw is demosaiced in full resolution with LibRaw and
   written to the local cache as a q75 JPEG. Decoding runs before scrubbing
   starts, so arrow-key navigation never waits on disk.
3. **Scrub** — step through the culled set with the keyboard. Only a ±30-file
   window around the current position is held in memory at once. Files that
   fail to decode are skipped and surfaced in a dismissible banner.
4. **Commit** — flag rejects with `Z`, then commit to Trash. Every flagged
   file is moved to the macOS Trash; failures are reported per file, and the
   app stays in the session so you can retry.

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
| `Z`            | Toggle the reject flag (badge shown)        |

Click a filmstrip thumbnail to jump straight to that photo.

## Cache

Decoded images are stored as full-resolution q75 JPEGs in
`~/Library/Application Support/QuickCull/cache`, keyed by file path. The cache
is wiped on launch (and best-effort on quit), so each session re-decodes from
the originals and never accumulates stale data.

## Build

Requires Xcode (16+) on macOS 14+. The first build downloads and compiles
LibRaw 0.22.1 into `Build/libraw/` automatically (universal arm64 + x86_64
dylib); rebuilds after a clean take a few minutes.

    xcodebuild -project QuickCull.xcodeproj -scheme QuickCull \
      -configuration Debug -destination 'platform=macOS' \
      -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build

## Test

Build the test bundle, then run it directly with `xcrun xctest` (the project
is configured for testing; run the tests on the built bundle rather than via
`xcodebuild test`):

    xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore \
      -configuration Debug -destination 'platform=macOS' \
      -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing

    xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest

The logic test suite (decoder, cache, session, windowing, key map, commit,
integration) covers the whole culling pipeline.

### Fixtures

`QuickCullCoreTests/Fixtures/raws/` holds pinned raw samples (one per brand,
plus deliberately truncated files for error-path tests). Regenerate or
restore them with:

    Scripts/fetch-fixtures.sh

This downloads from the public sources used during development and verifies
every file against its pinned sha256.

## Licensing

QuickCull dynamically links LibRaw (LGPL-2.1) to decode raw files. The
library is shipped unmodified and may be replaced with your own build; see
[`NOTICE`](NOTICE) for details.

## Out of scope for v1

- Zoom / pan inside the viewer
- Undo of a Trash commit
- Persistent flags across sessions (flags are per session by design)
