# Scripts

One script per job. Examples below are relative to the repo root.
`start.sh`, `stop.sh`, `install.sh` and `gen-compile-db.sh` resolve the
root themselves; `bench-decode.sh` and the `verify-*.swift` scripts expect
to be invoked from the repo root.

- `start.sh` quits any running instance, builds Release, and launches the app.
  The daily development loop.
- `stop.sh` gracefully quits the running app.
- `install.sh` builds Release and copies `QuickCull.app` to `/Applications`
  (`--user` for `~/Applications`, `--no-build` to reinstall the last build).
- `build-libraw.sh` downloads LibRaw 0.22.1 and builds the universal dylib
  into `Build/libraw/`. Runs automatically as an Xcode build phase; also
  safe to run by hand. Idempotent via a version marker.
- `copy-test-fixtures.sh` installs `QuickCullCoreTests/Fixtures` into the
  test bundle with its folder structure intact. Runs automatically as an
  Xcode build phase on the tests target.
- `fetch-fixtures.sh` (re)downloads the pinned raw fixtures with sha256
  verification into `QuickCullCoreTests/Fixtures/raws/`.
- `gen-compile-db.sh` emits a git-ignored `compile_commands.json` so a
  language server can type-check `QuickCullCore` with cross-file context.
  `xcodebuild` stays authoritative (see `AGENTS.md`).
- `bench-decode.sh` runs a cold-import benchmark for `DecodeEngine`: runs the
  fixture set ×N, reports mean/p95, optionally compares against a baseline
  CSV. Candidates are evaluated one at a time against `DecodeOptions.v1`.
- `make-icon.swift` generates the 1024px monogram PNG used as the layer
  artwork in `Assets/AppIcon.icon`:
  `swift Scripts/make-icon.swift <out.png> [glyph]`.
- `verify-control-bar.swift`, `verify-dropdown.swift` run manual regression
  checks that render production SwiftUI structure off-screen and assert
  layout/click-through behavior:
  `swift Scripts/verify-*.swift`. They mirror app code by hand, so keep
  them in sync with `ScrubView`/`DropdownMenu` when those change. Unit
  tests cover the underlying policy; these cover the rendered result.
