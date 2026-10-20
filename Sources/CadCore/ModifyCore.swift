import Foundation

// MARK: - Errors / modes

/// User-facing errors raised by modify operations.
public enum ModifyError: Error, LocalizedError, Equatable {
    case notFound
    case cannotTrim
    case cannotExtend
    case noIntersection
    case radiusTooLarge
    case distanceTooLarge
    case parallel
    case cannotOffset
    case offsetTooLarge
    case cannotFillet
    case cannotChamfer
    case cannotBreak
    case fullCircleArc
    case cannotJoin
    case cannotLengthen
    case invalidLength
    case invalidValue

    public var errorDescription: String? {
        switch self {
        case .notFound: return "Object not found"
        case .cannotTrim: return "Object cannot be trimmed"
        case .cannotExtend: return "Object cannot be extended"
        case .noIntersection: return "No intersection found"
        case .radiusTooLarge: return "Radius is too large"
        case .distanceTooLarge: return "Distance is too large"
        case .parallel: return "Lines are parallel"
        case .cannotOffset: return "Cannot offset that object"
        case .offsetTooLarge: return "Offset distance is too large"
        case .cannotFillet: return "Cannot fillet these objects"
        case .cannotChamfer: return "Cannot chamfer these objects"
        case .cannotBreak: return "Object cannot be broken"
        case .fullCircleArc: return "Arc cannot be full 360 degrees"
        case .cannotJoin: return "Objects cannot be joined"
        case .cannotLengthen: return "Object cannot be lengthened"
        case .invalidLength: return "Invalid length"
        case .invalidValue: return "Value must be positive"
        }
    }
}

/// LENGTHEN options. `delta`/`total` are lengths (arc length for arcs), `percent` is a
/// percentage of the current length (e.g. 150 = 1.5x), `deltaAngle` is radians (arcs only).
public enum LengthenMode: Equatable {
    case delta(Double)
    case total(Double)
    case percent(Double)
    case deltaAngle(Double)
}

// MARK: - Directed curve piece

/// Directed curve piece used internally by modify operations. Arcs carry a signed sweep
/// (positive = CCW travel, negative = CW travel), unlike `Prim` arcs which are always CCW.
enum Piece: Equatable {
    case line(Vec2, Vec2)
    case arc(c: Vec2, r: Double, a0: Double, sweep: Double)

    init(_ prim: Prim) {
        switch prim {
        case let .seg(a, b): self = .line(a, b)
        case let .arc(c, r, s, w): self = .arc(c: c, r: r, a0: s, sweep: w)
        }
    }

    /// Polyline segment from `a` to `b` with bulge.
    static func bulged(_ a: Vec2, _ b: Vec2, _ bulge: Double) -> Piece {
        let prim = bulgeSegment(a, b, bulge: bulge)
        guard case let .arc(c, r, _, _) = prim else { return .line(a, b) }
        return .arc(c: c, r: r, a0: (a - c).angle, sweep: 4 * atan(bulge))
    }

    var start: Vec2 { point(0) }
    var end: Vec2 { point(1) }

    var length: Double {
        switch self {
        case let .line(a, b): return a.distance(to: b)
        case let .arc(_, r, _, w): return r * abs(w)
        }
    }

    var isArc: Bool { if case .arc = self { return true }; return false }

    func point(_ t: Double) -> Vec2 {
        switch self {
        case let .line(a, b): return a.lerp(to: b, t)
        case let .arc(c, r, a0, w): return c + .polar(r, a0 + w * t)
        }
    }

    /// Unit tangent in the direction of travel.
    func tangent(_ t: Double) -> Vec2 {
        switch self {
        case let .line(a, b): return (b - a).normalized
        case let .arc(_, _, a0, w):
            let d = Vec2.polar(1, a0 + w * t).perp
            return w >= 0 ? d : -d
        }
    }

    /// Local parameter of the projection of `p` (unclamped for lines; arcs map to the
    /// nearest representative around the sweep).
    func param(of p: Vec2) -> Double {
        switch self {
        case let .line(a, b):
            let d = b - a
            let l2 = d.lengthSquared
            return l2 < 1e-24 ? 0 : (p - a).dot(d) / l2
        case let .arc(c, _, a0, w):
            guard abs(w) > 1e-15 else { return 0 }
            let raw = (p - c).angle - a0
            let t = normalizeAngle(w >= 0 ? raw : -raw) / abs(w)
            if t <= 1 + 1e-12 { return t }
            let alt = t - 2 * .pi / abs(w)
            return (t - 1) < -alt ? t : alt
        }
    }

    func sub(_ t0: Double, _ t1: Double) -> Piece {
        switch self {
        case let .line(a, b): return .line(a.lerp(to: b, t0), a.lerp(to: b, t1))
        case let .arc(c, r, a0, w): return .arc(c: c, r: r, a0: a0 + w * t0, sweep: w * (t1 - t0))
        }
    }

    var reversed: Piece {
        switch self {
        case let .line(a, b): return .line(b, a)
        case let .arc(c, r, a0, w): return .arc(c: c, r: r, a0: a0 + w, sweep: -w)
        }
    }

    var bulge: Double {
        if case let .arc(_, _, _, w) = self { return bulgeFor(sweep: w) }
        return 0
    }

    /// Undirected primitive (arcs normalized to CCW).
    var prim: Prim {
        switch self {
        case let .line(a, b): return .seg(a, b)
        case let .arc(c, r, a0, w):
            return w >= 0 ? .arc(center: c, radius: r, start: a0, sweep: w)
                          : .arc(center: c, radius: r, start: a0 + w, sweep: -w)
        }
    }

    /// Infinite line / full circle carrying this piece.
    var carrier: Prim {
        switch self {
        case .line: return prim
        case let .arc(c, r, _, _): return .circle(c, r)
        }
    }

    /// Points along the direction of travel.
    func tessellate(maxAngleStep: Double = .pi / 36) -> [Vec2] {
        switch self {
        case let .line(a, b): return [a, b]
        case let .arc(_, _, _, w):
            let n = max(2, Int(ceil(abs(w) / maxAngleStep)))
            return (0...n).map { point(Double($0) / Double(n)) }
        }
    }

    func translated(_ v: Vec2) -> Piece {
        switch self {
        case let .line(a, b): return .line(a + v, b + v)
        case let .arc(c, r, a0, w): return .arc(c: c + v, r: r, a0: a0, sweep: w)
        }
    }

    /// Lengthens (or shortens with negative `delta`) the piece at one end by an arc length.
    func extended(atEnd: Bool, by delta: Double) -> Piece {
        switch self {
        case let .line(a, b):
            let d = (b - a).normalized
            return atEnd ? .line(a, b + d * delta) : .line(a - d * delta, b)
        case let .arc(c, r, a0, w):
            let dw = (w >= 0 ? 1.0 : -1.0) * delta / r
            return atEnd ? .arc(c: c, r: r, a0: a0, sweep: w + dw) : .arc(c: c, r: r, a0: a0 - dw, sweep: w + dw)
        }
    }

    /// Moves the start (or end) to `p`, which should lie on the carrier.
    func withStart(_ p: Vec2) -> Piece {
        switch self {
        case let .line(_, b): return .line(p, b)
        case let .arc(c, r, a0, w):
            let a = (p - c).angle
            return .arc(c: c, r: r, a0: a, sweep: w + remainder(a0 - a, 2 * .pi))
        }
    }
    func withEnd(_ p: Vec2) -> Piece {
        switch self {
        case let .line(a, _): return .line(a, p)
        case let .arc(c, r, a0, w):
            let a = (p - c).angle
            return .arc(c: c, r: r, a0: a0, sweep: w + remainder(a - (a0 + w), 2 * .pi))
        }
    }

    /// Extension length needed at the start/end to reach the nearest boundary intersection.
    func extensionToBoundary(atEnd: Bool, boundaries: [Prim]) -> Double? {
        let len = length
        var best: Double?
        switch self {
        case let .line(a, b):
            for q in boundaries {
                for p in intersections(.seg(a, b), q, extendFirst: true) {
                    let t = param(of: p)
                    let ext = atEnd ? (t - 1) * len : -t * len
                    if ext > 1e-9 * max(1, len) && ext < (best ?? .infinity) { best = ext }
                }
            }
        case let .arc(c, r, a0, w):
            let sgn = w >= 0 ? 1.0 : -1.0
            let room = 2 * .pi - abs(w)
            for q in boundaries {
                for p in intersections(.circle(c, r), q) {
                    let ang = (p - c).angle
                    let d = atEnd ? normalizeAngle(sgn * (ang - (a0 + w))) : normalizeAngle(sgn * (a0 - ang))
                    if d > 1e-9 && d < room - 1e-9 && d * r < (best ?? .infinity) { best = d * r }
                }
            }
        }
        return best
    }
}

// MARK: - Path (chain of pieces with arc-length parameter)

struct CurvePath {
    var pieces: [Piece]
    var closed: Bool
    private(set) var cum: [Double]

    init(_ pieces: [Piece], closed: Bool) {
        self.pieces = pieces.filter { $0.length > 1e-12 }
        self.closed = closed
        var c = [0.0]
        for p in self.pieces { c.append(c.last! + p.length) }
        cum = c
    }

    var length: Double { cum.last ?? 0 }
    var start: Vec2 { pieces.first?.start ?? .zero }
    var end: Vec2 { pieces.last?.end ?? .zero }

    func globalParam(piece i: Int, t: Double) -> Double {
        cum[i] + max(0, min(1, t)) * pieces[i].length
    }

    func locate(_ s: Double) -> (Int, Double) {
        guard !pieces.isEmpty else { return (0, 0) }
        let s = max(0, min(length, s))
        for i in pieces.indices where s <= cum[i + 1] || i == pieces.count - 1 {
            let l = pieces[i].length
            return (i, l > 0 ? (s - cum[i]) / l : 0)
        }
        return (pieces.count - 1, 1)
    }

    func point(at s: Double) -> Vec2 {
        let (i, t) = locate(s)
        return pieces.isEmpty ? .zero : pieces[i].point(t)
    }
    func tangent(at s: Double) -> Vec2 {
        let (i, t) = locate(s)
        return pieces.isEmpty ? Vec2(1, 0) : pieces[i].tangent(t)
    }

    /// Arc-length parameter of the point on the path closest to `p`.
    func project(_ p: Vec2) -> Double {
        var best = (d: Double.infinity, s: 0.0)
        for (i, pc) in pieces.enumerated() {
            let q = pc.prim.closestPoint(to: p)
            let d = q.distance(to: p)
            if d < best.d - 1e-12 { best = (d, globalParam(piece: i, t: pc.param(of: q))) }
        }
        return best.s
    }

    /// Pieces between s0 and s1 (s0 < s1), without wrap-around.
    func sub(_ s0: Double, _ s1: Double) -> [Piece] {
        var out: [Piece] = []
        let eps = 1e-10 * max(1, length)
        for (i, p) in pieces.enumerated() {
            let a = max(s0, cum[i]), b = min(s1, cum[i + 1])
            guard b - a > eps else { continue }
            let l = p.length
            out.append(p.sub((a - cum[i]) / l, (b - cum[i]) / l))
        }
        return out
    }

    /// Pieces going forward from s0 to s1, wrapping through the start of a closed path.
    func subWrapped(_ s0: Double, _ s1: Double) -> [Piece] {
        s0 < s1 ? sub(s0, s1) : sub(s0, length) + sub(0, s1)
    }

    /// Intersection parameters of the path with the given primitives (sorted, unique).
    func cutParams(with prims: [Prim]) -> [Double] {
        var out: [Double] = []
        for (i, pc) in pieces.enumerated() {
            let pp = pc.prim
            let bb = pp.bbox.expanded(by: 1e-7)
            for q in prims where q.bbox.intersects(bb) {
                for x in intersections(pp, q) { out.append(globalParam(piece: i, t: pc.param(of: x))) }
            }
        }
        out.sort()
        var uniq: [Double] = []
        let eps = 1e-9 * max(1, length)
        for s in out where uniq.last.map({ s - $0 > eps }) ?? true { uniq.append(s) }
        if closed, uniq.count > 1, let f = uniq.first, let l = uniq.last, f + length - l <= eps { uniq.removeLast() }
        return uniq
    }
}

// MARK: - Entity <-> path conversion

func polylinePieces(_ verts: [PolyVertex], closed: Bool) -> [Piece] {
    guard verts.count >= 2 else { return [] }
    let n = closed ? verts.count : verts.count - 1
    var out: [Piece] = []
    for i in 0..<n {
        let a = verts[i], b = verts[(i + 1) % verts.count]
        if a.point.isClose(to: b.point, tol: 1e-12) { continue }
        out.append(.bulged(a.point, b.point, a.bulge))
    }
    return out
}

func verticesFrom(_ pieces: [Piece], closed: Bool) -> [PolyVertex] {
    var v = pieces.map { PolyVertex($0.start, bulge: $0.bulge) }
    if !closed, let l = pieces.last { v.append(PolyVertex(l.end)) }
    return v
}

func segsFrom(_ pts: [Vec2]) -> [Piece] {
    guard pts.count >= 2 else { return [] }
    return (0..<(pts.count - 1)).map { .line(pts[$0], pts[$0 + 1]) }
}

extension Drawing {
    func entityOrThrow(_ id: EntityID) throws -> Entity {
        guard let e = entity(id) else { throw ModifyError.notFound }
        return e
    }

    /// Directed path of a curve entity, or nil for non-curves.
    func curvePath(of e: Entity) -> CurvePath? {
        switch e.kind {
        case .line(let l): return CurvePath([.line(l.start, l.end)], closed: false)
        case .arc(let a): return CurvePath([.arc(c: a.center, r: a.radius, a0: a.startAngle, sweep: a.sweep)], closed: false)
        case .circle(let c): return CurvePath([.arc(c: c.center, r: c.radius, a0: 0, sweep: 2 * .pi)], closed: true)
        case .polyline(let p): return CurvePath(polylinePieces(p.vertices, closed: p.closed), closed: p.closed)
        case .ellipse(let el): return CurvePath(segsFrom(ellipsePoints(el, segments: 360)), closed: el.isFull)
        case .spline(let s): return CurvePath(segsFrom(splinePoints(s)), closed: s.closed)
        default: return nil
        }
    }

    /// Primitives of the given entities (nil = all visible), used as cutting edges / boundaries.
    func edgePrims(_ ids: Set<EntityID>?, excluding ex: EntityID) -> [Prim] {
        var out: [Prim] = []
        for e in entities where e.id != ex {
            if let ids {
                guard ids.contains(e.id) else { continue }
            } else {
                guard isVisible(e) else { continue }
                switch e.kind {
                case .text, .point: continue
                default: break
                }
            }
            out += prims(of: e)
        }
        return out
    }
}

/// Builds an entity of the same "family" as `original` from directed pieces.
func entityFrom(_ pieces: [Piece], closed: Bool, like original: Entity, id: EntityID) -> Entity {
    var e = original
    e.id = id
    if case .polyline(let p) = original.kind {
        e.kind = .polyline(PolylineGeom(vertices: verticesFrom(pieces, closed: closed), closed: closed, width: p.width))
        return e
    }
    if pieces.count == 1 {
        switch pieces[0] {
        case let .line(a, b):
            e.kind = .line(LineGeom(start: a, end: b))
            return e
        case let .arc(c, r, a0, w):
            if abs(w) >= 2 * .pi - 1e-9 {
                e.kind = .circle(CircleGeom(center: c, radius: r))
            } else {
                e.kind = .arc(w >= 0 ? ArcGeom(center: c, radius: r, startAngle: a0, endAngle: a0 + w)
                                     : ArcGeom(center: c, radius: r, startAngle: a0 + w, endAngle: a0))
            }
            return e
        }
    }
    e.kind = .polyline(PolylineGeom(vertices: verticesFrom(pieces, closed: closed), closed: closed))
    return e
}

/// Assigns the original id to the first result and fresh ids to the rest.
func assignIDs(_ es: [Entity], firstID: EntityID) -> [Entity] {
    es.enumerated().map { i, e in
        var x = e
        x.id = i == 0 ? firstID : UUID()
        return x
    }
}

// MARK: - Area

/// Signed area of a closed loop of polyline vertices (the last vertex connects back to the
/// first), including the circular segments of bulged edges. Positive when the loop runs
/// counter-clockwise; take `abs` for the enclosed area.
public func polygonArea(_ verts: [PolyVertex]) -> Double {
    guard verts.count >= 2 else { return 0 }
    var a = 0.0
    for i in verts.indices {
        let p = verts[i].point, q = verts[(i + 1) % verts.count].point
        a += p.cross(q) / 2
        let b = verts[i].bulge
        if abs(b) > 1e-12 {
            let theta = 4 * atan(abs(b))
            let chord = p.distance(to: q)
            guard chord > 1e-12 else { continue }
            let r = chord / (2 * sin(theta / 2))
            let seg = r * r / 2 * (theta - sin(theta))
            a += b > 0 ? seg : -seg
        }
    }
    return a
}
