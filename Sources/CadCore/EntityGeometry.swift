import Foundation

// MARK: - Curve tessellation helpers

public func ellipsePoints(_ e: EllipseGeom, segments: Int = 96) -> [Vec2] {
    let sweep = ccwSweep(from: e.startParam, to: e.endParam)
    let n = max(4, Int(Double(segments) * sweep / (2 * .pi)))
    return (0...n).map { e.point(at: e.startParam + sweep * Double($0) / Double(n)) }
}

/// Evaluates a spline: B-spline from control points (with knots when valid), or
/// a Catmull-Rom curve through fit points.
public func splinePoints(_ s: SplineGeom, segmentsPerSpan: Int = 16) -> [Vec2] {
    if !s.controlPoints.isEmpty {
        let cps = s.controlPoints
        let p = max(1, min(s.degree, cps.count - 1))
        var knots = s.knots
        if knots.count != cps.count + p + 1 {
            // Clamped uniform knot vector.
            let inner = cps.count - p - 1
            knots = Array(repeating: 0, count: p + 1)
            if inner > 0 { for i in 1...inner { knots.append(Double(i) / Double(inner + 1)) } }
            knots += Array(repeating: 1, count: p + 1)
        }
        let t0 = knots[p], t1 = knots[cps.count]
        let n = max(8, segmentsPerSpan * (cps.count - p))
        return (0...n).map { i in
            let t = t0 + (t1 - t0) * Double(i) / Double(n)
            return deBoor(t: min(t, t1 - 1e-12 * max(1, abs(t1))), degree: p, knots: knots, cps: cps)
        }
    }
    let pts = s.fitPoints
    guard pts.count > 2 else { return pts }
    var out: [Vec2] = []
    let closed = s.closed
    let count = closed ? pts.count : pts.count - 1
    for i in 0..<count {
        let p0 = pts[closed ? (i - 1 + pts.count) % pts.count : max(0, i - 1)]
        let p1 = pts[i]
        let p2 = pts[(i + 1) % pts.count]
        let p3 = pts[closed ? (i + 2) % pts.count : min(pts.count - 1, i + 2)]
        for k in 0..<segmentsPerSpan {
            let t = Double(k) / Double(segmentsPerSpan)
            let t2 = t * t, t3 = t2 * t
            let a = p1 * 2
            let b = (p2 - p0) * t
            let c = (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2
            let d = (p1 * 3 - p0 - p2 * 3 + p3) * t3
            out.append((a + b + c + d) * 0.5)
        }
    }
    out.append(closed ? pts[0] : pts[pts.count - 1])
    return out
}

private func deBoor(t: Double, degree p: Int, knots: [Double], cps: [Vec2]) -> Vec2 {
    var k = p
    while k < cps.count - 1 && t >= knots[k + 1] { k += 1 }
    var d = (0...p).map { cps[max(0, min(cps.count - 1, $0 + k - p))] }
    if p == 0 { return d[0] }
    for r in 1...p {
        for j in stride(from: p, through: r, by: -1) {
            let i = j + k - p
            let denom = knots[i + p - r + 1] - knots[i]
            let alpha = denom.magnitude < 1e-15 ? 0 : (t - knots[i]) / denom
            d[j] = d[j - 1] * (1 - alpha) + d[j] * alpha
        }
    }
    return d[p]
}

func polylinePrims(_ verts: [PolyVertex], closed: Bool) -> [Prim] {
    guard verts.count >= 2 else { return [] }
    var out: [Prim] = []
    let n = closed ? verts.count : verts.count - 1
    for i in 0..<n {
        let a = verts[i], b = verts[(i + 1) % verts.count]
        if a.point.isClose(to: b.point, tol: 1e-12) { continue }
        out.append(bulgeSegment(a.point, b.point, bulge: a.bulge))
    }
    return out
}

/// Points along a closed loop in vertex order (arcs tessellated in their travel direction).
public func loopPoints(_ loop: [PolyVertex], closed: Bool = true, maxAngleStep: Double = .pi / 36) -> [Vec2] {
    let pts = polylinePieces(loop, closed: closed).flatMap { Array($0.tessellate(maxAngleStep: maxAngleStep).dropLast()) }
    if !closed, let last = loop.last { return pts + [last.point] }
    return pts
}

func pointsToSegs(_ pts: [Vec2]) -> [Prim] {
    guard pts.count >= 2 else { return [] }
    return (0..<(pts.count - 1)).map { .seg(pts[$0], pts[$0 + 1]) }
}

// MARK: - Text metrics (approximate, font-independent)

public let textWidthFactor = 0.62
public let textLineSpacing = 1.6

/// Corners of the text's approximate bounding rectangle in world coordinates.
public func textCorners(_ t: TextGeom) -> [Vec2] {
    let lines = t.lines
    let maxChars = Double(lines.map { $0.count }.max() ?? 0)
    var w = maxChars * t.height * textWidthFactor
    if t.isMultiline && t.width > 0 { w = min(max(w, t.height), t.width) }
    let h = t.height * (Double(lines.count - 1) * textLineSpacing + 1)
    // Local box relative to the insertion point (before rotation).
    var x0 = 0.0
    switch t.hAlign {
    case .left: x0 = 0
    case .center: x0 = -w / 2
    case .right: x0 = -w
    }
    var y0: Double
    if t.isMultiline {
        switch t.vAlign {
        case .top, .baseline: y0 = -h
        case .middle: y0 = -h / 2
        case .bottom: y0 = 0
        }
    } else {
        switch t.vAlign {
        case .baseline: y0 = -(h - t.height)
        case .bottom: y0 = -(h - t.height) + t.height * 0.25
        case .middle: y0 = -(h - t.height) - t.height / 2
        case .top: y0 = -(h - t.height) - t.height
        }
    }
    let local = [Vec2(x0, y0), Vec2(x0 + w, y0), Vec2(x0 + w, y0 + h), Vec2(x0, y0 + h)]
    return local.map { $0.rotated(by: t.rotation) + t.position }
}

// MARK: - Dimension graphics

public struct DimensionGraphics {
    public var prims: [Prim] = []
    public var arrows: [[Vec2]] = []
    public var text: TextGeom
}

public func dimensionGraphics(_ d: DimensionGeom, style st: DimStyle) -> DimensionGraphics {
    let s = st.scale
    let arrow = st.arrowSize * s
    let th = st.textHeight * s
    let gap = st.textGap * s
    var label = st.format(d.measurement, kind: d.kind)
    if !d.textOverride.isEmpty { label = d.textOverride.replacingOccurrences(of: "<>", with: label) }

    func arrowHead(tip: Vec2, dir: Vec2) -> [Vec2] {
        let u = dir.normalized
        let n = u.perp * (arrow / 6)
        let base = tip - u * arrow
        return [tip, base + n, base - n]
    }

    var g = DimensionGraphics(text: TextGeom(position: .zero, height: th, text: label, hAlign: .center, vAlign: .bottom))
    switch d.kind {
    case .linear, .aligned:
        let dir: Vec2 = d.kind == .aligned ? (d.p2 - d.p1).normalized : .polar(1, d.rotation)
        guard dir.length > 0 else { return g }
        let n = dir.perp
        // Dimension line positions: project measured points onto the line through p3.
        let off1 = (d.p3 - d.p1).dot(n)
        let off2 = (d.p3 - d.p2).dot(n)
        let a = d.p1 + n * off1
        let b = d.p2 + n * off2
        // Extension lines.
        func ext(_ from: Vec2, _ to: Vec2) {
            let v = to - from
            let l = v.length
            guard l > st.extensionOffset * s else { return }
            let u = v / l
            g.prims.append(.seg(from + u * (st.extensionOffset * s), to + u * (st.extensionExtend * s)))
        }
        ext(d.p1, a)
        ext(d.p2, b)
        g.prims.append(.seg(a, b))
        let ab = b - a
        if ab.length > 1e-12 {
            g.arrows.append(arrowHead(tip: a, dir: -ab))
            g.arrows.append(arrowHead(tip: b, dir: ab))
        }
        var ang = dir.angle
        if cos(ang) < -1e-9 || (abs(cos(ang)) < 1e-9 && sin(ang) < 0) { ang += .pi }
        let up = Vec2.polar(1, ang).perp
        g.text.position = (a + b) / 2 + up * gap
        g.text.rotation = normalizeAngle(ang)
    case .radius, .diameter:
        let c = d.p1
        let r = d.p1.distance(to: d.p2)
        let u = (d.p3 - c).normalized == .zero ? (d.p2 - c).normalized : (d.p3 - c).normalized
        let onCurve = c + u * r
        let start = d.kind == .diameter ? c - u * r : c
        let outside = d.p3.distance(to: c) > r
        let endPt = outside ? d.p3 : onCurve
        g.prims.append(.seg(start, endPt))
        g.arrows.append(arrowHead(tip: onCurve, dir: outside ? -u : u))
        if d.kind == .diameter { g.arrows.append(arrowHead(tip: start, dir: -u)) }
        var ang = u.angle
        if cos(ang) < -1e-9 { ang += .pi }
        g.text.rotation = normalizeAngle(ang)
        g.text.position = (outside ? d.p3 : (start + onCurve) / 2) + Vec2.polar(1, ang).perp * gap
    case .angular:
        let c = d.p1
        let r = c.distance(to: d.p3)
        var a1 = (d.p2 - c).angle, a2 = (d.p4 - c).angle
        // Use the arc between the legs that contains p3.
        let a3 = (d.p3 - c).angle
        if !angleOnArc(a3, start: a1, end: a2) { swap(&a1, &a2) }
        let sweep = ccwSweep(from: a1, to: a2)
        g.prims.append(.arc(center: c, radius: r, start: a1, sweep: sweep))
        for (leg, ang) in [(d.p2, a1), (d.p4, a2)] {
            let legLen = leg.distance(to: c)
            let target = c + .polar(r, ang)
            if legLen < r { g.prims.append(.seg(c + .polar(legLen + st.extensionOffset * s, ang), target + .polar(st.extensionExtend * s, ang))) }
        }
        let p1 = c + .polar(r, a1), p2 = c + .polar(r, a1 + sweep)
        g.arrows.append(arrowHead(tip: p1, dir: Vec2.polar(1, a1).perp * -1))
        g.arrows.append(arrowHead(tip: p2, dir: Vec2.polar(1, a1 + sweep).perp))
        let mid = a1 + sweep / 2
        g.text.position = c + .polar(r + gap, mid)
        var rot = mid - .pi / 2
        if cos(rot) < -1e-9 { rot += .pi }
        g.text.rotation = normalizeAngle(rot)
    }
    return g
}

// MARK: - Hatch pattern lines

/// Clips a family of parallel lines to the hatch loops (even-odd rule).
public func hatchPatternLines(_ h: HatchGeom) -> [Prim] {
    let polys = h.loops.map { loopPoints($0) }
    let edges: [(Vec2, Vec2)] = polys.flatMap { pts in pts.indices.map { (pts[$0], pts[($0 + 1) % pts.count]) } }
    guard !edges.isEmpty, h.spacing > 0 else { return [] }
    let box = BBox(points: polys.flatMap { $0 })
    var out: [Prim] = []
    let angles = h.pattern == .cross ? [h.angle, h.angle + .pi / 2] : [h.angle]
    for ang in angles {
        let dir = Vec2.polar(1, ang), nrm = dir.perp
        let corners = box.corners
        let offs = corners.map { $0.dot(nrm) }
        let along = corners.map { $0.dot(dir) }
        guard let oMin = offs.min(), let oMax = offs.max(), let aMin = along.min(), let aMax = along.max() else { continue }
        let count = Int((oMax - oMin) / h.spacing)
        if count > 5000 { continue }
        var o = (oMin / h.spacing).rounded(.up) * h.spacing
        while o <= oMax {
            let p1 = nrm * o + dir * (aMin - 1), p2 = nrm * o + dir * (aMax + 1)
            var ts: [Double] = []
            for (e1, e2) in edges {
                if let (t, u, _) = lineLineIntersection(p1, p2, e1, e2), u >= 0, u < 1 { ts.append(t) }
            }
            ts.sort()
            var i = 0
            while i + 1 < ts.count {
                out.append(.seg(p1.lerp(to: p2, ts[i]), p1.lerp(to: p2, ts[i + 1])))
                i += 2
            }
            o += h.spacing
        }
    }
    return out
}

// MARK: - Entity geometry queries

extension Drawing {
    /// World-space curve primitives of an entity (inserts expanded).
    public func prims(of e: Entity) -> [Prim] {
        switch e.kind {
        case .line(let l): return [.seg(l.start, l.end)]
        case .viewport(let v):
            let c = v.frame.corners
            return pointsToSegs(c + [c[0]])
        case .attdef(let a):
            let c = textCorners(a.displayText)
            return pointsToSegs(c + [c[0]])
        case .circle(let c): return [.circle(c.center, c.radius)]
        case .arc(let a): return [.arc(a)]
        case .polyline(let p): return polylinePrims(p.vertices, closed: p.closed)
        case .ellipse(let el): return pointsToSegs(ellipsePoints(el))
        case .spline(let s): return pointsToSegs(splinePoints(s))
        case .point(let p): return [.seg(p.position, p.position)]
        case .text(let t):
            let c = textCorners(t)
            return pointsToSegs(c + [c[0]])
        case .dimension(let d):
            let g = dimensionGraphics(d, style: settings.dimStyle)
            let c = textCorners(g.text)
            return g.prims + pointsToSegs(c + [c[0]])
        case .hatch(let h):
            return h.loops.flatMap { polylinePrims($0, closed: true) }
        case .insert:
            return expandInsert(e).flatMap { prims(of: $0) }
        }
    }

    /// Entities of a block reference in world coordinates, with ByBlock/layer-0 resolved.
    public func expandInsert(_ e: Entity, depth: Int = 0) -> [Entity] {
        guard case .insert(let ins) = e.kind, depth < 16, let block = blocks[ins.blockName] else { return [] }
        let t = ins.transform(basePoint: block.basePoint)
        // Attribute definitions are templates; the insert's own values are drawn instead.
        let attribs = ins.attributes.filter { !$0.isInvisible }.map { a in
            Entity(.text(a.text), layer: a.layer ?? e.layer,
                   color: a.color.map { $0 == .byBlock ? e.color : $0 } ?? e.color,
                   linetype: e.linetype, lineweight: e.lineweight, id: e.id)
        }
        let constant = block.entities.compactMap { c -> Entity? in
            if case .attdef(let a) = c.kind, a.isConstant, !a.isInvisible {
                var tg = a.text; tg.text = a.defaultValue
                var x = Entity(.text(tg), layer: c.layer == "0" ? e.layer : c.layer, color: c.color == .byBlock ? e.color : c.color, id: e.id)
                x = x.transformed(by: t)
                return x
            }
            return nil
        }
        return attribs + constant + block.entities.filter { if case .attdef = $0.kind { return false } else { return true } }.map { child in
            var c = child.transformed(by: t)
            c.id = e.id
            if c.layer == "0" { c.layer = e.layer }
            if c.color == .byBlock { c.color = e.color }
            if c.linetype.caseInsensitiveCompare("ByBlock") == .orderedSame { c.linetype = e.linetype }
            if c.lineweight == -2 { c.lineweight = e.lineweight }
            return c
        }
    }

    public func bbox(of e: Entity) -> BBox {
        switch e.kind {
        case .text(let t): return BBox(points: textCorners(t))
        case .attdef(let a): return BBox(points: textCorners(a.displayText))
        case .insert: return expandInsert(e).reduce(BBox.empty) { $0.union(bbox(of: $1)) }
        default: return prims(of: e).reduce(BBox.empty) { $0.union($1.bbox) }
        }
    }

    /// Distance from `p` to the entity, 0 when inside a filled/text area.
    public func distance(from p: Vec2, to e: Entity) -> Double {
        switch e.kind {
        case .text(let t):
            if pointInPolygon(p, textCorners(t)) { return 0 }
        case .hatch(let h):
            let polys = h.loops.map { loopPoints($0) }
            var inside = false
            for poly in polys where pointInPolygon(p, poly) { inside.toggle() }
            if inside { return 0 }
        case .insert:
            return expandInsert(e).map { distance(from: p, to: $0) }.min() ?? .infinity
        default: break
        }
        return prims(of: e).map { $0.distance(to: p) }.min() ?? .infinity
    }

    /// Window (fully inside) or crossing (touching) selection test.
    public func entity(_ e: Entity, inWindow box: BBox, crossing: Bool) -> Bool {
        let b = bbox(of: e)
        if box.contains(b) { return true }
        guard crossing, b.intersects(box) else { return false }
        if case .insert = e.kind { return expandInsert(e).contains { entity($0, inWindow: box, crossing: true) } }
        return prims(of: e).contains { $0.intersects(box: box) }
    }

    // MARK: Resolved display properties

    public func resolvedColor(_ e: Entity) -> CadColor {
        switch e.color {
        case .byLayer, .byBlock: return layer(named: e.layer)?.color ?? .aci(7)
        default: return e.color
        }
    }
    public func resolvedLinetype(_ e: Entity) -> Linetype? {
        var name = e.linetype
        if name.caseInsensitiveCompare("ByLayer") == .orderedSame || name.caseInsensitiveCompare("ByBlock") == .orderedSame {
            name = layer(named: e.layer)?.linetype ?? "Continuous"
        }
        return linetype(named: name)
    }
    public func resolvedLineweight(_ e: Entity) -> Double {
        if e.lineweight >= 0 { return e.lineweight }
        let lw = layer(named: e.layer)?.lineweight ?? -1
        return lw >= 0 ? lw : 0.25
    }
}

public func pointInPolygon(_ p: Vec2, _ poly: [Vec2]) -> Bool {
    var inside = false
    var j = poly.count - 1
    for i in poly.indices {
        let a = poly[i], b = poly[j]
        if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        j = i
    }
    return inside
}

// MARK: - Transform

extension Entity {
    public func transformed(by t: Transform2D) -> Entity {
        var e = self
        e.kind = kind.transformed(by: t)
        return e
    }
}

extension EntityKind {
    public func transformed(by t: Transform2D) -> EntityKind {
        let s = t.scaleFactor
        let rot = t.rotationAngle
        let mir = t.isMirroring
        func readableRotation(_ r: Double) -> Double {
            let a = t.applyVector(.polar(1, r)).angle
            if !mir { return normalizeAngle(a) }
            return cos(a) < -1e-9 ? normalizeAngle(a + .pi) : normalizeAngle(a)
        }
        switch self {
        case .line(let l):
            return .line(LineGeom(start: t.apply(l.start), end: t.apply(l.end)))
        case .circle(let c):
            if abs(abs(t.a) - abs(t.d)) > 1e-9 || abs(abs(t.b) - abs(t.c)) > 1e-9 {
                let major = t.applyVector(Vec2(c.radius, 0)), minor = t.applyVector(Vec2(0, c.radius))
                let (mj, mn) = major.length >= minor.length ? (major, minor) : (minor, major)
                return .ellipse(EllipseGeom(center: t.apply(c.center), majorAxis: mj, ratio: mn.length / max(mj.length, 1e-12)))
            }
            return .circle(CircleGeom(center: t.apply(c.center), radius: c.radius * s))
        case .arc(let a):
            let c = t.apply(a.center)
            let sp = t.apply(a.startPoint), ep = t.apply(a.endPoint)
            let (s1, e1) = mir ? (ep, sp) : (sp, ep)
            return .arc(ArcGeom(center: c, radius: a.radius * s, startAngle: (s1 - c).angle, endAngle: (e1 - c).angle))
        case .polyline(var p):
            p.vertices = p.vertices.map { PolyVertex(t.apply($0.point), bulge: mir ? -$0.bulge : $0.bulge) }
            p.width *= s
            return .polyline(p)
        case .ellipse(var e):
            e.center = t.apply(e.center)
            e.majorAxis = t.applyVector(e.majorAxis)
            if mir && !e.isFull {
                let (st, en) = (e.startParam, e.endParam)
                e.startParam = normalizeAngle(-en); e.endParam = normalizeAngle(-st)
            }
            return .ellipse(e)
        case .text(var x):
            x.position = t.apply(x.position)
            x.height *= s
            x.width *= s
            x.rotation = readableRotation(x.rotation)
            return .text(x)
        case .point(let p):
            return .point(PointGeom(position: t.apply(p.position)))
        case .dimension(var d):
            d.p1 = t.apply(d.p1); d.p2 = t.apply(d.p2); d.p3 = t.apply(d.p3); d.p4 = t.apply(d.p4)
            d.rotation = normalizeAngle(d.rotation + rot)
            if mir && d.kind == .angular { swap(&d.p2, &d.p4) }
            return .dimension(d)
        case .insert(var i):
            let local = Transform2D.scale(sx: i.scaleX, sy: i.scaleY).then(.rotation(i.rotation))
            let combined = local.then(Transform2D(a: t.a, b: t.b, c: t.c, d: t.d, tx: 0, ty: 0))
            let xAxis = combined.applyVector(Vec2(1, 0)), yAxis = combined.applyVector(Vec2(0, 1))
            i.position = t.apply(i.position)
            i.attributes = i.attributes.map { a in
                var a = a
                if case .text(let tt) = EntityKind.text(a.text).transformed(by: t) { a.text = tt }
                return a
            }
            i.rotation = normalizeAngle(xAxis.angle)
            i.scaleX = xAxis.length
            i.scaleY = (combined.determinant < 0 ? -1 : 1) * yAxis.length
            return .insert(i)
        case .hatch(var h):
            h.loops = h.loops.map { $0.map { PolyVertex(t.apply($0.point), bulge: mir ? -$0.bulge : $0.bulge) } }
            h.angle = normalizeAngle(h.angle + rot)
            h.spacing *= s
            return .hatch(h)
        case .attdef(var a):
            if case .text(let tt) = EntityKind.text(a.text).transformed(by: t) { a.text = tt }
            return .attdef(a)
        case .viewport(var v):
            // Frames stay axis-aligned; the model content scales with the frame.
            let f = BBox(points: v.frame.corners.map(t.apply))
            v.center = f.center
            v.width = f.width
            v.height = f.height
            return .viewport(v)
        case .spline(var sp):
            sp.controlPoints = sp.controlPoints.map(t.apply)
            sp.fitPoints = sp.fitPoints.map(t.apply)
            return .spline(sp)
        }
    }
}

// MARK: - Snap points

public enum SnapKind: String, CaseIterable, Codable {
    case endpoint, midpoint, center, quadrant, intersection, perpendicular, tangent, nearest, node, insertion

    public var label: String {
        switch self {
        case .endpoint: return "Endpoint"
        case .midpoint: return "Midpoint"
        case .center: return "Center"
        case .quadrant: return "Quadrant"
        case .intersection: return "Intersection"
        case .perpendicular: return "Perpendicular"
        case .tangent: return "Tangent"
        case .nearest: return "Nearest"
        case .node: return "Node"
        case .insertion: return "Insertion"
        }
    }
}

public struct SnapPoint: Hashable {
    public var point: Vec2
    public var kind: SnapKind
    public init(_ point: Vec2, _ kind: SnapKind) { self.point = point; self.kind = kind }
}

extension Drawing {
    /// Static object snap points (endpoint, midpoint, center, quadrant, node, insertion).
    public func snapPoints(of e: Entity) -> [SnapPoint] {
        var out: [SnapPoint] = []
        func quads(_ c: Vec2, _ r: Double, _ arc: ArcGeom? = nil) {
            for k in 0..<4 {
                let a = Double(k) * .pi / 2
                if let arc, !angleOnArc(a, start: arc.startAngle, end: arc.endAngle) { continue }
                out.append(SnapPoint(c + .polar(r, a), .quadrant))
            }
        }
        switch e.kind {
        case .line(let l):
            out += [SnapPoint(l.start, .endpoint), SnapPoint(l.end, .endpoint), SnapPoint(l.midpoint, .midpoint)]
        case .circle(let c):
            out.append(SnapPoint(c.center, .center)); quads(c.center, c.radius)
        case .arc(let a):
            out += [SnapPoint(a.startPoint, .endpoint), SnapPoint(a.endPoint, .endpoint),
                    SnapPoint(a.midPoint, .midpoint), SnapPoint(a.center, .center)]
            quads(a.center, a.radius, a)
        case .polyline(let p):
            for v in p.vertices { out.append(SnapPoint(v.point, .endpoint)) }
            for prim in polylinePrims(p.vertices, closed: p.closed) {
                out.append(SnapPoint(prim.midPoint, .midpoint))
                if case let .arc(c, _, _, _) = prim { out.append(SnapPoint(c, .center)) }
            }
        case .ellipse(let el):
            out.append(SnapPoint(el.center, .center))
            if el.isFull {
                for t in [0, Double.pi / 2, .pi, 3 * .pi / 2] { out.append(SnapPoint(el.point(at: t), .quadrant)) }
            } else {
                out += [SnapPoint(el.point(at: el.startParam), .endpoint), SnapPoint(el.point(at: el.endParam), .endpoint)]
            }
        case .spline(let s):
            let pts = splinePoints(s)
            if let f = pts.first, let l = pts.last { out += [SnapPoint(f, .endpoint), SnapPoint(l, .endpoint)] }
            for p in s.fitPoints { out.append(SnapPoint(p, .node)) }
        case .point(let p):
            out.append(SnapPoint(p.position, .node))
        case .text(let t):
            out.append(SnapPoint(t.position, .insertion))
        case .dimension(let d):
            out += [SnapPoint(d.p1, .node), SnapPoint(d.p2, .node)]
        case .insert(let i):
            out.append(SnapPoint(i.position, .insertion))
            for c in expandInsert(e) { out += snapPoints(of: c).filter { $0.kind != .insertion } }
        case .hatch:
            break
        case .attdef(let a):
            out.append(SnapPoint(a.text.position, .insertion))
        case .viewport(let v):
            let c = v.frame.corners
            for i in 0..<4 {
                out.append(SnapPoint(c[i], .endpoint))
                out.append(SnapPoint((c[i] + c[(i + 1) % 4]) / 2, .midpoint))
            }
        }
        return out
    }
}

// MARK: - Grips

extension Drawing {
    public func grips(of e: Entity) -> [Vec2] {
        switch e.kind {
        case .line(let l): return [l.start, l.midpoint, l.end]
        case .circle(let c): return [c.center] + (0..<4).map { c.center + .polar(c.radius, Double($0) * .pi / 2) }
        case .arc(let a): return [a.startPoint, a.midPoint, a.endPoint, a.center]
        case .polyline(let p): return p.vertices.map(\.point)
        case .ellipse(let el):
            return [el.center, el.center + el.majorAxis, el.center - el.majorAxis, el.center + el.minorAxis, el.center - el.minorAxis]
        case .spline(let s): return s.fitPoints.isEmpty ? s.controlPoints : s.fitPoints
        case .viewport(let v): return v.frame.corners + [v.center]
        case .attdef(let a): return [a.text.position]
        case .point(let p): return [p.position]
        case .text(let t): return [t.position]
        case .dimension(let d):
            return d.kind == .angular ? [d.p1, d.p2, d.p4, d.p3] : [d.p1, d.p2, d.p3]
        case .insert(let i): return [i.position]
        case .hatch(let h): return h.loops.first.map { $0.map(\.point) } ?? []
        }
    }

    /// Returns the entity after dragging grip `index` to `p`.
    public func applyGrip(_ e: Entity, index: Int, to p: Vec2) -> Entity {
        let g = grips(of: e)
        guard index < g.count else { return e }
        let delta = p - g[index]
        var out = e
        switch e.kind {
        case .line(var l):
            switch index {
            case 0: l.start = p
            case 2: l.end = p
            default: l.start += delta; l.end += delta
            }
            out.kind = .line(l)
        case .circle(var c):
            if index == 0 { c.center = p } else { c.radius = max(1e-9, p.distance(to: c.center)) }
            out.kind = .circle(c)
        case .arc(let a):
            if index == 3 {
                out.kind = .arc(ArcGeom(center: p, radius: a.radius, startAngle: a.startAngle, endAngle: a.endAngle))
            } else {
                var pts = [a.startPoint, a.midPoint, a.endPoint]
                pts[index] = p
                if let n = ArcGeom.through(pts[0], pts[1], pts[2]) { out.kind = .arc(n) }
            }
        case .polyline(var pl):
            pl.vertices[index].point = p
            out.kind = .polyline(pl)
        case .ellipse(var el):
            switch index {
            case 0: el.center = p
            case 1, 2:
                let minorLen = el.minorAxis.length
                el.majorAxis = index == 1 ? p - el.center : el.center - p
                el.ratio = minorLen / max(el.majorAxis.length, 1e-12)
            default:
                el.ratio = p.distance(to: el.center) / max(el.majorAxis.length, 1e-12)
            }
            if el.ratio > 1 { el.majorAxis = el.majorAxis.perp * el.ratio; el.ratio = 1 / el.ratio }
            out.kind = .ellipse(el)
        case .attdef(var a):
            a.text.position = p
            out.kind = .attdef(a)
        case .viewport(var v):
            if index == 4 {
                v.center = p
            } else {
                // Drag a corner; the opposite corner stays, the view scale is kept.
                let opposite = v.frame.corners[(index + 2) % 4]
                let f = BBox(corner: opposite, p)
                let s = v.scale
                let shift = (f.center - v.center) / s
                v.center = f.center; v.width = max(f.width, 1e-6); v.height = max(f.height, 1e-6)
                v.viewCenter += shift
                v.scale = s
            }
            out.kind = .viewport(v)
        case .spline(var s):
            if s.fitPoints.isEmpty { s.controlPoints[index] = p } else { s.fitPoints[index] = p }
            out.kind = .spline(s)
        case .point:
            out.kind = .point(PointGeom(position: p))
        case .text(var t):
            t.position = p
            out.kind = .text(t)
        case .dimension(var d):
            if d.kind == .angular {
                switch index { case 0: d.p1 = p; case 1: d.p2 = p; case 2: d.p4 = p; default: d.p3 = p }
            } else {
                switch index { case 0: d.p1 = p; case 1: d.p2 = p; default: d.p3 = p }
            }
            out.kind = .dimension(d)
        case .insert(var i):
            i.position = p
            out.kind = .insert(i)
        case .hatch(var h):
            h.loops[0][index].point = p
            out.kind = .hatch(h)
        }
        return out
    }
}

extension AttDefGeom {
    /// What is drawn for a definition: its tag (AutoCAD shows tags outside the block).
    public var displayText: TextGeom {
        var t = text
        t.text = tag.isEmpty ? "ATTDEF" : tag
        return t
    }
}
