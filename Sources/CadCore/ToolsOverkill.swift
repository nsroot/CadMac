import Foundation

// MARK: - OVERKILL

public struct OverkillOptions: Equatable {
    /// Distance tolerance for comparing geometry.
    public var tolerance: Double = 1e-6
    /// Ignore layer/color/linetype/lineweight when comparing objects.
    public var ignoreProperties = false
    /// Merge collinear lines that partially overlap (AutoCAD default on).
    public var combineOverlapping = true
    /// Also merge collinear lines that only touch end to end (AutoCAD default off).
    public var combineEndToEnd = false
    public init() {}
}

public struct OverkillResult: Equatable {
    /// Objects to delete.
    public var removed: Set<EntityID> = []
    /// Replacement geometry for kept objects (merged lines).
    public var modified: [Entity] = []
    /// Number of exact duplicates found (subset of `removed`).
    public var duplicates = 0
    /// Number of overlapping objects merged into others (subset of `removed`).
    public var merged = 0
    public var isEmpty: Bool { removed.isEmpty && modified.isEmpty }
    public init() {}
}

private struct PropKey: Hashable {
    var layer: String, color: CadColor, linetype: String, lineweight: Double
}

/// Approximate geometric equality used for duplicate detection.
public func entityKindsEqual(_ a: EntityKind, _ b: EntityKind, tol: Double = 1e-6) -> Bool {
    func eq(_ p: Vec2, _ q: Vec2) -> Bool { p.distance(to: q) <= tol }
    func eqd(_ x: Double, _ y: Double) -> Bool { abs(x - y) <= tol }
    switch (a, b) {
    case let (.line(l1), .line(l2)):
        return (eq(l1.start, l2.start) && eq(l1.end, l2.end)) || (eq(l1.start, l2.end) && eq(l1.end, l2.start))
    case let (.circle(c1), .circle(c2)):
        return eq(c1.center, c2.center) && eqd(c1.radius, c2.radius)
    case let (.arc(a1), .arc(a2)):
        return eq(a1.center, a2.center) && eqd(a1.radius, a2.radius)
            && eq(a1.startPoint, a2.startPoint) && eq(a1.endPoint, a2.endPoint)
    case let (.point(p1), .point(p2)):
        return eq(p1.position, p2.position)
    case let (.ellipse(e1), .ellipse(e2)):
        return eq(e1.center, e2.center) && eq(e1.majorAxis, e2.majorAxis) && eqd(e1.ratio, e2.ratio)
            && eq(e1.point(at: e1.startParam), e2.point(at: e2.startParam)) && eq(e1.point(at: e1.endParam), e2.point(at: e2.endParam))
    case let (.polyline(p1), .polyline(p2)):
        guard p1.closed == p2.closed, eqd(p1.width, p2.width), p1.vertices.count == p2.vertices.count else { return false }
        let v1 = p1.vertices, v2 = p2.vertices
        let forward = zip(v1, v2).allSatisfy { eq($0.point, $1.point) && abs($0.bulge - $1.bulge) <= 1e-9 }
        if forward { return true }
        guard !p1.closed else { return false }
        // Reversed open polyline: points reversed, bulges reversed and negated.
        let n = v1.count
        for i in 0..<n {
            guard eq(v1[i].point, v2[n - 1 - i].point) else { return false }
            if i < n - 1, abs(v1[i].bulge + v2[n - 2 - i].bulge) > 1e-9 { return false }
        }
        return true
    case let (.text(t1), .text(t2)):
        return eq(t1.position, t2.position) && t1.text == t2.text && eqd(t1.height, t2.height)
            && abs(t1.rotation - t2.rotation) < 1e-9 && t1.isMultiline == t2.isMultiline
    case let (.insert(i1), .insert(i2)):
        return i1.blockName == i2.blockName && eq(i1.position, i2.position) && eqd(i1.scaleX, i2.scaleX)
            && eqd(i1.scaleY, i2.scaleY) && abs(i1.rotation - i2.rotation) < 1e-9 && i1.attributes == i2.attributes
    default:
        return a == b
    }
}

extension Drawing {
    /// Finds duplicate and overlapping objects among `ids` (active space). Does not modify the drawing.
    public func overkill(_ ids: Set<EntityID>, options o: OverkillOptions = OverkillOptions()) -> OverkillResult {
        let tol = o.tolerance
        var res = OverkillResult()
        let cands = entities.filter { ids.contains($0.id) }
        func key(_ e: Entity) -> PropKey {
            o.ignoreProperties ? PropKey(layer: "", color: .byLayer, linetype: "", lineweight: 0)
                               : PropKey(layer: e.layer.lowercased(), color: e.color, linetype: e.linetype.lowercased(), lineweight: e.lineweight)
        }

        // 1. Exact duplicates (all types). Bucket by property key, type and rounded bbox center.
        let cell = max(tol * 1000, 1e-3)
        struct Bucket: Hashable { var p: PropKey; var type: String; var x: Int; var y: Int }
        var buckets: [Bucket: [Entity]] = [:]
        var survivors: [Entity] = []
        for e in cands {
            let c = bbox(of: e).center
            let bx = c.x.isFinite ? Int((c.x / cell).rounded(.down)) : 0
            let by = c.y.isFinite ? Int((c.y / cell).rounded(.down)) : 0
            let type = e.kind.typeName
            var dup = false
            search: for dx in -1...1 {
                for dy in -1...1 {
                    for other in buckets[Bucket(p: key(e), type: type, x: bx + dx, y: by + dy)] ?? []
                    where entityKindsEqual(other.kind, e.kind, tol: tol) {
                        dup = true
                        break search
                    }
                }
            }
            if dup {
                res.removed.insert(e.id)
                res.duplicates += 1
            } else {
                buckets[Bucket(p: key(e), type: type, x: bx, y: by), default: []].append(e)
                survivors.append(e)
            }
        }

        // 2. Arcs lying on a circle with identical properties are redundant.
        var circles: [PropKey: [CircleGeom]] = [:]
        for e in survivors { if case .circle(let c) = e.kind { circles[key(e), default: []].append(c) } }
        if !circles.isEmpty {
            for e in survivors {
                guard case .arc(let a) = e.kind else { continue }
                if circles[key(e)]?.contains(where: { $0.center.distance(to: a.center) <= tol && abs($0.radius - a.radius) <= tol }) == true {
                    res.removed.insert(e.id)
                    res.merged += 1
                }
            }
        }

        // 3. Collinear lines that overlap (or touch end to end) merge into one.
        guard o.combineOverlapping || o.combineEndToEnd else { return res }
        struct LineInfo { var e: Entity; var dir: Vec2; var theta: Double; var offset: Double }
        var lines: [LineInfo] = []
        for e in survivors {
            guard case .line(let l) = e.kind, l.length > tol else { continue }
            var d = (l.end - l.start).normalized
            var th = atan2(d.y, d.x)
            if th < 0 { th += .pi; d = -d }
            if th >= .pi - 1e-9 { th -= .pi; d = -d }
            lines.append(LineInfo(e: e, dir: d, theta: th, offset: d.cross(l.start)))
        }
        lines.sort { ($0.theta, $0.offset) < ($1.theta, $1.offset) }
        let angTol = 1e-7
        let order = Dictionary(cands.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var used = [Bool](repeating: false, count: lines.count)
        for i in lines.indices where !used[i] {
            let a = lines[i]
            // Collect collinear peers with the same properties.
            var group = [i]
            var peers: [Int] = []
            var j = i + 1
            while j < lines.count, lines[j].theta - a.theta <= angTol { peers.append(j); j += 1 }
            if a.theta <= angTol {
                var k = lines.count - 1
                while k > j - 1, lines[k].theta >= .pi - angTol { peers.append(k); k -= 1 }
            }
            for j in peers where !used[j] {
                let b = lines[j]
                var dth = abs(a.theta - b.theta)
                dth = min(dth, .pi - dth)
                guard dth <= angTol, key(a.e) == key(b.e), case .line(let lb) = b.e.kind else { continue }
                // Both endpoints of b within tol of a's infinite line.
                guard case .line(let la) = a.e.kind else { continue }
                if abs(a.dir.cross(lb.start - la.start)) <= tol && abs(a.dir.cross(lb.end - la.start)) <= tol {
                    group.append(j)
                }
            }
            guard group.count > 1 else { continue }
            guard case .line(let la) = a.e.kind else { continue }
            let origin = la.start, d = a.dir
            struct Iv { var lo: Double; var hi: Double; var idx: Int }
            var ivs: [Iv] = group.map { k in
                guard case .line(let l) = lines[k].e.kind else { return Iv(lo: 0, hi: 0, idx: k) }
                let t0 = (l.start - origin).dot(d), t1 = (l.end - origin).dot(d)
                return Iv(lo: min(t0, t1), hi: max(t0, t1), idx: k)
            }
            ivs.sort { $0.lo < $1.lo }
            var clusters: [[Iv]] = []
            var cur: [Iv] = [], curHi = -Double.infinity
            for iv in ivs {
                let joins = o.combineEndToEnd ? iv.lo <= curHi + tol : iv.lo < curHi - tol
                if !cur.isEmpty && joins {
                    cur.append(iv); curHi = max(curHi, iv.hi)
                } else {
                    if !cur.isEmpty { clusters.append(cur) }
                    cur = [iv]; curHi = iv.hi
                }
            }
            if !cur.isEmpty { clusters.append(cur) }
            for cl in clusters {
                for iv in cl { used[iv.idx] = true }
                guard cl.count > 1 else { continue }
                // Keep the earliest object in draw order.
                let keepIv = cl.min { (order[lines[$0.idx].e.id] ?? 0) < (order[lines[$1.idx].e.id] ?? 0) }!
                let lo = cl.map(\.lo).min()!, hi = cl.map(\.hi).max()!
                var kept = lines[keepIv.idx].e
                guard case .line(let kl) = kept.kind else { continue }
                var p0 = origin + d * lo, p1 = origin + d * hi
                if (kl.end - kl.start).dot(d) < 0 { swap(&p0, &p1) }
                if !(p0.distance(to: kl.start) <= tol && p1.distance(to: kl.end) <= tol) {
                    kept.kind = .line(LineGeom(start: p0, end: p1))
                    res.modified.append(kept)
                }
                for iv in cl where iv.idx != keepIv.idx {
                    res.removed.insert(lines[iv.idx].e.id)
                    res.merged += 1
                }
            }
        }
        return res
    }

    /// Runs `overkill` and applies it. Returns the result.
    @discardableResult
    public mutating func applyOverkill(_ ids: Set<EntityID>, options: OverkillOptions = OverkillOptions()) -> OverkillResult {
        let r = overkill(ids, options: options)
        for e in r.modified { replace(e) }
        if !r.removed.isEmpty { remove(ids: r.removed) }
        return r
    }
}
