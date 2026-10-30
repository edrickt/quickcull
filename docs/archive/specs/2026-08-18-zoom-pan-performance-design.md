# Zoom & Pan Performance — Design (Native Feel)

Date: 2026-08-18
Status: Approved (approach A — surgical SwiftUI fix)
Author: Muse Spark + Oslo

## 1. Overview

QuickCull's viewer (`ImageDisplayView.ZoomableImageView`) supports pinch 1×…4×, double-click fit↔200%, mouse drag, and trackpad two-finger pan when zoomed. Users report zoom/pan feels sluggish vs native macOS apps. Interaction semantics are correct (center-anchored zoom, clamped panning, inverted two-finger pan on both axes from `e254e00`, synchronized Split) — only perceived performance/latency needs fixing.

This spec describes a minimal, single-file fix that makes the existing interaction feel native without changing its mental model or introducing an AppKit layer.

## 2. Goals

- Make pinch-zoom, mouse drag, and two-finger pan feel immediate (no frame of lag, no dead zone, no micro-stutter) at 60–120 Hz.
- Preserve current semantics:
  - Zoom `1×…4×`, double-click toggles fit ↔ 2×, any zoomed double-click resets to 1×.
  - Panning only when `scale > 1.01`, clamped so image never leaves viewport (`clampedOffset` unchanged).
  - Two-finger pan inverted on both axes: `offset + delta` (not `- delta`).
  - Split: both panes share `ScrubView` hoisted bindings (`zoomScale/lastScale/offset/lastOffset`) and pan/zoom together.
  - Full image stays visible (black letterbox, no occlusion).
- No new files, no new dependencies, compatible with existing `ScrubView` hoisted state and `fileID` onChange recentering.

## 3. Non-Goals

- Cursor/pinch-anchor zoom (keep center anchor). Deferred.
- Momentum/inertia, rubber-band bounce, or deceleration physics. Deferred.
- Migration to `NSViewRepresentable`/`CALayer` or custom `NSEvent` magnify handler. Deferred to future if this fix is insufficient (see Approach B).
- New persisted settings or user preferences.

## 4. Root-Cause Diagnosis (approved)

Six contributors to sluggishness in `QuickCull/ImageDisplayView.swift:105-294`:

1. **Async hop** — `installScrollMonitor` does `DispatchQueue.main.async { offset = clamped }`. Adds exactly one runloop tick (~16 ms at 60 Hz) to every trackpad delta.
2. **Missing hit-test** — `e254e00` removed `globalFrame.contains(mouse)` guard. In Split both left/right `ZoomableImageView` install a local monitor; every scrollWheel event is handled twice (double offset, monitor fight, extra async).
3. **Implicit animation during live gesture** — `MagnificationGesture.onChanged` mutates `scale`/`offset` inside SwiftUI's default transaction, which interpolates. Pinch should be `animation: nil` live, animated only on snap-back `onEnded`.
4. **Drag dead zone** — `DragGesture(minimumDistance: 4)` delays pan start by 4 pt.
5. **Over-filtering** — `abs(dx)<0.1 && abs(dy)<0.1` drops precise micro-deltas, causing stutter on slow pan.
6. **Snapshot staleness + reinstall churn** — `containerSnap/fittedSnap` captured at install time; `onChange(scale/container)` reinstalls monitor on next SwiftUI diff, not synchronously, so geometry can lag during resize while scrolling.

Fixing 1+2 alone recovers most perceived lag; 3–6 polish to native.

## 5. Architecture

Keep current layering:

- `ScrubView` hoists `@State zoomScale/lastScale/offset/lastOffset` (reset on `phase==.empty|decoding` and `viewMode` toggle) and passes bindings to `ImageDisplayView`.
- `ImageDisplayView` renders one `ZoomableImageView` in Single, two side-by-side in Split (`HStack(spacing:8)` gap, no divider). Split right pane reuses same bindings, `fileID: currentFile?.id` so both recenter together.
- `ZoomableImageView` internally: `GeometryReader` → `fittedSize` → `Image(scaleEffect+offset)` + `globalFrame` state + `scrollMonitor` + three handlers.

Change internals only; no new types, no coordinator.

## 6. Detailed Changes

### 6.1 Two-finger pan (scroll monitor) — `installScrollMonitor`

**Before** (`HEAD` vs `e254e00` diff):

```swift
scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
  guard currentScale > 1.01 else { return event }
  let dx = precise ? scrollingDeltaX : deltaX*10
  // no hit-test, abs<0.1 filter, -dx/-dy then +dx/+dy after invert
  DispatchQueue.main.async { offset = clamped } // lag
  return nil
}
```

**After:**

- Restore hit-test: `guard globalFrame.contains(NSEvent.mouseLocation) else { return event }`. Ensures only hovered pane handles event; in Split a single synchronous write to the shared binding moves both panes visually (no double).
- Keep invert on both axes: `new = CGSize(width: currentOffset.width + dx, height: currentOffset.height + dy)` (already correct per `e254e00` request).
- Handle both precise and wheel: `dx = hasPreciseScrollingDeltas ? scrollingDeltaX : CGFloat(deltaX)*10` (retain wheel scaling, but tune if mouse feels slow in manual test).
- Demote filter: `guard abs(dx)>=0.02 || abs(dy)>=0.02 else { return event }` or remove entirely; verify slow-pan no longer stutters.
- Synchronous write, no async:

```swift
let clamped = clampedOffset(new, container: container, fitted: fitted, scale: currentScale)
offsetBinding.wrappedValue = clamped
lastOffsetBinding.wrappedValue = clamped
return nil // consume while zoomed
```

- Avoid snapshot: read `container/fitted` from the `GeometryReader` captured values via `@State` or by capturing `geo.size` in a `PreferenceKey` updated onAppear/onChange and read at event time, not install-time `let containerSnap`. Alternatively keep install-time snap but reinstall is cheap; key is synchronous write. If staleness observed during window resize, switch to live read.

- When `scale <= 1.01`, return `event` unhandled (allow normal scroll to propagate, fail gracefully).

### 6.2 Pinch zoom — `magnificationGesture`

```swift
MagnificationGesture()
  .onChanged { value in
    var tx = Transaction(); tx.animation = nil; tx.disablesAnimations = true
    withTransaction(tx) {
      let newScale = min(max(lastScale*value, 1), 4)
      scale = newScale
      if newScale <= 1.01 { offset = .zero } else { offset = clampedOffset(offset, ...) }
    }
  }
  .onEnded { _ in
    lastScale = scale
    if scale <= 1.01 {
      withAnimation(.easeInOut(duration: 0.15)) { scale = 1; offset = .zero }
      lastScale = 1; lastOffset = .zero
    } else {
      let clamped = clampedOffset(offset, ...)
      if clamped != offset { withTransaction(Transaction(animation:nil)){ offset = clamped } }
      lastOffset = offset
    }
  }
```

No implicit animation live; only snap-back animates.

### 6.3 Mouse drag — `dragGesture`

```swift
DragGesture(minimumDistance: 0, coordinateSpace: .local)
  .onChanged { val in
    guard scale > 1.01 else { return }
    var tx = Transaction(); tx.animation = nil
    withTransaction(tx) {
      let new = CGSize(width: lastOffset.width + val.translation.width,
                       height: lastOffset.height + val.translation.height)
      offset = clampedOffset(new, container: container, fitted: fitted, scale: scale)
    }
  }
  .onEnded { _ in lastOffset = offset }
```

`minimumDistance: 0` removes dead zone. Transaction nil keeps 1:1 feel.

### 6.4 Math unchanged

`fittedSize(for:in:)` and `clampedOffset(_:container:fitted:scale:)` unchanged. Bounds: `maxX = max((fitted.width*scale - container.width)/2, 0)`.

### 6.5 Lifecycle

- `onAppear` installs, `onDisappear` removes. Keep `onChange(of: container.width/height)` re-clamp but do not reinstall unless `globalFrame` changes. `onChange(of: scale)` no longer needs reinstall if using live geometry.
- `onChange(of: fileID)` still resets `offset/lastOffset = .zero` (persist scale).

## 7. Data Flow

```
ScrubView @State zoom* ──► ImageDisplayView ──► ZoomableImageView(@Binding scale/lastScale/offset/lastOffset)
                                          ▲                 │
                                          │         gesture/monitor writes synchronously
                                          └─────────────────┘
Split: two ZoomableImageViews share same bindings → one delta updates both views' .scaleEffect/.offset in same transaction.
```

All writes are synchronous on main thread; SwiftUI diff coalesces at next CATransaction.

## 8. Error Handling & Edge Cases

- Not zoomed (`scale<=1.01`): scroll monitor returns event, no panning, no consumption.
- Rapid scrub (fileID changes): offset reset to .zero, monitor hit-test uses new globalFrame on next layout.
- Window resize while zoomed: `onChange(container.width/height)` re-clamps offset live; no monitor reinstall required.
- Last image `rightFile==nil`: placeholder pane has no `ZoomableImageView`, no monitor, no conflict.
- Filter empty (`files.isEmpty`): viewer is black, no monitor active.

## 9. Testing & Verification

- **Build:** `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build` passes.
- **Unit:** existing `QuickCullCoreTests` unaffected (no logic change). No new unit tests needed; `clampedOffset` already covered implicitly.
- **Manual (required before merge):**
  - Single: pinch 1×…4×, verify no lag, no animation hitch, clamped pan via drag & two-finger both inverted, slow-pan no stutter, fast flick no overshoot beyond clamp.
  - Split: hover left vs right, verify only hovered pane's monitor consumes, both panes move together, offset stays synced, re-center on index change.
  - Double-click toggles fit↔2× with animation, any zoomed→1× resets.
  - `globalFrame` after window resize/HUD toggle still hit-tests correctly.
  - Instruments Time Profiler / SwiftUI View Body not regressing (>55 fps during pinch).

## 10. Alternatives Considered

- **B AppKit-native NSViewRepresentable** — handles `magnify(with:)` + `scrollWheel` + `momentumPhase` synchronously on CALayer. Most native (cursor-anchored, inertia) but ~200 lines + coordinator, diverges from SwiftUI. Deferred unless A insufficient.
- **C Minimal hit-test+async only** — fixes 1+2 but leaves dead zone and gesture animation lag. Rejected: still feels sluggish on pinch.

## 11. Scope & Files

- Single file: `QuickCull/ImageDisplayView.swift`
- No new targets, no spec-model changes.

## 12. Acceptance Criteria

- Two-finger pan inverted on both axes, 1:1, synchronous, hit-tested, no double-application in Split.
- Drag starts at 0 distance, live updates with `animation:nil`.
- Pinch live updates with `animation:nil`, only snap-back animates.
- No `DispatchQueue.main.async` in scroll path.
- Build passes, manual QA per §9.

```

