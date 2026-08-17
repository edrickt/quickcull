# Cull Filter — Design

Filter the scrub sequence by deletion status: show All photos, only photos
flagged for deletion, or only keepers. Tri-state filter controlled from the
toolbar; flags (`Z`) remain the per-photo marking mechanism and commit is
unchanged.

## Background

QuickCull scrubs a session's photo sequence with the arrow keys, flags rejects
with `Z`, and commits flagged files to Trash. Today the sequence is always the
full file list. A culler commonly wants to review only the rejects before
committing (did I flag the right ones?) or only the keepers (what survives?).
The filter provides both, without changing flag semantics or commit.

## Approach (approved)

**Session-internal filtered sequence.** `Session` owns the full list
privately (`allFiles`) and exposes the filtered projection as `files` — the
property every view and window already reads. Filtering is therefore invisible
to the UI: `FilmstripView` and `ImageDisplayView` need no changes, and image
windows are rebuilt from the projection using the existing
`installWindows(for:)` path that commit already uses.

Rejected alternatives: (B) keep `files` as the full set and add
`visibleFiles`, switching every consumer — more churn, no benefit; (C) skip
non-matching files during navigation while windows keep the full list —
breaks the contiguous-index contract the filmstrip scroll and the ±radius
windows rely on.

## Model — `QuickCullCore/Session`

New public type:

```swift
public enum CullFilter: CaseIterable, Equatable, Sendable {
    case all      // everything
    case flagged  // photos flagged for deletion only
    case keepers  // unflagged photos only
}
```

`Session` changes (single owner of both lists; nothing else touches them):

- `private let allFiles: [SessionFile]` — the full post-commit list.
  `public private(set) var files` becomes the visible projection.
  `init(files:)` sets both; the default filter is `.all`, so `files ==
  allFiles` and pre-filter behavior is unchanged bit-for-bit.
- `public private(set) var filter: CullFilter = .all`
- `public var totalCount: Int { allFiles.count }` — for keeper counts
  (flagged count already exists as `flaggedCount`).
- Projection rule: `.all` → all files; `.flagged` → `flagged.contains(id)`;
  `.keepers` → not flagged.
- `setFilter(_:)` — recomputes the projection. If the current photo still
  matches, it stays current (located by id; its index shifts). Otherwise the
  current photo becomes the nearest match in full-list order, ties resolving
  to the later (forward) file. A filter that matches nothing (e.g. Flagged
  while nothing is flagged) yields an empty projection, which resets the
  filter to `.all`, keeping the current photo by id.
- `toggleFlag()` — flag logic unchanged; then, if the current photo dropped
  out of the projection (unflag in Flagged mode, flag in Keepers mode), the
  file at the same index — the next match — becomes current, clamped at the
  end. If the projection becomes empty, the filter resets to `.all` and the
  current photo (just unflagged/flagged) is located by id in `allFiles`.
  Returns `Bool`: whether the projection changed, so `AppState` knows whether
  to rebuild windows.
- `remove(_:)` — removes from `allFiles` (flag clearing as today), then
  recomputes the projection and clamps the index. In `.all` mode this is
  today's behavior exactly. If the projection becomes empty while `allFiles`
  is not (e.g. every flagged photo committed while in Flagged mode), the
  filter resets to `.all` and the session lands on the first remaining file.
- `flaggedFiles` filters `allFiles`, not `files`: in Keepers mode the flagged
  files are not in the projection, and commit must still find them. (In
  `.all` mode the two lists coincide, so this is behavior-preserving.)

## App flow — `QuickCullCore/App/AppState`

- `setFilter(_ filter: CullFilter)` — guard `phase == .scrubbing`, call
  `session.setFilter(...)`, then `installWindows(for: session.files)` (which
  ends with `syncWindows()`), so the viewer and filmstrip render the new
  projection.
- `handle(.toggleFlag)` — call `session.toggleFlag()`; only when it returns
  `true` (projection changed) rebuild the windows; otherwise `syncWindows()`
  as today. `.all`-mode flag toggling therefore costs nothing new.
- Commit (`confirmCommit`) is unchanged: it uses `flaggedFiles` (now sourced
  from `allFiles`) and `installWindows(for: session.files)` — which in a
  filtered session installs windows over the projection, exactly as intended.

## UI — `QuickCull/ScrubView`

A segmented picker in the toolbar, next to the existing trash button:

```
[All] [Flagged (12)] [Keepers (38)]      ⋮   Move Flagged to Trash
```

- Segments: `All`, `Flagged (n)`, `Keepers (n)`; n = `flaggedCount` and
  `totalCount − flaggedCount`, updating live from observed state.
- Binding calls `appState.setFilter(...)`.
- Disabled while `isCommitting`, matching the commit button, so a filter
  change cannot race a commit.
- No new keyboard shortcut (decision: toolbar control only).
- This is the only view change in the app.

## Edge cases

| Case | Behavior |
|---|---|
| Flag current photo in Keepers mode | Drops out; next keeper becomes current |
| Unflag current photo in Flagged mode | Drops out; next flagged becomes current |
| Unflag the last flagged photo in Flagged mode | Projection empty → filter resets to All, current photo kept |
| Commit all flagged photos in Flagged mode | Projection empty → filter resets to All, land on first remaining file |
| Switch filter while a photo is current | Current kept if it matches, else nearest match (ties forward) |
| New import | Fresh `Session`, filter `.all` (filter is per-session, like flags) |
| Import/commit removals | `remove()` keeps both lists in sync; index math unchanged in `.all` |

## Testing

New `Session` tests:

- Projection matrix: each filter × each membership (flagged/unflagged file
  present or absent from `files`, order preserved).
- `setFilter` current-photo preservation; nearest-match jump with forward
  tie-break; jump backward when strictly nearer.
- Auto-advance in both filtered modes; index clamp at the end.
- Empty-projection reset in both triggers (last unflag; commit-all-flagged),
  including current-photo-by-id in the toggle case and first-file in the
  remove case.
- `flaggedFiles` returns flagged files from the full set under the Keepers
  filter.
- `remove()` index math under each filter.

New `AppState` tests:

- `setFilter` rebuilds the windows over the projection (window counts match).
- `toggleFlag` rebuilds windows only when the projection changed.

Existing tests must pass unchanged — the default `.all` filter pins the
no-regression guarantee.

## Out of scope

- Keyboard shortcut for the filter (explicitly declined).
- Persistent filter across sessions (filter is per-session, like flags).
- Dimmed/hidden non-matching thumbnails in the filmstrip (declined: filmstrip
  shows only matching photos).
