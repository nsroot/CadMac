import AppKit
import CadCore

/// Maps world coordinates (y up) to view coordinates (non-flipped NSView, y up).
struct ViewTransform {
    var center = Vec2(210, 148)
    var scale: Double = 2       // pixels per drawing unit
    var size = CGSize(width: 800, height: 600)

    func toView(_ p: Vec2) -> CGPoint {
        CGPoint(x: (p.x - center.x) * scale + size.width / 2, y: (p.y - center.y) * scale + size.height / 2)
    }
    func toWorld(_ p: CGPoint) -> Vec2 {
        Vec2((p.x - size.width / 2) / scale + center.x, (p.y - size.height / 2) / scale + center.y)
    }
    var visibleBox: BBox {
        BBox(corner: toWorld(.zero), toWorld(CGPoint(x: size.width, y: size.height)))
    }

    mutating func zoom(by factor: Double, at viewPoint: CGPoint) {
        let anchor = toWorld(viewPoint)
        scale = min(max(scale * factor, 1e-6), 1e7)
        let after = toWorld(viewPoint)
        center += anchor - after
    }

    mutating func zoomToFit(_ box: BBox, margin: Double = 0.06) {
        guard !box.isEmpty else { return }
        let w = max(box.width, 1e-6), h = max(box.height, 1e-6)
        scale = min(size.width / w, size.height / h) * (1 - 2 * margin)
        center = box.center
    }
}

struct RenderStyle {
    var darkBackground = true
    var showLineweights = false
    /// Print/plot mode: ACI 7 is black, all colors kept (or monochrome).
    var monochrome = false
    /// Overrides the dark/light default when set from Preferences.
    var customBackground: CGColor? = nil
    var background: CGColor {
        if let c = customBackground { return c }
        return darkBackground ? CGColor(red: 0.13, green: 0.157, blue: 0.188, alpha: 1) : .white
    }
}

/// Draws drawing entities into a CGContext.
struct Renderer {
    let drawing: Drawing
    let vt: ViewTransform
    let ctx: CGContext
    var style = RenderStyle()

    // MARK: Colors

    func cgColor(_ c: CadColor, alpha: CGFloat = 1) -> CGColor {
        if style.monochrome { return CGColor(gray: 0, alpha: alpha) }
        let rgb = c.rgb(darkBackground: style.darkBackground)
        return CGColor(red: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: alpha)
    }

    func entityColor(_ e: Entity) -> CGColor { cgColor(drawing.resolvedColor(e)) }

    // MARK: Entities

    func drawAll(_ entities: [Entity]? = nil, skip: Set<EntityID> = []) {
        let vis = vt.visibleBox
        for e in entities ?? drawing.entities where !skip.contains(e.id) {
            guard drawing.isVisible(e) else { continue }
            if !drawing.bbox(of: e).expanded(by: 1 / vt.scale).intersects(vis) { continue }
            draw(e)
        }
    }

    /// Draws an entity. `override` replaces its color; `extraWidth` thickens strokes (highlight).
    func draw(_ e: Entity, override: CGColor? = nil, extraWidth: CGFloat = 0, dashed: Bool = false) {
        let color = override ?? entityColor(e)
        var width: CGFloat = 1
        if style.showLineweights { width = max(1, CGFloat(drawing.resolvedLineweight(e)) * 3.78) }
        width += extraWidth
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if dashed {
            ctx.setLineDash(phase: 0, lengths: [6, 4])
        } else {
            applyLinetype(e)
        }
        defer { ctx.setLineDash(phase: 0, lengths: []) }

        switch e.kind {
        case .text(let t):
            drawText(t, color: color)
        case .point(let p):
            let c = vt.toView(p.position)
            let r: CGFloat = 3
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.fillEllipse(in: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3))
            ctx.move(to: CGPoint(x: c.x - r, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + r, y: c.y))
            ctx.move(to: CGPoint(x: c.x, y: c.y - r)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + r))
            ctx.strokePath()
        case .dimension(let d):
            let g = dimensionGraphics(d, style: drawing.settings.dimStyle)
            ctx.setLineDash(phase: 0, lengths: [])
            stroke(g.prims)
            for tri in g.arrows {
                ctx.beginPath()
                ctx.addLines(between: tri.map(vt.toView))
                ctx.closePath()
                ctx.fillPath()
            }
            drawText(g.text, color: color)
        case .hatch(let h):
            let path = CGMutablePath()
            for loop in h.loops { addLoop(loop, to: path) }
            if h.pattern == .solid {
                ctx.addPath(path)
                ctx.setFillColor(override?.copy(alpha: 0.6) ?? color)
                ctx.fillPath(using: .evenOdd)
            } else {
                let lines = hatchPatternLines(h)
                // Avoid drawing absurdly dense patterns.
                if h.spacing * vt.scale >= 2 {
                    ctx.setLineDash(phase: 0, lengths: [])
                    stroke(lines)
                } else {
                    ctx.addPath(path)
                    ctx.setFillColor(color.copy(alpha: 0.35) ?? color)
                    ctx.fillPath(using: .evenOdd)
                }
            }
        case .insert:
            for child in drawing.expandInsert(e) { draw(child, override: override, extraWidth: extraWidth, dashed: dashed) }
        case .polyline(let p) where p.width > 0:
            ctx.setLineWidth(max(width, CGFloat(p.width * vt.scale)))
            ctx.setLineCap(.butt)
            stroke(drawing.prims(of: e))
        default:
            stroke(drawing.prims(of: e))
        }
    }

    func applyLinetype(_ e: Entity) {
        applyPattern(drawing.resolvedLinetype(e), ltScale: drawing.settings.ltScale)
    }

    /// Sets the dash pattern for a linetype at the current zoom (continuous when too dense).
    func applyPattern(_ lt: Linetype?, ltScale: Double) {
        guard let lt, !lt.pattern.isEmpty else {
            ctx.setLineDash(phase: 0, lengths: []); return
        }
        let k = ltScale * vt.scale
        let total = lt.pattern.reduce(0) { $0 + abs($1) } * k
        guard total >= 4, total < 1e6 else { ctx.setLineDash(phase: 0, lengths: []); return }
        var lengths: [CGFloat] = []
        var lastPositive: Bool?
        for v in lt.pattern {
            let on = v >= 0
            let len = v == 0 ? 0.5 : CGFloat(abs(v) * k)
            if lastPositive == on, !lengths.isEmpty { lengths[lengths.count - 1] += len } else { lengths.append(len) }
            lastPositive = on
        }
        if lengths.count % 2 == 1 { lengths.append(lengths.count > 1 ? 0 : lengths[0]) }
        ctx.setLineDash(phase: 0, lengths: lengths)
    }

    // MARK: Scene (fast path)

    var worldToView: CGAffineTransform {
        CGAffineTransform(a: vt.scale, b: 0, c: 0, d: vt.scale,
                          tx: -vt.center.x * vt.scale + vt.size.width / 2, ty: -vt.center.y * vt.scale + vt.size.height / 2)
    }

    /// Adds a world-space path under the view transform; stroke widths stay in screen pixels.
    func addWorldPath(_ p: CGPath, extra: CGAffineTransform = .identity) {
        ctx.saveGState()
        ctx.concatenate(worldToView)
        ctx.concatenate(extra)
        ctx.addPath(p)
        ctx.restoreGState()
    }

    private struct SegKey: Hashable { var a: Int32, b: Int32, c: Int32, d: Int32 }

    /// Adds primitives snapped to a half-pixel grid, skipping duplicates, so dense zoomed-out
    /// geometry produces few edges for the rasterizer.
    func addDecimated(_ prims: [Prim]) {
        var seen = Set<SegKey>()
        let path = CGMutablePath()
        func q(_ p: CGPoint) -> (Int32, Int32) {
            (Int32(clamping: Int((p.x * 2).rounded())), Int32(clamping: Int((p.y * 2).rounded())))
        }
        func seg(_ a: CGPoint, _ b: CGPoint) {
            let qa = q(a), qb = q(b)
            let key = qa <= qb ? SegKey(a: qa.0, b: qa.1, c: qb.0, d: qb.1) : SegKey(a: qb.0, b: qb.1, c: qa.0, d: qa.1)
            guard seen.insert(key).inserted else { return }
            let pa = CGPoint(x: CGFloat(qa.0) / 2, y: CGFloat(qa.1) / 2)
            path.move(to: pa)
            if qa == qb { path.addLine(to: CGPoint(x: pa.x + 0.5, y: pa.y)) } else { path.addLine(to: CGPoint(x: CGFloat(qb.0) / 2, y: CGFloat(qb.1) / 2)) }
        }
        for p in prims {
            switch p {
            case let .seg(a, b):
                seg(vt.toView(a), vt.toView(b))
            case let .arc(c, r, st, sw):
                let rpx = r * vt.scale
                if rpx < 0.75 { let v = vt.toView(c); seg(v, v); continue }
                let n = max(2, min(96, Int((sw * rpx / 3).rounded(.up))))
                var prev = vt.toView(c + .polar(r, st))
                for k in 1...n {
                    let cur = vt.toView(c + .polar(r, st + sw * Double(k) / Double(n)))
                    seg(prev, cur)
                    prev = cur
                }
            }
        }
        ctx.addPath(path)
    }

    func drawScene(_ s: Scene) {
        let vis = vt.visibleBox.expanded(by: 4 / vt.scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for f in s.fills where f.bbox.intersects(vis) {
            ctx.setFillColor(cgColor(f.color))
            if f.bbox.width * vt.scale < 1.5 && f.bbox.height * vt.scale < 1.5 {
                // Sub-pixel fill: a single dot is visually identical and far cheaper.
                let c = vt.toView(f.bbox.center)
                ctx.fill(CGRect(x: c.x - 0.5, y: c.y - 0.5, width: 1, height: 1))
                continue
            }
            addWorldPath(f.path)
            ctx.fillPath(using: .evenOdd)
        }
        for b in s.strokes where b.bbox.intersects(vis) {
            ctx.setStrokeColor(cgColor(b.style.color))
            var w: CGFloat = style.showLineweights ? max(1, CGFloat(b.style.lineweight) * 3.78) : 1
            if b.style.width > 0 {
                w = max(w, CGFloat(b.style.width * vt.scale))
                ctx.setLineCap(.butt)
            } else {
                ctx.setLineCap(.round)
            }
            ctx.setLineWidth(w)
            let pxArea = (b.bbox.width * vt.scale + 1) * (b.bbox.height * vt.scale + 1)
            if Double(b.prims.count) * 6 > pxArea {
                // Too dense to see individual curves: draw a pixel-snapped, de-duplicated version.
                ctx.setLineDash(phase: 0, lengths: [])
                addDecimated(b.prims)
            } else {
                applyPattern(s.linetypes[b.style.linetype], ltScale: s.ltScale)
                addWorldPath(b.path)
            }
            ctx.strokePath()
        }
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineWidth(1)
        for p in s.points where vis.contains(p.point) {
            let c = vt.toView(p.point)
            let col = cgColor(p.color)
            ctx.setFillColor(col); ctx.setStrokeColor(col)
            ctx.fillEllipse(in: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3))
            ctx.move(to: CGPoint(x: c.x - 3, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 3, y: c.y))
            ctx.move(to: CGPoint(x: c.x, y: c.y - 3)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 3))
            ctx.strokePath()
        }
        for t in s.texts where t.bbox.intersects(vis) { drawText(t.text, color: cgColor(t.color)) }
    }

    // MARK: Paths

    func path(for prims: [Prim]) -> CGMutablePath {
        let path = CGMutablePath()
        var last: CGPoint?
        for p in prims {
            let s = vt.toView(p.startPoint)
            if last == nil || hypot(last!.x - s.x, last!.y - s.y) > 0.01 { path.move(to: s) }
            switch p {
            case let .seg(_, b):
                let bb = vt.toView(b)
                if hypot(bb.x - s.x, bb.y - s.y) < 0.01 {
                    // Degenerate (e.g. point marker): draw a dot.
                    path.addLine(to: CGPoint(x: s.x + 0.01, y: s.y))
                } else {
                    path.addLine(to: bb)
                }
            case let .arc(c, r, st, sw):
                path.addArc(center: vt.toView(c), radius: r * vt.scale, startAngle: st, endAngle: st + sw, clockwise: false)
            }
            last = path.currentPoint
        }
        return path
    }

    func stroke(_ prims: [Prim]) {
        guard !prims.isEmpty else { return }
        ctx.addPath(path(for: prims))
        ctx.strokePath()
    }

    func addLoop(_ loop: [PolyVertex], to path: CGMutablePath) {
        guard loop.count >= 2 else { return }
        path.addLines(between: loopPoints(loop).map(vt.toView))
        path.closeSubpath()
    }

    // MARK: Text

    private static let fontCache = NSCache<NSString, CTFont>()

    /// Default text font family, chosen in Preferences (any installed macOS font).
    static var defaultFontFamily = "Helvetica"

    static func font(pixelHeight: CGFloat, family: String = "") -> CTFont {
        // AutoCAD text height is cap height; caps are ~0.72 em. Cache by family + quarter-pixel size.
        let fam = family.isEmpty ? defaultFontFamily : family
        let q = Int(pixelHeight * 4)
        let key = "\(fam)|\(q)" as NSString
        if let f = fontCache.object(forKey: key) { return f }
        let f = CTFontCreateWithName(fam as CFString, CGFloat(q) / 4 / 0.72, nil)
        fontCache.setObject(f, forKey: key)
        return f
    }

    /// Splits text into display lines, wrapping MTEXT to its width.
    func layoutLines(_ t: TextGeom, font: CTFont) -> [String] {
        guard t.isMultiline, t.width > 0 else { return t.lines }
        let maxPx = t.width * vt.scale
        var out: [String] = []
        for para in t.lines {
            var cur = ""
            for word in para.split(separator: " ", omittingEmptySubsequences: false) {
                let candidate = cur.isEmpty ? String(word) : cur + " " + word
                if !cur.isEmpty && textWidth(candidate, font: font) > maxPx {
                    out.append(cur); cur = String(word)
                } else {
                    cur = candidate
                }
            }
            out.append(cur)
        }
        return out
    }

    func textWidth(_ s: String, font: CTFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    func drawText(_ t: TextGeom, color: CGColor) {
        let px = t.height * vt.scale
        guard px >= 1 else { return }
        if px < 3 {
            // Too small to read: draw a greeked bar.
            let c = textCorners(t).map(vt.toView)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.move(to: c[0]); ctx.addLine(to: c[1]); ctx.strokePath()
            return
        }
        let font = Renderer.font(pixelHeight: px, family: t.font)
        let lines = layoutLines(t, font: font)
        let n = Double(lines.count)
        let h = t.height
        let total = h * ((n - 1) * textLineSpacing + 1)
        var firstBaseline: Double
        if t.isMultiline {
            switch t.vAlign {
            case .top, .baseline: firstBaseline = -h
            case .middle: firstBaseline = total / 2 - h
            case .bottom: firstBaseline = total - h
            }
        } else {
            switch t.vAlign {
            case .baseline: firstBaseline = 0
            case .bottom: firstBaseline = 0.25 * h
            case .middle: firstBaseline = -h / 2
            case .top: firstBaseline = -h
            }
        }
        ctx.saveGState()
        let origin = vt.toView(t.position)
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.rotate(by: t.rotation)
        ctx.textMatrix = .identity
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        for (i, s) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            var x: CGFloat = 0
            switch t.hAlign {
            case .left: x = 0
            case .center: x = -w / 2
            case .right: x = -w
            }
            let y = CGFloat((firstBaseline - Double(i) * h * textLineSpacing) * vt.scale)
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }
}
