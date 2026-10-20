import Foundation
import Testing
@testable import CadCore

// MARK: - Sample drawings

func dwgwSampleBasic() -> Drawing {
    var d = Drawing()
    d.layers.append(Layer(name: "Walls", color: .aci(1), linetype: "DASHED", lineweight: 0.5))
    d.layers.append(Layer(name: "Notes", color: .rgb(RGB(10, 200, 30))))
    d.add(Entity(.line(LineGeom(start: Vec2(0, 0), end: Vec2(200, 0))), layer: "Walls"))
    d.add(Entity(.line(LineGeom(start: Vec2(200, 0), end: Vec2(200, 120))), layer: "Walls", color: .aci(5), lineweight: 0.35))
    d.add(Entity(.circle(CircleGeom(center: Vec2(60, 60), radius: 25)), layer: "Walls"))
    d.add(Entity(.arc(ArcGeom(center: Vec2(140, 60), radius: 30, startAngle: 0.2, endAngle: 2.6)), layer: "Walls", linetype: "Continuous"))
    d.add(Entity(.polyline(PolylineGeom(vertices: [PolyVertex(Vec2(10, 100)), PolyVertex(Vec2(80, 100), bulge: 0.4),
                                                   PolyVertex(Vec2(80, 140)), PolyVertex(Vec2(10, 140))], closed: true, width: 0.8)),
                 layer: "Walls"))
    d.add(Entity(.text(TextGeom(position: Vec2(10, 160), height: 5, text: "CadMac native DWG")), layer: "Notes"))
    d.add(Entity(.text(TextGeom(position: Vec2(120, 160), height: 4, text: "Merkez Ø50 ±0.1° ğüş", rotation: 0.3,
                                hAlign: .center, vAlign: .middle)), layer: "Notes"))
    return d
}

func dwgwSampleBlocks() -> Drawing {
    var d = Drawing()
    d.layers.append(Layer(name: "Furniture", color: .aci(3)))
    let tag = AttDefGeom(tag: "NAME", prompt: "Name?", defaultValue: "Table",
                         text: TextGeom(position: Vec2(0, -8), height: 2.5, text: "NAME", hAlign: .center))
    let num = AttDefGeom(tag: "NO", prompt: "Number", defaultValue: "1",
                         text: TextGeom(position: Vec2(0, -12), height: 2, text: "NO"), isInvisible: true)
    d.blocks["TABLE"] = BlockDef(name: "TABLE", basePoint: .zero, entities: [
        Entity(.polyline(PolylineGeom(points: [Vec2(-10, -5), Vec2(10, -5), Vec2(10, 5), Vec2(-10, 5)], closed: true))),
        Entity(.circle(CircleGeom(center: .zero, radius: 3)), color: .byBlock),
        Entity(.attdef(tag)), Entity(.attdef(num)),
    ])
    d.blocks["CHAIR"] = BlockDef(name: "CHAIR", basePoint: Vec2(1, 1), entities: [
        Entity(.polyline(PolylineGeom(points: [Vec2(0, 0), Vec2(4, 0), Vec2(4, 4), Vec2(0, 4)], closed: true))),
        Entity(.line(LineGeom(start: Vec2(0, 4), end: Vec2(4, 4))), lineweight: 0.5),
    ])
    let table = d.blocks["TABLE"]!
    for k in 0..<3 {
        var ins = InsertGeom(blockName: "TABLE", position: Vec2(Double(k) * 40, 0), rotation: Double(k) * 0.3)
        ins.attributes = ins.makeAttributes(block: table, values: ["NAME": "Table \(k + 1)", "NO": "\(k + 1)"])
        d.add(Entity(.insert(ins), layer: "Furniture"))
    }
    d.add(Entity(.insert(InsertGeom(blockName: "CHAIR", position: Vec2(0, 20), scaleX: 2, scaleY: 1.5)), layer: "Furniture", color: .aci(6)))
    d.add(Entity(.insert(InsertGeom(blockName: "CHAIR", position: Vec2(30, 20), scaleX: -1, scaleY: 1)), layer: "Furniture"))
    let ids = d.modelEntities.prefix(2).map(\.id)
    d.groups = [EntityGroup(name: "PAIR", description: "first two tables", members: ids)]
    return d
}

func dwgwSampleDimsHatch() -> Drawing {
    var d = Drawing()
    d.layers.append(Layer(name: "Dims", color: .aci(2)))
    d.layers.append(Layer(name: "Hatch", color: .aci(8)))
    d.add(Entity(.polyline(PolylineGeom(points: [Vec2(0, 0), Vec2(100, 0), Vec2(100, 60), Vec2(0, 60)], closed: true))))
    d.add(Entity(.circle(CircleGeom(center: Vec2(150, 30), radius: 20))))
    d.add(Entity(.dimension(DimensionGeom(kind: .linear, p1: Vec2(0, 0), p2: Vec2(100, 0), p3: Vec2(50, -15))), layer: "Dims"))
    d.add(Entity(.dimension(DimensionGeom(kind: .linear, p1: Vec2(100, 0), p2: Vec2(100, 60), p3: Vec2(115, 30), rotation: .pi / 2)), layer: "Dims"))
    d.add(Entity(.dimension(DimensionGeom(kind: .aligned, p1: Vec2(0, 60), p2: Vec2(100, 0), p3: Vec2(60, 45), textOverride: "<> mm")), layer: "Dims"))
    d.add(Entity(.dimension(DimensionGeom(kind: .radius, p1: Vec2(150, 30), p2: Vec2(170, 30), p3: Vec2(180, 45))), layer: "Dims"))
    d.add(Entity(.dimension(DimensionGeom(kind: .diameter, p1: Vec2(150, 30), p2: Vec2(150, 50), p3: Vec2(160, 65))), layer: "Dims"))
    d.add(Entity(.dimension(DimensionGeom(kind: .angular, p1: Vec2(0, 0), p2: Vec2(100, 0), p3: Vec2(30, 12), p4: Vec2(100, 60))), layer: "Dims"))
    d.add(Entity(.hatch(HatchGeom(loops: [[PolyVertex(Vec2(5, 5)), PolyVertex(Vec2(45, 5)), PolyVertex(Vec2(45, 55)), PolyVertex(Vec2(5, 55))]])),
                 layer: "Hatch", color: .aci(4)))
    d.add(Entity(.hatch(HatchGeom(loops: [[PolyVertex(Vec2(55, 5)), PolyVertex(Vec2(95, 5), bulge: 0.3), PolyVertex(Vec2(95, 55)), PolyVertex(Vec2(55, 55))]],
                                  pattern: .lines, patternName: "ANSI31", angle: .pi / 4, spacing: 3)), layer: "Hatch"))
    d.add(Entity(.hatch(HatchGeom(loops: [[PolyVertex(Vec2(130, 10)), PolyVertex(Vec2(170, 10)), PolyVertex(Vec2(170, 50)), PolyVertex(Vec2(130, 50))],
                                          [PolyVertex(Vec2(140, 20)), PolyVertex(Vec2(160, 20)), PolyVertex(Vec2(160, 40)), PolyVertex(Vec2(140, 40))]],
                                  pattern: .cross, patternName: "NET", angle: 0, spacing: 4)), layer: "Hatch"))
    d.add(Entity(.ellipse(EllipseGeom(center: Vec2(50, 100), majorAxis: Vec2(30, 10), ratio: 0.4))))
    d.add(Entity(.ellipse(EllipseGeom(center: Vec2(120, 100), majorAxis: Vec2(0, 20), ratio: 0.5, startParam: 0.5, endParam: 4))))
    d.add(Entity(.spline(SplineGeom(controlPoints: [Vec2(0, 130), Vec2(20, 160), Vec2(60, 160), Vec2(80, 130), Vec2(120, 150)], degree: 3,
                                    knots: [0, 0, 0, 0, 0.5, 1, 1, 1, 1]))))
    d.add(Entity(.spline(SplineGeom(fitPoints: [Vec2(130, 130), Vec2(150, 160), Vec2(170, 135), Vec2(200, 160)]))))
    d.add(Entity(.point(PointGeom(position: Vec2(200, 100)))))
    d.add(Entity(.text(TextGeom(position: Vec2(0, 200), height: 3.5, text: "MText line one\nline {two} \\ back slash",
                                isMultiline: true, width: 80))))
    return d
}

func dwgwSampleLayouts() -> Drawing {
    var d = Drawing()
    d.layers.append(Layer(name: "Plan", color: .aci(1)))
    d.layers.append(Layer(name: "Frame", color: .aci(7)))
    d.layers.append(Layer(name: "Viewports", color: .aci(8), isPlottable: false))
    d.add(Entity(.polyline(PolylineGeom(points: [Vec2(0, 0), Vec2(4000, 0), Vec2(4000, 3000), Vec2(0, 3000)], closed: true)), layer: "Plan"))
    d.add(Entity(.circle(CircleGeom(center: Vec2(2000, 1500), radius: 800)), layer: "Plan"))
    d.add(Entity(.text(TextGeom(position: Vec2(2000, 1500), height: 200, text: "MODEL", hAlign: .center, vAlign: .middle)), layer: "Plan"))
    let model = BBox(min: .zero, max: Vec2(4000, 3000))
    var l1 = Layout(name: "Sheet A", tabOrder: 1)
    var vp1 = ViewportGeom(center: Vec2(150, 150), width: 260, height: 200, viewCenter: .zero, viewHeight: 1)
    vp1.fit(model)
    var vp2 = ViewportGeom(center: Vec2(350, 200), width: 110, height: 90, viewCenter: Vec2(2000, 1500), viewHeight: 1800,
                           isLocked: true, frozenLayers: ["Plan"])
    vp2.scale = 0.05
    l1.entities = [Entity(.viewport(vp1), layer: "Viewports"), Entity(.viewport(vp2), layer: "Viewports"),
                   Entity(.polyline(PolylineGeom(points: [Vec2(10, 10), Vec2(410, 10), Vec2(410, 287), Vec2(10, 287)], closed: true)), layer: "Frame"),
                   Entity(.text(TextGeom(position: Vec2(300, 20), height: 5, text: "SHEET A")), layer: "Frame")]
    var l2 = Layout(name: "Sheet B", tabOrder: 2, paper: PaperSetup(name: "ISO A4 (297.00 x 210.00 MM)", width: 297, height: 210))
    var vp3 = ViewportGeom(center: Vec2(148.5, 105), width: 270, height: 180, viewCenter: .zero, viewHeight: 1)
    vp3.fit(model)
    l2.entities = [Entity(.viewport(vp3), layer: "Viewports"),
                   Entity(.text(TextGeom(position: Vec2(20, 10), height: 4, text: "SHEET B")), layer: "Frame")]
    d.layouts = [l1, l2]
    return d
}

// MARK: - Minimal structural parser (test-only)

/// Independent R2000 structure check: sections, CRCs, object map, object sizes and handle references.
private struct DWGWCheck {
    var errors: [String] = []
    var handles: [Int: Int] = [:]         // handle -> file offset
    var types: [Int: Int] = [:]           // handle -> object type
    var references: [(from: Int, to: Int)] = []
    var sections: [(rec: Int, at: Int, size: Int)] = []

    static func crc(_ seed: UInt16, _ d: ArraySlice<UInt8>) -> UInt16 { DWGBitWriter.crc(seed, d) }

    struct Bits {
        let b: [UInt8]; var p: Int
        mutating func bit() -> Int { let v = Int(b[p >> 3] >> (7 - UInt8(p & 7))) & 1; p += 1; return v }
        mutating func bits(_ n: Int) -> Int { var v = 0; for _ in 0..<n { v = v << 1 | bit() }; return v }
        mutating func rc() -> Int { bits(8) }
        mutating func rs() -> Int { let a = rc(); return a | rc() << 8 }
        mutating func rl() -> Int { let a = rs(); return a | rs() << 16 }
        mutating func bs() -> Int {
            switch bits(2) { case 0: return Int(Int16(truncatingIfNeeded: rs())); case 1: return rc(); case 2: return 0; default: return 256 }
        }
        mutating func handle() -> (code: Int, value: Int) {
            let code = bits(4), n = bits(4)
            var v = 0
            for _ in 0..<n { v = v << 8 | rc() }
            return (code, v)
        }
    }

    init(_ data: Data) {
        let f = [UInt8](data)
        guard f.count > 0x58, String(decoding: f[0..<6], as: UTF8.self) == "AC1015" else { errors.append("not AC1015"); return }
        func rl(_ at: Int) -> Int { Int(f[at]) | Int(f[at + 1]) << 8 | Int(f[at + 2]) << 16 | Int(f[at + 3]) << 24 }
        let n = rl(0x15)
        var p = 0x19
        for _ in 0..<n { sections.append((Int(f[p]), rl(p + 1), rl(p + 5))); p += 9 }
        let fileCRC = UInt16(f[p]) | UInt16(f[p + 1]) << 8
        if DWGWCheck.crc(0, f[0..<p]) ^ 0x3CC4 != fileCRC { errors.append("file header CRC") }
        if Array(f[(p + 2)..<(p + 18)]) != DWGWriterImpl.fileHeaderEnd { errors.append("file header sentinel") }

        // Header variables and classes: sentinel, size, data, CRC, sentinel.
        for (rec, start, end) in [(0, DWGWriterImpl.headerStart, DWGWriterImpl.headerEnd), (1, DWGWriterImpl.classesStart, DWGWriterImpl.classesEnd)] {
            guard let s = sections.first(where: { $0.rec == rec }) else { errors.append("missing section \(rec)"); continue }
            if Array(f[s.at..<(s.at + 16)]) != start { errors.append("section \(rec) start sentinel") }
            let size = rl(s.at + 16)
            if s.size != 16 + 4 + size + 2 + 16 { errors.append("section \(rec) size") }
            let c = UInt16(f[s.at + 20 + size]) | UInt16(f[s.at + 21 + size]) << 8
            if DWGWCheck.crc(0xC0C1, f[(s.at + 16)..<(s.at + 20 + size)]) != c { errors.append("section \(rec) CRC") }
            if Array(f[(s.at + 22 + size)..<(s.at + 38 + size)]) != end { errors.append("section \(rec) end sentinel") }
        }

        // Object map.
        guard let m = sections.first(where: { $0.rec == 2 }) else { errors.append("no object map"); return }
        var q = m.at
        while true {
            let size = Int(f[q]) << 8 | Int(f[q + 1])
            let c = UInt16(f[q + size]) << 8 | UInt16(f[q + size + 1])
            if DWGWCheck.crc(0xC0C1, f[q..<(q + size)]) != c { errors.append("object map CRC at \(q)") }
            if size > 2032 { errors.append("object map section too long") }
            if size == 2 { q += 4; break }
            var r = q + 2
            var h = 0, loc = 0
            func mc() -> Int {
                var v = 0, shift = 0
                while true {
                    let byte = Int(f[r]); r += 1
                    if byte & 0x80 != 0 { v |= (byte & 0x7F) << shift; shift += 7; continue }
                    v |= (byte & 0x3F) << shift
                    return byte & 0x40 != 0 ? -v : v
                }
            }
            while r < q + size {
                h += mc(); loc += mc()
                if handles[h] != nil { errors.append("duplicate handle \(h)") }
                handles[h] = loc
            }
            q += size + 2
        }
        if q - m.at != m.size { errors.append("object map size") }

        // Objects.
        for (h, loc) in handles.sorted(by: { $0.key < $1.key }) {
            var r = loc
            var size = 0, shift = 0
            while true {
                let s = Int(f[r]) | Int(f[r + 1]) << 8; r += 2
                size |= (s & 0x7FFF) << shift; shift += 15
                if s & 0x8000 == 0 { break }
            }
            let c = UInt16(f[r + size]) | UInt16(f[r + size + 1]) << 8
            if DWGWCheck.crc(0xC0C1, f[loc..<(r + size)]) != c { errors.append("object \(h) CRC") }
            var b = Bits(b: Array(f[r..<(r + size)]), p: 0)
            let type = b.bs()
            types[h] = type
            let bitSize = b.rl()
            let own = b.handle()
            if own.value != h { errors.append("object at handle \(h) says \(own.value)") }
            if bitSize > size * 8 { errors.append("object \(h) bit size past end") }
            // Handle stream: from bitSize to the end (padding < 8 bits).
            var hb = Bits(b: b.b, p: bitSize)
            while size * 8 - hb.p >= 8 {
                let ref = hb.handle()
                if ref.value != 0 { references.append((h, ref.value)) }
                if hb.p > size * 8 { errors.append("object \(h) handle stream overrun"); break }
            }
        }
        for r in references where handles[r.to] == nil { errors.append("object \(r.from) references missing handle \(r.to)") }
    }
}

// MARK: - Tests

private func checkStructure(_ d: Drawing, sourceLocation: SourceLocation = #_sourceLocation) throws -> Data {
    let data = try NativeDWGWriter.write(d)
    let c = DWGWCheck(data)
    #expect(c.errors.isEmpty, "\(c.errors.prefix(20))", sourceLocation: sourceLocation)
    #expect(c.handles.count > 30, sourceLocation: sourceLocation)
    return data
}

@Test func dwgWriterBitEncodings() {
    var w = DWGBitWriter()
    w.bs(0); w.bs(256); w.bs(15); w.bs(257); w.bs(-1)
    var r = (w.bytes, 0)
    func bits(_ n: Int) -> Int {
        var v = 0
        for _ in 0..<n { v = v << 1 | Int(r.0[r.1 >> 3] >> (7 - UInt8(r.1 & 7))) & 1; r.1 += 1 }
        return v
    }
    #expect(bits(2) == 2)
    #expect(bits(2) == 3)
    #expect(bits(2) == 1 && bits(8) == 15)
    #expect(bits(2) == 0 && bits(8) == 1 && bits(8) == 1)
    #expect(bits(2) == 0 && bits(16) == 0xFFFF)
    // Modular chars from the spec examples.
    #expect(DWGBitWriter.modularChar(4610) == [0x82, 0x24])
    #expect(DWGBitWriter.modularChar(112823273) == [0xE9, 0x97, 0xE6, 0x35])
    #expect(DWGBitWriter.modularChar(-1413) == [0x85, 0x4B])
    #expect(DWGBitWriter.modularShort(4650033) == [0x31, 0xF4, 0x8D, 0x00])
    // Handle reference 5.2.05.E7.
    var h = DWGBitWriter()
    h.h(5, 0x5E7)
    #expect(h.bytes == [0x52, 0x05, 0xE7])
    // DD with default.
    var dd = DWGBitWriter()
    dd.dd(3.5, default: 3.5)
    #expect(dd.bitCount == 2)
    #expect(DWGBitWriter.encodeText("Ağ°") == Array("A\\U+011F".utf8) + [0xB0])
}

@Test func dwgWriterStructureBasic() throws { _ = try checkStructure(dwgwSampleBasic()) }
@Test func dwgWriterStructureBlocks() throws { _ = try checkStructure(dwgwSampleBlocks()) }
@Test func dwgWriterStructureDimsHatch() throws { _ = try checkStructure(dwgwSampleDimsHatch()) }
@Test func dwgWriterStructureLayouts() throws { _ = try checkStructure(dwgwSampleLayouts()) }
@Test func dwgWriterStructureEmpty() throws { _ = try checkStructure(Drawing()) }

/// Writes the sample files for manual testing in AutoCAD when CADMAC_DWG_SAMPLES is set
/// (e.g. `CADMAC_DWG_SAMPLES=1 swift test --filter dwgWriterSamples`).
@Test func dwgWriterSamples() throws {
    guard ProcessInfo.processInfo.environment["CADMAC_DWG_SAMPLES"] != nil else { return }
    let dir = URL(fileURLWithPath: "/Users/nikasert/Desktop/CadMac/DWG-Test")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try NativeDWGWriter.write(dwgwSampleBasic(), to: dir.appendingPathComponent("01-basic.dwg"))
    try NativeDWGWriter.write(dwgwSampleBlocks(), to: dir.appendingPathComponent("02-blocks-attributes.dwg"))
    try NativeDWGWriter.write(dwgwSampleDimsHatch(), to: dir.appendingPathComponent("03-dimensions-hatch.dwg"))
    try NativeDWGWriter.write(dwgwSampleLayouts(), to: dir.appendingPathComponent("04-layouts.dwg"))
    if Corpus.hasSampleDXF, let data = try? Data(contentsOf: URL(fileURLWithPath: Corpus.sampleDXF)) {
        let d = try DXFReader.read(data: data)
        try NativeDWGWriter.write(d, to: dir.appendingPathComponent("05-poker-roundtrip.dwg"))
    }
}


// MARK: - Round trip through NativeDWGReader

private func dwgwJSON<T: Encodable>(_ v: T) -> Any? {
    guard let d = try? JSONEncoder().encode(v) else { return nil }
    return try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed)
}

private func dwgwClose(_ a: Any?, _ b: Any?, _ tol: Double) -> Bool {
    if let x = a as? [String: Any], let y = b as? [String: Any] {
        return Set(x.keys) == Set(y.keys) && x.keys.allSatisfy { dwgwClose(x[$0], y[$0], tol) }
    }
    if let x = a as? [Any], let y = b as? [Any] { return x.count == y.count && zip(x, y).allSatisfy { dwgwClose($0, $1, tol) } }
    if let x = a as? String, let y = b as? String { return x == y }
    if let x = a as? NSNumber, let y = b as? NSNumber { return abs(x.doubleValue - y.doubleValue) <= tol }
    return a == nil && b == nil
}

/// What an entity should look like after DWG -> Drawing: R2000 has no true color, fit splines are
/// stored as their control polygon, MTEXT baseline means top, ATTRIBs carry their own layer/color.
private func dwgwExpected(_ e: Entity) -> Entity {
    var e = e
    if case .rgb(let c) = e.color { e.color = .aci(nearestACI(c)) }
    switch e.kind {
    case .spline(let s) where s.controlPoints.isEmpty:
        if let sp = DWGWriterImpl.splineData(s) {
            e.kind = .spline(SplineGeom(controlPoints: sp.cps, degree: sp.degree, knots: sp.knots, closed: s.closed))
        }
    case .text(var t) where t.isMultiline && t.vAlign == .baseline:
        t.vAlign = .top
        e.kind = .text(t)
    case .insert(var i):
        for k in i.attributes.indices {
            if i.attributes[k].layer == nil { i.attributes[k].layer = e.layer }
            if i.attributes[k].color == nil { i.attributes[k].color = e.color }
        }
        e.kind = .insert(i)
    default: break
    }
    return e
}

private func dwgwSameEntities(_ a: [Entity], _ b: [Entity], _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a.count == b.count, "\(what): \(a.count) vs \(b.count) entities", sourceLocation: sourceLocation)
    for (x, y) in zip(a, b) {
        let ex = dwgwExpected(x)
        var y2 = y
        y2.id = ex.id
        #expect(dwgwClose(dwgwJSON(ex), dwgwJSON(y2), 1e-6), "\(what) mismatch:\n\(ex)\n\(y2)", sourceLocation: sourceLocation)
    }
}

private func dwgwRoundTrip(_ d: Drawing, sourceLocation: SourceLocation = #_sourceLocation) throws -> Drawing {
    let data = try NativeDWGWriter.write(d)
    let rep = try NativeDWGReader.report(data: data)
    #expect(rep.version == "AC1015", sourceLocation: sourceLocation)
    #expect(rep.crcErrors == 0 && rep.checksumErrors == 0, sourceLocation: sourceLocation)
    #expect(rep.unresolvedHandles == 0 && rep.unresolvedLayers == 0 && rep.unresolvedOwners == 0, sourceLocation: sourceLocation)
    #expect(rep.decodedCount == rep.objectCount, sourceLocation: sourceLocation)
    // The reader only reads the name of STYLE records.
    #expect(Set(rep.misaligned.keys).isSubset(of: ["STYLE"]), "misaligned: \(rep.misaligned)", sourceLocation: sourceLocation)
    let r = try NativeDWGReader.read(data: data)
    dwgwSameEntities(d.modelEntities, r.modelEntities, "model", sourceLocation: sourceLocation)
    #expect(r.layouts.map(\.name) == d.layouts.map(\.name), sourceLocation: sourceLocation)
    for (la, lb) in zip(d.layouts, r.layouts) {
        dwgwSameEntities(la.entities, lb.entities, "layout \(la.name)", sourceLocation: sourceLocation)
        #expect(la.paper.width == lb.paper.width && la.paper.height == lb.paper.height, sourceLocation: sourceLocation)
    }
    #expect(Set(r.blocks.keys) == Set(d.blocks.keys), sourceLocation: sourceLocation)
    for (name, b) in d.blocks {
        guard let rb = r.blocks[name] else { continue }
        #expect(rb.basePoint == b.basePoint, sourceLocation: sourceLocation)
        dwgwSameEntities(b.entities, rb.entities, "block \(name)", sourceLocation: sourceLocation)
    }
    for l in d.layers {
        var ex = l
        if case .rgb(let c) = l.color { ex.color = .aci(nearestACI(c)) }
        #expect(r.layer(named: l.name) == ex, "layer \(l.name): \(String(describing: r.layer(named: l.name)))", sourceLocation: sourceLocation)
    }
    #expect(r.settings.insUnits == d.settings.insUnits, sourceLocation: sourceLocation)
    #expect(r.groups.count == d.groups.count, sourceLocation: sourceLocation)
    for (g, rg) in zip(d.groups, r.groups) {
        #expect(rg.name == g.name && rg.description == g.description && rg.isSelectable == g.isSelectable, sourceLocation: sourceLocation)
        let ids = Set(d.modelEntities.map(\.id))
        let positions = g.members.compactMap { m in d.modelEntities.firstIndex { $0.id == m } }
        let rpositions = rg.members.compactMap { m in r.modelEntities.firstIndex { $0.id == m } }
        #expect(positions == rpositions, sourceLocation: sourceLocation)
        _ = ids
    }
    return r
}

@Test func dwgWriterRoundTripBasic() throws {
    var d = dwgwSampleBasic()
    d.settings.insUnits = .centimeters
    d.layers.append(Layer(name: "Off", color: .aci(4), isOn: false))
    d.layers.append(Layer(name: "FrozenLocked", color: .aci(6), lineweight: 0.25, isFrozen: true, isLocked: true, isPlottable: false))
    let r = try dwgwRoundTrip(d)
    #expect(r.settings.insUnits == .centimeters)
    #expect(r.layer(named: "Off")?.isOn == false)
}

/// Real drawings hold `yazı` and `YAZI` as two separate layers; a save must keep both and keep the
/// entities on the layer they were drawn on.
@Test func dwgWriterKeepsLayersThatDifferOnlyByCase() throws {
    var d = dwgwSampleBasic()
    d.layers.append(Layer(name: "yazı", color: .aci(3)))
    d.layers.append(Layer(name: "YAZI", color: .aci(3)))
    d.add(Entity(.line(LineGeom(start: Vec2(300, 0), end: Vec2(320, 20))), layer: "YAZI"))
    d.add(Entity(.line(LineGeom(start: Vec2(300, 30), end: Vec2(320, 50))), layer: "yazı"))
    let r = try dwgwRoundTrip(d)
    #expect(Set(r.layers.map(\.name)).isSuperset(of: ["yazı", "YAZI"]), "layers: \(r.layers.map(\.name))")
    #expect(r.modelEntities.filter { $0.layer == "YAZI" }.count == 1)
    #expect(r.modelEntities.filter { $0.layer == "yazı" }.count == 1)
}

@Test func dwgWriterRoundTripBlocksAttributesGroups() throws {
    let r = try dwgwRoundTrip(dwgwSampleBlocks())
    let ins = r.modelEntities.compactMap { if case .insert(let i) = $0.kind { return i } else { return nil } }
    #expect(ins.count == 5)
    #expect(ins[1].attributes.map(\.value) == ["Table 2", "2"])
    #expect(r.blocks["TABLE"]?.attributeDefinitions.map(\.tag) == ["NAME", "NO"])
    #expect(r.groups.first?.members.count == 2)
}

@Test func dwgWriterRoundTripDimensionsHatch() throws {
    let r = try dwgwRoundTrip(dwgwSampleDimsHatch())
    let dims = r.modelEntities.filter { if case .dimension = $0.kind { return true } else { return false } }
    #expect(dims.count == 6)
}

@Test func dwgWriterRoundTripLayouts() throws {
    let r = try dwgwRoundTrip(dwgwSampleLayouts())
    let vps = r.layouts[0].entities.compactMap { if case .viewport(let v) = $0.kind { return v } else { return nil } }
    #expect(vps.count == 2)
    #expect(vps[1].isLocked && vps[1].frozenLayers == ["Plan"])
}

@Test(.enabled(if: Corpus.hasSampleDXF)) func dwgWriterRoundTripRealDrawing() throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: Corpus.sampleDXF))
    let d = try DXFReader.read(data: data)
    _ = try checkStructure(d)
    let r = try NativeDWGReader.read(data: try NativeDWGWriter.write(d))
    #expect(r.modelEntities.count == d.modelEntities.count)
    #expect(r.layouts.map(\.entities.count) == d.layouts.map(\.entities.count))
    #expect(r.blocks.count == d.blocks.count)
    #expect(r.layers.count == d.layers.count)
}
