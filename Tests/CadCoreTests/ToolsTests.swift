import Foundation
import Testing
@testable import CadCore

private func near(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-9) -> Bool { a.distance(to: b) <= tol }
private func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, layer: String = "0", color: CadColor = .byLayer) -> Entity {
    Entity(.line(LineGeom(start: Vec2(x1, y1), end: Vec2(x2, y2))), layer: layer, color: color)
}
private func circle(_ x: Double, _ y: Double, _ r: Double, layer: String = "0") -> Entity {
    Entity(.circle(CircleGeom(center: Vec2(x, y), radius: r)), layer: layer)
}
private func text(_ s: String, layer: String = "0") -> Entity {
    Entity(.text(TextGeom(position: .zero, height: 2.5, text: s)), layer: layer)
}
private func insert(_ name: String, at p: Vec2 = .zero) -> Entity {
    Entity(.insert(InsertGeom(blockName: name, position: p)))
}
private func drawing(_ es: [Entity]) -> Drawing {
    var d = Drawing()
    for e in es { d.add(e) }
    return d
}
private func lineGeom(_ e: Entity?) -> LineGeom? { if case .line(let l)? = e?.kind { return l }; return nil }

// MARK: - Wildcards

@Test func wildcardBasics() {
    #expect(wildcardMatch("*", "anything"))
    #expect(wildcardMatch("WALL*", "wall-ext"))
    #expect(!wildcardMatch("WALL*", "door"))
    #expect(wildcardMatch("A?C", "abc"))
    #expect(!wildcardMatch("A?C", "abbc"))
    #expect(wildcardMatch("#*", "1st"))
    #expect(!wildcardMatch("#*", "first"))
    #expect(wildcardMatch("door,wall*", "WALL2"))
    #expect(wildcardMatch("~wall*", "door"))
    #expect(!wildcardMatch("~wall*", "wall"))
    #expect(wildcardMatch("a`*b", "a*b"))
    #expect(!wildcardMatch("a`*b", "axb"))
    #expect(wildcardMatch("*_*", "A_B"))
}

@Test func parseHelpers() {
    #expect(parseColor("red") == .aci(1))
    #expect(parseColor("ByLayer") == .byLayer)
    #expect(parseColor("Color 30") == .aci(30))
    #expect(parseColor("255,0,0") == .rgb(RGB(255, 0, 0)))
    #expect(parseColor("nope") == nil)
    #expect(parseLineweight("0.25 mm") == 0.25)
    #expect(parseLineweight("ByLayer") == -1)
}

// MARK: - QSELECT

@Test func qselectByLayerAndType() {
    let d = drawing([line(0, 0, 10, 0, layer: "Walls"), line(0, 0, 0, 5, layer: "Doors"),
                     circle(0, 0, 5, layer: "Walls"), text("Hello", layer: "Walls")])
    #expect(d.qselectTypes() == ["Circle", "Line", "Text"])
    let walls = d.quickSelect(QSelectCriteria(property: .layer, op: .equals, value: "walls"))
    #expect(walls.count == 3)
    let wallLines = d.quickSelect(QSelectCriteria(objectType: "Line", property: .layer, op: .equals, value: "Walls"))
    #expect(wallLines == [d.entities[0].id])
    let notWalls = d.quickSelect(QSelectCriteria(property: .layer, op: .notEqual, value: "Walls"))
    #expect(notWalls == [d.entities[1].id])
    let wild = d.quickSelect(QSelectCriteria(property: .layer, op: .wildcard, value: "D*"))
    #expect(wild == [d.entities[1].id])
    let allLines = d.quickSelect(QSelectCriteria(objectType: "Line", property: .layer, op: .selectAll))
    #expect(allLines.count == 2)
}

@Test func qselectNumericAndText() {
    let d = drawing([line(0, 0, 10, 0), line(0, 0, 3, 4), circle(0, 0, 2), circle(5, 5, 8),
                     text("Room 101"), text("Kitchen"), insert("CHAIR"), insert("TABLE"), insert("CHAIR")])
    let long = d.quickSelect(QSelectCriteria(objectType: "Line", property: .length, op: .greater, value: "6"))
    #expect(long == [d.entities[0].id])
    let five = d.quickSelect(QSelectCriteria(objectType: "Line", property: .length, op: .equals, value: "5"))
    #expect(five == [d.entities[1].id])
    let small = d.quickSelect(QSelectCriteria(objectType: "Circle", property: .radius, op: .less, value: "3"))
    #expect(small == [d.entities[2].id])
    let big = d.quickSelect(QSelectCriteria(objectType: "Circle", property: .area, op: .greater, value: "100"))
    #expect(big == [d.entities[3].id])
    let room = d.quickSelect(QSelectCriteria(objectType: "Text", property: .textContents, op: .contains, value: "room"))
    #expect(room == [d.entities[4].id])
    let chairs = d.quickSelect(QSelectCriteria(objectType: "Block Reference", property: .blockName, op: .equals, value: "chair"))
    #expect(chairs.count == 2)
    // A property the object lacks never matches.
    let anyRadius = d.quickSelect(QSelectCriteria(property: .radius, op: .greater, value: "0"))
    #expect(anyRadius.count == 2)
}

@Test func qselectColorAndModes() {
    let d = drawing([line(0, 0, 1, 0, color: .aci(1)), line(0, 0, 2, 0, color: .byLayer), line(0, 0, 3, 0, color: .aci(1))])
    let red = d.quickSelect(QSelectCriteria(property: .color, op: .equals, value: "Red"))
    #expect(red == [d.entities[0].id, d.entities[2].id])
    let red1 = d.quickSelect(QSelectCriteria(property: .color, op: .equals, value: "1"))
    #expect(red1 == red)
    let excl = d.quickSelect(QSelectCriteria(property: .color, op: .equals, value: "Red"), mode: .exclude)
    #expect(excl == [d.entities[1].id])
    let appended = d.quickSelect(QSelectCriteria(property: .color, op: .equals, value: "ByLayer"), mode: .append, current: [d.entities[0].id])
    #expect(appended == [d.entities[0].id, d.entities[1].id])
    let within = d.quickSelect(QSelectCriteria(property: .color, op: .equals, value: "Red"), applyTo: [d.entities[0].id, d.entities[1].id])
    #expect(within == [d.entities[0].id])
}

@Test func qselectSkipsLockedLayers() {
    var d = drawing([line(0, 0, 1, 0, layer: "L1"), line(0, 0, 1, 0, layer: "L2")])
    d.layers[d.layers.firstIndex { $0.name == "L2" }!].isLocked = true
    #expect(d.quickSelect(QSelectCriteria(property: .layer, op: .selectAll)).count == 1)
}

// MARK: - ALIGN

@Test func alignOnePairIsTranslation() {
    let t = alignTransform(source: Vec2(1, 1), destination: Vec2(4, 5))
    #expect(near(t.apply(Vec2(0, 0)), Vec2(3, 4)))
}

@Test func alignTwoPairsRotates() {
    // Segment (0,0)-(10,0) aligned onto (5,5)-(5,7): rotate 90°, no scale.
    let t = alignTransform(source: Vec2(0, 0), destination: Vec2(5, 5), source2: Vec2(10, 0), destination2: Vec2(5, 7))
    #expect(near(t.apply(Vec2(0, 0)), Vec2(5, 5)))
    #expect(near(t.apply(Vec2(10, 0)), Vec2(5, 15)))
    #expect(abs(t.scaleFactor - 1) < 1e-12)
}

@Test func alignTwoPairsScales() {
    let t = alignTransform(source: Vec2(0, 0), destination: Vec2(5, 5), source2: Vec2(10, 0), destination2: Vec2(5, 7), scale: true)
    #expect(near(t.apply(Vec2(10, 0)), Vec2(5, 7)))
    #expect(near(t.apply(Vec2(5, 0)), Vec2(5, 6)))
    #expect(abs(t.scaleFactor - 0.2) < 1e-12)
    #expect(!t.isMirroring)
}

@Test func alignDegenerateFallsBackToTranslation() {
    let t = alignTransform(source: Vec2(0, 0), destination: Vec2(1, 1), source2: Vec2(0, 0), destination2: Vec2(3, 3))
    #expect(t == .translation(Vec2(1, 1)))
}

// MARK: - DRAWORDER

@Test func drawOrderFrontBack() {
    let es = (0..<5).map { line(Double($0), 0, Double($0), 1) }
    let ids = es.map(\.id)
    let front = reorderEntities(es, moving: [ids[1], ids[3]], .front).map(\.id)
    #expect(front == [ids[0], ids[2], ids[4], ids[1], ids[3]])
    let back = reorderEntities(es, moving: [ids[3], ids[1]], .back).map(\.id)
    #expect(back == [ids[1], ids[3], ids[0], ids[2], ids[4]])
}

@Test func drawOrderAboveUnder() {
    let es = (0..<5).map { line(Double($0), 0, Double($0), 1) }
    let ids = es.map(\.id)
    let above = reorderEntities(es, moving: [ids[0]], .above([ids[2], ids[3]])).map(\.id)
    #expect(above == [ids[1], ids[2], ids[3], ids[0], ids[4]])
    let under = reorderEntities(es, moving: [ids[4]], .under([ids[1], ids[3]])).map(\.id)
    #expect(under == [ids[0], ids[4], ids[1], ids[2], ids[3]])
    // References that are themselves moved are ignored; no remaining reference = unchanged.
    #expect(reorderEntities(es, moving: [ids[0]], .above([ids[0]])).map(\.id) == ids)
}

@Test func textToFront() {
    var d = drawing([text("A"), line(0, 0, 1, 1),
                     Entity(.dimension(DimensionGeom(kind: .aligned, p1: .zero, p2: Vec2(1, 0), p3: Vec2(0, 1)))),
                     circle(0, 0, 1)])
    let ids = d.entities.map(\.id)
    #expect(d.textToFront(.text) == 1)
    #expect(d.entities.map(\.id) == [ids[1], ids[2], ids[3], ids[0]])
    #expect(d.textToFront(.all) == 2)
    #expect(d.entities.map(\.id) == [ids[1], ids[3], ids[2], ids[0]])
}

// MARK: - GROUP

@Test func groupLifecycle() throws {
    var d = drawing([line(0, 0, 1, 0), line(0, 0, 0, 1), circle(0, 0, 1)])
    let ids = d.entities.map(\.id)
    let anon = try d.createGroup(name: nil, members: [ids[0], ids[1]])
    #expect(anon == "*A1")
    #expect(d.nextAnonymousGroupName() == "*A2")
    #expect(throws: GroupError.invalidName("*a1")) { try d.createGroup(name: "*a1", members: [ids[2]]) }
    let named = try d.createGroup(name: "Chairs", description: "all chairs", members: [ids[2]])
    #expect(named == "Chairs")
    #expect(throws: GroupError.duplicateName("chairs")) { try d.createGroup(name: "chairs", members: [ids[0]]) }
    #expect(throws: GroupError.empty) { try d.createGroup(name: "X", members: []) }
    #expect(d.expandingGroups([ids[0]]) == [ids[0], ids[1]])

    #expect(try d.addToGroup("chairs", [ids[0], ids[2]]) == 1)
    #expect(d.groups[1].members == [ids[2], ids[0]])
    #expect(try d.removeFromGroup("Chairs", [ids[2]]) == 1)
    try d.renameGroup("Chairs", to: "Seats")
    #expect(d.groupIndex(named: "seats") == 1)
    #expect(throws: GroupError.invalidName("*A1")) { try d.renameGroup("Seats", to: "*A1") }
    try d.createGroup(name: "Other", members: [ids[1]])
    #expect(throws: GroupError.duplicateName("other")) { try d.renameGroup("Seats", to: "other") }
    try d.deleteGroup(named: "Other")

    #expect(d.toggleGroupSelection() == false)
    #expect(d.expandingGroups([ids[0]]) == [ids[0]])
    #expect(d.toggleGroupSelection() == true)

    let removed = d.ungroup(containing: [ids[0]])
    #expect(Set(removed) == ["*A1", "Seats"])
    #expect(d.groups.isEmpty)
}

@Test func removingLastMemberDeletesGroup() throws {
    var d = drawing([line(0, 0, 1, 0)])
    let id = d.entities[0].id
    try d.createGroup(name: "G", members: [id])
    try d.removeFromGroup("G", [id])
    #expect(d.groups.isEmpty)
}

// MARK: - OVERKILL

@Test func overkillRemovesExactDuplicates() {
    var d = drawing([line(0, 0, 10, 0), line(10, 0, 0, 0), circle(5, 5, 2), circle(5, 5, 2), circle(5, 5, 3),
                     text("A"), text("A"), line(0, 0, 10, 0, layer: "Other")])
    let ids = d.entities.map(\.id)
    let r = d.applyOverkill(Set(ids))
    #expect(r.removed == [ids[1], ids[3], ids[6]])
    #expect(r.duplicates == 3)
    #expect(d.entities.count == 5)
    // Different layer is kept unless properties are ignored.
    var o = OverkillOptions()
    o.ignoreProperties = true
    let r2 = d.overkill(Set(d.entities.map(\.id)), options: o)
    #expect(r2.removed == [ids[7]])
}

@Test func overkillMergesCollinearOverlaps() {
    var d = drawing([line(0, 0, 6, 0), line(4, 0, 10, 0), line(12, 0, 15, 0), line(15, 0, 20, 0), line(0, 1, 5, 1)])
    let ids = d.entities.map(\.id)
    let r = d.applyOverkill(Set(ids))
    #expect(r.removed == [ids[1]])
    #expect(r.merged == 1)
    #expect(d.entities.count == 4)
    let merged = lineGeom(d.entity(ids[0]))!
    #expect(near(merged.start, Vec2(0, 0)) && near(merged.end, Vec2(10, 0)))

    var o = OverkillOptions()
    o.combineEndToEnd = true
    let r2 = d.applyOverkill(Set(d.entities.map(\.id)), options: o)
    #expect(r2.removed == [ids[3]])
    let joined = lineGeom(d.entity(ids[2]))!
    #expect(near(joined.start, Vec2(12, 0)) && near(joined.end, Vec2(20, 0)))
}

@Test func overkillContainedReversedAndDiagonal() {
    var d = drawing([line(10, 10, 0, 0), line(2, 2, 5, 5), line(0, 10, 10, 0)])
    let ids = d.entities.map(\.id)
    let r = d.applyOverkill(Set(ids))
    #expect(r.removed == [ids[1]])
    #expect(r.modified.isEmpty) // kept line already spans the union
    let kept = lineGeom(d.entity(ids[0]))!
    #expect(near(kept.start, Vec2(10, 10)) && near(kept.end, Vec2(0, 0)))
}

@Test func overkillArcOnCircleAndPolylines() {
    let arc = Entity(.arc(ArcGeom(center: .zero, radius: 5, startAngle: 0, endAngle: 1)))
    let p1 = Entity(.polyline(PolylineGeom(points: [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1)])))
    let p2 = Entity(.polyline(PolylineGeom(points: [Vec2(1, 1), Vec2(1, 0), Vec2(0, 0)])))
    var d = drawing([circle(0, 0, 5), arc, p1, p2])
    let ids = d.entities.map(\.id)
    let r = d.applyOverkill(Set(ids))
    #expect(r.removed == [ids[1], ids[3]])
}

@Test func overkillLeavesUnselectedAlone() {
    let d = drawing([line(0, 0, 10, 0), line(0, 0, 10, 0)])
    #expect(d.overkill([d.entities[0].id]).isEmpty)
}

// MARK: - COUNT / FIND

@Test func countBlocks() {
    let d = drawing([insert("Chair"), insert("Table"), insert("Chair"), line(0, 0, 1, 1)])
    let c = d.blockCounts()
    #expect(c.map(\.name) == ["Chair", "Table"])
    #expect(c.map(\.count) == [2, 1])
    #expect(d.blockReferences(named: "chair").count == 2)
    #expect(d.blockCounts(in: [d.entities[1].id]).map(\.count) == [1])
}

@Test func findAndReplace() {
    var ins = InsertGeom(blockName: "TAG", position: .zero)
    ins.attributes = [AttribValue(tag: "NO", text: TextGeom(position: .zero, height: 1, text: "Door 12"))]
    var d = drawing([text("Door frame"), text("indoor"), Entity(.insert(ins)), text("DOOR")])
    let ids = d.entities.map(\.id)
    #expect(d.findText("door") == ids)
    #expect(d.findText("door", options: FindOptions(matchCase: false, wholeWords: true)) == [ids[0], ids[2], ids[3]])
    #expect(d.findText("Door", options: FindOptions(matchCase: true)) == [ids[0], ids[2]])
    let n = d.replaceText("door", with: "Gate", options: FindOptions(wholeWords: true))
    #expect(n == 3)
    if case .text(let t) = d.entities[0].kind { #expect(t.text == "Gate frame") }
    if case .text(let t) = d.entities[1].kind { #expect(t.text == "indoor") }
    if case .insert(let i) = d.entities[2].kind { #expect(i.attributes[0].value == "Gate 12") }
}
