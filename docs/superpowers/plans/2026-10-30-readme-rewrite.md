# README Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite root `README.md` user-first per Approach A so a photographer converts in 30 seconds and a developer can still build/test.

**Architecture:** Single-file rewrite in three stacked slices (top/middle/bottom), each slice independently reviewable, facts pinned from current README + `Scripts/README.md`.

**Tech Stack:** GitHub-rendered Markdown only, no new tooling.

**Spec:** `docs/superpowers/specs/2026-10-30-readme-rewrite-design.md`

## Global Constraints

- MIT license with `LICENSE` link stays; LibRaw LGPL-2.1 + `NOTICE` note stays.
- Requirements floor: macOS 14 (Sonoma) or later, Apple silicon or Intel, Xcode 16 or later.
- Flags are `Z` red / `X` yellow / `C` green, exclusive, same-key clears.
- Ad-hoc signed (not notarized) Gatekeeper note + right-click Open + `xattr -dr com.apple.quarantine` path stays correct.
- Single `README.md` at repo root; no new CONTRIBUTING.md or user-guide split.

## Review Focus

- Release download link 404s or names wrong asset — reader expects `Releases/latest` + `QuickCull-…-macOS-universal.zip` to resolve.
- Gatekeeper wording misleads — reader expects right-click Open to work first launch, double-click after.
- Key table drifts from app — reader expects arrows/Space/Z/X/C to match current behavior.
- Format list invents or drops a maker — reader expects Canon CR2/CR3, Nikon NEF/NRW, Sony ARW/SRF/SR2, Fuji RAF, ORF, RW2, PEF/DNG, 3FR/FFF, IIQ, X3F, SRW, DCR/KDC, ERF + JPEG/PNG/HEIC/HEIF.
- Build/test commands don't run from root — reader expects `Scripts/start.sh` loop and the pinned `xcodebuild … build-for-testing` + `xcrun xctest …QuickCullCoreTests.xctest` sequence to work.

---

### Task 1: Top — pitch, download, how it works

**Files:**
- Modify: `README.md` (top ~80 lines: title through How it works)
- Test: visual check via `README.md` render + link check

**Interfaces:**
- Consumes: spec structure order; current README facts (release URL, install quirk, 4-step workflow).
- Produces: anchors `#quickcull`, `## Download`, `## How it works` that Tasks 2–3 link against.

- [ ] **Step 1: Draft top slice**

Write in `README.md`: one-paragraph pitch, badges (release/macOS/license), screenshot placeholder `docs/assets/screenshot-main.png`, `## Download` (Requirements + Releases asset + drag to /Applications + ad-hoc Open steps + quarantine command + from-source `install.sh` variants), `## How it works` (4 steps: Select, Decode all, Scrub, Flag and commit).

- [ ] **Step 2: Verify facts against sources**

Run: `rg -n "releases/latest|xattr -dr|install.sh|start.sh" README.md` and compare each hit to current README + `Scripts/README.md`.
Expected: release URL, quarantine command, `--user`/`--no-build` flags all present and verbatim.

- [ ] **Step 3: Verify render**

Run: open `README.md` preview (or `npx markdownlint-cli README.md` if available; otherwise visual read).
Expected: headings nest correctly, code blocks fenced, no raw HTML breakage.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README top — pitch, download, workflow"
```

### Task 2: Middle — highlights, controls, formats

**Files:**
- Modify: `README.md` (middle: Highlights through Supported formats)
- Test: fact check against current README

**Interfaces:**
- Consumes: anchors from Task 1.
- Produces: anchors `## Highlights`, `## Controls`, `## Supported formats` for Task 3 TOC.

- [ ] **Step 1: Draft middle slice**

Write: `## Highlights` (≤6 bullets: true RAW histogram, decode-first scrub, flat memory one-liner, three views, metadata sidebar, 3-color flags), `## Controls` (core keys table: arrows, shift-jump, Z/X/C, Space loupe + exclusivity note + filter/commit summary), `## Supported formats` (LibRaw list + ImageIO list, one line each).

- [ ] **Step 2: Verify against Review Focus lines 3–4**

Run: `rg -n "Z.*red|X.*yellow|C.*green|CR2|NEF|ARW|RAF|ORF|RW2|DNG|HEIC" README.md`
Expected: all key bindings and all maker extensions from Review Focus present, none invented.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README middle — highlights, controls, formats"
```

### Task 3: Bottom — developers, licensing, polish

**Files:**
- Modify: `README.md` (bottom: Repository layout through Out of scope + TOC)
- Test: command check + full-file read

**Interfaces:**
- Consumes: anchors from Tasks 1–2.
- Produces: complete `README.md`, done.

- [ ] **Step 1: Draft bottom slice**

Write: `## Repository layout` (tree), `## Build` (LibRaw first-build note + `xcodebuild` line), `## Test` (pinned `build-for-testing` + `xctest` + 264-test note + fixtures `fetch-fixtures.sh`), `## Licensing` (MIT + LibRaw dylib path + NOTICE), `## Out of scope for v1` (2 bullets), plus TOC under title linking all sections.

- [ ] **Step 2: Verify build/test commands**

Run: compare `rg -n "xcodebuild|xctest|fetch-fixtures|Scripts/start" README.md` against `AGENTS.md` build/test block.
Expected: commands match verbatim; `Scripts/start.sh` dev loop + Applications note present.

- [ ] **Step 3: Final read-through**

Run: full read of `README.md` top to bottom.
Expected: photographer path (pitch→download→workflow) reads without dev detail; no memory-tier numbers or histogram sampling math above Highlights; all links resolve (`LICENSE`, `NOTICE`, `Scripts/README.md`, `docs/`).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README bottom — developers, licensing, TOC"
```
