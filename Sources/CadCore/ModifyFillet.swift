import Foundation

// MARK: - FILLET / CHAMFER

/// Carrier of a fillet operand: infinite line or full circle.
private enum Carrier {
    case line(Vec2, Vec2)          // point, unit direction
    case circle(Vec2, Double)

    func offsets(_ r: Double) -> [Carrier] {
        switch self {
        case let .line(p, d): return [.line(p + d.perp * r, d), .line(p - d.perp * r, d)]
        case let .circle(c, R):
            var out: [Carrier] = [.circle(c, R + r)]
            if abs(R - r) > 1e-9 { out.append(.circle(c, abs(R - r))) }
            return out
        }
    }

    var prim: Prim {
        switch self {
        case let .line(p, d): return .seg(p, p + d)
        case let .circle(c, R): return .circle(c, R)
        }
    }

    func foot(_ p: Vec2) -> Vec2 {
        switch self {
        case let .line(a, d): return a + d * (p - a).dot(d)
        case let .circle(c, R): return c + (p - c).normalized * R
        }
    }
}

extension Drawing {
    /// FILLET between two lines, a line and an arc, or two arcs. Radius 0 makes a sharp corner
    /// by trimming/extending both objects. `pick1`/`pick2` select which side of each object is
    /// kept. Returns the modified entities (same ids) and the new arc (if radius > 0).
    /// When `id1 == id2` and the picks are on adjacent segments of a polyline, that vertex is
    /// filleted (result returned in `modified`).
    public func fillet(_ id1: EntityID, pick1: Vec2, _ id2: EntityID, pick2: Vec2,
                       radius: Double) throws -> (modified: [Entity], added: [Entity]) {
        guard radius >= 0 else { throw ModifyError.invalidValue }
        let e1 = try entityOrThrow(id1), e2 = try entityOrThrow(id2)
        if id1 == id2 {
            guard case .polyline(let p) = e1.kind else { throw ModifyError.cannotFillet }
            guard let v = sharedVertex(p, pick1, pick2) else { throw ModifyError.cannotFillet }
            var out = e1
            out.kind = .polyline(try filletPolylineVertices(p, radius: radius, only: v))
            return ([out], [])
        }
        if case .line(let l1) = e1.kind, case .line(let l2) = e2.kind {
            return try filletLines(e1, l1, pick1, e2, l2, pick2, radius: radius)
        }
        guard let c1 = carrier(of: e1), let c2 = carrier(of: e2) else { throw ModifyError.cannotFillet }

        if radius < 1e-12 {
            let xs = intersections(c1.prim, c2.prim, extendFirst: true, extendSecond: true)
            guard let x = xs.min(by: { $0.distance(to: pick1) + $0.distance(to: pick2) < $1.distance(to: pick1) + $1.distance(to: pick2) })
            else { throw ModifyError.noIntersection }
            return ([try sharpTrim(e1, at: x, pick: pick1), try sharpTrim(e2, at: x, pick: pick2)], [])
        }

        var best: (score: Double, c: Vec2, t1: Vec2, t2: Vec2)?
        for o1 in c1.offsets(radius) {
            for o2 in c2.offsets(radius) {
                for c in intersections(o1.prim, o2.prim, extendFirst: true, extendSecond: true) {
                    let t1 = c1.foot(c), t2 = c2.foot(c)
                    let s = t1.distance(to: pick1) + t2.distance(to: pick2)
                    if s < (best?.score ?? .infinity) { best = (s, c, t1, t2) }
                }
            }
        }
        guard let b = best else { throw ModifyError.radiusTooLarge }
        let (arc, dir1, dir2) = filletArc(center: b.c, radius: radius, t1: b.t1, t2: b.t2)
        let m1 = try tangentTrim(e1, at: b.t1, into: dir1)
        let m2 = try tangentTrim(e2, at: b.t2, into: dir2)
        return ([m1, m2], [e1.duplicate(kind: .arc(arc))])
    }

    /// FILLET > Polyline: fillets every vertex between two straight segments.
    public func filletPolyline(_ id: EntityID, radius: Double) throws -> Entity {
        let e = try entityOrThrow(id)
        guard case .polyline(let p) = e.kind else { throw ModifyError.cannotFillet }
        guard radius >= 0 else { throw ModifyError.invalidValue }
        var out = e
        out.kind = .polyline(try filletPolylineVertices(p, radius: radius, only: nil))
        return out
    }

    /// CHAMFER between two lines with distance d1 on the first and d2 on the second.
    public func chamfer(_ id1: EntityID, pick1: Vec2, _ id2: EntityID, pick2: Vec2,
                        d1: Double, d2: Double) throws -> (modified: [Entity], added: [Entity]) {
        let e1 = try entityOrThrow(id1), e2 = try entityOrThrow(id2)
        guard d1 >= 0, d2 >= 0 else { throw ModifyError.invalidValue }
        guard id1 != id2, case .line(let l1) = e1.kind, case .line(let l2) = e2.kind else { throw ModifyError.cannotChamfer }
        let c = try corner(l1, pick1, l2, pick2)
        let a = c.p + c.u1 * d1, b = c.p + c.u2 * d2
        guard c.reach1 >= d1 - 1e-9, c.reach2 >= d2 - 1e-9 else { throw ModifyError.distanceTooLarge }
        let m1 = e1.withKind(.line(keepFar(l1, c.u1, c.p, newNear: a)))
        let m2 = e2.withKind(.line(keepFar(l2, c.u2, c.p, newNear: b)))
        if d1 < 1e-12 && d2 < 1e-12 { return ([m1, m2], []) }
        return ([m1, m2], [e1.duplicate(kind: .line(LineGeom(start: a, end: b)))])
    }

    // MARK: helpers

    private struct Corner { var p: Vec2; var u1: Vec2; var u2: Vec2; var reach1: Double; var reach2: Double }

    /// Intersection of two lines plus the kept directions (towards the picks).
    private func corner(_ l1: LineGeom, _ pick1: Vec2, _ l2: LineGeom, _ pick2: Vec2) throws -> Corner {
        let d1 = (l1.end - l1.start).normalized, d2 = (l2.end - l2.start).normalized
        guard d1 != .zero, d2 != .zero else { throw ModifyError.cannotFillet }
        guard abs(d1.cross(d2)) > 1e-10, let (_, _, p) = lineLineIntersection(l1.start, l1.end, l2.start, l2.end) else {
            throw ModifyError.parallel
        }
        func side(_ l: LineGeom, _ d: Vec2, _ pick: Vec2) -> (Vec2, Double) {
            var s = (pick - p).dot(d)
            if abs(s) < 1e-12 {
                // Pick at the corner: keep the longer part.
                s = max((l.start - p).dot(d), (l.end - p).dot(d)) >= -min((l.start - p).dot(d), (l.end - p).dot(d)) ? 1 : -1
            }
            let u = s >= 0 ? d : -d
            return (u, max((l.start - p).dot(u), (l.end - p).dot(u)))
        }
        let (u1, r1) = side(l1, d1, pick1), (u2, r2) = side(l2, d2, pick2)
        return Corner(p: p, u1: u1, u2: u2, reach1: r1, reach2: r2)
    }

    /// Keeps the endpoint farthest along `u` and replaces the other one with `newNear`.
    private func keepFar(_ l: LineGeom, _ u: Vec2, _ p: Vec2, newNear: Vec2) -> LineGeom {
        (l.start - p).dot(u) >= (l.end - p).dot(u) ? LineGeom(start: l.start, end: newNear) : LineGeom(start: newNear, end: l.end)
    }

    private func filletLines(_ e1: Entity, _ l1: LineGeom, _ pick1: Vec2, _ e2: Entity, _ l2: LineGeom, _ pick2: Vec2,
                             radius: Double) throws -> (modified: [Entity], added: [Entity]) {
        let c = try corner(l1, pick1, l2, pick2)
        if radius < 1e-12 {
            return ([e1.withKind(.line(keepFar(l1, c.u1, c.p, newNear: c.p))),
                     e2.withKind(.line(keepFar(l2, c.u2, c.p, newNear: c.p)))], [])
        }
        let theta = acos(max(-1, min(1, c.u1.dot(c.u2))))
        guard theta > 1e-9, theta < .pi - 1e-9 else { throw ModifyError.parallel }
        let tl = radius / tan(theta / 2)
        guard c.reach1 >= tl - 1e-9, c.reach2 >= tl - 1e-9 else { throw ModifyError.radiusTooLarge }
        let center = c.p + (c.u1 + c.u2).normalized * (radius / sin(theta / 2))
        let t1 = c.p + c.u1 * tl, t2 = c.p + c.u2 * tl
        let (arc, _, _) = filletArc(center: center, radius: radius, t1: t1, t2: t2)
        return ([e1.withKind(.line(keepFar(l1, c.u1, c.p, newNear: t1))),
                 e2.withKind(.line(keepFar(l2, c.u2, c.p, newNear: t2)))],
                [e1.duplicate(kind: .arc(arc))])
    }

    /// Minor arc between the tangent points plus the travel directions into the arc at each end.
    private func filletArc(center c: Vec2, radius r: Double, t1: Vec2, t2: Vec2) -> (ArcGeom, Vec2, Vec2) {
        let a1 = (t1 - c).angle, a2 = (t2 - c).angle
        let ccw = ccwSweep(from: a1, to: a2) <= .pi
        let k1 = Vec2.polar(1, a1).perp, k2 = Vec2.polar(1, a2).perp
        if ccw {
            return (ArcGeom(center: c, radius: r, startAngle: a1, endAngle: a2), k1, -k2)
        }
        return (ArcGeom(center: c, radius: r, startAngle: a2, endAngle: a1), -k1, k2)
    }

    private func carrier(of e: Entity) -> Carrier? {
        switch e.kind {
        case .line(let l):
            let d = (l.end - l.start).normalized
            return d == .zero ? nil : .line(l.start, d)
        case .arc(let a): return .circle(a.center, a.radius)
        case .circle(let c): return .circle(c.center, c.radius)
        default: return nil
        }
    }

    /// Trims/extends a line or arc so that it ends at tangent point `t`, keeping the part that
    /// continues away from the fillet arc (whose travel direction at `t` is `dir`).
    private func tangentTrim(_ e: Entity, at t: Vec2, into dir: Vec2) throws -> Entity {
        switch e.kind {
        case .line(let l):
            let ds = (l.start - t).dot(dir), de = (l.end - t).dot(dir)
            guard min(ds, de) < 1e-9 else { throw ModifyError.radiusTooLarge }
            return e.withKind(.line(ds <= de ? LineGeom(start: l.start, end: t) : LineGeom(start: t, end: l.end)))
        case .arc(let a):
            let ang = (t - a.center).angle
            let k = Vec2.polar(1, ang).perp
            return e.withKind(.arc(k.dot(dir) > 0
                ? ArcGeom(center: a.center, radius: a.radius, startAngle: a.startAngle, endAngle: ang)
                : ArcGeom(center: a.center, radius: a.radius, startAngle: ang, endAngle: a.endAngle)))
        case .circle:
            return e   // circles are not trimmed by FILLET
        default:
            throw ModifyError.cannotFillet
        }
    }

    /// Trims/extends a line or arc to the point `x`, keeping the side of `pick`.
    private func sharpTrim(_ e: Entity, at x: Vec2, pick: Vec2) throws -> Entity {
        switch e.kind {
        case .line(let l):
            let d = (l.end - l.start).normalized
            let u = (pick - x).dot(d) >= 0 ? d : -d
            return e.withKind(.line(keepFar(l, u, x, newNear: x)))
        case .arc(let a):
            let ax = (x - a.center).angle, ap = (pick - a.center).angle
            let opts = [ArcGeom(center: a.center, radius: a.radius, startAngle: ax, endAngle: a.endAngle),
                        ArcGeom(center: a.center, radius: a.radius, startAngle: a.startAngle, endAngle: ax)]
            let containing = opts.filter { angleOnArc(ap, start: $0.startAngle, end: $0.endAngle) }
            guard let best = (containing.isEmpty ? opts : containing).min(by: { $0.sweep < $1.sweep }) else { throw ModifyError.cannotFillet }
            return e.withKind(.arc(best))
        case .circle:
            return e
        default:
            throw ModifyError.cannotFillet
        }
    }

    /// Index of the vertex shared by the polyline segments nearest to the two picks.
    private func sharedVertex(_ p: PolylineGeom, _ a: Vec2, _ b: Vec2) -> Int? {
        let n = p.segmentCount, cnt = p.vertices.count
        guard n >= 2 else { return nil }
        func seg(_ q: Vec2) -> Int {
            (0..<n).min(by: { segPrim(p, $0).distance(to: q) < segPrim(p, $1).distance(to: q) })!
        }
        let i = seg(a), j = seg(b)
        if (i + 1) % cnt == j && (p.closed || i + 1 < cnt) { return j }
        if (j + 1) % cnt == i && (p.closed || j + 1 < cnt) { return i }
        return nil
    }

    private func segPrim(_ p: PolylineGeom, _ i: Int) -> Prim {
        let a = p.vertices[i], b = p.vertices[(i + 1) % p.vertices.count]
        return bulgeSegment(a.point, b.point, bulge: a.bulge)
    }

    /// Fillets polyline vertices between two straight segments (all, or just `only`).
    func filletPolylineVertices(_ p: PolylineGeom, radius: Double, only: Int?) throws -> PolylineGeom {
        let vs = p.vertices, n = vs.count
        guard n >= 3 else { return p }
        var out: [PolyVertex] = []
        // Length of each segment already consumed at its start by a fillet.
        var consumedAtStart = Array(repeating: 0.0, count: n)
        var changes: [Int: (PolyVertex, PolyVertex)] = [:]
        let candidates = only.map { [$0] } ?? Array(0..<n)
        for i in candidates {
            if !p.closed && (i == 0 || i == n - 1) { continue }
            let prev = vs[(i - 1 + n) % n], cur = vs[i], next = vs[(i + 1) % n]
            guard abs(prev.bulge) < 1e-12, abs(cur.bulge) < 1e-12 else { continue }
            let u1 = (prev.point - cur.point), u2 = (next.point - cur.point)
            let len1 = u1.length, len2 = u2.length
            guard len1 > 1e-12, len2 > 1e-12 else { continue }
            let theta = acos(max(-1, min(1, u1.dot(u2) / (len1 * len2))))
            guard theta > 1e-9, theta < .pi - 1e-9 else { continue }
            if radius < 1e-12 { continue }
            let tl = radius / tan(theta / 2)
            let prevIdx = (i - 1 + n) % n
            if tl > len1 - consumedAtStart[prevIdx] + 1e-9 || tl > len2 + 1e-9 {
                if only != nil { throw ModifyError.radiusTooLarge }
                continue
            }
            consumedAtStart[i] = tl
            let t1 = cur.point + u1 / len1 * tl, t2 = cur.point + u2 / len2 * tl
            let turn = (cur.point - prev.point).cross(next.point - cur.point)
            let sweep = (.pi - theta) * (turn > 0 ? 1 : -1)
            changes[i] = (PolyVertex(t1, bulge: bulgeFor(sweep: sweep)), PolyVertex(t2, bulge: 0))
        }
        for i in 0..<n {
            if let (a, b) = changes[i] { out.append(a); out.append(b) } else { out.append(vs[i]) }
        }
        var r = p
        r.vertices = out
        return r
    }
}

extension Entity {
    func withKind(_ k: EntityKind) -> Entity {
        var e = self
        e.kind = k
        return e
    }
}
