import Foundation
import Testing
@testable import CadCore

@Test func boundaryAroundCircleCutByDiagonal() throws {
    var d = Drawing()
    d.add(Entity(.polyline(PolylineGeom(points: [Vec2(0, 0), Vec2(200, 0), Vec2(200, 120), Vec2(0, 120)], closed: true))))
    d.add(Entity(.circle(CircleGeom(center: Vec2(100, 60), radius: 40))))
    d.add(Entity(.line(LineGeom(start: Vec2(0, 0), end: Vec2(200, 120)))))
    let loop = try #require(d.boundary(around: Vec2(30, 10), using: nil))
    print("LOOP", loop.map { "\($0.point) b=\($0.bulge)" })
    let expected = 12000 - Double.pi * 1600 / 2
    #expect(abs(abs(polygonArea(loop)) - expected) < 1e-6)
}

@Test func unitsRoundTripAndFormatting() throws {
    var d = Drawing()
    #expect(d.settings.insUnits == .millimeters)
    #expect(d.settings.formatLength(1250, precision: 0) == "1250 mm")
    #expect(d.settings.formatLengthDetailed(1250).contains("125 cm"))
    #expect(d.settings.formatLengthDetailed(1250).contains("1.25 m"))
    #expect(d.settings.formatArea(1_000_000).contains("1 m²"))
    d.settings.insUnits = .centimeters
    let back = try DXFReader.read(string: DXFWriter.write(d))
    #expect(back.settings.insUnits == .centimeters)
}

@Test func viewportCenterIncludesViewTarget() throws {
    // AutoCAD/LibreDWG store the view center relative to the view target (17/27).
    let dxf = """
    0
    SECTION
    2
    ENTITIES
    0
    LINE
    8
    0
    67
    1
    10
    0
    20
    0
    11
    420
    21
    297
    0
    VIEWPORT
    8
    0
    67
    1
    10
    100
    20
    100
    40
    200
    41
    100
    12
    3841691.0
    22
    -6962807.0
    17
    -3830115.0
    27
    6965276.0
    45
    5000
    68
    1
    69
    3
    0
    ENDSEC
    0
    EOF
    """
    let d = try DXFReader.read(string: dxf)
    let vps = d.layouts.flatMap(\.entities).compactMap { e -> ViewportGeom? in if case .viewport(let v) = e.kind { return v } else { return nil } }
    let vp = try #require(vps.first)
    #expect(abs(vp.viewCenter.x - 11576) < 1e-6 && abs(vp.viewCenter.y - 2469) < 1e-6)
}

@Test func attributeKeepsOwnLayerAndColor() throws {
    var d = Drawing()
    d.ensureLayer("TAGS")
    d.blocks["B"] = BlockDef(name: "B", entities: [Entity(.line(LineGeom(start: .zero, end: Vec2(10, 0))))])
    let a = AttribValue(tag: "NO", text: TextGeom(position: Vec2(1, 1), height: 2, text: "A202"), layer: "TAGS", color: .aci(1))
    d.add(Entity(.insert(InsertGeom(blockName: "B", position: .zero, attributes: [a])), layer: "0"))
    let back = try DXFReader.read(string: DXFWriter.write(d))
    guard case .insert(let ins) = back.modelEntities.first(where: { if case .insert = $0.kind { return true } else { return false } })?.kind else {
        Issue.record("insert missing"); return
    }
    #expect(ins.attributes.first?.layer == "TAGS")
    #expect(ins.attributes.first?.color == .aci(1))
    let drawn = back.expandInsert(back.modelEntities.first { if case .insert = $0.kind { return true } else { return false } }!)
    #expect(drawn.contains { e in if case .text(let t) = e.kind { return t.text == "A202" && e.layer == "TAGS" } else { return false } })
}
