# QuickCull — v1 Design Spec

Date: 2026-08-16
Status: approved design (pre-plan)

## Purpose

QuickCull is a native macOS app for rapidly culling raw-format images from all
major camera manufacturers. The photographer selects raw files, QuickCull
decodes them at full resolution to high-quality JPEGs, then the photographer
scrubs through the images with keyboard-only controls and flags rejects. A
commit step moves flagged files to the macOS Trash and lets culling continue.

## Product Decisions (validated with user)

- Native macOS app, Swift + SwiftUI, targeting macOS 14 Sonoma+.
- Import = multi-select raw files (not folder scan).
- Decode engine: LibRaw, in-process, dynamically linked (LGPL-2.1 compliant).
  No embedded previews used — every JPEG is a true demosaic from raw data.
- Full-resolution decode, JPEG quality 75.
- Two-phase pipeline: ALL files are decoded before scrubbing begins. During
  scrubbing the only work is loading decoded JPEGs into the sliding window.
- Sliding in-memory window: current image ±30 (max 61 decoded JPEGs in memory).
- Decode cache: `~/Library/Application Support/QuickCull/cache/`. Wiped on
  every launch (authoritative cleanup), best-effort wipe on quit. Force-quit
  leftovers are covered by the launch wipe; they are never loaded.
- Flags are in-memory only, per session. A new import clears all flags.
- Z toggles a red corner badge; flagging does not auto-advance. No undo in v1.
- Keyboard: ←/→ previous/next, ↑/↓ jump ±10, Z toggle flag. No zoom in v1.
- UI: single large image (fit-to-window) + bottom filmstrip of the sliding
  window; current frame highlighted, flagged frames badged; click thumbnail to
  jump.
- Commit: moves flagged files to macOS Trash, removes them from the session,
  clears flags, and scrubbing continues (multi-pass culling possible).
- Free at launch; may move to a paid model later. The LGPL dynamic-linking
  arrangement supports both without changes.

## Out of Scope (v1)

Zoom/loupe at 100%, undo, ratings/colors, folder-scan import, persistent
flags, metadata editing, sidecar/XMP handling, compare mode, export beyond the
decode cache, moving flagged files anywhere other than Trash, multi-window or
multi-session UI.

## Architecture

Single app target. Each component has one responsibility and a testable
boundary.

### Components

1. **`RawDecoder` protocol + `LibRawDecoder` implementation**
   - The only place LibRaw is touched.
   - `decode(url:) -> Result<DecodedJPEG, DecodeError>`: full-resolution
     demosaic to JPEG q75.
   - LibRaw vendored as a C library target, built from source, dynamically
     linked; `libraw.dylib` ships in `QuickCull.app/Contents/Frameworks/`.
   - All other components depend on the protocol, never on LibRaw. Swapping
     the implementation (e.g., XPC isolation) later requires no changes
     elsewhere.

2. **`DecodeEngine` (actor)**
   - Phase 1 workhorse. Bounded worker pool: one worker per performance core.
   - Job queue over the session's file list; processes all files before
     scrubbing is enabled.
   - Progress via `AsyncStream` (done/total, current file).
   - Per-file errors captured and reported; one bad file never aborts the
     queue.

3. **`ImageCacheStore`**
   - Owns `~/Library/Application Support/QuickCull/cache/`.
   - Launch: delete the cache directory and recreate it (authoritative,
     idempotent — covers crash/force-quit leftovers).
   - Quit: best-effort delete; failure is harmless.
   - Writes decoded JPEGs keyed by source file identity: path + size + mtime.
   - Scrubbing reads only from the cache.

4. **`Session`**
   - Ordered list of loaded images, current index, in-memory flag set.
   - Flags discarded when a new import starts.
   - After a commit, trashed entries are removed; the session continues.

5. **`SlidingWindow`**
   - Enforces the memory invariant: current image ±30 (max 61 decoded JPEGs).
   - On index change: load the current image first, then neighbors outward;
     evict the far edge.
   - Memory stays flat regardless of session size.

6. **Scrub UI (SwiftUI)**
   - Main image (fit-to-window) + filmstrip of the sliding window.
   - Red corner badge on flagged image and its filmstrip thumbnail.
   - Keyboard handling via a testable pure mapping function (key → action).

7. **`TrashCommit`**
   - Moves flagged files to macOS Trash (`FileManager.trashItem`).
   - Per-file failure reporting; failures keep their flags.
   - Removes committed files from the session; scrubbing continues.

### Boundaries

- `DecodeEngine` → `RawDecoder` + `ImageCacheStore`.
- `SlidingWindow` → `ImageCacheStore` only.
- UI → `Session` + `SlidingWindow`.
- Nothing outside `LibRawDecoder` knows LibRaw exists.

## Data Flow

```
Launch
  └─ wipe cache dir → recreate   (authoritative; covers force-quit leftovers)

Import (user multi-selects files)
  └─ Session created: files validated (supported extension, readable,
     deduped by resolved path)
  └─ Phase 1: DecodeEngine decodes ALL files → full-res q75 JPEGs → cache
     · progress UI (n / total); failures collected; scrubbing blocked
  └─ Phase 2: SlidingWindow loads current ±30 from cache → first image shown

Scrub
  └─ ←/→ : index ±1    ↑/↓ : index ±10
     · SlidingWindow shifts: current loads first, neighbors outward,
       far edge evicted
  └─ Z : toggle flag in Session's in-memory set
     · red corner badge on main image and filmstrip thumbnail

Commit (explicit user action)
  └─ flagged files → macOS Trash (per-file results)
  └─ trashed files removed from Session; flags cleared
  └─ scrubbing continues; commit can be repeated (multi-pass)

Quit
  └─ best-effort cache wipe (optional; launch wipe is the guarantee)
```

## Error Handling

- **Corrupt/unsupported raw**: caught per-file in Phase 1; reported in an
  import summary; session proceeds without that file. LibRaw error codes are
  translated to `DecodeError`.
- **Decoder crash risk** (inherent to in-process LibRaw): mitigated by
  extension/header sniffing before decode and full use of LibRaw's error
  paths. Decode happens only in Phase 1, so a crash costs nothing but a
  restart — the cache is rebuilt on next launch. If pathological files become
  a real-world problem, the `RawDecoder` boundary allows moving decode to an
  XPC service without touching other components.
- **Disk full during Phase 1**: queue halts; error state reports space needed;
  already-decoded files remain usable for a partial session.
- **Trash failure** (unusual volume): per-file failure reported; flags kept;
  session unaffected.
- **Duplicate selection**: deduped by resolved path at import; flags keyed by
  unique file ID.
- **New import during a session**: old session state (including flags) is
  fully discarded first.

## Supported Formats (v1)

Extension whitelist derived from LibRaw's supported set:

- Canon: CR2, CR3
- Nikon: NEF, NRW
- Sony: ARW, SRF, SR2
- Fujifilm: RAF
- Olympus / OM System: ORF
- Panasonic: RW2
- Leica, Ricoh: DNG
- Pentax: PEF
- Hasselblad: 3FR, FFF
- Phase One: IIQ
- Sigma: X3F
- Samsung: SRW
- Kodak: DCR, KDC
- Epson: ERF
- Generic: DNG

New cameras from these brands typically decode via LibRaw updates without app
changes.

## Build & Distribution

- LibRaw: vendored, built from source as a C target, dynamically linked;
  `libraw.dylib` inside `QuickCull.app/Contents/Frameworks/`. LGPL-2.1
  obligations: dynamic linking + a notice that users may replace the library.
  Valid for both free and paid distribution.
- Code signing: Developer ID + notarization required for distributing to
  others (Gatekeeper); self-signed acceptable for local development.
- App structure: single self-contained `.app` bundle. No helper processes, no
  daemons, no launch agents. Minimal settings surface in v1.

## User-Visible Flow (v1)

1. Launch → empty state with "Choose RAW files…" (multi-select file importer).
2. Import progress: decode bar with done/total; failures listed at the end.
3. Scrub screen: image + filmstrip; keyboard controls.
4. Commit → confirmation ("Move N files to Trash?") → done → keep scrubbing.

## Testing

- **Unit**: `LibRawDecoder` against small sample raw fixtures from each major
  manufacturer (checked into the repo); `ImageCacheStore` keying and wipe
  behavior; `SlidingWindow` invariants (never > 61 images, correct eviction at
  edges); `Session` flag/commit logic against temp files with real trash calls
  in a sandboxed test.
- **Performance**: import-throughput test to catch worker-pool parallelism
  regressions.
- **UI**: keyboard mapping as a testable pure function; manual smoke checklist
  for filmstrip, badge, jump keys, and commit.
