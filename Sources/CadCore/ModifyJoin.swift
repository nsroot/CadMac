import Foundation

// MARK: - JOIN / EXPLODE / STRETCH

extension Drawing {
    /// JOIN: collinear lines -> one line; co-circular arcs -> one arc (or circle when they cover
    /// 360 degrees); otherwise lines/arcs/open polylines whose endpoints coincide (within
    /// `tolerance`) are chained into polylines (closed when the chain closes).
    /// Objects that cannot be joined are left untouched. New entities get fresh ids and the
    /// properties of the first object of their chain; `removed` lists all consumed ids.
    public func join(_ ids: [EntityID], tolerance: Double = 1e-6) throws -> (removed: Set<EntityID>, added: [Entity]) {
        var seen = Set<EntityID>()
        let items: [(e: Entity, pieces: [Piece])] = ids.compactMap { id in
            guard !seen.contains(id), let e = entity(id) else { return nil }
            seen.insert(id)
            switch e.kind {
            case .line, .arc: break
            case .polyline(let p) where !p.closed: break
            default: return nil
            }
            guard let path = curvePath(of: e), !path.pieces.isEmpty else { return nil }
            return (e, path.pieces)
        }
        guard items.count >= 2 else { throw ModifyError.cannotJoin }
        let tol = max(tolerance, 1e-12)

        // Collinear lines.
        let lines = items.compactMap { item -> LineGeom? in if case .line(let l) = item.e.kind { return l }; return nil }
        if lines.count == items.count, let l0 = lines.first {
            let d = (l0.end - l0.start).normalized
            let ok = d != .zero && lines.allSatisfy { abs(d.cross($0.start - l0.start)) <= tol && abs(d.cross($0.end - l0.start)) <= tol }
            if ok {
                let ts = lines.flatMap { [($0.start - l0.start).dot(d), ($0.end - l0.start).dot(d)] }
                let line = LineGeom(start: l0.start + d * ts.min()!, end: l0.start + d * ts.max()!)
                return (Set(items.map { $0.e.id }), [items[0].e.duplicate(kind: .line(line))])
            }
        }

        // Co-circular arcs.
        let arcs = items.compactMap { item -> ArcGeom? in if case .arc(let a) = item.e.kind { return a }; return nil }
        if arcs.count == items.count, let a0 = arcs.first,
           arcs.allSatisfy({ $0.center.isClose(to: a0.center, tol: tol) && abs($0.radius - a0.radius) <= tol }) {
            let atol = tol / max(a0.radius, 1e-12)
            var bestGap: (len: Double, from: Double)?
            for (i, a) in arcs.enumerated() {
                let e = a.startAngle + a.sweep
                let covered = arcs.enumerated().contains { j, b in
                    guard j != i else { return false }
                    var d = normalizeAngle(e - b.startAngle)
                    if d > 2 * .pi - atol { d = 0 }
                    return d < b.sweep - atol
                }
                if covered { continue }
                var gap = arcs.map { b -> Double in
                    let g = normalizeAngle(b.startAngle - e)
                    return g > 2 * .pi - atol ? 0 : g
                }.min()!
                if gap < atol { gap = 0 }
                if gap > 0 && gap > (bestGap?.len ?? 0) { bestGap = (gap, e) }
            }
            let kind: EntityKind
            if let g = bestGap {
                kind = .arc(ArcGeom(center: a0.center, radius: a0.radius, startAngle: g.from + g.len, endAngle: g.from))
            } else {
                kind = .circle(CircleGeom(center: a0.center, radius: a0.radius))
            }
            return (Set(items.map { $0.e.id }), [items[0].e.duplicate(kind: kind)])
        }

        // Chain by coincident endpoints.
        func rev(_ ps: [Piece]) -> [Piece] { ps.reversed().map { $0.reversed } }
        var remaining = items
        var removed = Set<EntityID>()
        var added: [Entity] = []
        while !remaining.isEmpty {
            let seed = remaining.removeFirst()
            var chain = seed.pieces
            var members = [seed.e.id]
            var closed = false
            var progress = true
            while progress && !closed {
                progress = false
                for (k, it) in remaining.enumerated() {
                    let cs = chain.first!.start, ce = chain.last!.end
                    let s = it.pieces.first!.start, e = it.pieces.last!.end
                    var ps = it.pieces
                    if ce.isClose(to: s, tol: tol) {
                        ps[0] = ps[0].withStart(ce); chain += ps
                    } else if ce.isClose(to: e, tol: tol) {
                        ps = rev(ps); ps[0] = ps[0].withStart(ce); chain += ps
                    } else if cs.isClose(to: e, tol: tol) {
                        ps[ps.count - 1] = ps[ps.count - 1].withEnd(cs); chain = ps + chain
                    } else if cs.isClose(to: s, tol: tol) {
                        ps = rev(ps); ps[ps.count - 1] = ps[ps.count - 1].withEnd(cs); chain = ps + chain
                    } else { continue }
                    remaining.remove(at: k)
                    members.append(it.e.id)
                    progress = true
                    closed = chain.count > 1 && chain.last!.end.isClose(to: chain.first!.start, tol: tol)
                    break
                }
            }
            guard members.count > 1 else { continue }
            if closed { chain[chain.count - 1] = chain[chain.count - 1].withEnd(chain[0].start) }
            var e = seed.e.duplicate()
            var width = 0.0
            if case .polyline(let p) = seed.e.kind { width = p.width }
            e.kind = .polyline(PolylineGeom(vertices: verticesFrom(chain, closed: closed), closed: closed, width: width))
            added.append(e)
            removed.formUnion(members)
        }
        if added.isEmpty { throw ModifyError.cannotJoin }
        return (removed, added)
    }

    /// EXPLODE: polyline -> lines/arcs; insert -> its world-space entities (one level, fresh ids);
    /// dimension -> lines/arcs, text and solid hatch arrowheads; hatch -> closed boundary
    /// polylines. Returns nil when the object cannot be exploded.
    public func explode(_ id: EntityID) -> [Entity]? {
        guard let e = entity(id) else { return nil }
        func fromPrim(_ p: Prim) -> Entity {
            switch p {
            case let .seg(a, b): return e.duplicate(kind: .line(LineGeom(start: a, end: b)))
            case let .arc(c, r, s, w):
                if w >= 2 * .pi - 1e-9 { return e.duplicate(kind: .circle(CircleGeom(center: c, radius: r))) }
                return e.duplicate(kind: .arc(ArcGeom(center: c, radius: r, startAngle: s, endAngle: s + w)))
            }
        }
        switch e.kind {
        case .polyline(let p):
            let out = polylinePieces(p.vertices, closed: p.closed).map { fromPrim($0.prim) }
            return out.isEmpty ? nil : out
        case .insert:
            let out = expandInsert(e).map { c -> Entity in var x = c; x.id = UUID(); return x }
            return out.isEmpty ? nil : out
        case .dimension(let d):
            let g = dimensionGraphics(d, style: settings.dimStyle)
            var out = g.prims.map(fromPrim)
            out += g.arrows.map { tri in e.duplicate(kind: .hatch(HatchGeom(loops: [tri.map { PolyVertex($0) }]))) }
            out.append(e.duplicate(kind: .text(g.text)))
            return out
        case .hatch(let h):
            let out = h.loops.filter { $0.count >= 2 }.map { e.duplicate(kind: .polyline(PolylineGeom(vertices: $0, closed: true))) }
            return out.isEmpty ? nil : out
        default:
            return nil
        }
    }

    /// STRETCH: entities completely inside `window` are moved by `delta`; for the others, every
    /// vertex / defining point inside the window is moved (arcs keep their included angle).
    /// Returns only the entities that changed.
    public func stretch(_ ids: Set<EntityID>, window: BBox, delta: Vec2) -> [Entity] {
        let move = Transform2D.translation(delta)
        func mv(_ p: Vec2) -> Vec2 { window.contains(p) ? p + delta : p }
        var out: [Entity] = []
        for e in entities where ids.contains(e.id) {
            var n = e
            if window.contains(bbox(of: e)) {
                n = e.transformed(by: move)
            } else {
                switch e.kind {
                case .line(let l): n.kind = .line(LineGeom(start: mv(l.start), end: mv(l.end)))
                case .arc(let a):
                    let s = mv(a.startPoint), t = mv(a.endPoint)
                    if case let .arc(c, r, st, w) = bulgeSegment(s, t, bulge: bulgeFor(sweep: a.sweep)) {
                        n.kind = .arc(ArcGeom(center: c, radius: r, startAngle: st, endAngle: st + w))
                    }
                case .circle(let c): if window.contains(c.center) { n = e.transformed(by: move) }
                case .ellipse(let el): if window.contains(el.center) { n = e.transformed(by: move) }
                case .polyline(var p):
                    p.vertices = p.vertices.map { PolyVertex(mv($0.point), bulge: $0.bulge) }
                    n.kind = .polyline(p)
                case .hatch(var h):
                    h.loops = h.loops.map { $0.map { PolyVertex(mv($0.point), bulge: $0.bulge) } }
                    n.kind = .hatch(h)
                case .spline(var s):
                    s.controlPoints = s.controlPoints.map(mv); s.fitPoints = s.fitPoints.map(mv)
                    n.kind = .spline(s)
                case .text(var t): t.position = mv(t.position); n.kind = .text(t)
                case .point(let p): n.kind = .point(PointGeom(position: mv(p.position)))
                case .insert(var i): i.position = mv(i.position); n.kind = .insert(i)
                case .dimension(var d):
                    d.p1 = mv(d.p1); d.p2 = mv(d.p2); d.p3 = mv(d.p3); d.p4 = mv(d.p4)
                    n.kind = .dimension(d)
                case .attdef(var a): a.text.position = mv(a.text.position); n.kind = .attdef(a)
                case .viewport(var v):
                    // Stretching a viewport frame resizes it at the same scale.
                    let f = BBox(points: v.frame.corners.map(mv))
                    let s = v.scale
                    v.center = f.center; v.width = f.width; v.height = f.height
                    v.scale = s
                    n.kind = .viewport(v)
                }
            }
            if n != e { out.append(n) }
        }
        return out
    }
}
