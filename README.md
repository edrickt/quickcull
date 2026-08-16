# QuickCull

Native macOS app for fast raw-image culling. Culls raw files from all major
camera manufacturers: decode everything to high-quality JPEG, scrub with the
arrow keys, flag rejects with Z, commit to Trash.

See `docs/superpowers/specs/` for the design.

## Build

Requires Xcode (16+) on macOS 14+. First build downloads and compiles LibRaw
into `Build/libraw/` automatically.

    xcodebuild -project QuickCull.xcodeproj -scheme QuickCull build
