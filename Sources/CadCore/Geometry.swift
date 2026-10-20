import Foundation

public let geomEps = 1e-9

// MARK: - Vec2

public struct Vec2: Hashable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public init(x: Double, y: Double) { self.x = x; self.y = y }

    public static let zero = Vec2(0, 0)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func * (s: Double, a: Vec2) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }
    public static func += (a: inout Vec2, b: Vec2) { a = a + b }
    public static func -= (a: inout Vec2, b: Vec2) { a = a - b }

    public var length: Double { (x * x + y * y).squareRoot() }
    public var lengthSquared: Double { x * x + y * y }
    public var normalized: Vec2 { let l = length; return l < geomEps ? .zero : self / l }
    /// Counter-clockwise perpendicular.
    public var perp: Vec2 { Vec2(-y, x) }
    /// Angle in radians, range (-pi, pi].
    public var angle: Double { atan2(y, x) }

    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    public func distance(to o: Vec2) -> Double { (self - o).length }
    public func lerp(to o: Vec2, _ t: Double) -> Vec2 { self + (o - self) * t }
    public func rotated(by a: Double) -> Vec2 {
        let c = cos(a), s = sin(a)
        return Vec2(x * c - y * s, x * s + y * c)
    }
    public func rotated(by a: Double, around c: Vec2) -> Vec2 { (self - c).rotated(by: a) + c }
    public func isClose(to o: Vec2, tol: Double = 1e-7) -> Bool { distance(to: o) <= tol }

    public static func polar(_ r: Double, _ a: Double) -> Vec2 { Vec2(r * cos(a), r * sin(a)) }

    public var description: String { "(\(fmt(x)), \(fmt(y)))" }
}

public func fmt(_ v: Double, precision: Int = 4) -> String {
    var s = String(format: "%.\(precision)f", v)
    if s.contains(".") {
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
    }
    if s == "-0" { s = "0" }
    return s
}

// MARK: - Angles

public func normalizeAngle(_ a: Double) -> Double {
    var r = a.truncatingRemainder(dividingBy: 2 * .pi)
    if r < 0 { r += 2 * .pi }
    return r
}

/// Counter-clockwise sweep from `start` to `end`, in (0, 2pi].
public func ccwSweep(from start: Double, to end: Double) -> Double {
    let s = normalizeAngle(end - start)
    return s < geomEps ? 2 * .pi : s
}

/// True when `a` lies on the CCW arc from `start` to `end`.
public func angleOnArc(_ a: Double, start: Double, end: Double, tol: Double = 1e-9) -> Bool {
    let sweep = ccwSweep(from: start, to: end)
    let d = normalizeAngle(a - start)
    return d <= sweep + tol || d >= 2 * .pi - tol
}

public func degrees(_ r: Double) -> Double { r * 180 / .pi }
public func radians(_ d: Double) -> Double { d * .pi / 180 }

// MARK: - BBox

public struct BBox: Equatable, Codable {
    public var min: Vec2
    public var max: Vec2

    public init(min: Vec2, max: Vec2) { self.min = min; self.max = max }
    public init(points: [Vec2]) {
        var mn = Vec2(.infinity, .infinity), mx = Vec2(-.infinity, -.infinity)
        for p in points {
            mn = Vec2(Swift.min(mn.x, p.x), Swift.min(mn.y, p.y))
            mx = Vec2(Swift.max(mx.x, p.x), Swift.max(mx.y, p.y))
        }
        self.min = mn; self.max = mx
    }
    public init(corner a: Vec2, _ b: Vec2) { self.init(points: [a, b]) }

    public static let empty = BBox(min: Vec2(.infinity, .infinity), max: Vec2(-.infinity, -.infinity))

    public var isEmpty: Bool { min.x > max.x || min.y > max.y }
    public var width: Double { max.x - min.x }
    public var height: Double { max.y - min.y }
    public var center: Vec2 { (min + max) / 2 }

    public func union(_ o: BBox) -> BBox {
        if isEmpty { return o }
        if o.isEmpty { return self }
        return BBox(min: Vec2(Swift.min(min.x, o.min.x), Swift.min(min.y, o.min.y)),
                    max: Vec2(Swift.max(max.x, o.max.x), Swift.max(max.y, o.max.y)))
    }
    public func contains(_ p: Vec2) -> Bool { p.x >= min.x && p.x <= max.x && p.y >= min.y && p.y <= max.y }
    public func contains(_ b: BBox) -> Bool { !b.isEmpty && contains(b.min) && contains(b.max) }
    public func intersects(_ b: BBox) -> Bool {
        !(b.min.x > max.x || b.max.x < min.x || b.min.y > max.y || b.max.y < min.y)
    }
    public func expanded(by d: Double) -> BBox { BBox(min: min - Vec2(d, d), max: max + Vec2(d, d)) }
    public var corners: [Vec2] { [min, Vec2(max.x, min.y), max, Vec2(min.x, max.y)] }
}

// MARK: - Transform2D

/// Affine transform: p' = (a*x + c*y + tx, b*x + d*y + ty).
public struct Transform2D: Equatable, Codable {
    public var a, b, c, d, tx, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static let identity = Transform2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public static func translation(_ v: Vec2) -> Transform2D {
        Transform2D(a: 1, b: 0, c: 0, d: 1, tx: v.x, ty: v.y)
    }
    public static func rotation(_ ang: Double, about p: Vec2 = .zero) -> Transform2D {
        let co = cos(ang), si = sin(ang)
        let r = Transform2D(a: co, b: si, c: -si, d: co, tx: 0, ty: 0)
        return Transform2D.translation(-p).then(r).then(.translation(p))
    }
    public static func scale(_ s: Double, about p: Vec2 = .zero) -> Transform2D {
        scale(sx: s, sy: s, about: p)
    }
    public static func scale(sx: Double, sy: Double, about p: Vec2 = .zero) -> Transform2D {
        Transform2D.translation(-p).then(Transform2D(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)).then(.translation(p))
    }
    /// Mirror across the line through p1 and p2.
    public static func mirror(_ p1: Vec2, _ p2: Vec2) -> Transform2D {
        let dir = (p2 - p1).normalized
        let ux = dir.x, uy = dir.y
        let m = Transform2D(a: ux * ux - uy * uy, b: 2 * ux * uy, c: 2 * ux * uy, d: uy * uy - ux * ux, tx: 0, ty: 0)
        return Transform2D.translation(-p1).then(m).then(.translation(p1))
    }

    /// Returns the transform that applies `self` first, then `o`.
    public func then(_ o: Transform2D) -> Transform2D {
        Transform2D(a: o.a * a + o.c * b,
                    b: o.b * a + o.d * b,
                    c: o.a * c + o.c * d,
                    d: o.b * c + o.d * d,
                    tx: o.a * tx + o.c * ty + o.tx,
                    ty: o.b * tx + o.d * ty + o.ty)
    }

    public func apply(_ p: Vec2) -> Vec2 { Vec2(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty) }
    public func applyVector(_ v: Vec2) -> Vec2 { Vec2(a * v.x + c * v.y, b * v.x + d * v.y) }

    public var determinant: Double { a * d - b * c }
    /// True when the transform flips orientation (mirror).
    public var isMirroring: Bool { determinant < 0 }
    /// Uniform scale factor (sqrt of |det|).
    public var scaleFactor: Double { abs(determinant).squareRoot() }
    /// Rotation angle of the transformed x-axis.
    public var rotationAngle: Double { atan2(b, a) }

    public var inverted: Transform2D {
        let det = determinant
        guard abs(det) > 1e-15 else { return .identity }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return Transform2D(a: ia, b: ib, c: ic, d: id,
                           tx: -(ia * tx + ic * ty), ty: -(ib * tx + id * ty))
    }
}
