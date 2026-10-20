import Foundation

// MARK: - BOUNDARY (hatch pick point)

extension Drawing {
    /// Finds the smallest closed region around `point` formed by the given entities (nil = all
    /// visible curves). The curves are split at all mutual intersections into a planar graph,
    /// dangling edges are pruned and the bounded faces are enumerated; the smallest face that
    /// contains the point is returned as a CCW vertex loop (bulges for arcs), or nil.
    public func boundary(around point: Vec2, using ids: Set<EntityID>?) -> [PolyVertex]? {
        // 1. Candidate primitives.
        var cand: [Prim] = []
        for e in entities {
            if let ids { guard ids.contains(e.id) else { continue } } else { guard isVisible(e) else { continue } }
            switch e.kind {
            case .line, .arc, .circle, .polyline, .ellipse, .spline, .insert: cand += self.prims(of: e)
            default: continue
            }
        }
        let prims = cand.filter { $0.length > 1e-12 }
        guard !prims.isEmpty else { return nil }
        let ext = prims.reduce(BBox.empty) { $0.union($1.bbox) }
        let tol = 1e-7 * max(1, max(ext.width, ext.height))

        // 2. Split at intersections.
        let boxes = prims.map { $0.bbox.expanded(by: tol) }
        var pieces: [Piece] = []
        for (i, p) in prims.enumerated() {
            let pc = Piece(p)
            var ts: [Double] = [0, 1]
            for (j, q) in prims.enumerated() where j != i && boxes[i].intersects(boxes[j]) {
                for x in intersections(p, q) { ts.append(max(0, min(1, pc.param(of: x)))) }
            }
            if p.isFullCircle && ts.count == 2 { ts.append(0.5) }
            if p.isFullCircle && ts.filter({ $0 > 1e-9 && $0 < 1 - 1e-9 }).count == 1 {
                // Make sure a circle touched once still forms a 2-edge loop.
                ts.append(ts.first { $0 > 1e-9 && $0 < 1 - 1e-9 }! < 0.5 ? 0.75 : 0.25)
            }
            ts.sort()
            for k in 0..<(ts.count - 1) where (ts[k + 1] - ts[k]) * pc.length > tol {
                pieces.append(pc.sub(ts[k], ts[k + 1]))
            }
        }

        // 3. Planar graph.
        var nodes: [Vec2] = []
        func node(_ p: Vec2) -> Int {
            if let i = nodes.firstIndex(where: { $0.isClose(to: p, tol: tol * 10) }) { return i }
            nodes.append(p)
            return nodes.count - 1
        }
        var edges: [(u: Int, v: Int, piece: Piece)] = []
        for pc in pieces {
            let u = node(pc.start), v = node(pc.end)
            guard u != v else { continue }
            let mid = pc.point(0.5)
            if edges.contains(where: { (($0.u == u && $0.v == v) || ($0.u == v && $0.v == u)) && $0.piece.point(0.5).isClose(to: mid, tol: tol * 10) }) { continue }
            edges.append((u, v, pc))
        }
        // Prune dangling edges.
        var alive = Array(repeating: true, count: edges.count)
        var changed = true
        while changed {
            changed = false
            var deg = Array(repeating: 0, count: nodes.count)
            for (k, e) in edges.enumerated() where alive[k] { deg[e.u] += 1; deg[e.v] += 1 }
            for (k, e) in edges.enumerated() where alive[k] && (deg[e.u] < 2 || deg[e.v] < 2) {
                alive[k] = false; changed = true
            }
        }

        // 4. Half-edges sorted around each node.
        struct Half { var from: Int; var to: Int; var piece: Piece }
        var halves: [Half] = []
        for (k, e) in edges.enumerated() where alive[k] {
            halves.append(Half(from: e.u, to: e.v, piece: e.piece))
            halves.append(Half(from: e.v, to: e.u, piece: e.piece.reversed))
        }
        guard !halves.isEmpty else { return nil }
        var outgoing = Array(repeating: [Int](), count: nodes.count)
        for (h, x) in halves.enumerated() { outgoing[x.from].append(h) }
        var angleOf = Array(repeating: 0.0, count: halves.count)
        for n in nodes.indices where !outgoing[n].isEmpty {
            let minLen = outgoing[n].map { halves[$0].piece.length }.min()!
            let step = minLen * 1e-3
            for h in outgoing[n] {
                let pc = halves[h].piece
                angleOf[h] = normalizeAngle((pc.point(step / pc.length) - nodes[n]).angle)
            }
            outgoing[n].sort { angleOf[$0] < angleOf[$1] }
        }
        func twin(_ h: Int) -> Int { h ^ 1 }
        func next(_ h: Int) -> Int {
            let t = twin(h)
            let list = outgoing[halves[h].to]
            let i = list.firstIndex(of: t)!
            return list[(i - 1 + list.count) % list.count]
        }

        // 5. Faces; pick the smallest bounded face containing the point.
        var visited = Array(repeating: false, count: halves.count)
        var best: (area: Double, verts: [PolyVertex])?
        for h0 in halves.indices where !visited[h0] {
            var cycle: [Int] = []
            var h = h0
            while !visited[h] && cycle.count <= halves.count {
                visited[h] = true
                cycle.append(h)
                h = next(h)
            }
            guard h == h0 else { continue }
            let verts = cycle.map { PolyVertex(halves[$0].piece.start, bulge: halves[$0].piece.bulge) }
            let a = polygonArea(verts)
            guard a > tol * tol else { continue }
            let poly = cycle.flatMap { Array(halves[$0].piece.tessellate().dropLast()) }
            guard pointInPolygon(point, poly) else { continue }
            if a < (best?.area ?? .infinity) { best = (a, verts) }
        }
        guard let loop = best?.verts else { return nil }
        return mergeCollinear(loop)
    }
}

/// Removes vertices between two collinear straight segments of a closed loop.
private func mergeCollinear(_ v: [PolyVertex]) -> [PolyVertex] {
    var out = v
    var i = 0
    while out.count > 3 && i < out.count {
        let n = out.count
        let prev = out[(i - 1 + n) % n], cur = out[i], next = out[(i + 1) % n]
        let d1 = cur.point - prev.point, d2 = next.point - cur.point
        if abs(prev.bulge) < 1e-12 && abs(cur.bulge) < 1e-12 && d1.dot(d2) > 0 &&
            abs(d1.normalized.cross(d2.normalized)) < 1e-9 {
            out.remove(at: i)
            if i > 0 { i -= 1 }
        } else {
            i += 1
        }
    }
    return out
}
