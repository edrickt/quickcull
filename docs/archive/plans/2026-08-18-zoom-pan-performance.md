# Zoom & Pan Performance (Native Feel) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make pinch-zoom, mouse drag, and two-finger pan feel native-immediate by removing async lag, hit-test duplication, animation hitch, and dead zones while keeping center-anchored 1×…4× zoom and inverted pan.

**Architecture:** Single-file surgical fix in `ZoomableImageView` (SwiftUI). Keep hoisted `ScrubView` bindings and `clampedOffset` math. Make scroll monitor synchronous + hit-tested, disable implicit animation during live gestures, remove drag dead zone. No new files, no AppKit view — uses `NSEvent` monitor + `Transaction(animation:nil)`.

**Tech Stack:** Swift 5.10+, SwiftUI, AppKit `NSEvent`, macOS 13+, Xcode 15, `xcodebuild`

## Global Constraints

- Single file changed: `QuickCull/ImageDisplayView.swift:105-294` (only `ZoomableImageView` internals).
- Interaction semantics preserved: center-anchored zoom 1×…4×, double-click fit(1×) ↔ 2×, panning only when `scale > 1.01`, clamped so image never leaves viewport, two-finger panning inverted on both axes (`+dx/+dy` from `e254e00`), synchronized Split (both panes share bindings).
- No new files, no new targets, no new dependencies.
- All live gesture writes (`onChanged`) use `Transaction(animation:nil)` / `disablesAnimations`; only `onEnded` snap-back may animate (`easeInOut 0.15/0.2`).
- Build must pass: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build`.

---

## File Structure

- **Modify:** `QuickCull/ImageDisplayView.swift`
  - `private struct ZoomableImageView` — owns `scrollMonitor: Any?`, `globalFrame: CGRect`, bindings `scale/lastScale/offset/lastOffset`, methods `installScrollMonitor`, `removeScrollMonitor`, `magnificationGesture`, `dragGesture`, `handleDoubleClick`, `fittedSize`, `clampedOffset`.
  - No new files. Plan reuses existing `clampedOffset` and `fittedSize` unchanged.
  - Consumed by: `ImageDisplayView.body` Single branch and Split left/right `GeometryReader` panes (already sharing hoisted state from `QuickCull/ScrubView.swift:13-16`).

---

### Task 1: Synchronous hit-tested two-finger pan

**Files:**
- Modify: `QuickCull/ImageDisplayView.swift:114-115` (globalFrame + scrollMonitor state)
- Modify: `QuickCull/ImageDisplayView.swift:138-144` (background GeometryReader for hit-test)
- Modify: `QuickCull/ImageDisplayView.swift:145-159` (onAppear/onChange lifecycle)
- Modify: `QuickCull/ImageDisplayView.swift:171-205` (installScrollMonitor / removeScrollMonitor)

**Interfaces:**
- Consumes: `@Binding offset/lastOffset/scale`, `@State globalFrame: CGRect`, `clampedOffset(_:container:fitted:scale:) -> CGSize`, `fittedSize(for:in:) -> CGSize`, `GeometryReader.size`, `NSEvent.scrollingDeltaX/Y`, `NSEvent.mouseLocation`.
- Produces: Synchronous `offset/lastOffset` update consumed by `Image.scaleEffect`+`offset` and by second Split pane via shared binding. No new public API.

- [ ] **Step 1: Verify current failure — build + locate async/hit-test gap**

  Read `QuickCull/ImageDisplayView.swift:171-196` and confirm `DispatchQueue.main.async` and missing `globalFrame.contains` guard.

  ```bash
  rg -n "DispatchQueue.main.async|globalFrame|addLocalMonitor" QuickCull/ImageDisplayView.swift
  # Expect: async line present, globalFrame check absent in working copy
  ```

  Run: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build`
  Expected: PASS (build succeeds, bug is perf not compile).

- [ ] **Step 2: Implement synchronous hit-tested monitor**

  Replace `installScrollMonitor` with synchronous, hit-tested version (inverted both axes kept). Keep wheel scaling, demote filter to 0.02, remove async, read live bindings.

  ```swift
  private func installScrollMonitor(container: CGSize, fitted: CGSize) {
      removeScrollMonitor()
  #if canImport(AppKit)
      let offsetBinding = $offset
      let lastOffsetBinding = $lastOffset
      let scaleBinding = $scale
      let frameBinding = $globalFrame
      let containerSnap = container
      let fittedSnap = fitted
      scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
          let currentScale = scaleBinding.wrappedValue
          guard currentScale > 1.01 else { return event }
          // Only handle event over this pane — prevents Split double-apply
          let mouse = NSEvent.mouseLocation
          guard frameBinding.wrappedValue.contains(mouse) else { return event }
          let dx: CGFloat = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : CGFloat(event.deltaX) * 10
          let dy: CGFloat = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : CGFloat(event.deltaY) * 10
          if abs(dx) < 0.02 && abs(dy) < 0.02 { return event }
          let currentOffset = offsetBinding.wrappedValue
          // Inverted on both axes (e254e00): +dx/+dy
          let new = CGSize(width: currentOffset.width + dx, height: currentOffset.height + dy)
          let clamped = clampedOffset(new, container: containerSnap, fitted: fittedSnap, scale: currentScale)
          // Synchronous — no DispatchQueue.main.async
          offsetBinding.wrappedValue = clamped
          lastOffsetBinding.wrappedValue = clamped
          return nil // consume while zoomed
      }
  #endif
  }
  ```

  Ensure `globalFrame` background stays:

  ```swift
  .background(
      GeometryReader { proxy in
          Color.clear
              .onAppear { globalFrame = proxy.frame(in: .global) }
              .onChange(of: proxy.frame(in: .global)) { _, newFrame in globalFrame = newFrame }
      }
  )
  ```

  Lifecycle: keep `onAppear { installScrollMonitor(...) }`, `onDisappear { removeScrollMonitor() }`, but `onChange(of: container.width/height/scale)` only re-clamps or reinstalls globalFrame if needed — do not reinstall on every scale tick if live geometry suffices.

- [ ] **Step 3: Verify fix — no async, hit-test present**

  ```bash
  rg -n "DispatchQueue.main.async" QuickCull/ImageDisplayView.swift
  # Expected: no match

  rg -n "globalFrame.contains" QuickCull/ImageDisplayView.swift
  # Expected: 1 match inside installScrollMonitor

  rg -n "scrollingDeltaX.*scrollingDeltaY" QuickCull/ImageDisplayView.swift
  # Expected: precise + wheel bronze

  xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build
  # Expected: PASS
  ```

- [ ] **Step 4: Manual QA for pan**

  ```bash
  ./start.sh   # or open QuickCull.xcodeproj in Xcode, run QuickCull scheme
  ```
  - Single: zoom to 2× via double-click, two-finger swipe right → image pans right (inverted), swipe up → pans up, slow pan (<0.1) no stutter, fast flick clamped.
  - Split: hover left pane and pan → both panes move together (single write), hover right pane same, hover outside gap → no pan, no double-speed.

- [ ] **Step 5: Commit**

  ```bash
  git add QuickCull/ImageDisplayView.swift
  git commit -m "perf: synchronous hit-tested two-finger pan (remove async, restore globalFrame, demote filter, keep invert)"
  ```

---

### Task 2: Immediate mouse drag (remove dead zone)

**Files:**
- Modify: `QuickCull/ImageDisplayView.swift:237-250` (`dragGesture`)

**Interfaces:**
- Consumes: `lastOffset: CGSize`, `container: CGSize`, `fitted: CGSize`, `scale: CGFloat`, `clampedOffset`.
- Produces: `offset/lastOffset` updates consumed by SwiftUI render + Split sync binding.

- [ ] **Step 1: Verify current dead zone**

  ```bash
  rg -n "DragGesture.*minimumDistance" QuickCull/ImageDisplayView.swift
  # Expect: minimumDistance: 4
  ```

- [ ] **Step 2: Implement zero-distance, animation-free drag**

  Replace:

  ```swift
  private func dragGesture(container: CGSize, fitted: CGSize) -> some Gesture {
      DragGesture(minimumDistance: 0, coordinateSpace: .local)
          .onChanged { val in
              guard scale > 1.01 else { return }
              var tx = Transaction()
              tx.animation = nil
              tx.disablesAnimations = true
              withTransaction(tx) {
                  let new = CGSize(
                      width: lastOffset.width + val.translation.width,
                      height: lastOffset.height + val.translation.height
                  )
                  offset = clampedOffset(new, container: container, fitted: fitted, scale: scale)
              }
          }
          .onEnded { _ in
              lastOffset = offset
          }
  }
  ```

- [ ] **Step 3: Verify — build + gesture**

  ```bash
  rg -n "minimumDistance: 0" QuickCull/ImageDisplayView.swift
  # Expected: match

  xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build
  # Expected: PASS
  ```

- [ ] **Step 4: Manual QA — drag**

  Zoom to 2×, mouse drag 1 px → image moves immediately (no 4 pt delay), drag while holding scales smoothly, release → `lastOffset` persists for next drag, scrub to next image → offset resets.

- [ ] **Step 5: Commit**

  ```bash
  git add QuickCull/ImageDisplayView.swift
  git commit -m "perf: immediate drag pan (minimumDistance 0, transaction nil)"
  ```

---

### Task 3: Live pinch without implicit animation

**Files:**
- Modify: `QuickCull/ImageDisplayView.swift:209-235` (`magnificationGesture`)

**Interfaces:**
- Consumes: `lastScale: CGFloat`, `scale/offset`, `container/fitted`, `clampedOffset`.
- Produces: `scale/offset/lastScale/lastOffset` for render. `onEnded` snap-back animation only path.

- [ ] **Step 1: Verify current animation hitch**

  Read `magnificationGesture` — confirm `onChanged` mutates `scale` without `Transaction(animation:nil)` and `onEnded` does `withAnimation` for snap-back.

- [ ] **Step 2: Implement nil-animation live pinch**

  Replace:

  ```swift
  private func magnificationGesture(container: CGSize, fitted: CGSize) -> some Gesture {
      MagnificationGesture()
          .onChanged { value in
              var tx = Transaction()
              tx.animation = nil
              tx.disablesAnimations = true
              withTransaction(tx) {
                  let newScale = lastScale * value
                  let clamped = min(max(newScale, 1), 4)
                  scale = clamped
                  if clamped <= 1.01 {
                      offset = .zero
                  } else {
                      offset = clampedOffset(offset, container: container, fitted: fitted, scale: clamped)
                  }
              }
          }
          .onEnded { _ in
              lastScale = scale
              if scale <= 1.01 {
                  withAnimation(.easeInOut(duration: 0.15)) {
                      scale = 1
                      offset = .zero
                  }
                  lastScale = 1
                  lastOffset = .zero
              } else {
                  let clamped = clampedOffset(offset, container: container, fitted: fitted, scale: scale)
                  if clamped != offset {
                      var tx = Transaction(); tx.animation = nil; tx.disablesAnimations = true
                      withTransaction(tx) { offset = clamped }
                  }
                  lastOffset = offset
              }
          }
  }
  ```

  Note: `clamped` range stays `1…4`, center-anchored (no anchor math) as per spec.

- [ ] **Step 3: Verify — build + grep**

  ```bash
  rg -n "Transaction.*animation.*nil|withTransaction" QuickCull/ImageDisplayView.swift
  # Expected: matches in magnificationGesture + dragGesture

  xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build
  # Expected: PASS
  ```

- [ ] **Step 4: Manual QA — pinch + double-click**

  - Pinch on trackpad: 1×→4× live without easing, 60–120 fps (check Instruments SwiftUI), release → `lastScale` holds.
  - Pinch to <1.01 → snap to 1× with `easeInOut 0.15`.
  - Double-click toggle still `withAnimation(.easeInOut 0.2)` fit↔2×.

- [ ] **Step 5: Commit**

  ```bash
  git add QuickCull/ImageDisplayView.swift
  git commit -m "perf: live pinch without implicit animation (transaction nil, snap-back only)"
  ```

---

### Task 4: Final polish & verification

**Files:**
- Verify: `QuickCull/ImageDisplayView.swift` (no remaining `DispatchQueue.main.async`, no `minimumDistance: 4`, no snapshot staleness)
- Reference: `docs/superpowers/specs/2026-08-18-zoom-pan-performance-design.md`

- [ ] **Step 1: Static checks**

  ```bash
  rg -n "DispatchQueue.main.async" QuickCull/ImageDisplayView.swift
  # Expected: 0 matches

  rg -n "minimumDistance" QuickCull/ImageDisplayView.swift
  # Expected: minimumDistance: 0 only

  rg -n "abs\(dx\) < 0\.1|abs\(dy\) < 0\.1" QuickCull/ImageDisplayView.swift
  # Expected: 0 matches (demoted to 0.02 or removed)

  rg -n "onAppear.*installScrollMonitor|onDisappear.*removeScrollMonitor" QuickCull/ImageDisplayView.swift
  # Expected: present
  ```

- [ ] **Step 2: Full build + tests**

  ```bash
  xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build
  # Expected: PASS no warnings about Copy Headers

  xcodebuild test -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet || ./start.sh &
  # Core tests should still pass — no logic change to Session/Cache
  ```

- [ ] **Step 3: End-to-end manual regression**

  Checklist (spec §9 acceptance):
  - Single: pinch, drag, two-finger pan inverted both axes 1:1, slow pan no stutter, fast flick clamped, double-click toggle.
  - Split: left/right hover each controls both panes singly, `fileID` change recenters offset but persists scale, HUD toggle gap still 8pt.
  - Empty filter → black, no monitor, no crash.
  - Window resize while zoomed → reclamp, no monitor leak (check Instruments Leaks).

- [ ] **Step 4: Commit if polish needed, else tag**

  If no diff, no commit; otherwise:

  ```bash
  git add QuickCull/ImageDisplayView.swift
  git commit -m "chore: final polish zoom/pan perf (re-clamp, lifecycle)"
  ```

---

## Self-Review

**Spec coverage:**
- §6.1 synchronous hit-tested pan (invert kept, async removed, filter demoted) → Task 1
- §6.2 pinch nil-animation → Task 3
- §6.3 drag dead-zone removal → Task 2
- §6.4 clamped math unchanged → respected in all tasks
- §6.5 lifecycle → Task 1 + Task 4
- §9 validation (build + manual) → Task 4
- Global constraints (single file, center-anchored, inverted, Split sync, no new files) → enforced in header + each task.

**Placeholder scan:** No TBD/TODO, no "appropriate error handling" vagueness, each step has concrete code + bash verification, no "similar to Task N" — code repeated verbatim.

**Type consistency:** `scale: CGFloat`, `lastScale: CGFloat`, `offset/lastOffset: CGSize`, `globalFrame: CGRect`, `scrollMonitor: Any?`, `container/fitted: CGSize`, `clampedOffset(_:container:fitted:scale:) -> CGSize` consistent across Tasks 1–3. `Transaction(animation:nil)` pattern same in T2/T3.

Fixes: none needed.

```

