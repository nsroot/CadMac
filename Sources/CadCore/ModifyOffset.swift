import Foundation

// MARK: - OFFSET

extension Drawing {
    /// OFFSET: parallel copy at `distance` on the side of `side`. Lines, arcs, circles,
    /// polylines (bulges supported, adjacent offset segments are joined by intersecting their
    /// carriers = miter) and ellipses (approximated by a polyline). The result has a new id.
    public func offset(_ id: EntityID, distance: Double, side: Vec2) throws -> Entity {
        let e = try entityOrThrow(id)
        guard distance > 0 else { throw ModifyError.invalidValue }
        switch e.kind {
        case .line(let l):
            let d = l.end - l.start
            guard d.length > 1e-12 else { throw ModifyError.cannotOffset }
            let sgn: Double = d.cross(side - l.start) >= 0 ? 1 : -1
            let v = d.normalized.perp * (sgn * distance)
            return e.duplicate(kind: .line(LineGeom(start: l.start + v, end: l.end + v)))
        case .circle(let c):
            let r = side.distance(to: c.center) < c.radius ? c.radius - distance : c.radius + distance
            guard r > 1e-9 else { throw ModifyError.offsetTooLarge }
            return e.duplicate(kind: .circle(CircleGeom(center: c.center, radius: r)))
        case .arc(let a):
            let r = side.distance(to: a.center) < a.radius ? a.radius - distance : a.radius + distance
            guard r > 1e-9 else { throw ModifyError.offsetTooLarge }
            return e.duplicate(kind: .arc(ArcGeom(center: a.center, radius: r, startAngle: a.startAngle, endAngle: a.endAngle)))
        case .ellipse(let el):
            return e.duplicate(kind: try offsetEllipse(el, distance: distance, side: side))
        case .polyline(let p):
            let verts = try offsetPolyline(p, distance: distance, side: side)
            return e.duplicate(kind: .polyline(PolylineGeom(vertices: verts, closed: p.closed, width: p.width)))
        default:
            throw ModifyError.cannotOffset
        }
    }

    /// OFFSET Through: offset so that the copy passes through `point`.
    public func offsetThrough(_ id: EntityID, point: Vec2) throws -> Entity {
        let e = try entityOrThrow(id)
        let d: Double
        switch e.kind {
        case .line(let l):
            let dir = (l.end - l.start).normalized
            d = abs(dir.cross(point - l.start))
        case .circle(let c): d = abs(point.distance(to: c.center) - c.radius)
        case .arc(let a): d = abs(point.distance(to: a.center) - a.radius)
        case .polyline, .ellipse:
            d = prims(of: e).map { $0.distance(to: point) }.min() ?? 0
        default: throw ModifyError.cannotOffset
        }
        guard d > 1e-9 else { throw ModifyError.cannotOffset }
        return try offset(id, distance: d, side: point)
    }

    private func offsetEllipse(_ el: EllipseGeom, distance: Double, side: Vec2) throws -> EntityKind {
        let a = el.majorAxis.length, b = a * el.ratio
        guard a > 1e-12, b > 1e-12 else { throw ModifyError.cannotOffset }
        let u = el.majorAxis / a, v = u.perp
        let q = side - el.center
        let inside = pow(q.dot(u) / a, 2) + pow(q.dot(v) / b, 2) < 1
        if inside && distance >= b { throw ModifyError.offsetTooLarge }
        let sgn = inside ? -1.0 : 1.0
        let sweep = ccwSweep(from: el.startParam, to: el.endParam)
        let n = el.isFull ? 128 : max(8, Int(128 * sweep / (2 * .pi)))
        var pts: [Vec2] = []
        for i in 0...(el.isFull ? n - 1 : n) {
            let t = el.startParam + sweep * Double(i) / Double(n)
            let d = el.majorAxis * -sin(t) + el.minorAxis * cos(t)  // CCW tangent
            let outward = Vec2(d.y, -d.x).normalized
            pts.append(el.point(at: t) + outward * (sgn * distance))
        }
        return .polyline(PolylineGeom(points: pts, closed: el.isFull))
    }

    private func offsetPolyline(_ p: PolylineGeom, distance: Double, side: Vec2) throws -> [PolyVertex] {
        let pieces = polylinePieces(p.vertices, closed: p.closed)
        guard !pieces.isEmpty else { throw ModifyError.cannotOffset }
        // Side: +1 = left of the direction of travel.
        var sgn: Double
        if p.closed {
            let poly = pieces.flatMap { Array($0.tessellate().dropLast()) }
            let ccw = polygonArea(p.vertices) > 0
            let inside = pointInPolygon(side, poly)
            sgn = (inside == ccw) ? 1 : -1
        } else {
            var best = (d: Double.infinity, i: 0, q: Vec2.zero)
            for (i, pc) in pieces.enumerated() {
                let q = pc.prim.closestPoint(to: side)
                let d = q.distance(to: side)
                if d < best.d - 1e-12 { best = (d, i, q) }
            }
            let pc = pieces[best.i]
            let t = max(0, min(1, pc.param(of: best.q)))
            sgn = pc.tangent(t).cross(side - best.q) >= 0 ? 1 : -1
        }
        let delta = sgn * distance
        var offs: [Piece] = []
        for pc in pieces {
            switch pc {
            case let .line(a, b):
                let v = (b - a).normalized.perp * delta
                offs.append(.line(a + v, b + v))
            case let .arc(c, r, a0, w):
                let nr = r - delta * (w >= 0 ? 1 : -1)
                if nr > 1e-9 { offs.append(.arc(c: c, r: nr, a0: a0, sweep: w)) }
            }
        }
        guard !offs.isEmpty else { throw ModifyError.offsetTooLarge }
        let n = offs.count
        let joins = p.closed ? n : n - 1
        for k in 0..<joins {
            let i = k, j = (k + 1) % n
            let a = offs[i], b = offs[j]
            if a.end.isClose(to: b.start, tol: 1e-9) { continue }
            let mid = (a.end + b.start) / 2
            let xs = intersections(a.carrier, b.carrier, extendFirst: true, extendSecond: true)
            if let x = xs.min(by: { $0.distance(to: mid) < $1.distance(to: mid) }) {
                offs[i] = offs[i].withEnd(x)
                offs[j] = offs[j].withStart(x)
            }
            // No intersection (parallel / disjoint carriers): the vertex list below bridges
            // the gap with a straight segment.
        }
        var out: [Piece] = []
        for (k, pc) in offs.enumerated() {
            if let last = out.last, !last.end.isClose(to: pc.start, tol: 1e-9) { out.append(.line(last.end, pc.start)) }
            out.append(pc)
            if p.closed && k == n - 1, let f = out.first, !pc.end.isClose(to: f.start, tol: 1e-9) {
                out.append(.line(pc.end, f.start))
            }
        }
        return verticesFrom(out.filter { $0.length > 1e-12 }, closed: p.closed)
    }
}
