# README rewrite — design (short)

Date: 2026-10-30. Approach A picked by owner.

## Intent / why

Current `README.md` (~12k) reads like a spec: memory tiers, pre-load windows,
histogram internals lead before the download. Rewrite it user-first so a
photographer decides in 30 seconds, while a developer can still build/test
from the same page. Research used: GitHub/18F/Google/UC-OSPO README guides +
5 macOS-app READMEs (Clearly, Downright, Capso, MarkEdit, Belay).

## Goals

- Photographer sees what it is, what it looks like, download + 4-step
  workflow above the fold.
- Developer sees repo layout, build, test, fixtures without digging into docs/.
- Install quirks stay correct (ad-hoc sign right-click Open, quarantine flag,
  `install.sh` variants, LibRaw first-build cost).

## Non-goals

- No new screenshots captured in this pass — leave a placeholder slot.
- No new CONTRIBUTING.md / docs/user-guide.md split; link to existing
  `Scripts/README.md` and `docs/` only.
- No behavior or copy changes to install/build commands themselves.

## Anti-goals

- Fails if download is buried, install quirk is lost, or internals
  (cache sizes, window tiers, histogram sampling) lead again.
- Fails if keybindings, formats, or license notes become inaccurate.

## Constraints

- MIT + LibRaw LGPL-2.1 + NOTICE must stay; ad-hoc (not notarized) note stays.
- Facts pinned: macOS 14+, Xcode 16+, universal arm64/x86_64, Z/X/C flags,
  format list, `Scripts/start.sh` dev loop, 264-test xctest invocation.
- Single `README.md` at root; keep GitHub-rendered Markdown only.

## Approaches

- A. User first, dev second (picked): hero + badges + screenshot, Download,
  How it works, Features (short), Controls (compact), Supported formats,
  For Developers (layout/build/test/fixtures), Licensing, Out of scope.
  Trades length for one page that serves both.
- B. Minimal README + docs split: cleanest front page, rejected — more files
  to maintain, extra clicks for photographers.
- C. Reformat only: most accurate, rejected — still spec-first, violates
  best-practice "sell before documenting".

## What was decided

- Structure (top to bottom): title/pitch, badges, screenshot placeholder,
  Download, How it works (4 steps), Highlights (6 bullets max, no memory
  math), Controls (core table only), Supported formats (one-liners),
  For Developers (layout/build/test), Licensing, Out of scope for v1.
- Detail cut or collapsed: memory numbers → one "stays responsive" line;
  histogram sampling → one bullet; filter/commit edge cases → link to code.

## Left to the builder

- Wording, badge set (release/build/platform/license), TOC, exact collapsing
  (`<details>` or plain sections), screenshot path when available.
