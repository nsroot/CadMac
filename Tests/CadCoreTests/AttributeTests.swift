import Foundation
import Testing
@testable import CadCore

private func attDXF(_ pairs: [(Int, String)]) -> String {
    pairs.map { "\($0.0)\n\($0.1)" }.joined(separator: "\n") + "\n"
}

/// Block "TB" with a frame, a variable SHEET attribute, an invisible one and a constant one.
private func titleBlock() -> BlockDef {
    let base = Vec2(10, 10)
    let sheet = AttDefGeom(tag: "SHEET", prompt: "Sheet number", defaultValue: "A001",
                           text: TextGeom(position: Vec2(20, 12), height: 2.5, text: "SHEET", hAlign: .right, vAlign: .middle))
    let secret = AttDefGeom(tag: "SECRET", prompt: "Hidden note", defaultValue: "x",
                            text: TextGeom(position: Vec2(12, 15), height: 1, text: "SECRET"), isInvisible: true)
    let company = AttDefGeom(tag: "COMPANY", defaultValue: "ACME",
                             text: TextGeom(position: Vec2(12, 12), height: 2, text: "COMPANY"), isConstant: true)
    return BlockDef(name: "TB", basePoint: base, entities: [
        Entity(.polyline(PolylineGeom(points: [Vec2(10, 10), Vec2(30, 10), Vec2(30, 20), Vec2(10, 20)], closed: true))),
        Entity(.attdef(sheet)), Entity(.attdef(secret)), Entity(.attdef(company)),
    ])
}

private func attributeDrawing() -> (Drawing, EntityID) {
    var d = Drawing()
    let tb = titleBlock()
    d.blocks["TB"] = tb
    var ins = InsertGeom(blockName: "TB", position: Vec2(100, 50), scaleX: 2, scaleY: 2, rotation: .pi / 2)
    ins.attributes = ins.makeAttributes(block: tb, values: ["SHEET": "A202"])
    let e = Entity(.insert(ins), layer: "Title")
    d.add(e)
    // A free-standing ATTDEF in model space too.
    d.add(Entity(.attdef(AttDefGeom(tag: "LOOSE", prompt: "P", defaultValue: "D", text: TextGeom(position: Vec2(1, 2), height: 3, text: "LOOSE")))))
    return (d, e.id)
}

@Test func attributeValuesArePlacedWithInsertTransform() {
    let tb = titleBlock()
    let ins = InsertGeom(blockName: "TB", position: Vec2(100, 50), scaleX: 2, scaleY: 2, rotation: .pi / 2)
    let atts = ins.makeAttributes(block: tb, values: ["SHEET": "A202"])
    #expect(atts.map(\.tag) == ["SHEET", "SECRET"])
    #expect(atts[0].value == "A202" && atts[1].value == "x" && atts[1].isInvisible)
    // (20,12) - base (10,10) = (10,2), scaled 2 = (20,4), rotated 90 = (-4,20), + (100,50).
    #expect(atts[0].text.position.isClose(to: Vec2(96, 70), tol: 1e-9))
    #expect(abs(atts[0].text.height - 5) < 1e-9)
    #expect(abs(atts[0].text.rotation - .pi / 2) < 1e-9)
}

@Test func attributeDXFRoundTrip() throws {
    let (d, _) = attributeDrawing()
    let out = DXFWriter.write(d)
    #expect(out.contains("\nATTDEF\n") && out.contains("\nATTRIB\n") && out.contains("\nSEQEND\n"))
    #expect(out.contains("AcDbAttributeDefinition") && out.contains("AcDbAttribute\n"))
    let r = try DXFReader.read(string: out)

    let tb = try #require(r.blocks["TB"])
    let defs = tb.attributeDefinitions
    #expect(defs.map(\.tag) == ["SHEET", "SECRET", "COMPANY"])
    #expect(defs[0].prompt == "Sheet number" && defs[0].defaultValue == "A001" && !defs[0].isInvisible)
    #expect(defs[0].text.hAlign == .right && defs[0].text.vAlign == .middle && defs[0].text.position.isClose(to: Vec2(20, 12)))
    #expect(defs[1].isInvisible && defs[2].isConstant && defs[2].defaultValue == "ACME")

    // No attribute text leaks out as separate TEXT entities.
    #expect(!r.modelEntities.contains { if case .text = $0.kind { return true }; return false })
    let inserts = r.modelEntities.compactMap { e -> InsertGeom? in if case .insert(let i) = e.kind { return i }; return nil }
    #expect(inserts.count == 1)
    let atts = inserts[0].attributes
    #expect(atts.map(\.tag) == ["SHEET", "SECRET"])
    #expect(atts.map(\.value) == ["A202", "x"])
    #expect(atts.map(\.isInvisible) == [false, true])
    #expect(atts[0].text.position.isClose(to: Vec2(96, 70), tol: 1e-6))
    #expect(abs(atts[0].text.height - 5) < 1e-9 && abs(atts[0].text.rotation - .pi / 2) < 1e-9)
    #expect(atts[0].text.hAlign == .right && atts[0].text.vAlign == .middle)

    let loose = r.modelEntities.compactMap { e -> AttDefGeom? in if case .attdef(let a) = e.kind { return a }; return nil }
    #expect(loose.count == 1 && loose[0].tag == "LOOSE" && loose[0].prompt == "P" && loose[0].defaultValue == "D")

    // Writing again gives the same drawing content.
    let r2 = try DXFReader.read(string: DXFWriter.write(r))
    #expect(r2.blocks["TB"]?.attributeDefinitions == tb.attributeDefinitions)
}

@Test func attributesInPaperSpaceLayouts() throws {
    var d = Drawing()
    d.blocks["TB"] = titleBlock()
    for (i, n) in ["A001", "A202"].enumerated() {
        var ins = InsertGeom(blockName: "TB", position: Vec2(5, 5))
        ins.attributes = ins.makeAttributes(block: d.blocks["TB"]!, values: ["SHEET": n])
        if i == 0 { d.layouts[0].entities.append(Entity(.insert(ins))) } else {
            d.layouts.append(Layout(name: "Sheet2", tabOrder: 2, entities: [Entity(.insert(ins))]))
        }
    }
    let r = try DXFReader.read(string: DXFWriter.write(d))
    let values = r.layouts.map { l in
        l.entities.compactMap { e -> String? in
            if case .insert(let i) = e.kind { return i.attributes.first { $0.tag == "SHEET" }?.value }
            return nil
        }
    }
    #expect(values == [["A001"], ["A202"]])
}

@Test func readsHandWrittenInsertWithAttribs() throws {
    let src = attDXF([
        (0, "SECTION"), (2, "BLOCKS"),
        (0, "BLOCK"), (8, "0"), (2, "TAG"), (70, "2"), (10, "0"), (20, "0"),
        (0, "LINE"), (8, "0"), (10, "0"), (20, "0"), (11, "10"), (21, "0"),
        (0, "ATTDEF"), (8, "0"), (100, "AcDbText"), (10, "0"), (20, "1"), (40, "2"), (1, "DEF"), (72, "1"), (11, "5"), (21, "1"),
        (100, "AcDbAttributeDefinition"), (3, "Enter name"), (2, "NAME"), (70, "0"), (73, "0"), (74, "0"),
        (0, "ENDBLK"),
        (0, "ENDSEC"),
        (0, "SECTION"), (2, "ENTITIES"),
        (0, "INSERT"), (5, "40"), (8, "L1"), (66, "1"), (2, "TAG"), (10, "100"), (20, "200"),
        (0, "ATTRIB"), (5, "41"), (8, "L1"), (100, "AcDbText"), (10, "100"), (20, "201"), (40, "2"), (1, "Hello"),
        (72, "1"), (11, "105"), (21, "201"), (100, "AcDbAttribute"), (2, "NAME"), (70, "0"), (74, "0"),
        (0, "ATTRIB"), (5, "42"), (8, "L1"), (100, "AcDbText"), (10, "100"), (20, "190"), (40, "1"), (1, "hidden"),
        (100, "AcDbAttribute"), (2, "INV"), (70, "1"),
        // R2018 multiline attribute: plain text comes from the embedded MTEXT.
        (0, "ATTRIB"), (5, "43"), (8, "L1"), (100, "AcDbText"), (10, "100"), (20, "180"), (40, "1"), (1, ""),
        (100, "AcDbAttribute"), (280, "0"), (2, "MULTI"), (70, "0"), (71, "2"), (72, "0"),
        (101, "Embedded Object"), (10, "100"), (20, "180"), (40, "1"), (41, "0"), (71, "1"), (72, "5"),
        (1, "Line one\\PLine two"), (73, "1"),
        (0, "SEQEND"), (5, "44"), (8, "L1"),
        (0, "TEXT"), (10, "0"), (20, "0"), (40, "1"), (1, "plain"),
        (0, "ENDSEC"), (0, "EOF"),
    ])
    let d = try DXFReader.read(string: src)
    #expect(d.modelEntities.count == 2)
    guard case .insert(let ins) = d.modelEntities[0].kind else { Issue.record("insert"); return }
    #expect(ins.attributes.map(\.tag) == ["NAME", "INV", "MULTI"])
    #expect(ins.attributes.map(\.value) == ["Hello", "hidden", "Line one\nLine two"])
    #expect(ins.attributes.map(\.isInvisible) == [false, true, false])
    #expect(ins.attributes[0].text.position == Vec2(105, 201) && ins.attributes[0].text.hAlign == .center)
    #expect(ins.attributes[2].text.isMultiline)
    guard case .text(let t) = d.modelEntities[1].kind else { Issue.record("text"); return }
    #expect(t.text == "plain")
    let def = try #require(d.blocks["TAG"]?.attributeDefinitions.first)
    #expect(def.tag == "NAME" && def.prompt == "Enter name" && def.defaultValue == "DEF" && def.text.position == Vec2(5, 1))

    // Drawn: visible attribute values and the block line, never the ATTDEF tag.
    let drawn = d.expandInsert(d.modelEntities[0])
    let texts = drawn.compactMap { e -> String? in if case .text(let t) = e.kind { return t.text }; return nil }
    #expect(Set(texts) == ["Hello", "Line one\nLine two"])
    #expect(!drawn.contains { if case .attdef = $0.kind { return true }; return false })
    #expect(drawn.contains { if case .line = $0.kind { return true }; return false })
}

@Test func minsertCopiesAttributes() throws {
    let src = attDXF([
        (0, "SECTION"), (2, "BLOCKS"),
        (0, "BLOCK"), (2, "B"), (70, "0"), (10, "0"), (20, "0"),
        (0, "LINE"), (10, "0"), (20, "0"), (11, "1"), (21, "0"),
        (0, "ENDBLK"), (0, "ENDSEC"),
        (0, "SECTION"), (2, "ENTITIES"),
        (0, "MINSERT"), (66, "1"), (2, "B"), (10, "0"), (20, "0"), (70, "2"), (71, "1"), (44, "10"), (45, "0"),
        (0, "ATTRIB"), (10, "1"), (20, "1"), (40, "1"), (1, "V"), (2, "T"), (70, "0"),
        (0, "SEQEND"),
        (0, "ENDSEC"), (0, "EOF"),
    ])
    let d = try DXFReader.read(string: src)
    let pos = d.modelEntities.compactMap { e -> Vec2? in if case .insert(let i) = e.kind { return i.attributes.first?.text.position }; return nil }
    #expect(pos == [Vec2(1, 1), Vec2(11, 1)])
}

@Test func expandInsertDrawsAttributesNotDefinitions() {
    var d = Drawing()
    let tb = titleBlock()
    d.blocks["TB"] = tb
    var ins = InsertGeom(blockName: "TB", position: Vec2(10, 10))
    ins.attributes = ins.makeAttributes(block: tb)
    let e = Entity(.insert(ins))
    let drawn = d.expandInsert(e)
    let texts = drawn.compactMap { x -> String? in if case .text(let t) = x.kind { return t.text }; return nil }
    // SHEET default + constant COMPANY; the invisible SECRET and the tags are not drawn.
    #expect(Set(texts) == ["A001", "ACME"])
    #expect(!drawn.contains { if case .attdef = $0.kind { return true }; return false })
}

@Test func groupDXFRoundTrip() throws {
    var d = Drawing()
    let a = d.add(Entity(.line(LineGeom(start: .zero, end: Vec2(1, 0)))))
    let b = d.add(Entity(.circle(CircleGeom(center: .zero, radius: 2))))
    let c = d.add(Entity(.line(LineGeom(start: .zero, end: Vec2(0, 1)))))
    let p = Entity(.line(LineGeom(start: .zero, end: Vec2(5, 5))))
    d.layouts[0].entities.append(p)
    d.groups = [
        EntityGroup(name: "Doors", description: "All doors", members: [a, b]),
        EntityGroup(name: "*A1", members: [c, p.id], isSelectable: false),
        EntityGroup(name: "Gone", members: [UUID()]),
    ]
    let out = DXFWriter.write(d)
    #expect(out.contains("\nAcDbGroup\n") && out.contains("{ACAD_REACTORS"))
    let r = try DXFReader.read(string: out)
    #expect(r.groups.map(\.name) == ["Doors", "*A1"])
    func kinds(_ g: EntityGroup) -> [String] {
        g.members.compactMap { id in r.allSpaces.joined().first { $0.id == id }?.kind.typeName }
    }
    #expect(r.groups[0].description == "All doors" && r.groups[0].isSelectable)
    #expect(kinds(r.groups[0]) == ["Line", "Circle"])
    // Members in another space than the first one are dropped (AutoCAD groups are per space).
    #expect(!r.groups[1].isSelectable && kinds(r.groups[1]) == ["Line"])
    #expect(r.groups[1].members.allSatisfy { id in r.modelEntities.contains { $0.id == id } })
}

@Test func readsHandWrittenGroup() throws {
    let src = attDXF([
        (0, "SECTION"), (2, "ENTITIES"),
        (0, "LINE"), (5, "A0"), (10, "0"), (20, "0"), (11, "1"), (21, "1"),
        (0, "LINE"), (5, "A1"), (10, "0"), (20, "0"), (11, "2"), (21, "1"),
        (0, "ENDSEC"),
        (0, "SECTION"), (2, "OBJECTS"),
        (0, "DICTIONARY"), (5, "C"), (330, "0"), (100, "AcDbDictionary"), (3, "ACAD_GROUP"), (350, "D"),
        (0, "DICTIONARY"), (5, "D"), (330, "C"), (100, "AcDbDictionary"), (3, "PAIR"), (350, "B0"), (3, "*A3"), (350, "B1"),
        (0, "GROUP"), (5, "B0"), (330, "D"), (100, "AcDbGroup"), (300, "two lines"), (70, "0"), (71, "1"), (340, "A0"), (340, "A1"),
        (0, "GROUP"), (5, "B1"), (330, "D"), (100, "AcDbGroup"), (300, ""), (70, "1"), (71, "1"), (340, "A1"),
        (0, "ENDSEC"), (0, "EOF"),
    ])
    let d = try DXFReader.read(string: src)
    #expect(d.groups.map(\.name) == ["PAIR", "*A3"])
    #expect(d.groups[0].members == d.modelEntities.map(\.id) && d.groups[0].description == "two lines")
    #expect(d.groups[1].members == [d.modelEntities[1].id])
}

@Test func ctabFieldsShowTheirLayoutName() throws {
    let src = attDXF([
        (0, "SECTION"), (2, "BLOCKS"),
        (0, "BLOCK"), (2, "TB"), (70, "2"), (10, "0"), (20, "0"),
        (0, "ATTDEF"), (10, "0"), (20, "0"), (40, "1"), (1, ""), (100, "AcDbAttributeDefinition"), (3, "Sheet"), (2, "SHEETNO"), (70, "0"),
        (0, "ENDBLK"), (0, "ENDSEC"),
        (0, "SECTION"), (2, "ENTITIES"),
        (0, "MTEXT"), (5, "100"), (67, "1"), (10, "1"), (20, "1"), (40, "2"), (1, "Sheet A001"),
        (0, "INSERT"), (5, "110"), (67, "1"), (66, "1"), (2, "TB"), (10, "0"), (20, "0"),
        (0, "ATTRIB"), (5, "111"), (67, "1"), (10, "0"), (20, "0"), (40, "1"), (1, "A001"), (100, "AcDbAttribute"), (2, "SHEETNO"), (70, "0"),
        (0, "SEQEND"), (5, "112"),
        (0, "ENDSEC"),
        (0, "SECTION"), (2, "OBJECTS"),
        // MTEXT 100 -> xdict 200 -> ACAD_FIELD dict 201 -> _text FIELD 202 -> ctab FIELD 203.
        (0, "DICTIONARY"), (5, "200"), (330, "100"), (100, "AcDbDictionary"), (3, "ACAD_FIELD"), (360, "201"),
        (0, "DICTIONARY"), (5, "201"), (102, "{ACAD_REACTORS"), (330, "200"), (102, "}"), (330, "200"), (100, "AcDbDictionary"), (3, "TEXT"), (360, "202"),
        (0, "FIELD"), (5, "202"), (330, "201"), (100, "AcDbField"), (1, "_text"), (2, "Sheet %<\\_FldIdx 0>%"), (90, "1"), (360, "203"),
        (0, "FIELD"), (5, "203"), (330, "202"), (100, "AcDbField"), (1, "AcVar"), (2, "\\AcVar ctab"), (302, "A001"),
        (0, "DICTIONARY"), (5, "300"), (330, "111"), (100, "AcDbDictionary"), (3, "ACAD_FIELD"), (360, "301"),
        (0, "DICTIONARY"), (5, "301"), (330, "300"), (100, "AcDbDictionary"), (3, "TEXT"), (360, "302"),
        (0, "FIELD"), (5, "302"), (330, "301"), (100, "AcDbField"), (1, "_text"), (2, "%<\\_FldIdx 0>%"), (360, "303"),
        (0, "FIELD"), (5, "303"), (330, "302"), (100, "AcDbField"), (1, "AcVar"), (2, "\\AcVar CTab"), (302, "A001"),
        (0, "ENDSEC"), (0, "EOF"),
    ])
    let d = try DXFReader.read(string: src)
    let l = try #require(d.layouts.first)
    let texts = l.entities.compactMap { e -> String? in if case .text(let t) = e.kind { return t.text }; return nil }
    #expect(texts == ["Sheet \(l.name)"])
    let atts = l.entities.compactMap { e -> String? in if case .insert(let i) = e.kind { return i.attributes.first?.value }; return nil }
    #expect(atts == [l.name])
}
