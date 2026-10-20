import Foundation

// MARK: - ARRAY / DIVIDE / MEASURE / AREA

extension Drawing {
    private func selection(_ ids: Set<EntityID>) -> [Entity] { entities.filter { ids.contains($0.id) } }

    /// Rectangular array copies (originals excluded), fresh ids. Rows step along +Y by
    /// `rowSpacing`, columns along +X by `columnSpacing` (negative spacing = other direction).
    public func rectangularArray(_ ids: Set<EntityID>, rows: Int, columns: Int,
                                 rowSpacing: Double, columnSpacing: Double) -> [Entity] {
        let sel = selection(ids)
        var out: [Entity] = []
        for r in 0..<max(1, rows) {
            for c in 0..<max(1, columns) where r != 0 || c != 0 {
                let t = Transform2D.translation(Vec2(Double(c) * columnSpacing, Double(r) * rowSpacing))
                out += sel.map { $0.duplicate(kind: $0.kind.transformed(by: t)) }
            }
        }
        return out
    }

    /// Polar array copies (originals excluded), fresh ids. `count` includes the original.
    /// A full `fillAngle` (2pi) spaces items 2pi/count apart; otherwise fillAngle/(count-1).
    /// Without `rotateItems`, copies are translated so the selection's center follows the circle.
    public func polarArray(_ ids: Set<EntityID>, center: Vec2, count: Int, fillAngle: Double,
                           rotateItems: Bool) -> [Entity] {
        guard count >= 2 else { return [] }
        let sel = selection(ids)
        let full = abs(abs(fillAngle) - 2 * .pi) < 1e-9 || abs(fillAngle) > 2 * .pi
        let step = full ? (fillAngle >= 0 ? 1 : -1) * 2 * .pi / Double(count) : fillAngle / Double(count - 1)
        let ref = extents(of: sel).center
        var out: [Entity] = []
        for i in 1..<count {
            let a = step * Double(i)
            let t = rotateItems ? Transform2D.rotation(a, about: center)
                                : Transform2D.translation(ref.rotated(by: a, around: center) - ref)
            out += sel.map { $0.duplicate(kind: $0.kind.transformed(by: t)) }
        }
        return out
    }

    /// Path array copies (originals excluded), fresh ids. The original sits at the start of the
    /// path; `count` items are spaced evenly along it (ends included for open paths).
    /// `alignItems` rotates copies with the path tangent.
    public func pathArray(_ ids: Set<EntityID>, path pathID: EntityID, count: Int, alignItems: Bool) -> [Entity] {
        guard count >= 2, let pe = entity(pathID), let path = curvePath(of: pe), path.length > 0 else { return [] }
        let sel = selection(ids.subtracting([pathID]))
        let step = path.length / Double(path.closed ? count : count - 1)
        let p0 = path.point(at: 0), a0 = path.tangent(at: 0).angle
        var out: [Entity] = []
        for i in 1..<count {
            let s = step * Double(i)
            let p = path.point(at: s)
            var t = Transform2D.translation(p - p0)
            if alignItems { t = t.then(.rotation(path.tangent(at: s).angle - a0, about: p)) }
            out += sel.map { $0.duplicate(kind: $0.kind.transformed(by: t)) }
        }
        return out
    }

    /// DIVIDE: points splitting the object into `segments` equal-length parts
    /// (segments-1 points for open curves, `segments` points for closed ones, starting at the start).
    public func divide(_ id: EntityID, segments: Int) -> [Vec2] {
        guard segments >= 2, let e = entity(id), let path = curvePath(of: e), path.length > 0 else { return [] }
        let L = path.length
        let range = path.closed ? Array(0..<segments) : Array(1..<segments)
        return range.map { path.point(at: L * Double($0) / Double(segments)) }
    }

    /// MEASURE: points every `length` from the start of the object.
    public func measure(_ id: EntityID, length: Double) -> [Vec2] {
        guard length > 0, let e = entity(id), let path = curvePath(of: e), path.length > 0 else { return [] }
        let L = path.length
        let n = Int((L / length + 1e-9).rounded(.down))
        guard n >= 1, n < 1_000_000 else { return [] }
        return (1...n).compactMap { k -> Vec2? in
            let s = Double(k) * length
            if path.closed && s > L - 1e-9 * max(1, L) { return nil }
            return path.point(at: min(s, L))
        }
    }

    /// Enclosed area of a circle, ellipse, polyline (treated as closed, bulges included),
    /// closed spline or hatch (nested loops subtract). nil for other objects.
    public func area(of id: EntityID) -> Double? {
        guard let e = entity(id) else { return nil }
        switch e.kind {
        case .circle(let c): return .pi * c.radius * c.radius
        case .ellipse(let el):
            let a = el.majorAxis.length
            if el.isFull { return .pi * a * a * el.ratio }
            return abs(polygonArea(ellipsePoints(el, segments: 720).map { PolyVertex($0) }))
        case .polyline(let p):
            guard p.vertices.count >= 3 || (p.vertices.count == 2 && p.closed) else { return nil }
            return abs(polygonArea(p.vertices))
        case .spline(let s):
            guard s.closed else { return nil }
            return abs(polygonArea(splinePoints(s).map { PolyVertex($0) }))
        case .hatch(let h):
            let polys = h.loops.map { loop in polylinePieces(loop, closed: true).flatMap { Array($0.tessellate().dropLast()) } }
            var total = 0.0
            for (i, loop) in h.loops.enumerated() {
                guard let probe = polys[i].first else { continue }
                let depth = polys.indices.filter { $0 != i && pointInPolygon(probe, polys[$0]) }.count
                total += (depth % 2 == 0 ? 1 : -1) * abs(polygonArea(loop))
            }
            return abs(total)
        default: return nil
        }
    }

    /// Length of any curve object (closed curves: full perimeter). nil for non-curves.
    public func perimeter(of id: EntityID) -> Double? {
        guard let e = entity(id) else { return nil }
        switch e.kind {
        case .circle(let c): return 2 * .pi * c.radius
        case .ellipse(let el):
            let pts = ellipsePoints(el, segments: 2048)
            return zip(pts, pts.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        default:
            return curvePath(of: e)?.length
        }
    }
}
