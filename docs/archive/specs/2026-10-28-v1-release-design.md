# v1.0.0 Release — Design Spec

Date: 2026-10-28
Status: proposed design (pre-plan)
Related: `README.md`, `AGENTS.md`, `Scripts/install.sh`, `.github` (absent)

## Purpose

Publish the first public release of QuickCull on GitHub: a tagged `v1.0.0`
with a downloadable universal `QuickCull.app` and release notes that tell a
non-builder how to install it. Alongside it, bring the docs back in line with
what the code actually does, because the README is currently the only install
document and it assumes a checkout.

Facts this design rests on (verified 2026-10-28):

- No tags, no releases exist; `main` is level with `origin/main` at `eb7e190`.
- `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 2`,
  `MACOSX_DEPLOYMENT_TARGET = 14.0`.
- The Release build is already universal: `QuickCull` and its bundled
  `libraw.dylib` are both fat x86_64 + arm64; the app is 8.6 MB.
- `security find-identity -v -p codesigning` returns 0 identities, so the app
  can only be ad-hoc signed and cannot be notarized from this machine.
  `ENABLE_HARDENED_RUNTIME = NO` is deliberate and stays that way.
- The full suite passes: 227 tests, 0 failures, ~80 s.

## Goals

- A GitHub release at `v1.0.0` with `QuickCull-1.0.0-macOS-universal.zip`
  attached, containing `QuickCull.app`.
- Release notes with a working install path for both audiences: people who
  just want the app, and people who want to build it.
- README accurate against the code as shipped, with installation near the top
  rather than in a `Run` section 70 lines down.
- `AGENTS.md` test count corrected (it says 207; the suite runs 227).

## Non-goals

- Notarization, Developer ID signing, stapling. Not possible here; the notes
  state the Gatekeeper step plainly instead of pretending the app is signed.
- A DMG. The zip is one file, unpacked by Finder, and nothing in the install
  path needs a volume.
- Homebrew cask, Sparkle auto-update, CI release automation, `CHANGELOG.md`.
  Release notes live in the release; a changelog is a habit to adopt when
  releases become frequent.
- Changing any product code. This release ships `eb7e190` as it stands.

## Decisions

- **Asset layout.** Zip the built `.app` so the bundle survives download
  intact and `xattr -dr com.apple.quarantine` is a single documented command.
  Name it `QuickCull-1.0.0-macOS-universal.zip` so the arch is legible before
  download.
- **Signing story (my call).** Keep ad-hoc signing. Install instructions give
  the right-click → Open path first (it needs no Terminal), and the
  `xattr -dr` one-liner as the alternative for people who downloaded with
  `curl`.
- **Docs placement (my call).** New `## Install` section directly under
  `Highlights`, three subsections: Requirements, Download, From source. The
  existing `## Run` and `## Build` sections stay but stop repeating install
  instructions; they point at `## Install` and `Scripts/install.sh`.
- **Tag.** Annotated tag `v1.0.0` on the docs commit, so the tag points at the
  README a downloader will read.
- **Checksum.** `shasum -a 256` of the zip goes in the release notes.

## Doc changes

`README.md`
- Add `## Install` after `## Highlights` (Requirements / Download / From
  source), including the first-launch Gatekeeper step and the 8.6 MB,
  macOS 14+, universal facts.
- Add a release-download line to the top blurb so the README answers "where do
  I get it" in the first screenful.
- Keep `## Run` as the developer loop; drop its duplicated install paragraph.
- Re-verify every factual claim that a release makes expensive to get wrong:
  cache path, `defaults` keys, supported formats, controls table, test count
  (227).

`AGENTS.md`
- Correct the test count to 227 and the command comments to match.

`docs/superpowers/specs/2026-10-28-v1-release-design.md`
- This document, committed with the release.

## Verification

1. `xcodebuild` Release build succeeds for the app scheme (already built once;
   rebuild from the release commit to be sure the artifact matches the tag).
2. `lipo -info` on the app binary and bundled `libraw.dylib` reports both
   x86_64 and arm64.
3. `codesign --verify --deep --strict` passes on the zipped-then-unzipped app.
4. Download the asset back from the published release into `/tmp`, unzip, and
   confirm the bundle structure, arch, and signature survive the round trip.
5. `gh release view v1.0.0` shows the asset, its size, and the notes.
6. Full test suite green on the release commit (already run: 227/0).

## Rollback

`gh release delete v1.0.0 --yes` plus `git push --delete origin v1.0.0` and
`git tag -d v1.0.0`. Nothing in the app changes, so no code rollback is
needed.

## Left to the builder

- Exact wording of the release notes body (kept close to the README's
  Highlights, but written for someone who has never seen the repo).
- Whether the build is done before or after the docs commit; the spec asks
  only that the artifact is built from the tagged commit.
