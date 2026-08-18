# FastRawViewer-style Line Histogram — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace filled histogram areas with thin FastRawViewer-style lines, faint axes/baseline, and add per-panel clipping % + mean stats while keeping stacked RGB-over-luma 72pt layout.

**Architecture:** Modify `QuickCull/ImageDisplayView.swift` only: `MetadataHUDView` adds stats `HStack` above each `Canvas`; `RawHistogramView` and `RawLuminanceHistogramView` change `ctx.fill` (0.55/0.85) to `ctx.stroke` (1.5pt, 0.9 opacity) with same log-y, plus faint `white.opacity(0.15)` baseline/border. No model/cache changes; same sRGB `RawHistogram` sidecar and `DisplayHistogram` fallback.

**Tech Stack:** Swift 5.10+, SwiftUI `Canvas`, `RawHistogram` sRGB 8-bit, xcodebuild

## Global Constraints

* Spec: `docs/superpowers/specs/2026-08-18-fastrawviewer-line-histogram-design.md` (approved 2026-08-18, amends rendered-histogram + split-hud specs).
* Visual: `RawHistogramView` draws `R .red.opacity(0.9)`, `G .green.opacity(0.9)`, `B .blue.opacity(0.9)` as `ctx.stroke(path, with:.color, lineWidth:1.5)` (was `fill 0.55`), `RawLuminanceHistogramView` draws `white.opacity(0.9)` 1.5pt (was fill `0.85` white), same `log10(1+count)/logMax` with `logMax>0?logMax:1`, `binW=width/256`, faint axes `white.opacity(0.15)` baseline `y=height` + left border `x=0`, clipping marker vertical white 1px at `x=width-1` when `clipping>0.001` (RGB `prefix(3)`, luma `clipping[3]`), background `.black.opacity(0.3)`, `RoundedRectangle(4)`, `accessibilityLabel`.
* Stats row: RGB panel `HStack{ Text("R:\(String(format:"%.1f%%", clipping[0]*100)) G:... B:..."); Spacer(); Text("Mean \(Int((meanR+meanG+meanB)/3))") }` `.font(.caption2).foregroundStyle(.secondary).padding(.horizontal,2)` where `meanC = total>0 ? Σ(bin*count)/total : 0` rounded; luma panel `HStack{ Text("Luma \(String(format:"%.1f%%", clipping[3]*100))"); Spacer(); Text("Mean \(meanL)") }` same style.
* Layout: `MetadataHUDView` `if let hist` block is `VStack(spacing:8){ VStack(spacing:2){ statsRGB; RawHistogramView 72 } ; VStack(spacing:2){ statsLuma; RawLuminanceHistogramView 72 } }.padding(.horizontal,10).padding(.top,8)` inside `ScrollView` above rows, `histogram=nil` at `.task` start.
* No model/storage change: `RawHistogram` `bins 3×256`, `luminance 256`, `sensorMax 255`, `samples`/`clipping` derived, `LibRawDecoder.renderedHistogram` sRGB `mem_image` and `DisplayHistogram` unchanged.
* Build: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build` must pass. Tests: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS'` must pass `134/0`.
* No new targets; `ScrubView`, `Session`, `ImageWindow`, `FilmstripView`, `GridView` unchanged.

---

## File Structure

* **Modify:** `QuickCull/ImageDisplayView.swift:333-485` — `MetadataHUDView` add two stats `HStack`s + outer `VStack(spacing:8)` with inner `VStack(spacing:2)` wrappers; `RawHistogramView:393-453` change fill→stroke 1.5pt, add axes baseline/border; `RawLuminanceHistogramView:455-485` same stroke change + axes.

---

### Task 1: FRV line histograms with stats and axes

**Files:**
* Modify: `QuickCull/ImageDisplayView.swift:333-485` (MetadataHUDView + RawHistogramView + RawLuminanceHistogramView)
* Test: `xcodebuild build` + `xcodebuild test -scheme QuickCullCore` + manual QA

**Interfaces:**
* Consumes: `RawHistogram` (`bins [[Int]] 3×256`, `luminance [Int] 256`, `clipping [Double] 4`, `samples [Int] 4`, `binCount 256`), `RawHistogramView(histogram:)` / `RawLuminanceHistogramView(histogram:)`, `MetadataHUDView` `histogram` state and `.task` loading.
* Produces: Two stacked 72pt line histograms with stats rows and faint axes, same log-y and clipping marker, build/tests green.

- [ ] **Step 1: Verify current filled histograms**

Run: `grep -n "ctx.fill\|ctx.stroke\|RawHistogramView\|RawLuminanceHistogramView\|accessibilityLabel" QuickCull/ImageDisplayView.swift | head -30`
Expected: `ctx.fill(path, with:.color(colors[channel]))` at ~440 and `ctx.fill(path, with:.color(.white.opacity(0.85)))` at ~475, no `ctx.stroke` for histogram lines, no stats `HStack` with `R:`.

- [ ] **Step 2: Update MetadataHUDView to add stats rows**

Edit `QuickCull/ImageDisplayView.swift:333-390` — replace `if let hist` block with:

```swift
if let hist = histogram {
    VStack(spacing: 8) {
        VStack(spacing: 2) {
            let rClip = String(format: "%.1f%%", hist.clipping[0] * 100)
            let gClip = String(format: "%.1f%%", hist.clipping[1] * 100)
            let bClip = String(format: "%.1f%%", hist.clipping[2] * 100)
            let totalR = hist.samples[0], totalG = hist.samples[1], totalB = hist.samples[2]
            let meanR: Double = totalR > 0 ? Double(hist.bins[0].enumerated().map{ $0.element * $0.offset }.reduce(0,+)) / Double(totalR) : 0
            let meanG: Double = totalG > 0 ? Double(hist.bins[1].enumerated().map{ $0.element * $0.offset }.reduce(0,+)) / Double(totalG) : 0
            let meanB: Double = totalB > 0 ? Double(hist.bins[2].enumerated().map{ $0.element * $0.offset }.reduce(0,+)) / Double(totalB) : 0
            let mean = Int((meanR + meanG + meanB) / 3 + 0.5)
            HStack {
                Text("R:\(rClip) G:\(gClip) B:\(bClip)")
                Spacer()
                Text("Mean \(mean)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
            RawHistogramView(histogram: hist)
                .frame(height: 72)
        }
        VStack(spacing: 2) {
            let lClip = String(format: "%.1f%%", hist.clipping.count > 3 ? hist.clipping[3]*100 : 0)
            let totalL = hist.samples.count > 3 ? hist.samples[3] : hist.luminance.reduce(0,+)
            let meanL: Int = {
                guard totalL > 0 else { return 0 }
                let sum = hist.luminance.enumerated().map{ $0.element * $0.offset }.reduce(0,+)
                return Int(Double(sum)/Double(totalL) + 0.5)
            }()
            HStack {
                Text("Luma \(lClip)")
                Spacer()
                Text("Mean \(meanL)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
            RawLuminanceHistogramView(histogram: hist)
                .frame(height: 72)
        }
    }
    .padding(.horizontal, 10)
    .padding(.top, 8)
}
```

Keep outer `ScrollView`/`VStack(alignment:.leading, spacing:6)` and `ForEach(rows...)` below. Preserve `.task` with `histogram=nil`.

Note: `hist.bins[channel].enumerated().map{ $0.element * $0.offset }` is `count * bin`; alternative `zip(0..<256, bins[channel])` same. Use either but keep formula `Σ(bin*count)/total`.

- [ ] **Step 3: Convert RawHistogramView from filled to thin lines + axes**

Edit `QuickCull/ImageDisplayView.swift:393-453` — replace `RawHistogramView` `body` Canvas block with:

```swift
private struct RawHistogramView: View {
    let histogram: RawHistogram
    var body: some View {
        Canvas { ctx, size in
            let binCount = RawHistogram.binCount
            guard size.width > 0, size.height > 0 else { return }
            let rawMax = histogram.bins.flatMap{ $0 }.map{ log10(Double($0)+1) }.max() ?? 0
            let logMax = rawMax > 0 ? rawMax : 1
            func yFor(_ count: Int) -> Double { size.height * (1 - log10(Double(count)+1)/logMax) }
            let binW = size.width / Double(binCount)
            // faint axes/baseline
            var axes = Path()
            axes.move(to: CGPoint(x: 0, y: size.height))
            axes.addLine(to: CGPoint(x: size.width, y: size.height))
            axes.move(to: CGPoint(x: 0, y: 0))
            axes.addLine(to: CGPoint(x: 0, y: size.height))
            ctx.stroke(axes, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
            let colors: [Color] = [.red.opacity(0.9), .green.opacity(0.9), .blue.opacity(0.9)]
            for channel in 0..<3 {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: yFor(histogram.bins[channel][0])))
                for bin in 1..<binCount {
                    let x = Double(bin) * binW
                    let y = yFor(histogram.bins[channel][bin])
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                ctx.stroke(path, with: .color(colors[channel]), lineWidth: 1.5)
            }
            if histogram.clipping.prefix(3).contains(where: { $0 > 0.001 }) {
                var line = Path()
                line.move(to: CGPoint(x: size.width - 1, y: 0))
                line.addLine(to: CGPoint(x: size.width - 1, y: size.height))
                ctx.stroke(line, with: .color(.white), lineWidth: 1)
            }
        }
        .background(.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("RAW histogram")
    }
}
```

Key changes vs old: `ctx.fill` → `ctx.stroke` 1.5pt, `move` starts at `yFor(bins[0])` not `height`, no `closeSubpath`, axes added, lineWidth 1.5, opacity 0.9.

- [ ] **Step 4: Convert RawLuminanceHistogramView similarly**

Edit `QuickCull/ImageDisplayView.swift:455-485` — replace with:

```swift
private struct RawLuminanceHistogramView: View {
    let histogram: RawHistogram
    var body: some View {
        Canvas { ctx, size in
            let binCount = RawHistogram.binCount
            guard size.width > 0, size.height > 0 else { return }
            let rawMax = histogram.luminance.map{ log10(Double($0)+1) }.max() ?? 0
            let logMax = rawMax > 0 ? rawMax : 1
            func yFor(_ count: Int) -> Double { size.height * (1 - log10(Double(count)+1)/logMax) }
            let binW = size.width / Double(binCount)
            var axes = Path()
            axes.move(to: CGPoint(x: 0, y: size.height))
            axes.addLine(to: CGPoint(x: size.width, y: size.height))
            axes.move(to: CGPoint(x: 0, y: 0))
            axes.addLine(to: CGPoint(x: 0, y: size.height))
            ctx.stroke(axes, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: yFor(histogram.luminance[0])))
            for bin in 1..<binCount {
                let x = Double(bin) * binW
                let y = yFor(histogram.luminance[bin])
                path.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
            if histogram.clipping.count > 3 && histogram.clipping[3] > 0.001 {
                var line = Path()
                line.move(to: CGPoint(x: size.width - 1, y: 0))
                line.addLine(to: CGPoint(x: size.width - 1, y: size.height))
                ctx.stroke(line, with: .color(.white), lineWidth: 1)
            }
        }
        .background(.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("Luminance histogram")
    }
}
```

- [ ] **Step 5: Build the app**

Run: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -destination 'platform=macOS' -quiet build 2>&1 | tail -20`
Expected: PASS (warnings pre-existing only).

- [ ] **Step 6: Run full QuickCullCore test suite**

Run: `xcodebuild test -project QuickCull.xcodeproj -scheme QuickCullCore -destination 'platform=macOS' 2>&1 | grep -E "Executed|PASS|FAIL" | tail -20`
Expected: PASS — `Executed 134 tests, 0 failures`.

- [ ] **Step 7: Manual QA**

Run: `./start.sh` → import `QuickCullCoreTests/Fixtures/raws/` + one `JPEG`:
* HUD shows two 72pt **line** histograms (thin red/green/blue + white) with faint baseline/border, not filled. Log-y preserved.
* Flat grey 128 → `R:0.0% G:0.0% B:0.0% Mean 128` / `Luma 0.0% Mean 128`, single spike at 128, no marker.
* Clipped `olympus_c5050z` → per-channel clipping % >0.001 shows white right-edge marker in both panels where relevant, mean ~90-120.
* Rapid scrub → both panels + stats update together, no stale flash.
* All-black/uniform image → mean 0 / 128, no divide-by-zero, line flat at bottom/top.

- [ ] **Step 8: Commit**

```bash
git add QuickCull/ImageDisplayView.swift
git commit -m "feat: FastRawViewer-style line histograms with axes and clipping % + mean"
```

---

## Self-Review

**Spec coverage:**
* Thin lines 1.5pt 0.9 opacity per channel + white luma, log-y, faint axes 0.15, clipping marker 1px at 255, background black 0.3 RoundedRectangle — Task 1 Steps 3-4.
* Stats rows R/G/B clipping % + mean + luma clipping/mean caption2 secondary — Task 1 Step 2.
* Stacked 72pt panels with VStack spacing 8 outer + 2 inner, padding 10/8 — Task 1 Step 2.
* Build + 134 tests green, manual QA line/stats/marker — Steps 5-7.

**Placeholder scan:** No TBD/TODO; every step has concrete Swift code with exact `lineWidth:1.5`, `opacity(0.9)`, `String(format:"%.1f%%")`, `mean` formula `Σ(bin*count)/total`, `xcodebuild` commands.

**Type consistency:** `RawHistogram.bins [[Int]] 3×256`, `luminance [Int] 256`, `clipping [Double] 4`, `samples [Int] 4`, `binCount 256` used identically in Steps 2-4; `RawHistogramView(histogram: RawHistogram)` / `RawLuminanceHistogramView(histogram: RawHistogram)` signatures match `MetadataHUDView` calls `RawHistogramView(histogram: hist)`; `clip*100` and `mean` Int conversions match spec.

