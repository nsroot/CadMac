import Foundation
import Testing
@testable import CadCore

// MARK: - Helpers

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }
private func near(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-6) -> Bool { a.distance(to: b) <= tol }

private func L(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Entity {
    Entity(.line(LineGeom(start: Vec2(x1, y1), end: Vec2(x2, y2))), layer: "Walls", color: .aci(3))
}
private func lineGeom(_ e: Entity) -> LineGeom? { if case .line(let l) = e.kind { return l }; return nil }
private func arcGeom(_ e: Entity) -> ArcGeom? { if case .arc(let a) = e.kind { return a }; return nil }
private func polyGeom(_ e: Entity) -> PolylineGeom? { if case .polyline(let p) = e.kind { return p }; return nil }
private func pts(_ p: PolylineGeom) -> [Vec2] { p.vertices.map(\.point) }
private func samePoints(_ a: [Vec2], _ b: [Vec2], _ tol: Double = 1e-6) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { near($0, $1, tol) }
}
private func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Entity {
    Entity(.polyline(PolylineGeom(points: [Vec2(x0, y0), Vec2(x1, y0), Vec2(x1, y1), Vec2(x0, y1)], closed: true)))
}
private func drawing(_ es: [Entity]) -> Drawing {
    var d = Drawing()
    for e in es { d.add(e) }
    return d
}

// MARK: - TRIM

@Test func trimLineBetweenTwoCutters() throws {
    let target = L(0, 0, 10, 0)
    let d = drawing([target, L(3, -5, 3, 5), L(7, -5, 7, 5)])
    let r = try d.trim(target.id, pick: Vec2(5, 0.1), cuttingEdges: nil)
    #expect(r.count == 2)
    #expect(r[0].id == target.id && r[1].id != target.id)
    #expect(r.allSatisfy { $0.layer == "Walls" && $0.color == .aci(3) })
    let a = try #require(lineGeom(r[0])), b = try #require(lineGeom(r[1]))
    #expect(near(a.start, Vec2(0, 0)) && near(a.end, Vec2(3, 0)))
    #expect(near(b.start, Vec2(7, 0)) && near(b.end, Vec2(10, 0)))
}

@Test func trimLineEndAndExplicitEdges() throws {
    let target = L(0, 0, 10, 0)
    let c1 = L(3, -5, 3, 5), c2 = L(7, -5, 7, 5)
    let d = drawing([target, c1, c2])
    let r = try d.trim(target.id, pick: Vec2(1, 0), cuttingEdges: nil)
    #expect(r.count == 1)
    let a = try #require(lineGeom(r[0]))
    #expect(near(a.start, Vec2(3, 0)) && near(a.end, Vec2(10, 0)))
    // Only the x=7 edge is a cutting edge: picking at 5 removes 0..7.
    let r2 = try d.trim(target.id, pick: Vec2(5, 0), cuttingEdges: [c2.id])
    #expect(r2.count == 1)
    let b = try #require(lineGeom(r2[0]))
    #expect(near(b.start, Vec2(7, 0)) && near(b.end, Vec2(10, 0)))
}

@Test func trimWithoutIntersection() throws {
    let target = L(0, 0, 10, 0)
    let d = drawing([target, L(0, 5, 10, 5)])
    #expect(try d.trim(target.id, pick: Vec2(5, 0), cuttingEdges: nil).isEmpty)
    #expect(throws: ModifyError.noIntersection) {
        try d.trim(target.id, pick: Vec2(5, 0), cuttingEdges: nil, deleteIfNoIntersection: false)
    }
}

@Test func trimCircleBecomesArc() throws {
    let c = Entity(.circle(CircleGeom(center: .zero, radius: 5)))
    let d = drawing([c, L(0, -10, 0, 10)])
    let r = try d.trim(c.id, pick: Vec2(5, 0), cuttingEdges: nil)
    #expect(r.count == 1)
    let a = try #require(arcGeom(r[0]))
    #expect(near(a.startAngle, .pi / 2) && near(a.endAngle, 3 * .pi / 2) && near(a.radius, 5))
}

@Test func trimArc() throws {
    let arc = Entity(.arc(ArcGeom(center: .zero, radius: 5, startAngle: 0, endAngle: .pi)))
    let d = drawing([arc, L(0, -10, 0, 10)])
    let r = try d.trim(arc.id, pick: Vec2.polar(5, radians(30)), cuttingEdges: nil)
    let a = try #require(arcGeom(r.first!))
    #expect(r.count == 1 && near(a.startAngle, .pi / 2) && near(a.endAngle, .pi))
}

@Test func trimClosedPolylineWrapsAround() throws {
    let p = rect(0, 0, 10, 10)
    let d = drawing([p, L(5, -5, 5, 15)])
    let r = try d.trim(p.id, pick: Vec2(10, 5), cuttingEdges: nil)
    let g = try #require(polyGeom(r.first!))
    #expect(r.count == 1 && !g.closed)
    #expect(samePoints(pts(g), [Vec2(5, 10), Vec2(0, 10), Vec2(0, 0), Vec2(5, 0)]))
}

@Test func trimBulgedPolylineKeepsPartialBulge() throws {
    // Semicircle from (0,0) to (10,0) through (5,-5).
    let p = Entity(.polyline(PolylineGeom(vertices: [PolyVertex(Vec2(0, 0), bulge: 1), PolyVertex(Vec2(10, 0))])))
    let d = drawing([p, L(5, -10, 5, 10)])
    let r = try d.trim(p.id, pick: Vec2(1.5, -3.5), cuttingEdges: nil)
    let g = try #require(polyGeom(r.first!))
    #expect(g.vertices.count == 2)
    #expect(near(g.vertices[0].point, Vec2(5, -5)) && near(g.vertices[1].point, Vec2(10, 0)))
    #expect(near(g.vertices[0].bulge, tan(.pi / 8)))
}

// MARK: - EXTEND

@Test func extendLineBothEnds() throws {
    let t = L(0, 0, 5, 0)
    let d = drawing([t, L(10, -5, 10, 5), L(-3, -5, -3, 5)])
    let a = try #require(lineGeom(try d.extend(t.id, pick: Vec2(4, 0), boundaries: nil)))
    #expect(near(a.start, Vec2(0, 0)) && near(a.end, Vec2(10, 0)))
    let b = try #require(lineGeom(try d.extend(t.id, pick: Vec2(1, 0), boundaries: nil)))
    #expect(near(b.start, Vec2(-3, 0)) && near(b.end, Vec2(5, 0)))
    #expect(throws: ModifyError.noIntersection) { try d.extend(t.id, pick: Vec2(4, 0), boundaries: []) }
}

@Test func extendArcAndPolyline() throws {
    let arc = Entity(.arc(ArcGeom(center: .zero, radius: 5, startAngle: 0, endAngle: .pi / 2)))
    let pl = Entity(.polyline(PolylineGeom(points: [Vec2(0, 20), Vec2(5, 20), Vec2(5, 25)])))
    let wall = L(-10, -1, 10, -1)
    let top = L(-10, 30, 10, 30)
    let d = drawing([arc, pl, wall, top])
    let a = try #require(arcGeom(try d.extend(arc.id, pick: Vec2(0.5, 4.9), boundaries: [wall.id])))
    // Circle meets y=-1 at angle pi + asin(1/5).
    #expect(near(a.startAngle, 0) && near(a.endAngle, .pi + asin(0.2)))
    let p = try #require(polyGeom(try d.extend(pl.id, pick: Vec2(5, 24), boundaries: [top.id])))
    #expect(samePoints(pts(p), [Vec2(0, 20), Vec2(5, 20), Vec2(5, 30)]))
}

// MARK: - OFFSET

@Test func offsetLineCircleArc() throws {
    let l = L(0, 0, 10, 0)
    let c = Entity(.circle(CircleGeom(center: .zero, radius: 5)))
    let a = Entity(.arc(ArcGeom(center: .zero, radius: 5, startAngle: 0, endAngle: .pi)))
    let d = drawing([l, c, a])
    let up = try #require(lineGeom(try d.offset(l.id, distance: 2, side: Vec2(5, 3))))
    #expect(near(up.start, Vec2(0, 2)) && near(up.end, Vec2(10, 2)))
    let down = try d.offset(l.id, distance: 2, side: Vec2(5, -1))
    #expect(down.id != l.id && down.layer == "Walls")
    #expect(near(lineGeom(down)!.start, Vec2(0, -2)))
    if case .circle(let cg) = try d.offset(c.id, distance: 1, side: Vec2(1, 0)).kind { #expect(near(cg.radius, 4)) } else { Issue.record("not circle") }
    if case .circle(let cg) = try d.offset(c.id, distance: 1, side: Vec2(9, 0)).kind { #expect(near(cg.radius, 6)) } else { Issue.record("not circle") }
    let ao = try #require(arcGeom(try d.offset(a.id, distance: 2, side: Vec2(0, 10))))
    #expect(near(ao.radius, 7) && near(ao.startAngle, 0) && near(ao.endAngle, .pi))
    #expect(throws: ModifyError.offsetTooLarge) { try d.offset(c.id, distance: 6, side: .zero) }
    let through = try #require(lineGeom(try d.offsetThrough(l.id, point: Vec2(3, 4))))
    #expect(near(through.start, Vec2(0, 4)) && near(through.end, Vec2(10, 4)))
}

@Test func offsetOpenPolylineMiter() throws {
    let p = Entity(.polyline(PolylineGeom(points: [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10)])))
    let d = drawing([p])
    let inner = try #require(polyGeom(try d.offset(p.id, distance: 1, side: Vec2(5, 1))))
    #expect(samePoints(pts(inner), [Vec2(0, 1), Vec2(9, 1), Vec2(9, 10)]))
    let outer = try #require(polyGeom(try d.offset(p.id, distance: 1, side: Vec2(5, -3))))
    #expect(samePoints(pts(outer), [Vec2(0, -1), Vec2(11, -1), Vec2(11, 10)]))
}

@Test func offsetClosedPolylineInAndOut() throws {
    let p = rect(0, 0, 10, 10)
    let d = drawing([p])
    let inner = try #require(polyGeom(try d.offset(p.id, distance: 1, side: Vec2(5, 5))))
    #expect(inner.closed)
    #expect(samePoints(pts(inner), [Vec2(1, 1), Vec2(9, 1), Vec2(9, 9), Vec2(1, 9)]))
    let outer = try #require(polyGeom(try d.offset(p.id, distance: 1, side: Vec2(-3, 5))))
    #expect(near(abs(polygonArea(outer.vertices)), 144))
}

@Test func offsetRoundedPolylineKeepsArcs() throws {
    // Rectangle 10x10 with r=2 fillets, offset outward by 1: area = 12*12 - (4 - pi)*3^2.
    let base = drawing([rect(0, 0, 10, 10)])
    let rounded = try base.filletPolyline(base.entities[0].id, radius: 2)
    let d = drawing([rounded])
    let out = try #require(polyGeom(try d.offset(rounded.id, distance: 1, side: Vec2(-5, 5))))
    #expect(out.vertices.count == 8)
    #expect(near(abs(polygonArea(out.vertices)), 144 - (4 - .pi) * 9, 1e-6))
    // Inward by 3 collapses the r=2 arcs: plain 4x4 square.
    let inn = try #require(polyGeom(try d.offset(rounded.id, distance: 3, side: Vec2(5, 5))))
    #expect(near(abs(polygonArea(inn.vertices)), 16, 1e-6))
}

// MARK: - FILLET / CHAMFER

@Test func filletPerpendicularLines() throws {
    let l1 = L(-5, 0, 10, 0), l2 = L(0, -5, 0, 10)
    let d = drawing([l1, l2])
    let r = try d.fillet(l1.id, pick1: Vec2(5, 0), l2.id, pick2: Vec2(0, 5), radius: 2)
    #expect(r.modified.map(\.id) == [l1.id, l2.id])
    let a = try #require(lineGeom(r.modified[0])), b = try #require(lineGeom(r.modified[1]))
    #expect(near(a.start, Vec2(2, 0)) && near(a.end, Vec2(10, 0)))
    #expect(near(b.start, Vec2(0, 2)) && near(b.end, Vec2(0, 10)))
    let arc = try #require(arcGeom(r.added[0]))
    #expect(near(arc.center, Vec2(2, 2)) && near(arc.radius, 2))
    #expect(near(arc.startAngle, .pi) && near(arc.endAngle, 3 * .pi / 2))
}

@Test func filletOppositeQuadrant() throws {
    let l1 = L(-10, 0, 10, 0), l2 = L(0, -10, 0, 10)
    let d = drawing([l1, l2])
    let r = try d.fillet(l1.id, pick1: Vec2(-5, 0), l2.id, pick2: Vec2(0, -5), radius: 1)
    let arc = try #require(arcGeom(r.added[0]))
    #expect(near(arc.center, Vec2(-1, -1)))
    #expect(near(lineGeom(r.modified[0])!.end, Vec2(-1, 0)) && near(lineGeom(r.modified[0])!.start, Vec2(-10, 0)))
    #expect(near(arc.sweep, .pi / 2))
}

@Test func filletZeroRadiusExtendsToCorner() throws {
    let l1 = L(0, 0, 5, 0), l2 = L(10, 2, 10, 10)
    let d = drawing([l1, l2])
    let r = try d.fillet(l1.id, pick1: Vec2(1, 0), l2.id, pick2: Vec2(10, 8), radius: 0)
    #expect(r.added.isEmpty)
    #expect(near(lineGeom(r.modified[0])!.end, Vec2(10, 0)) && near(lineGeom(r.modified[0])!.start, Vec2(0, 0)))
    #expect(near(lineGeom(r.modified[1])!.start, Vec2(10, 0)) && near(lineGeom(r.modified[1])!.end, Vec2(10, 10)))
}

@Test func filletErrors() throws {
    let l1 = L(0, 0, 3, 0), l2 = L(0, 0, 0, 3), l3 = L(0, 5, 10, 5)
    let d = drawing([l1, l2, l3])
    #expect(throws: ModifyError.radiusTooLarge) { try d.fillet(l1.id, pick1: Vec2(1, 0), l2.id, pick2: Vec2(0, 1), radius: 5) }
    #expect(throws: ModifyError.parallel) { try d.fillet(l1.id, pick1: Vec2(1, 0), l3.id, pick2: Vec2(2, 5), radius: 1) }
}

@Test func filletLineArc() throws {
    let line = L(-10, 0, 10, 0)
    let arc = Entity(.arc(ArcGeom(center: .zero, radius: 5, startAngle: 0, endAngle: .pi)))
    let d = drawing([line, arc])
    let r = try d.fillet(line.id, pick1: Vec2(8, 0), arc.id, pick2: Vec2.polar(5, radians(60)), radius: 1)
    let fa = try #require(arcGeom(r.added[0]))
    let cx = 35.0.squareRoot()
    #expect(near(fa.center, Vec2(cx, 1)) && near(fa.radius, 1))
    let nl = try #require(lineGeom(r.modified[0]))
    #expect(near(nl.start, Vec2(cx, 0)) && near(nl.end, Vec2(10, 0)))
    let na = try #require(arcGeom(r.modified[1]))
    #expect(near(na.startPoint, Vec2(cx, 1) * (5.0 / 6.0)) && near(na.endAngle, .pi))
    // Tangency: fillet endpoints coincide with the trimmed objects' ends.
    #expect(near(fa.startPoint, na.startPoint) || near(fa.endPoint, na.startPoint))
}

@Test func filletPolylineAllCornersAndSameObject() throws {
    let p = rect(0, 0, 10, 10)
    let d = drawing([p])
    let f = try #require(polyGeom(try d.filletPolyline(p.id, radius: 2)))
    #expect(f.vertices.count == 8 && f.closed)
    #expect(near(polygonArea(f.vertices), 100 - (4 - .pi) * 4))
    #expect(near(f.vertices[0].point, Vec2(0, 2)) && near(f.vertices[1].point, Vec2(2, 0)))
    #expect(near(f.vertices[0].bulge, tan(.pi / 8)))
    // Same polyline, adjacent segments: only that corner.
    let r = try d.fillet(p.id, pick1: Vec2(5, 0), p.id, pick2: Vec2(10, 5), radius: 1)
    let g = try #require(polyGeom(r.modified[0]))
    #expect(g.vertices.count == 5 && near(polygonArea(g.vertices), 100 - (1 - .pi / 4)))
}

@Test func chamferLines() throws {
    let l1 = L(0, 0, 10, 0), l2 = L(0, 0, 0, 10)
    let d = drawing([l1, l2])
    let r = try d.chamfer(l1.id, pick1: Vec2(5, 0), l2.id, pick2: Vec2(0, 5), d1: 2, d2: 3)
    #expect(near(lineGeom(r.modified[0])!.start, Vec2(2, 0)) && near(lineGeom(r.modified[0])!.end, Vec2(10, 0)))
    #expect(near(lineGeom(r.modified[1])!.start, Vec2(0, 3)))
    let c = try #require(lineGeom(r.added[0]))
    #expect(near(c.start, Vec2(2, 0)) && near(c.end, Vec2(0, 3)))
    #expect(throws: ModifyError.distanceTooLarge) { try d.chamfer(l1.id, pick1: Vec2(5, 0), l2.id, pick2: Vec2(0, 5), d1: 20, d2: 3) }
}

// MARK: - BREAK

@Test func breakLine() throws {
    let l = L(0, 0, 10, 0)
    let d = drawing([l])
    let r = try d.breakEntity(l.id, Vec2(7, 0.2), Vec2(3, -0.1))
    #expect(r.count == 2 && r[0].id == l.id)
    #expect(near(lineGeom(r[0])!.end, Vec2(3, 0)) && near(lineGeom(r[1])!.start, Vec2(7, 0)))
    let s = try d.breakEntity(l.id, Vec2(4, 0), Vec2(4, 0))
    #expect(s.count == 2 && near(lineGeom(s[0])!.end, Vec2(4, 0)) && near(lineGeom(s[1])!.start, Vec2(4, 0)))
    #expect(near(lineGeom(s[1])!.end, Vec2(10, 0)))
}

@Test func breakCircleAndClosedPolyline() throws {
    let c = Entity(.circle(CircleGeom(center: .zero, radius: 5)))
    let p = rect(0, 0, 10, 10)
    let d = drawing([c, p])
    let r = try d.breakEntity(c.id, Vec2(5, 0), Vec2(0, 5))
    let a = try #require(arcGeom(r[0]))
    #expect(near(a.startAngle, .pi / 2) && near(a.endAngle, 0) && near(a.sweep, 1.5 * .pi))
    #expect(throws: ModifyError.fullCircleArc) { try d.breakEntity(c.id, Vec2(5, 0), Vec2(5, 0)) }
    let b = try #require(polyGeom(try d.breakEntity(p.id, Vec2(5, 0), Vec2(10, 5)).first!))
    #expect(!b.closed)
    #expect(samePoints(pts(b), [Vec2(10, 5), Vec2(10, 10), Vec2(0, 10), Vec2(0, 0), Vec2(5, 0)]))
    let o = try #require(polyGeom(try d.breakEntity(p.id, Vec2(10, 5), Vec2(10, 5)).first!))
    #expect(!o.closed && near(o.vertices.first!.point, Vec2(10, 5)) && near(o.vertices.last!.point, Vec2(10, 5)))
}

// MARK: - JOIN

@Test func joinCollinearLinesAndArcs() throws {
    let a = L(0, 0, 5, 0), b = L(5, 0, 10, 0)
    let a1 = Entity(.arc(ArcGeom(center: .zero, radius: 3, startAngle: 0, endAngle: .pi)))
    let a2 = Entity(.arc(ArcGeom(center: .zero, radius: 3, startAngle: .pi, endAngle: 0)))
    let a3 = Entity(.arc(ArcGeom(center: .zero, radius: 3, startAngle: .pi / 2, endAngle: .pi)))
    let a4 = Entity(.arc(ArcGeom(center: .zero, radius: 3, startAngle: 0, endAngle: .pi / 2)))
    let d = drawing([a, b, a1, a2, a3, a4])
    let r = try d.join([a.id, b.id])
    #expect(r.removed == [a.id, b.id] && r.added.count == 1)
    let l = try #require(lineGeom(r.added[0]))
    #expect(near(l.start, Vec2(0, 0)) && near(l.end, Vec2(10, 0)))
    let c = try d.join([a1.id, a2.id])
    if case .circle(let cg) = c.added[0].kind { #expect(near(cg.radius, 3)) } else { Issue.record("expected circle") }
    let h = try #require(arcGeom(try d.join([a3.id, a4.id]).added[0]))
    #expect(near(h.startAngle, 0) && near(h.endAngle, .pi))
}

@Test func joinChainIntoClosedPolyline() throws {
    let es = [L(0, 0, 10, 0), L(10, 10, 10, 0), L(10, 10, 0, 10), L(0, 0, 0, 10)]
    let extra = Entity(.circle(CircleGeom(center: .zero, radius: 1)))
    let d = drawing(es + [extra])
    let r = try d.join(es.map(\.id) + [extra.id])
    #expect(r.removed == Set(es.map(\.id)))
    let p = try #require(polyGeom(r.added[0]))
    #expect(p.closed && p.vertices.count == 4 && near(abs(polygonArea(p.vertices)), 100))
    // Line + arc chain keeps the arc as a bulge.
    let l = L(-5, 0, 0, 0)
    let arc = Entity(.arc(ArcGeom(center: Vec2(3, 0), radius: 3, startAngle: 0, endAngle: .pi)))
    let d2 = drawing([l, arc])
    let q = try #require(polyGeom(try d2.join([l.id, arc.id]).added[0]))
    #expect(samePoints(pts(q), [Vec2(-5, 0), Vec2(0, 0), Vec2(6, 0)]))
    #expect(near(q.vertices[1].bulge, -1))
    #expect(throws: ModifyError.cannotJoin) { try d.join([es[0].id, extra.id]) }
}

// MARK: - EXPLODE

@Test func explodeObjects() throws {
    let pl = Entity(.polyline(PolylineGeom(vertices: [PolyVertex(Vec2(0, 0)), PolyVertex(Vec2(10, 0), bulge: 1), PolyVertex(Vec2(10, 10))])))
    var d = drawing([pl])
    let parts = try #require(d.explode(pl.id))
    #expect(parts.count == 2 && parts.allSatisfy { $0.id != pl.id })
    #expect(lineGeom(parts[0]) != nil)
    let a = try #require(arcGeom(parts[1]))
    #expect(near(a.center, Vec2(10, 5)) && near(a.radius, 5) && near(a.sweep, .pi))

    d.blocks["B"] = BlockDef(name: "B", entities: [L(0, 0, 1, 0)])
    let ins = Entity(.insert(InsertGeom(blockName: "B", position: Vec2(10, 10), scaleX: 2, scaleY: 2)))
    d.add(ins)
    let ex = try #require(d.explode(ins.id))
    #expect(ex.count == 1 && ex[0].id != ins.id)
    #expect(near(lineGeom(ex[0])!.start, Vec2(10, 10)) && near(lineGeom(ex[0])!.end, Vec2(12, 10)))

    let dim = Entity(.dimension(DimensionGeom(kind: .aligned, p1: .zero, p2: Vec2(10, 0), p3: Vec2(5, 5))))
    d.add(dim)
    let dx = try #require(d.explode(dim.id))
    #expect(dx.contains { if case .text(let t) = $0.kind { return t.text == "10.00" }; return false })
    #expect(dx.filter { if case .hatch = $0.kind { return true }; return false }.count == 2)
    #expect(d.explode(d.entities.first { if case .line = $0.kind { return true }; return false }?.id ?? UUID()) == nil)
}

// MARK: - LENGTHEN / STRETCH

@Test func lengthenModes() throws {
    let l = L(0, 0, 10, 0)
    let arc = Entity(.arc(ArcGeom(center: .zero, radius: 2, startAngle: 0, endAngle: .pi / 2)))
    let d = drawing([l, arc])
    #expect(near(lineGeom(try d.lengthen(l.id, pick: Vec2(9, 0), mode: .delta(2)))!.end, Vec2(12, 0)))
    #expect(near(lineGeom(try d.lengthen(l.id, pick: Vec2(1, 0), mode: .delta(2)))!.start, Vec2(-2, 0)))
    #expect(near(lineGeom(try d.lengthen(l.id, pick: Vec2(9, 0), mode: .total(20)))!.end, Vec2(20, 0)))
    #expect(near(lineGeom(try d.lengthen(l.id, pick: Vec2(9, 0), mode: .percent(50)))!.end, Vec2(5, 0)))
    #expect(throws: ModifyError.invalidLength) { try d.lengthen(l.id, pick: Vec2(9, 0), mode: .delta(-10)) }
    let a = try #require(arcGeom(try d.lengthen(arc.id, pick: Vec2(0, 2), mode: .deltaAngle(.pi / 2))))
    #expect(near(a.endAngle, .pi) && near(a.startAngle, 0))
    let b = try #require(arcGeom(try d.lengthen(arc.id, pick: Vec2(2, 0), mode: .delta(.pi))))
    #expect(near(b.startAngle, 1.5 * .pi))
}

@Test func stretchMovesInsideVertices() throws {
    let p = rect(0, 0, 10, 10)
    let inside = L(9, 4, 9, 6)
    let outside = L(-5, -5, -4, -4)
    let d = drawing([p, inside, outside])
    let r = d.stretch([p.id, inside.id, outside.id], window: BBox(corner: Vec2(8, -1), Vec2(12, 11)), delta: Vec2(5, 0))
    #expect(r.count == 2)
    let g = try #require(polyGeom(r.first { $0.id == p.id }!))
    #expect(samePoints(pts(g), [Vec2(0, 0), Vec2(15, 0), Vec2(15, 10), Vec2(0, 10)]))
    let m = try #require(lineGeom(r.first { $0.id == inside.id }!))
    #expect(near(m.start, Vec2(14, 4)) && near(m.end, Vec2(14, 6)))
}

// MARK: - ARRAY / DIVIDE / MEASURE

@Test func arrays() throws {
    let l = L(5, 0, 6, 0)
    let path = L(0, 20, 10, 20)
    let d = drawing([l, path])
    let rect = d.rectangularArray([l.id], rows: 2, columns: 3, rowSpacing: 10, columnSpacing: 20)
    #expect(rect.count == 5 && Set(rect.map(\.id)).count == 5 && !rect.contains { $0.id == l.id })
    let starts = Set(rect.map { lineGeom($0)!.start })
    #expect(starts == [Vec2(25, 0), Vec2(45, 0), Vec2(5, 10), Vec2(25, 10), Vec2(45, 10)])
    let polar = d.polarArray([l.id], center: .zero, count: 4, fillAngle: 2 * .pi, rotateItems: true)
    #expect(polar.count == 3)
    #expect(near(lineGeom(polar[0])!.start, Vec2(0, 5)) && near(lineGeom(polar[0])!.end, Vec2(0, 6)))
    #expect(near(lineGeom(polar[1])!.start, Vec2(-5, 0)))
    let pa = d.pathArray([l.id], path: path.id, count: 3, alignItems: false)
    #expect(pa.count == 2 && near(lineGeom(pa[0])!.start, Vec2(10, 0)) && near(lineGeom(pa[1])!.start, Vec2(15, 0)))
}

@Test func divideAndMeasure() throws {
    let l = L(0, 0, 10, 0)
    let c = Entity(.circle(CircleGeom(center: .zero, radius: 1)))
    let d = drawing([l, c])
    #expect(samePoints(d.divide(l.id, segments: 4), [Vec2(2.5, 0), Vec2(5, 0), Vec2(7.5, 0)]))
    #expect(samePoints(d.divide(c.id, segments: 4), [Vec2(1, 0), Vec2(0, 1), Vec2(-1, 0), Vec2(0, -1)]))
    #expect(samePoints(d.measure(l.id, length: 3), [Vec2(3, 0), Vec2(6, 0), Vec2(9, 0)]))
    #expect(d.measure(l.id, length: 2.5).count == 4)
}

// MARK: - AREA / PERIMETER

@Test func areaAndPerimeter() throws {
    let c = Entity(.circle(CircleGeom(center: .zero, radius: 2)))
    let disc = Entity(.polyline(PolylineGeom(vertices: [PolyVertex(Vec2(1, 0), bulge: 1), PolyVertex(Vec2(-1, 0), bulge: 1)], closed: true)))
    let sq = rect(0, 0, 10, 10)
    let holed = Entity(.hatch(HatchGeom(loops: [
        [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)].map { PolyVertex($0) },
        [Vec2(2, 2), Vec2(4, 2), Vec2(4, 4), Vec2(2, 4)].map { PolyVertex($0) },
    ])))
    let arc = Entity(.arc(ArcGeom(center: .zero, radius: 2, startAngle: 0, endAngle: .pi)))
    let el = Entity(.ellipse(EllipseGeom(center: .zero, majorAxis: Vec2(3, 0), ratio: 0.5)))
    let d = drawing([c, disc, sq, holed, arc, el])
    #expect(near(d.area(of: c.id)!, 4 * .pi))
    #expect(near(d.area(of: disc.id)!, .pi))
    #expect(near(d.area(of: sq.id)!, 100))
    #expect(near(d.area(of: holed.id)!, 96))
    #expect(near(d.area(of: el.id)!, .pi * 3 * 1.5))
    #expect(d.area(of: arc.id) == nil)
    #expect(near(d.perimeter(of: sq.id)!, 40))
    #expect(near(d.perimeter(of: arc.id)!, 2 * .pi))
    #expect(near(d.perimeter(of: disc.id)!, 2 * .pi))
    #expect(near(polygonArea([Vec2(0, 0), Vec2(0, 1), Vec2(1, 1), Vec2(1, 0)].map { PolyVertex($0) }), -1))
}

// MARK: - BOUNDARY

@Test func boundaryFromSeparateLines() throws {
    let es = [L(-2, 0, 12, 0), L(10, -2, 10, 12), L(12, 10, -2, 10), L(0, 12, 0, -2)]
    let d = drawing(es)
    let loop = try #require(d.boundary(around: Vec2(5, 5), using: nil))
    #expect(loop.count == 4)
    #expect(near(polygonArea(loop), 100))
    #expect(Set(loop.map { Vec2(($0.point.x * 1e6).rounded() / 1e6, ($0.point.y * 1e6).rounded() / 1e6) }) ==
            [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)])
    #expect(d.boundary(around: Vec2(20, 20), using: nil) == nil)
}

@Test func boundaryCircleAndPolyline() throws {
    let c = Entity(.circle(CircleGeom(center: Vec2(50, 50), radius: 5)))
    let p = rect(0, 0, 10, 10)
    let d = drawing([c, p])
    let lc = try #require(d.boundary(around: Vec2(51, 50), using: nil))
    #expect(near(polygonArea(lc), 25 * .pi))
    let lp = try #require(d.boundary(around: Vec2(1, 1), using: [p.id]))
    #expect(near(polygonArea(lp), 100))
    #expect(d.boundary(around: Vec2(51, 50), using: [p.id]) == nil)
}

@Test func boundaryOverlappingShapes() throws {
    let a = rect(0, 0, 10, 10), b = rect(5, 5, 15, 15)
    let c = Entity(.circle(CircleGeom(center: Vec2(10, 0), radius: 3)))
    let d = drawing([a, b])
    #expect(near(polygonArea(try #require(d.boundary(around: Vec2(7, 7), using: nil))), 25))
    #expect(near(polygonArea(try #require(d.boundary(around: Vec2(2, 2), using: nil))), 75))
    #expect(near(polygonArea(try #require(d.boundary(around: Vec2(12, 12), using: nil))), 75))
    // Circle overlapping a rectangle corner: the quarter disc inside the square.
    let d2 = drawing([a, c])
    let q = try #require(d2.boundary(around: Vec2(9, 1), using: nil))
    #expect(near(polygonArea(q), .pi * 9 / 4))
    #expect(q.contains { abs($0.bulge) > 0 })
    let rest = try #require(d2.boundary(around: Vec2(2, 8), using: nil))
    #expect(near(polygonArea(rest), 100 - .pi * 9 / 4))
}
