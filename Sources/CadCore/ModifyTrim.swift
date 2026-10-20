import Foundation

// MARK: - TRIM / EXTEND / BREAK / LENGTHEN

extension Drawing {
    private func trimmablePath(_ e: Entity) -> CurvePath? {
        switch e.kind {
        case .line, .arc, .circle, .polyline: return curvePath(of: e)
        default: return nil
        }
    }

    /// TRIM: removes the piece of `target` between the nearest cutting intersections around `pick`.
    /// `cuttingEdges` nil = all visible entities (quick mode). Returns 0, 1 or 2 replacement
    /// entities; the first one keeps the target's id. Circles become arcs and closed polylines
    /// become open polylines.
    public func trim(_ targetID: EntityID, pick: Vec2, cuttingEdges: Set<EntityID>?,
                     deleteIfNoIntersection: Bool = true) throws -> [Entity] {
        let e = try entityOrThrow(targetID)
        guard let path = trimmablePath(e), path.length > 0 else { throw ModifyError.cannotTrim }
        let cuts = path.cutParams(with: edgePrims(cuttingEdges, excluding: targetID))
        let L = path.length
        let eps = 1e-9 * max(1, L)
        let sp = path.project(pick)

        func none() throws -> [Entity] {
            if deleteIfNoIntersection { return [] }
            throw ModifyError.noIntersection
        }

        if path.closed {
            guard cuts.count >= 2 else { return try none() }
            let a = cuts.last(where: { $0 <= sp }) ?? cuts.last!
            let b = cuts.first(where: { $0 > sp }) ?? cuts.first!
            // Keep the part going forward from b around to a.
            let kept = path.subWrapped(b, a)
            guard !kept.isEmpty else { return [] }
            return [entityFrom(kept, closed: false, like: e, id: targetID)]
        }

        let inner = cuts.filter { $0 > eps && $0 < L - eps }
        guard !inner.isEmpty else { return try none() }
        let a = inner.last(where: { $0 <= sp }) ?? 0
        let b = inner.first(where: { $0 > sp }) ?? L
        var out: [Entity] = []
        if a > eps { out.append(entityFrom(path.sub(0, a), closed: false, like: e, id: targetID)) }
        if b < L - eps { out.append(entityFrom(path.sub(b, L), closed: false, like: e, id: targetID)) }
        return assignIDs(out, firstID: targetID)
    }

    /// EXTEND: lengthens the end of `target` nearest to `pick` to the nearest boundary
    /// intersection. Lines extend along their direction, arcs along their circle, open
    /// polylines extend their first/last segment.
    public func extend(_ targetID: EntityID, pick: Vec2, boundaries: Set<EntityID>?) throws -> Entity {
        let e = try entityOrThrow(targetID)
        let pieces: [Piece]
        switch e.kind {
        case .line, .arc: pieces = curvePath(of: e)!.pieces
        case .polyline(let p) where !p.closed: pieces = polylinePieces(p.vertices, closed: false)
        default: throw ModifyError.cannotExtend
        }
        guard let first = pieces.first, let last = pieces.last else { throw ModifyError.cannotExtend }
        let path = CurvePath(pieces, closed: false)
        let atEnd = pieces.count == 1
            ? pick.distance(to: last.end) < pick.distance(to: first.start)
            : path.project(pick) > path.length / 2
        let target = atEnd ? last : first
        let prims = edgePrims(boundaries, excluding: targetID)
        guard let ext = target.extensionToBoundary(atEnd: atEnd, boundaries: prims) else {
            throw ModifyError.noIntersection
        }
        var newPieces = pieces
        newPieces[atEnd ? pieces.count - 1 : 0] = target.extended(atEnd: atEnd, by: ext)
        return entityFrom(newPieces, closed: false, like: e, id: targetID)
    }

    /// BREAK: removes the portion between p1 and p2 (projected onto the object). When p1 == p2
    /// the object is split at that point. For circles the CCW portion from p1 to p2 is removed;
    /// for closed polylines the portion going forward (vertex order) from p1 to p2 is removed.
    public func breakEntity(_ id: EntityID, _ p1: Vec2, _ p2: Vec2) throws -> [Entity] {
        let e = try entityOrThrow(id)
        guard let path = trimmablePath(e), path.length > 0 else { throw ModifyError.cannotBreak }
        let L = path.length
        let eps = 1e-9 * max(1, L)
        let s1 = path.project(p1), s2 = path.project(p2)
        let atPoint = p1.distance(to: p2) < 1e-9 || abs(s1 - s2) < eps

        if path.closed {
            if atPoint {
                if case .circle = e.kind { throw ModifyError.fullCircleArc }
                let s = s1 > L - eps ? 0 : s1
                return [entityFrom(path.subWrapped(s, s), closed: false, like: e, id: id)]
            }
            let kept = path.subWrapped(s2, s1)
            guard !kept.isEmpty else { throw ModifyError.cannotBreak }
            return [entityFrom(kept, closed: false, like: e, id: id)]
        }

        let lo = min(s1, s2), hi = atPoint ? min(s1, s2) : max(s1, s2)
        var out: [Entity] = []
        if lo > eps { out.append(entityFrom(path.sub(0, lo), closed: false, like: e, id: id)) }
        if hi < L - eps { out.append(entityFrom(path.sub(hi, L), closed: false, like: e, id: id)) }
        if atPoint && out.count < 2 { return [e] }
        return assignIDs(out, firstID: id)
    }

    /// LENGTHEN: changes the length of a line, arc or open polyline at the end nearest `pick`.
    public func lengthen(_ id: EntityID, pick: Vec2, mode: LengthenMode) throws -> Entity {
        let e = try entityOrThrow(id)
        let pieces: [Piece]
        switch e.kind {
        case .line, .arc: pieces = curvePath(of: e)!.pieces
        case .polyline(let p) where !p.closed: pieces = polylinePieces(p.vertices, closed: false)
        default: throw ModifyError.cannotLengthen
        }
        guard let first = pieces.first, let last = pieces.last else { throw ModifyError.cannotLengthen }
        let path = CurvePath(pieces, closed: false)
        let L = path.length
        let atEnd = pieces.count == 1
            ? pick.distance(to: last.end) < pick.distance(to: first.start)
            : path.project(pick) > L / 2
        let target = atEnd ? last : first
        let delta: Double
        switch mode {
        case .delta(let d): delta = d
        case .total(let t):
            guard t > 0 else { throw ModifyError.invalidLength }
            delta = t - L
        case .percent(let p):
            guard p > 0 else { throw ModifyError.invalidLength }
            delta = L * p / 100 - L
        case .deltaAngle(let a):
            guard case let .arc(_, r, _, _) = target else { throw ModifyError.cannotLengthen }
            delta = a * r
        }
        let newPiece = target.extended(atEnd: atEnd, by: delta)
        guard target.length + delta > 1e-9 else { throw ModifyError.invalidLength }
        if case let .arc(_, _, _, w) = newPiece, abs(w) >= 2 * .pi - 1e-9 { throw ModifyError.fullCircleArc }
        var newPieces = pieces
        newPieces[atEnd ? pieces.count - 1 : 0] = newPiece
        return entityFrom(newPieces, closed: false, like: e, id: id)
    }
}
