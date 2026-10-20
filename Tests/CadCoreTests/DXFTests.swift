import Foundation
import Testing
@testable import CadCore

// MARK: - Helpers

/// Compares two Codable values structurally, numbers within `tol`.
private func approxEqual<T: Encodable>(_ a: T, _ b: T, tol: Double = 1e-6) -> Bool {
    let enc = JSONEncoder()
    guard let da = try? enc.encode(a), let db = try? enc.encode(b),
          let ja = try? JSONSerialization.jsonObject(with: da, options: .fragmentsAllowed),
          let jb = try? JSONSerialization.jsonObject(with: db, options: .fragmentsAllowed) else { return false }
    return jsonClose(ja, jb, tol)
}

private func jsonClose(_ a: Any, _ b: Any, _ tol: Double) -> Bool {
    if let x = a as? [String: Any], let y = b as? [String: Any] {
        return Set(x.keys) == Set(y.keys) && x.keys.allSatisfy { jsonClose(x[$0]!, y[$0]!, tol) }
    }
    if let x = a as? [Any], let y = b as? [Any] {
        return x.count == y.count && zip(x, y).allSatisfy { jsonClose($0, $1, tol) }
    }
    if let x = a as? String, let y = b as? String { return x == y }
    if let x = a as? NSNumber, let y = b as? NSNumber { return abs(x.doubleValue - y.doubleValue) <= tol }
    return false
}

private func sameEntity(_ a: Entity, _ b: Entity) -> Bool {
    var b2 = b
    b2.id = a.id
    return approxEqual(a, b2)
}

private func sampleDrawing() -> Drawing {
    var d = Drawing()
    d.layers.append(Layer(name: "Walls", color: .aci(1), linetype: "DASHED", lineweight: 0.5))
    d.layers.append(Layer(name: "Hidden", color: .rgb(RGB(10, 200, 30)), isOn: false, isFrozen: true, isLocked: true, isPlottable: false))
    d.layers.append(Layer(name: "Ünïcode Katman"))
    d.settings.ltScale = 2.5
    d.settings.currentLayer = "Walls"
    d.settings.textHeight = 3.5
    d.settings.dimStyle.scale = 2
    d.settings.dimStyle.textHeight = 3

    let box = [Entity(.line(LineGeom(start: Vec2(0, 0), end: Vec2(10, 0)))),
               Entity(.circle(CircleGeom(center: Vec2(5, 5), radius: 2)), color: .byBlock)]
    d.blocks["BOX"] = BlockDef(name: "BOX", basePoint: Vec2(1, 2), entities: box)

    let kinds: [Entity] = [
        Entity(.line(LineGeom(start: Vec2(1.5, -2.25), end: Vec2(100.125, 33.3333333))), layer: "Walls", color: .aci(3), linetype: "DASHED", lineweight: 0.35),
        Entity(.circle(CircleGeom(center: Vec2(10, 20), radius: 7.25)), color: .rgb(RGB(12, 34, 56))),
        Entity(.arc(ArcGeom(center: Vec2(-5, 4), radius: 3, startAngle: 0.3, endAngle: 2.7)), lineweight: -2),
        Entity(.polyline(PolylineGeom(vertices: [PolyVertex(Vec2(0, 0)), PolyVertex(Vec2(10, 0), bulge: 0.5),
                                                PolyVertex(Vec2(10, 10), bulge: -0.25), PolyVertex(Vec2(0, 10))],
                                      closed: true, width: 0.5))),
        Entity(.polyline(PolylineGeom(points: [Vec2(1, 1), Vec2(2, 3), Vec2(4, 1)]))),
        Entity(.ellipse(EllipseGeom(center: Vec2(3, 4), majorAxis: Vec2(6, 2), ratio: 0.4))),
        Entity(.ellipse(EllipseGeom(center: Vec2(3, 4), majorAxis: Vec2(0, 5), ratio: 0.5, startParam: 0.5, endParam: 4))),
        Entity(.text(TextGeom(position: Vec2(1, 2), height: 2.5, text: "Hello DXF", rotation: 0.4))),
        Entity(.text(TextGeom(position: Vec2(5, 6), height: 1.8, text: "Merkez Ø50 ±0.1°", rotation: 1.2, hAlign: .center, vAlign: .middle))),
        Entity(.text(TextGeom(position: Vec2(-3, 8), height: 2, text: "Line one\nLine {two} \\ back", rotation: 0.25,
                              hAlign: .right, vAlign: .bottom, isMultiline: true, width: 40))),
        Entity(.text(TextGeom(position: Vec2(0, 50), height: 2.5, text: String(repeating: "Long mtext ", count: 60),
                              vAlign: .top, isMultiline: true))),
        Entity(.text(TextGeom(position: Vec2(0, 60), height: 2.5, text: String(repeating: "ab\\{°}\nმმ", count: 80),
                              vAlign: .top, isMultiline: true))),
        Entity(.point(PointGeom(position: Vec2(9, 9)))),
        Entity(.spline(SplineGeom(controlPoints: [Vec2(0, 0), Vec2(2, 5), Vec2(6, 5), Vec2(8, 0), Vec2(12, 3)], degree: 3,
                                  knots: [0, 0, 0, 0, 0.5, 1, 1, 1, 1]))),
        Entity(.spline(SplineGeom(fitPoints: [Vec2(0, 0), Vec2(3, 4), Vec2(7, 1), Vec2(10, 6)]))),
        Entity(.hatch(HatchGeom(loops: [[PolyVertex(Vec2(0, 0)), PolyVertex(Vec2(5, 0), bulge: 0.3), PolyVertex(Vec2(5, 5)), PolyVertex(Vec2(0, 5))]])),
               color: .aci(5)),
        Entity(.hatch(HatchGeom(loops: [[PolyVertex(Vec2(10, 0)), PolyVertex(Vec2(15, 0)), PolyVertex(Vec2(15, 5))],
                                        [PolyVertex(Vec2(11, 1)), PolyVertex(Vec2(13, 1)), PolyVertex(Vec2(13, 2))]],
                                pattern: .lines, patternName: "ANSI31", angle: .pi / 4, spacing: 2))),
        Entity(.hatch(HatchGeom(loops: [[PolyVertex(Vec2(20, 0)), PolyVertex(Vec2(25, 0)), PolyVertex(Vec2(25, 5))]],
                                pattern: .cross, patternName: "NET", angle: 0.2, spacing: 1.5))),
        Entity(.insert(InsertGeom(blockName: "BOX", position: Vec2(50, 60), scaleX: 2, scaleY: 3, rotation: 0.7)), layer: "Ünïcode Katman"),
        Entity(.dimension(DimensionGeom(kind: .linear, p1: Vec2(0, 0), p2: Vec2(10, 5), p3: Vec2(5, 12), rotation: 0))),
        Entity(.dimension(DimensionGeom(kind: .linear, p1: Vec2(0, 0), p2: Vec2(10, 5), p3: Vec2(-5, 2), rotation: .pi / 2))),
        Entity(.dimension(DimensionGeom(kind: .aligned, p1: Vec2(0, 0), p2: Vec2(10, 5), p3: Vec2(3, 8), textOverride: "<> mm"))),
        Entity(.dimension(DimensionGeom(kind: .radius, p1: Vec2(10, 20), p2: Vec2(17.25, 20), p3: Vec2(20, 22)))),
        Entity(.dimension(DimensionGeom(kind: .diameter, p1: Vec2(10, 20), p2: Vec2(10, 27.25), p3: Vec2(12, 30)))),
        Entity(.dimension(DimensionGeom(kind: .angular, p1: Vec2(0, 0), p2: Vec2(10, 0), p3: Vec2(6, 4), p4: Vec2(5, 8)))),
    ]
    for e in kinds { d.add(e) }
    return d
}

// MARK: - Round trip

@Test func dxfRoundTripPreservesEntities() throws {
    let d = sampleDrawing()
    let text = DXFWriter.write(d)
    #expect(text.utf8.allSatisfy { $0 < 0x80 }, "writer output must be ASCII")
    let r = try DXFReader.read(string: text)

    #expect(r.entities.count == d.entities.count)
    for (a, b) in zip(d.entities, r.entities) {
        #expect(sameEntity(a, b), "mismatch:\n\(a)\n\(b)")
    }
    // Block.
    let blk = try #require(r.blocks["BOX"])
    #expect(blk.basePoint == Vec2(1, 2))
    #expect(blk.entities.count == 2)
    for (a, b) in zip(d.blocks["BOX"]!.entities, blk.entities) { #expect(sameEntity(a, b)) }
    #expect(!r.blocks.keys.contains { $0.hasPrefix("*") }, "dimension blocks are not imported")
    // Layers.
    for l in d.layers {
        let rl = try #require(r.layer(named: l.name))
        #expect(rl == l, "layer \(l.name): \(rl)")
    }
    // Settings.
    #expect(r.settings.ltScale == 2.5)
    #expect(r.settings.currentLayer == "Walls")
    #expect(r.settings.textHeight == 3.5)
    #expect(r.settings.dimStyle.scale == 2)
    #expect(r.settings.dimStyle.textHeight == 3)
    #expect(r.linetype(named: "DASHED")?.pattern == [12.7, -6.35])
}

@Test func dxfWriterStructure() {
    let text = DXFWriter.write(sampleDrawing())
    let lines = text.components(separatedBy: "\n")
    // Handles must be unique.
    var handles: [String] = []
    var i = 2
    while i + 1 < lines.count {
        if (lines[i] == "5" && lines[i - 1] != "$HANDSEED") || lines[i] == "105" { handles.append(lines[i + 1]) }
        i += 2
    }
    #expect(Set(handles).count == handles.count)
    for s in ["$ACADVER", "AC1018", "$HANDSEED", "BLOCK_RECORD", "*Model_Space", "*Paper_Space", "AcDbEntity",
              "DIMSTYLE", "OBJECTS", "ACAD_GROUP", "*D1", "AcDbRotatedDimension", "SOLID", "LWPOLYLINE", "MTEXT", "HATCH", "EOF"] {
        #expect(text.contains(s), "missing \(s)")
    }
    // HANDSEED is greater than every handle.
    let seedIdx = lines.firstIndex(of: "$HANDSEED")!
    let seed = Int(lines[seedIdx + 2], radix: 16)!
    #expect(handles.allSatisfy { Int($0, radix: 16)! < seed })
}

@Test func dxfDimensionBlockGeometry() throws {
    var d = Drawing()
    d.add(Entity(.dimension(DimensionGeom(kind: .aligned, p1: Vec2(0, 0), p2: Vec2(10, 0), p3: Vec2(0, 5)))))
    let text = DXFWriter.write(d)
    #expect(text.contains("*D1"))
    #expect(text.contains("10.00"))
}

// MARK: - Hand-written input

@Test func dxfReadsR12() throws {
    let src = """
      0
    SECTION
      2
    HEADER
      9
    $ACADVER
      1
    AC1009
      9
    $LTSCALE
     40
    0.5
      9
    $DIMASZ
     40
    0.18
      0
    ENDSEC
      0
    SECTION
      2
    TABLES
      0
    TABLE
      2
    LTYPE
     70
         1
      0
    LTYPE
      2
    MYDASH
     70
         0
      3
    My dash __ __
     72
        65
     73
         2
     40
    1.5
     49
    1.0
     49
    -0.5
      0
    ENDTAB
      0
    TABLE
      2
    LAYER
     70
         2
      0
    LAYER
      2
    WALLS
     70
         4
     62
        -1
      6
    MYDASH
      0
    ENDTAB
      0
    ENDSEC
      0
    SECTION
      2
    BLOCKS
      0
    BLOCK
      8
    0
      2
    SQ
     70
         0
     10
    0.0
     20
    0.0
      0
    LINE
      8
    0
     10
    0.0
     20
    0.0
     11
    1.0
     21
    1.0
      0
    ENDBLK
      8
    0
      0
    ENDSEC
      0
    SECTION
      2
    ENTITIES
      0
    LINE
      8
    WALLS
     62
         1
     10
    0.0
     20
    0.0
     30
    0.0
     11
    10.0
     21
    5.0
     31
    0.0
      0
    ARC
      8
    ARCS
     10
    1.0
     20
    2.0
     40
    3.0
     50
    90.0
     51
    180.0
      0
    POLYLINE
      8
    0
     66
         1
     70
         1
      0
    VERTEX
      8
    0
     10
    0.0
     20
    0.0
     42
    1.0
      0
    VERTEX
      8
    0
     10
    4.0
     20
    0.0
      0
    VERTEX
      8
    0
     10
    4.0
     20
    4.0
      0
    SEQEND
      8
    0
      0
    TEXT
      8
    0
     10
    1.0
     20
    1.0
     40
    2.5
      1
    %%c20 at 45%%d
     50
    30.0
     72
         1
     11
    5.0
     21
    6.0
      0
    INSERT
      8
    0
      2
    SQ
     10
    10.0
     20
    10.0
     41
    2.0
     42
    2.0
     50
    90.0
      0
    POINT
      8
    0
     67
         1
     10
    1.0
     20
    1.0
      0
    SOLID
      8
    0
     10
    0.0
     20
    0.0
     11
    1.0
     21
    0.0
     12
    0.0
     22
    1.0
     13
    1.0
     23
    1.0
      0
    ENDSEC
      0
    EOF
    """.replacingOccurrences(of: "\n", with: "\r\n")
    let d = try DXFReader.read(string: src)
    #expect(d.settings.ltScale == 0.5)
    #expect(d.settings.dimStyle.arrowSize == 0.18)
    let walls = try #require(d.layer(named: "WALLS"))
    #expect(!walls.isOn && walls.isLocked && walls.linetype == "MYDASH" && walls.color == .aci(1))
    #expect(d.linetype(named: "MYDASH")?.pattern == [1.0, -0.5])
    #expect(d.linetype(named: "Continuous") != nil)
    #expect(d.layer(named: "0") != nil)
    #expect(d.layer(named: "ARCS") != nil, "referenced layers are created")
    #expect(d.blocks["SQ"]?.entities.count == 1)
    #expect(d.entities.count == 6, "paper-space POINT skipped")

    guard case .line(let l) = d.entities[0].kind else { Issue.record("line"); return }
    #expect(l.end == Vec2(10, 5) && d.entities[0].color == .aci(1) && d.entities[0].layer == "WALLS")
    guard case .arc(let a) = d.entities[1].kind else { Issue.record("arc"); return }
    #expect(abs(a.startAngle - .pi / 2) < 1e-12 && abs(a.endAngle - .pi) < 1e-12 && a.radius == 3)
    guard case .polyline(let p) = d.entities[2].kind else { Issue.record("polyline"); return }
    #expect(p.closed && p.vertices.count == 3 && p.vertices[0].bulge == 1)
    guard case .text(let t) = d.entities[3].kind else { Issue.record("text"); return }
    #expect(t.text == "Ø20 at 45°" && t.position == Vec2(5, 6) && t.hAlign == .center)
    #expect(abs(t.rotation - radians(30)) < 1e-12)
    guard case .insert(let ins) = d.entities[4].kind else { Issue.record("insert"); return }
    #expect(ins.blockName == "SQ" && ins.scaleX == 2 && abs(ins.rotation - .pi / 2) < 1e-12)
    guard case .hatch(let h) = d.entities[5].kind else { Issue.record("solid"); return }
    #expect(h.pattern == .solid && h.loops[0].map(\.point) == [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)])
}

private func dxf(_ pairs: [(Int, String)]) -> String {
    pairs.map { "\($0.0)\n\($0.1)" }.joined(separator: "\n") + "\n"
}

private func entitiesDXF(_ body: [(Int, String)]) -> String {
    dxf([(0, "SECTION"), (2, "ENTITIES")] + body + [(0, "ENDSEC"), (0, "EOF")])
}

@Test func dxfReadsLWPolylineWithBulge() throws {
    let src = entitiesDXF([
        (0, "LWPOLYLINE"), (5, "2F"), (100, "AcDbEntity"), (8, "P"), (370, "50"), (100, "AcDbPolyline"),
        (90, "3"), (70, "1"), (43, "0.25"),
        (10, "0"), (20, "0"), (42, "0.414213562"),
        (10, "10"), (20, "0"),
        (10, "10"), (20, "10"), (42, "-1"),
    ])
    let d = try DXFReader.read(string: src)
    #expect(d.entities.count == 1)
    let e = d.entities[0]
    #expect(e.layer == "P" && e.lineweight == 0.5)
    guard case .polyline(let p) = e.kind else { Issue.record("not a polyline"); return }
    #expect(p.closed && p.width == 0.25)
    #expect(p.vertices.map(\.point) == [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10)])
    #expect(p.vertices.map(\.bulge) == [0.414213562, 0, -1])
}

@Test func dxfMirroredOCS() throws {
    let src = entitiesDXF([
        (0, "ARC"), (10, "5"), (20, "0"), (40, "2"), (50, "0"), (51, "90"), (210, "0"), (220, "0"), (230, "-1"),
        (0, "LWPOLYLINE"), (90, "2"), (70, "0"), (10, "1"), (20, "1"), (42, "0.5"), (10, "3"), (20, "1"), (230, "-1"),
    ])
    let d = try DXFReader.read(string: src)
    guard case .arc(let a) = d.entities[0].kind, case .polyline(let p) = d.entities[1].kind else { Issue.record("kinds"); return }
    // OCS (5,0) with -Z extrusion is WCS (-5,0); the arc spans 90..180 degrees.
    #expect(a.center.isClose(to: Vec2(-5, 0)))
    #expect(abs(a.startAngle - .pi / 2) < 1e-9 && abs(a.endAngle - .pi) < 1e-9)
    #expect(p.vertices[0].point.isClose(to: Vec2(-1, 1)) && p.vertices[0].bulge == -0.5)
}

@Test func dxfReadsMTextFormattingAndUnicode() throws {
    let src = entitiesDXF([
        (0, "MTEXT"), (8, "T"), (10, "1"), (20, "2"), (40, "3"), (41, "50"), (71, "5"),
        (3, "{\\fArial|b1|i0|c0|p34;Bold} \\H2.5x;big\\Pline\\~two "),
        (1, "\\C1;red \\S1/2; \\U+00B0 \\\\path\\{x\\}"),
        (11, "0"), (21, "1"),
    ])
    let d = try DXFReader.read(string: src)
    guard case .text(let t) = d.entities[0].kind else { Issue.record("mtext"); return }
    #expect(t.text == "Bold big\nline two red 1/2 ° \\path{x}")
    #expect(t.isMultiline && t.hAlign == .center && t.vAlign == .middle && t.width == 50)
    #expect(abs(t.rotation - .pi / 2) < 1e-12)
}

@Test func dxfReadsHatchEdgesAndDimensions() throws {
    let src = entitiesDXF([
        (0, "HATCH"), (8, "H"), (10, "0"), (20, "0"), (30, "0"), (210, "0"), (220, "0"), (230, "1"),
        (2, "ANSI31"), (70, "0"), (71, "0"), (91, "1"),
        (92, "1"), (93, "3"),
        (72, "1"), (10, "0"), (20, "0"), (11, "10"), (21, "0"),
        (72, "2"), (10, "10"), (20, "5"), (40, "5"), (50, "270"), (51, "90"), (73, "1"),
        (72, "1"), (10, "10"), (20, "10"), (11, "0"), (21, "0"),
        (97, "0"),
        (75, "0"), (76, "1"), (52, "0"), (41, "2"), (77, "0"), (78, "1"),
        (53, "45"), (43, "0"), (44, "0"), (45, "-4.49013"), (46, "4.49013"), (79, "0"),
        (98, "0"),
        (0, "DIMENSION"), (8, "D"), (2, "*D5"), (10, "10"), (20, "8"), (11, "5"), (21, "8"), (70, "32"), (1, "<>"),
        (100, "AcDbAlignedDimension"), (13, "0"), (23, "0"), (14, "10"), (24, "0"), (50, "0"),
        (0, "DIMENSION"), (8, "D"), (70, "34"),
        (13, "0"), (23, "0"), (14, "10"), (24, "0"), (15, "0"), (25, "0"), (10, "0"), (20, "10"), (16, "5"), (26, "5"),
    ])
    let d = try DXFReader.read(string: src)
    #expect(d.entities.count == 3)
    guard case .hatch(let h) = d.entities[0].kind else { Issue.record("hatch"); return }
    #expect(h.pattern == .lines && h.patternName == "ANSI31")
    #expect(abs(h.angle - .pi / 4) < 1e-9 && abs(h.spacing - 6.35) < 1e-4)
    #expect(h.loops.count == 1 && h.loops[0].count == 3)
    #expect(h.loops[0][1].point.isClose(to: Vec2(10, 0)) && abs(h.loops[0][1].bulge - 1) < 1e-9)
    guard case .dimension(let dm) = d.entities[1].kind else { Issue.record("dim"); return }
    #expect(dm.kind == .linear && dm.p1 == Vec2(0, 0) && dm.p2 == Vec2(10, 0) && dm.p3 == Vec2(10, 8) && dm.textOverride.isEmpty)
    guard case .dimension(let ang) = d.entities[2].kind else { Issue.record("angular"); return }
    #expect(ang.kind == .angular && ang.p1.isClose(to: .zero) && abs(ang.measurement - 90) < 1e-9)
}

@Test func dxfDecodesLatin1AndRejectsGarbage() throws {
    var bytes = Data(entitiesDXF([(0, "TEXT"), (10, "0"), (20, "0"), (40, "1"), (1, "Gr\u{FC}n")]).utf8)
    // Re-encode as Windows-1252.
    bytes = String(decoding: bytes, as: UTF8.self).data(using: .windowsCP1252)!
    let d = try DXFReader.read(data: bytes)
    guard case .text(let t) = d.entities[0].kind else { Issue.record("text"); return }
    #expect(t.text == "Grün")

    #expect(throws: DXFError.self) { try DXFReader.read(string: "") }
    #expect(throws: DXFError.self) { try DXFReader.read(string: "hello\nworld\n") }
    #expect(throws: DXFError.self) { try DXFReader.read(string: "0\nLINE\n8\n0\n") }
}

@Test func dwgImporterReportsMissingFile() {
    #expect(throws: DXFError.self) { try DWGImporter.read(url: URL(fileURLWithPath: "/nonexistent/file.dwg")) }
}

// MARK: - Layouts

private func layoutDrawing() -> Drawing {
    var d = sampleDrawing()
    d.layers.append(Layer(name: "Furniture", color: .aci(4)))
    d.layers.append(Layer(name: "Notes"))
    let a1 = PaperSetup(name: "ISO A1 (841.00 x 594.00 MM)", width: 841, height: 594, margins: [5, 10, 5, 10])
    let a4p = PaperSetup(name: "ISO A4 (210.00 x 297.00 MM)", width: 210, height: 297, margins: [6, 7, 8, 9])
    var vp50 = ViewportGeom(center: Vec2(300, 300), width: 400, height: 250, viewCenter: Vec2(25, 30), viewHeight: 1)
    vp50.scale = 1.0 / 50
    var vp100 = ViewportGeom(center: Vec2(650, 200), width: 200, height: 150, viewCenter: Vec2(-12.5, 7.25), viewHeight: 1,
                             isLocked: true)
    vp100.scale = 1.0 / 100
    let vpFrozen = ViewportGeom(center: Vec2(105, 150), width: 180, height: 120, viewCenter: Vec2(5, 5), viewHeight: 60,
                                frozenLayers: ["Furniture", "Notes"])
    let vpOff = ViewportGeom(center: Vec2(105, 40), width: 50, height: 30, viewCenter: Vec2(1, 2), viewHeight: 10, isOn: false)
    let sheet1: [Entity] = [
        Entity(.line(LineGeom(start: Vec2(10, 10), end: Vec2(831, 10))), layer: "Notes"),
        Entity(.viewport(vp50)),
        Entity(.text(TextGeom(position: Vec2(700, 30), height: 5, text: "Sheet 1"))),
        Entity(.viewport(vp100), layer: "Notes"),
    ]
    let sheet2: [Entity] = [
        Entity(.viewport(vpFrozen)),
        Entity(.text(TextGeom(position: Vec2(20, 280), height: 3.5, text: "Portrait"))),
        Entity(.line(LineGeom(start: Vec2(5, 5), end: Vec2(205, 5)))),
        Entity(.circle(CircleGeom(center: Vec2(190, 270), radius: 8))),
        Entity(.viewport(vpOff)),
    ]
    // Deliberately out of tab order in the array.
    d.layouts = [Layout(name: "Detail Sheet", tabOrder: 2, paper: a4p, entities: sheet2),
                 Layout(name: "Plan", tabOrder: 1, paper: a1, entities: sheet1)]
    return d
}

private func viewports(_ es: [Entity]) -> [ViewportGeom] {
    es.compactMap { if case .viewport(let v) = $0.kind { return v }; return nil }
}

@Test func dxfLayoutsRoundTrip() throws {
    let d = layoutDrawing()
    let text = DXFWriter.write(d)
    #expect(text.utf8.allSatisfy { $0 < 0x80 })
    for s in ["ACAD_LAYOUT", "AcDbLayout", "AcDbPlotSettings", "*Paper_Space0", "AcDbViewport"] { #expect(text.contains(s), "missing \(s)") }
    let r = try DXFReader.read(string: text)
    #expect(r.activeLayout == nil)
    // Model space is untouched.
    #expect(r.modelEntities.count == d.modelEntities.count)
    for (a, b) in zip(d.modelEntities, r.modelEntities) { #expect(sameEntity(a, b)) }

    #expect(r.layouts.map(\.name) == ["Plan", "Detail Sheet"])
    #expect(r.layouts.map(\.tabOrder) == [1, 2])
    let src = [d.layouts[1], d.layouts[0]]
    for (a, b) in zip(src, r.layouts) {
        #expect(b.paper.name == a.paper.name)
        #expect(abs(b.paper.width - a.paper.width) < 1e-9 && abs(b.paper.height - a.paper.height) < 1e-9)
        #expect(zip(a.paper.margins, b.paper.margins).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(b.entities.count == a.entities.count, "\(a.name): \(b.entities.count) vs \(a.entities.count)")
        for (x, y) in zip(a.entities, b.entities) { #expect(sameEntity(x, y), "\(x)\n\(y)") }
        let va = viewports(a.entities), vb = viewports(b.entities)
        #expect(va.count == vb.count)
        for (x, y) in zip(va, vb) {
            #expect(x.center.isClose(to: y.center, tol: 1e-6) && abs(x.width - y.width) < 1e-6 && abs(x.height - y.height) < 1e-6)
            #expect(x.viewCenter.isClose(to: y.viewCenter, tol: 1e-6) && abs(x.viewHeight - y.viewHeight) < 1e-6)
            #expect(x.isLocked == y.isLocked && x.isOn == y.isOn && x.frozenLayers == y.frozenLayers)
        }
    }
    let plan = viewports(r.layouts[0].entities)
    #expect(abs(plan[0].scale - 1.0 / 50) < 1e-12 && abs(plan[1].scale - 1.0 / 100) < 1e-12)
    #expect(plan[1].isLocked && !plan[0].isLocked)
    let detail = viewports(r.layouts[1].entities)
    #expect(detail[0].frozenLayers == ["Furniture", "Notes"])
    #expect(!detail[1].isOn)
    #expect(r.layouts[1].paper.height > r.layouts[1].paper.width, "portrait sheet")
}

@Test func dxfWritesModelSpaceWhileLayoutActive() throws {
    var d = layoutDrawing()
    d.activeLayout = "Detail Sheet"
    #expect(d.entities.count == 5)
    let r = try DXFReader.read(string: DXFWriter.write(d))
    #expect(r.activeLayout == nil)
    #expect(r.modelEntities.count == d.modelEntities.count)
    for (a, b) in zip(d.modelEntities, r.modelEntities) { #expect(sameEntity(a, b)) }
    #expect(r.layouts.count == 2)
    #expect(r.layouts[1].entities.count == 5)
}

@Test func dxfNoPaperSpaceGetsDefaultLayout() throws {
    let r = try DXFReader.read(string: entitiesDXF([(0, "LINE"), (10, "0"), (20, "0"), (11, "1000"), (21, "500")]))
    #expect(r.layouts.count == 1 && r.layouts[0].name == "Layout1")
    let vp = try #require(viewports(r.layouts[0].entities).first)
    #expect(vp.viewCenter.isClose(to: Vec2(500, 250), tol: 1e-9))
    #expect(r.modelEntities.count == 1)
}

@Test func dxfReadsR12PaperSpace() throws {
    let src = dxf([
        (0, "SECTION"), (2, "HEADER"),
        (9, "$ACADVER"), (1, "AC1009"),
        (9, "$PLIMMIN"), (10, "-5"), (20, "-5"),
        (9, "$PLIMMAX"), (10, "415"), (20, "292"),
        (0, "ENDSEC"),
        (0, "SECTION"), (2, "ENTITIES"),
        (0, "LINE"), (8, "0"), (10, "0"), (20, "0"), (11, "10"), (21, "10"),
        (0, "LINE"), (8, "0"), (67, "1"), (10, "-5"), (20, "-5"), (11, "100"), (21, "-5"),
        (0, "TEXT"), (8, "0"), (67, "1"), (10, "20"), (20, "20"), (40, "3"), (1, "Title"),
        (0, "VIEWPORT"), (8, "0"), (67, "1"), (10, "205"), (20, "143.5"), (40, "420"), (41, "297"), (68, "1"), (69, "1"),
        (0, "VIEWPORT"), (8, "0"), (67, "1"), (10, "100"), (20, "100"), (40, "80"), (41, "60"), (68, "2"), (69, "2"),
        (12, "5"), (22, "5"), (45, "20"),
        (0, "ENDSEC"), (0, "EOF"),
    ])
    let r = try DXFReader.read(string: src)
    #expect(r.modelEntities.count == 1)
    #expect(r.layouts.count == 1 && r.layouts[0].name == "Layout1")
    let l = r.layouts[0]
    #expect(abs(l.paper.width - 420) < 1e-9 && abs(l.paper.height - 297) < 1e-9)
    #expect(l.entities.count == 3, "overall viewport is dropped")
    guard case .line(let ln) = l.entities[0].kind else { Issue.record("line"); return }
    #expect(ln.start.isClose(to: .zero, tol: 1e-9), "sheet corner moved to the origin")
    let vp = try #require(viewports(l.entities).first)
    #expect(vp.center.isClose(to: Vec2(105, 105), tol: 1e-9) && abs(vp.viewHeight - 20) < 1e-12)
}

@Test func dxfReadsLayoutObjects() throws {
    // AutoCAD-style: active layout in ENTITIES (67=1), another in *Paper_Space0, inch + rotated paper.
    let src = dxf([
        (0, "SECTION"), (2, "TABLES"),
        (0, "TABLE"), (2, "LAYER"),
        (0, "LAYER"), (5, "10"), (2, "0"), (70, "0"), (62, "7"),
        (0, "LAYER"), (5, "11"), (2, "Hidden"), (70, "0"), (62, "7"),
        (0, "ENDTAB"),
        (0, "TABLE"), (2, "BLOCK_RECORD"),
        (0, "BLOCK_RECORD"), (5, "1F"), (2, "*Model_Space"), (340, "22"),
        (0, "BLOCK_RECORD"), (5, "A0"), (2, "*Paper_Space"), (340, "B0"),
        (0, "BLOCK_RECORD"), (5, "A1"), (2, "*Paper_Space0"),
        (0, "ENDTAB"),
        (0, "ENDSEC"),
        (0, "SECTION"), (2, "BLOCKS"),
        (0, "BLOCK"), (2, "*Paper_Space0"), (70, "0"), (10, "0"), (20, "0"),
        (0, "VIEWPORT"), (67, "1"), (8, "0"), (10, "5"), (20, "4"), (40, "12"), (41, "9"), (68, "0"), (69, "0"),
        (12, "5"), (22, "4"), (45, "9"),
        (0, "VIEWPORT"), (67, "1"), (8, "0"), (10, "4"), (20, "5"), (40, "4"), (41, "3"), (68, "0"), (69, "0"),
        (12, "100"), (22, "200"), (45, "300"), (331, "11"), (90, "16384"),
        (0, "CIRCLE"), (67, "1"), (8, "0"), (10, "1"), (20, "1"), (40, "0.5"),
        (0, "ENDBLK"),
        (0, "ENDSEC"),
        (0, "SECTION"), (2, "ENTITIES"),
        (0, "VIEWPORT"), (67, "1"), (8, "0"), (10, "128.5"), (20, "97.5"), (40, "300"), (41, "220"), (68, "1"), (69, "1"),
        (12, "128.5"), (22, "97.5"), (45, "220"),
        (0, "LINE"), (67, "1"), (8, "0"), (10, "0"), (20, "0"), (11, "50"), (21, "0"),
        (0, "LINE"), (8, "0"), (10, "0"), (20, "0"), (11, "5"), (21, "5"),
        (0, "ENDSEC"),
        (0, "SECTION"), (2, "OBJECTS"),
        (0, "LAYOUT"), (5, "22"), (100, "AcDbPlotSettings"), (44, "297"), (45, "210"), (100, "AcDbLayout"), (1, "Model"),
        (71, "0"), (330, "1F"),
        (0, "LAYOUT"), (5, "B1"), (100, "AcDbPlotSettings"), (4, "ANSI_A_(8.50_x_11.00_Inches)"),
        (40, "0"), (41, "0"), (42, "0"), (43, "0"), (44, "215.9"), (45, "279.4"), (72, "0"), (73, "1"),
        (100, "AcDbLayout"), (1, "Inch Sheet"), (71, "2"), (10, "0"), (20, "0"), (11, "11"), (21, "8.5"), (330, "A1"),
        (0, "LAYOUT"), (5, "B0"), (100, "AcDbPlotSettings"), (4, "ISO_A4_(297.00_x_210.00_MM)"),
        (40, "7.5"), (41, "20"), (42, "7.5"), (43, "20"), (44, "297"), (45, "210"), (72, "1"), (73, "0"),
        (100, "AcDbLayout"), (1, "First"), (71, "1"), (10, "-7.5"), (20, "-20"), (11, "289.5"), (21, "190"),
        (0, "ENDSEC"), (0, "EOF"),
    ])
    let r = try DXFReader.read(string: src)
    #expect(r.modelEntities.count == 1)
    #expect(r.layouts.map(\.name) == ["First", "Inch Sheet"])
    let first = r.layouts[0]
    #expect(first.paper.name == "ISO A4 (297.00 x 210.00 MM)")
    #expect(abs(first.paper.width - 297) < 1e-9 && abs(first.paper.height - 210) < 1e-9)
    #expect(first.entities.count == 1, "overall viewport dropped, line kept")
    guard case .line(let ln) = first.entities[0].kind else { Issue.record("line"); return }
    #expect(ln.start.isClose(to: Vec2(7.5, 20), tol: 1e-9), "shifted so the sheet corner is at the origin")
    let inch = r.layouts[1]
    #expect(abs(inch.paper.width - 11) < 1e-9 && abs(inch.paper.height - 8.5) < 1e-9, "\(inch.paper)")
    #expect(inch.entities.count == 2)
    let vp = try #require(viewports(inch.entities).first)
    #expect(vp.isLocked && vp.isOn && vp.frozenLayers == ["Hidden"])
    #expect(abs(vp.scale - 3.0 / 300) < 1e-12)
}
