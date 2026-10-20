import Foundation

/// Elementary curve pieces that every entity decomposes into, used for
/// rendering, hit testing, snapping and intersection.
public enum Prim: Hashable {
    case seg(Vec2, Vec2)
    /// CCW arc; sweep == 2pi means a full circle.
    case arc(center: Vec2, radius: Double, start: Double, sweep: Double)

    public static func circle(_ c: Vec2, _ r: Double) -> Prim { .arc(center: c, radius: r, start: 0, sweep: 2 * .pi) }
    public static func arc(_ a: ArcGeom) -> Prim { .arc(center: a.center, radius: a.radius, start: a.startAngle, sweep: a.sweep) }

    public var startPoint: Vec2 {
        switch self {
        case .seg(let a, _): return a
        case let .arc(c, r, s, _): return c + .polar(r, s)
        }
    }
    public var endPoint: Vec2 {
        switch self {
        case .seg(_, let b): return b
        case let .arc(c, r, s, w): return c + .polar(r, s + w)
        }
    }
    public var isFullCircle: Bool {
        if case let .arc(_, _, _, w) = self { return w >= 2 * .pi - 1e-9 }
        return false
    }

    public var bbox: BBox {
        switch self {
        case let .seg(a, b): return BBox(corner: a, b)
        case let .arc(c, r, s, w):
            var pts = [startPoint, endPoint]
            for k in 0..<4 {
                let a = Double(k) * .pi / 2
                if w >= 2 * .pi - 1e-9 || angleOnArc(a, start: s, end: s + w) { pts.append(c + .polar(r, a)) }
            }
            return BBox(points: pts)
        }
    }

    public func closestPoint(to p: Vec2) -> Vec2 {
        switch self {
        case let .seg(a, b):
            let d = b - a
            let l2 = d.lengthSquared
            if l2 < 1e-24 { return a }
            let t = max(0, min(1, (p - a).dot(d) / l2))
            return a + d * t
        case let .arc(c, r, s, w):
            let ang = (p - c).angle
            if w >= 2 * .pi - 1e-9 || angleOnArc(ang, start: s, end: s + w) {
                return c + .polar(r, ang)
            }
            let p1 = startPoint, p2 = endPoint
            return p.distance(to: p1) < p.distance(to: p2) ? p1 : p2
        }
    }

    public func distance(to p: Vec2) -> Double { closestPoint(to: p).distance(to: p) }

    public var length: Double {
        switch self {
        case let .seg(a, b): return a.distance(to: b)
        case let .arc(_, r, _, w): return r * w
        }
    }

    public var midPoint: Vec2 {
        switch self {
        case let .seg(a, b): return (a + b) / 2
        case let .arc(c, r, s, w): return c + .polar(r, s + w / 2)
        }
    }

    /// Points approximating this primitive (for tessellation / bbox tests).
    public func tessellate(maxAngleStep: Double = .pi / 36) -> [Vec2] {
        switch self {
        case let .seg(a, b): return [a, b]
        case let .arc(c, r, s, w):
            let n = max(2, Int(ceil(w / maxAngleStep)))
            return (0...n).map { c + .polar(r, s + w * Double($0) / Double(n)) }
        }
    }

    /// True if this primitive touches the box (any part inside or crossing).
    public func intersects(box: BBox) -> Bool {
        if !bbox.intersects(box) { return false }
        let pts = tessellate()
        for p in pts where box.contains(p) { return true }
        let edges = zip(box.corners, box.corners.dropFirst() + [box.corners[0]])
        for i in 0..<(pts.count - 1) {
            for (e1, e2) in edges where segSegIntersection(pts[i], pts[i + 1], e1, e2) != nil { return true }
        }
        return false
    }
}

// MARK: - Bulge helpers

/// Converts a polyline segment with bulge into a primitive.
public func bulgeSegment(_ a: Vec2, _ b: Vec2, bulge: Double) -> Prim {
    if abs(bulge) < 1e-12 || a.isClose(to: b, tol: 1e-12) { return .seg(a, b) }
    let theta = 4 * atan(bulge)               // signed sweep
    let chord = a.distance(to: b)
    let r = chord / (2 * sin(abs(theta) / 2))
    let mid = (a + b) / 2
    let h = r * cos(theta / 2)                // signed distance from chord midpoint to center
    let n = (b - a).normalized.perp
    // Positive bulge: center left of the chord (for sweeps < pi); negative: right.
    let c = bulge > 0 ? mid + n * h : mid - n * h
    if bulge > 0 {
        return .arc(center: c, radius: abs(r), start: (a - c).angle, sweep: abs(theta))
    } else {
        // Clockwise from a to b == CCW from b to a.
        return .arc(center: c, radius: abs(r), start: (b - c).angle, sweep: abs(theta))
    }
}

/// Bulge value for an arc going from a to b with the given signed sweep.
public func bulgeFor(sweep: Double) -> Double { tan(sweep / 4) }

// MARK: - Intersections

/// Bounded segment intersection; returns (t on first, u on second, point).
public func segSegIntersection(_ p1: Vec2, _ p2: Vec2, _ q1: Vec2, _ q2: Vec2, tol: Double = 1e-9) -> Vec2? {
    guard let (t, u, p) = lineLineIntersection(p1, p2, q1, q2) else { return nil }
    if t >= -tol && t <= 1 + tol && u >= -tol && u <= 1 + tol { return p }
    return nil
}

/// Infinite-line intersection; returns parameters along each line and the point.
public func lineLineIntersection(_ p1: Vec2, _ p2: Vec2, _ q1: Vec2, _ q2: Vec2) -> (Double, Double, Vec2)? {
    let r = p2 - p1, s = q2 - q1
    let denom = r.cross(s)
    if abs(denom) < 1e-14 { return nil }
    let t = (q1 - p1).cross(s) / denom
    let u = (q1 - p1).cross(r) / denom
    return (t, u, p1 + r * t)
}

/// Infinite line vs full circle; returns line parameters and points.
public func lineCircleIntersection(_ p1: Vec2, _ p2: Vec2, center: Vec2, radius: Double) -> [(Double, Vec2)] {
    let d = p2 - p1
    let f = p1 - center
    let a = d.dot(d)
    if a < 1e-24 { return [] }
    let b = 2 * f.dot(d)
    let c = f.dot(f) - radius * radius
    var disc = b * b - 4 * a * c
    if disc < 0 {
        if disc > -1e-9 * max(1, radius * radius) { disc = 0 } else { return [] }
    }
    let sq = disc.squareRoot()
    let t1 = (-b - sq) / (2 * a), t2 = (-b + sq) / (2 * a)
    if abs(t1 - t2) < 1e-12 { return [(t1, p1 + d * t1)] }
    return [(t1, p1 + d * t1), (t2, p1 + d * t2)]
}

public func circleCircleIntersection(_ c1: Vec2, _ r1: Double, _ c2: Vec2, _ r2: Double) -> [Vec2] {
    let d = c1.distance(to: c2)
    if d < 1e-12 || d > r1 + r2 + 1e-9 || d < abs(r1 - r2) - 1e-9 { return [] }
    let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
    let h2 = r1 * r1 - a * a
    let h = h2 > 0 ? h2.squareRoot() : 0
    let mid = c1 + (c2 - c1) * (a / d)
    let off = (c2 - c1).perp.normalized * h
    if h < 1e-12 { return [mid] }
    return [mid + off, mid - off]
}

/// Intersections between two bounded primitives. If `extendFirst`/`extendSecond`
/// is set, that primitive is treated as an infinite line / full circle.
public func intersections(_ a: Prim, _ b: Prim, extendFirst: Bool = false, extendSecond: Bool = false) -> [Vec2] {
    func onArc(_ p: Vec2, _ c: Vec2, _ s: Double, _ w: Double, _ ext: Bool) -> Bool {
        ext || w >= 2 * .pi - 1e-9 || angleOnArc((p - c).angle, start: s, end: s + w, tol: 1e-9)
    }
    let tol = 1e-9
    switch (a, b) {
    case let (.seg(p1, p2), .seg(q1, q2)):
        guard let (t, u, p) = lineLineIntersection(p1, p2, q1, q2) else { return [] }
        let okT = extendFirst || (t >= -tol && t <= 1 + tol)
        let okU = extendSecond || (u >= -tol && u <= 1 + tol)
        return okT && okU ? [p] : []
    case let (.seg(p1, p2), .arc(c, r, s, w)):
        return lineCircleIntersection(p1, p2, center: c, radius: r)
            .filter { (extendFirst || ($0.0 >= -tol && $0.0 <= 1 + tol)) && onArc($0.1, c, s, w, extendSecond) }
            .map { $0.1 }
    case (.arc, .seg):
        return intersections(b, a, extendFirst: extendSecond, extendSecond: extendFirst)
    case let (.arc(c1, r1, s1, w1), .arc(c2, r2, s2, w2)):
        return circleCircleIntersection(c1, r1, c2, r2)
            .filter { onArc($0, c1, s1, w1, extendFirst) && onArc($0, c2, s2, w2, extendSecond) }
    }
}

/// Perpendicular foot from `p` onto the primitive (unbounded line / full circle).
public func perpendicularFoot(from p: Vec2, to prim: Prim) -> Vec2? {
    switch prim {
    case let .seg(a, b):
        let d = b - a
        let l2 = d.lengthSquared
        guard l2 > 1e-24 else { return nil }
        let t = (p - a).dot(d) / l2
        guard t >= -1e-9 && t <= 1 + 1e-9 else { return nil }
        return a + d * t
    case let .arc(c, r, s, w):
        let v = p - c
        guard v.length > 1e-12 else { return nil }
        let ang = v.angle
        guard w >= 2 * .pi - 1e-9 || angleOnArc(ang, start: s, end: s + w) else { return nil }
        return c + .polar(r, ang)
    }
}

/// Tangent points from external point `p` to a circle.
public func tangentPoints(from p: Vec2, center: Vec2, radius: Double) -> [Vec2] {
    let d = p.distance(to: center)
    guard d > radius + 1e-12 else { return [] }
    let a = acos(radius / d)
    let base = (p - center).angle
    return [center + .polar(radius, base + a), center + .polar(radius, base - a)]
}
