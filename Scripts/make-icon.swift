import AppKit
import CoreGraphics
import CoreText

// QC app icon generator.
//
// Design: bold typographic "Q" and "C" overlapped horizontally, with the
// intersection of the two letterforms punched out (XOR). The letters read
// clearly at Dock size while the punched lens makes the overlap deliberate.
//
// Output is a 1024x1024 PNG used as the layer artwork of the Icon Composer
// package (AppIcon.icon). macOS composes it over the package's white fill and
// applies the container shape itself, so this must NOT include a background
// or any rounded-rect mask.
//
// Usage:
//   swift Scripts/make-icon.swift <out.png> [glyph]   # glyph = transparent bg
//   swift Scripts/make-icon.swift <out.png>           # flat  = white bg

let canvas: CGFloat = 1024

// ---- monogram parameters ----
let weight: NSFont.Weight = .heavy
let kernRatio: CGFloat = 0.18     // fraction of font size the letters overlap
let contentScale: CGFloat = 0.70  // monogram width relative to the canvas
// -----------------------------

let glyphOnly = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "glyph"

let black = NSColor.black
let white = NSColor.white

let ctx = CGContext(
    data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

if !glyphOnly {
    ctx.setFillColor(white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
}

func measure(_ s: NSAttributedString) -> CGRect {
    CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(s), .useGlyphPathBounds)
}
func draw(_ s: NSAttributedString, at origin: CGPoint) {
    ctx.textMatrix = .identity
    ctx.textPosition = origin
    CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
}

/// Per-glyph paths for a single-run string, with in-line positions baked in.
func glyphPaths(_ s: NSAttributedString) -> [CGPath] {
    var out: [CGPath] = []
    let line = CTLineCreateWithAttributedString(s)
    guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return out }
    for run in runs {
        let n = CTRunGetGlyphCount(run)
        guard n > 0 else { continue }
        var glyphs = [CGGlyph](repeating: 0, count: n)
        var positions = [CGPoint](repeating: .zero, count: n)
        CTRunGetGlyphs(run, CFRangeMake(0, n), &glyphs)
        CTRunGetPositions(run, CFRangeMake(0, n), &positions)
        let attrs = CTRunGetAttributes(run) as NSDictionary
        let runFont = attrs[kCTFontAttributeName as String] as! CTFont
        for i in 0..<n {
            guard let p = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
            let m = CGMutablePath()
            m.addPath(p, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
            out.append(m)
        }
    }
    return out
}

// size the font so "QC" comes out at the target width, then center it
let base = NSFont.systemFont(ofSize: 100, weight: weight)
let probe = NSAttributedString(string: "QC", attributes: [.font: base, .kern: -kernRatio * 100])
let size = 100 * (contentScale * canvas) / measure(probe).width
let font = NSFont(descriptor: base.fontDescriptor, size: size)!
let attr = NSAttributedString(string: "QC", attributes: [.font: font, .foregroundColor: black, .kern: -kernRatio * size])
let bounds = measure(attr)
let origin = CGPoint(x: canvas / 2 - bounds.midX, y: canvas / 2 - bounds.midY)

// draw both letters, then punch the intersection of Q and C back out
draw(attr, at: origin)

let paths = glyphPaths(attr)
if paths.count == 2 {
    func moved(_ p: CGPath) -> CGPath {
        let m = CGMutablePath()
        m.addPath(p, transform: CGAffineTransform(translationX: origin.x, y: origin.y))
        return m
    }
    ctx.saveGState()
    ctx.addPath(moved(paths[0]))          // Q
    ctx.clip()
    ctx.setFillColor(white.cgColor)
    ctx.addPath(moved(paths[1]))          // C
    ctx.fillPath()
    ctx.restoreGState()
}

guard let image = ctx.makeImage() else { fatalError() }
try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("ok")
