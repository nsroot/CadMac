import Foundation

/// Writes an ASCII DXF (AC1018 / AutoCAD 2004) with handles, owners and subclass markers.
///
/// Dimensions are written as real DIMENSION entities, each referencing an anonymous
/// `*Dn` block that holds its rendered geometry (lines, arcs, SOLID arrowheads, TEXT)
/// built from `dimensionGraphics`. AutoCAD and other viewers display that block, while
/// the definition points keep the dimension editable/associative when read back.
/// Non-ASCII text is written as `\U+XXXX` escapes so the file is pure ASCII.
public enum DXFWriter {
    public static func write(_ d: Drawing) -> String {
        var w = DXFWriterImpl(drawing: d)
        return w.run()
    }
}

private struct DXFBuf {
    var s = ""
    mutating func p(_ code: Int, _ v: String) {
        s += String(code)
        s += "\n"
        s += v
        s += "\n"
    }
    mutating func p(_ code: Int, _ v: Double) { p(code, dxfNum(v)) }
    mutating func p(_ code: Int, _ v: Int) { p(code, String(v)) }
    mutating func pt(_ code: Int, _ v: Vec2) {
        p(code, v.x); p(code + 10, v.y); p(code + 20, 0.0)
    }
}

func dxfNum(_ v: Double) -> String {
    guard v.isFinite else { return "0.0" }
    var s = String(format: "%.12f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s += "0" }
    if s == "-0.0" { s = "0.0" }
    return s
}

private struct DXFWriterImpl {
    let drawing: Drawing
    var nextHandle = 1
    /// Anonymous dimension blocks generated while writing entities.
    var dimBlocks: [(name: String, record: String, entities: [Entity], solids: [[Vec2]])] = []
    var linetypeNames: Set<String> = []
    var styleNames: [String] = ["Standard"]
    /// True while writing paper space entities (adds group code 67).
    var paperSpace = false
    /// Id (group 69) of the last viewport written in the current sheet.
    var nextViewportID = 1
    /// Layer name (uppercased) -> LAYER handle, for viewport freezes.
    var layerHandles: [String: String] = [:]
    /// Entity id -> handle of the first entity written with that id (GROUP members).
    var entityHandles: [EntityID: String] = [:]
    /// Entity id -> handles of the GROUP objects it belongs to (persistent reactors).
    var groupReactors: [EntityID: [String]] = [:]

    init(drawing: Drawing) { self.drawing = drawing }

    mutating func handle() -> String {
        defer { nextHandle += 1 }
        return String(nextHandle, radix: 16, uppercase: true)
    }

    // MARK: Assembly

    mutating func run() -> String {
        let d = drawing
        // Linetypes written to the LTYPE table (plus ByBlock/ByLayer).
        var ltypes: [Linetype] = [Linetype(name: "Continuous", description: "Solid line", pattern: [])]
        for lt in d.linetypes where !["CONTINUOUS", "BYLAYER", "BYBLOCK"].contains(lt.name.uppercased()) && !lt.name.isEmpty {
            if !ltypes.contains(where: { $0.name.uppercased() == lt.name.uppercased() }) { ltypes.append(lt) }
        }
        linetypeNames = Set(ltypes.map { $0.name.uppercased() })

        // Fixed handles.
        let tableNames = ["VPORT", "LTYPE", "LAYER", "STYLE", "VIEW", "UCS", "APPID", "DIMSTYLE", "BLOCK_RECORD"]
        // AutoCAD's conventional fixed handles; other tools (e.g. LibreDWG) assume them.
        let fixed = ["BLOCK_RECORD": "1", "LAYER": "2", "STYLE": "3", "LTYPE": "5", "VIEW": "6", "UCS": "7",
                     "VPORT": "8", "APPID": "9", "DIMSTYLE": "A"]
        var tableHandle: [String: String] = [:]
        for t in tableNames { tableHandle[t] = fixed[t] }
        let rootDict = "C", groupDict = "D"
        nextHandle = 0x20
        // Layouts in tab order; the first is the active "*Paper_Space", the rest live in
        // "*Paper_Space0", "*Paper_Space1", ... block definitions.
        let layouts = d.layouts.enumerated().sorted { ($0.element.tabOrder, $0.offset) < ($1.element.tabOrder, $1.offset) }.map(\.element)
        let msRecord = handle()
        let modelLayout = handle()
        var sheets: [(layout: Layout, block: String, record: String, object: String)] = []
        for (i, l) in layouts.enumerated() {
            sheets.append((l, i == 0 ? "*Paper_Space" : "*Paper_Space\(i - 1)", handle(), handle()))
        }
        if sheets.isEmpty {
            // AutoCAD needs at least one paper space layout.
            sheets.append((Layout(name: "Layout1", tabOrder: 1), "*Paper_Space", handle(), handle()))
        }
        let userBlocks = d.blocks.values.filter { !$0.name.isEmpty }.sorted { $0.name < $1.name }
        var blockRecords: [(name: String, record: String, layout: String?)] = [("*Model_Space", msRecord, modelLayout)]
        for sh in sheets { blockRecords.append((sh.block, sh.record, sh.object)) }
        for b in userBlocks { blockRecords.append((b.name, handle(), nil)) }
        let firstUserBlock = 1 + sheets.count
        var layers = d.layers
        if !layers.contains(where: { $0.name == "0" }) { layers.insert(Layer(name: "0"), at: 0) }
        var layerHandleList: [String] = []
        for l in layers {
            let h = handle()
            layerHandleList.append(h)
            if layerHandles[l.name.uppercased()] == nil { layerHandles[l.name.uppercased()] = h }
        }

        // Collect text styles.
        func scanStyles(_ es: [Entity]) {
            for e in es {
                var styles: [String] = []
                switch e.kind {
                case .text(let t): styles = [t.style]
                case .attdef(let a): styles = [a.text.style]
                case .insert(let i): styles = i.attributes.map(\.text.style)
                default: break
                }
                for st in styles where !st.isEmpty && !styleNames.contains(where: { $0.caseInsensitiveCompare(st) == .orderedSame }) {
                    styleNames.append(st)
                }
            }
        }
        for space in d.allSpaces { scanStyles(space) }
        for b in userBlocks { scanStyles(b.entities) }

        // Groups: handles are assigned up front so members can point back at them.
        // Members must share one space (AutoCAD rule): the first member's space wins.
        var spaceOf: [EntityID: Int] = [:]
        for (k, space) in (d.allSpaces + userBlocks.map(\.entities)).enumerated() {
            for e in space where spaceOf[e.id] == nil { spaceOf[e.id] = k }
        }
        var groups: [(group: EntityGroup, handle: String)] = []
        var groupNames = Set<String>()
        for g in d.groups {
            var seen = Set<EntityID>()
            let space = g.members.lazy.compactMap { spaceOf[$0] }.first
            let members = g.members.filter { spaceOf[$0] != nil && spaceOf[$0] == space && seen.insert($0).inserted }
            let key = g.name.uppercased()
            guard !members.isEmpty, !g.name.isEmpty, !groupNames.contains(key) else { continue }
            groupNames.insert(key)
            var gg = g
            gg.members = members
            let h = handle()
            groups.append((gg, h))
            for m in members { groupReactors[m, default: []].append(h) }
        }

        // ENTITIES and BLOCKS (dimension blocks are registered on the way).
        var ents = DXFBuf()
        for e in d.modelEntities { writeEntity(e, owner: msRecord, into: &ents) }
        var lastViewport: [String] = []
        paperSpace = true
        lastViewport.append(writeSheet(sheets[0].layout, owner: sheets[0].record, into: &ents))
        paperSpace = false
        var blocks = DXFBuf()
        writeBlock(name: "*Model_Space", record: msRecord, base: .zero, entities: [], paper: false, into: &blocks)
        for (i, sh) in sheets.enumerated() {
            if i == 0 {
                writeBlock(name: sh.block, record: sh.record, base: .zero, entities: [], paper: true, into: &blocks)
            } else {
                writeBlock(name: sh.block, record: sh.record, base: .zero, entities: [], paper: true, sheet: sh.layout,
                           lastViewport: &lastViewport, into: &blocks)
            }
        }
        for (i, b) in userBlocks.enumerated() {
            writeBlock(name: b.name, record: blockRecords[i + firstUserBlock].record, base: b.basePoint, entities: b.entities, paper: false, into: &blocks)
        }
        var k = 0
        while k < dimBlocks.count {
            let db = dimBlocks[k]
            writeBlock(name: db.name, record: db.record, base: .zero, entities: db.entities, solids: db.solids, paper: false, into: &blocks)
            k += 1
        }
        for db in dimBlocks { blockRecords.append((db.name, db.record, nil)) }

        // TABLES.
        var tables = DXFBuf()
        tables.p(0, "SECTION"); tables.p(2, "TABLES")
        func tableStart(_ name: String, count: Int) {
            tables.p(0, "TABLE"); tables.p(2, name); tables.p(5, tableHandle[name]!); tables.p(330, "0")
            tables.p(100, "AcDbSymbolTable"); tables.p(70, count)
        }
        func record(_ type: String, _ table: String, _ sub: String, handleCode: Int = 5) {
            tables.p(0, type); tables.p(handleCode, handle()); tables.p(330, tableHandle[table]!)
            tables.p(100, "AcDbSymbolTableRecord"); tables.p(100, sub)
        }
        // VPORT
        tableStart("VPORT", count: 1)
        record("VPORT", "VPORT", "AcDbViewportTableRecord")
        let ext = d.extents(of: d.modelEntities)
        let vb = ext.isEmpty ? BBox(min: d.settings.limitsMin, max: d.settings.limitsMax) : ext
        tables.p(2, "*Active"); tables.p(70, 0)
        tables.p(10, 0.0); tables.p(20, 0.0); tables.p(11, 1.0); tables.p(21, 1.0)
        tables.p(12, vb.center.x); tables.p(22, vb.center.y)
        tables.p(13, 0.0); tables.p(23, 0.0); tables.p(14, d.settings.snapSpacing); tables.p(24, d.settings.snapSpacing)
        tables.p(15, d.settings.gridSpacing); tables.p(25, d.settings.gridSpacing)
        tables.p(16, 0.0); tables.p(26, 0.0); tables.p(36, 1.0)
        tables.p(17, 0.0); tables.p(27, 0.0); tables.p(37, 0.0)
        tables.p(40, max(vb.height, vb.width / 1.5, 1) * 1.1); tables.p(41, 1.5); tables.p(42, 50.0)
        tables.p(43, 0.0); tables.p(44, 0.0); tables.p(50, 0.0); tables.p(51, 0.0)
        tables.p(71, 0); tables.p(72, 100); tables.p(73, 1); tables.p(74, 3); tables.p(75, 0); tables.p(76, 0); tables.p(77, 0); tables.p(78, 0)
        tables.p(0, "ENDTAB")
        // LTYPE
        tableStart("LTYPE", count: ltypes.count + 2)
        for (name, desc, pat) in [("ByBlock", "", [Double]()), ("ByLayer", "", [])] + ltypes.map({ ($0.name, $0.description, $0.pattern) }) {
            record("LTYPE", "LTYPE", "AcDbLinetypeTableRecord")
            tables.p(2, dxfEncodeUnicode(name)); tables.p(70, 0); tables.p(3, dxfEncodeUnicode(desc)); tables.p(72, 65)
            tables.p(73, pat.count); tables.p(40, pat.reduce(0) { $0 + abs($1) })
            for v in pat { tables.p(49, v); tables.p(74, 0) }
        }
        tables.p(0, "ENDTAB")
        // LAYER
        tableStart("LAYER", count: layers.count)
        for (li, l) in layers.enumerated() {
            tables.p(0, "LAYER"); tables.p(5, layerHandleList[li]); tables.p(330, tableHandle["LAYER"]!)
            tables.p(100, "AcDbSymbolTableRecord"); tables.p(100, "AcDbLayerTableRecord")
            tables.p(2, dxfEncodeUnicode(l.name))
            tables.p(70, (l.isFrozen ? 1 : 0) | (l.isLocked ? 4 : 0))
            var aci = 7
            switch l.color {
            case .aci(let i): aci = min(max(i, 1), 255)
            case .rgb(let c): aci = nearestACI(c)
            default: break
            }
            tables.p(62, l.isOn ? aci : -aci)
            if case .rgb(let c) = l.color { tables.p(420, c.packed) }
            tables.p(6, linetypeNames.contains(l.linetype.uppercased()) ? dxfEncodeUnicode(l.linetype) : "Continuous")
            if !l.isPlottable { tables.p(290, 0) }
            tables.p(370, l.lineweight >= 0 ? snapLineweight(l.lineweight) : -3)
        }
        tables.p(0, "ENDTAB")
        // STYLE
        tableStart("STYLE", count: styleNames.count)
        for s in styleNames {
            record("STYLE", "STYLE", "AcDbTextStyleTableRecord")
            tables.p(2, dxfEncodeUnicode(s)); tables.p(70, 0); tables.p(40, 0.0); tables.p(41, 1.0); tables.p(50, 0.0)
            tables.p(71, 0); tables.p(42, d.settings.textHeight); tables.p(3, "txt"); tables.p(4, "")
        }
        tables.p(0, "ENDTAB")
        tableStart("VIEW", count: 0); tables.p(0, "ENDTAB")
        tableStart("UCS", count: 0); tables.p(0, "ENDTAB")
        tableStart("APPID", count: 1)
        record("APPID", "APPID", "AcDbRegAppTableRecord")
        tables.p(2, "ACAD"); tables.p(70, 0)
        tables.p(0, "ENDTAB")
        // DIMSTYLE
        let ds = d.settings.dimStyle
        tableStart("DIMSTYLE", count: 1)
        tables.p(100, "AcDbDimStyleTable")
        record("DIMSTYLE", "DIMSTYLE", "AcDbDimStyleTableRecord", handleCode: 105)
        tables.p(2, "Standard"); tables.p(70, 0)
        tables.p(40, ds.scale); tables.p(41, ds.arrowSize); tables.p(42, ds.extensionOffset); tables.p(44, ds.extensionExtend)
        tables.p(140, ds.textHeight); tables.p(147, ds.textGap); tables.p(271, ds.precision)
        tables.p(0, "ENDTAB")
        // BLOCK_RECORD
        tableStart("BLOCK_RECORD", count: blockRecords.count)
        for br in blockRecords {
            tables.p(0, "BLOCK_RECORD"); tables.p(5, br.record); tables.p(330, tableHandle["BLOCK_RECORD"]!)
            tables.p(100, "AcDbSymbolTableRecord"); tables.p(100, "AcDbBlockTableRecord")
            tables.p(2, dxfEncodeUnicode(br.name))
            if let l = br.layout { tables.p(340, l) }
            tables.p(70, 0); tables.p(280, 1); tables.p(281, 0)
        }
        tables.p(0, "ENDTAB")
        tables.p(0, "ENDSEC")

        // OBJECTS
        var objs = DXFBuf()
        objs.p(0, "SECTION"); objs.p(2, "OBJECTS")
        let layoutDict = handle()
        objs.p(0, "DICTIONARY"); objs.p(5, rootDict); objs.p(330, "0"); objs.p(100, "AcDbDictionary"); objs.p(281, 1)
        objs.p(3, "ACAD_GROUP"); objs.p(350, groupDict)
        objs.p(3, "ACAD_LAYOUT"); objs.p(350, layoutDict)
        objs.p(0, "DICTIONARY"); objs.p(5, groupDict); objs.p(330, rootDict); objs.p(100, "AcDbDictionary"); objs.p(281, 1)
        for g in groups { objs.p(3, dxfEncodeUnicode(g.group.name)); objs.p(350, g.handle) }
        objs.p(0, "DICTIONARY"); objs.p(5, layoutDict); objs.p(330, rootDict); objs.p(100, "AcDbDictionary"); objs.p(281, 1)
        objs.p(3, "Model"); objs.p(350, modelLayout)
        for sh in sheets { objs.p(3, dxfEncodeUnicode(sh.layout.name)); objs.p(350, sh.object) }
        let modelExt = ext.isEmpty ? BBox(min: d.settings.limitsMin, max: d.settings.limitsMax) : ext
        writeLayoutObject(handle: modelLayout, dict: layoutDict, name: "Model", tabOrder: 0, paper: .a3Landscape,
                          limits: BBox(min: d.settings.limitsMin, max: d.settings.limitsMax), extents: modelExt,
                          record: msRecord, lastViewport: nil, into: &objs)
        for (i, sh) in sheets.enumerated() {
            let p = sh.layout.paper
            let sheetBox = BBox(min: .zero, max: Vec2(p.width, p.height))
            let ext = d.extents(of: sh.layout.entities)
            writeLayoutObject(handle: sh.object, dict: layoutDict, name: sh.layout.name, tabOrder: i + 1, paper: p,
                              limits: sheetBox, extents: ext.isEmpty ? sheetBox : ext, record: sh.record,
                              lastViewport: lastViewport[i], into: &objs)
        }
        for g in groups {
            objs.p(0, "GROUP"); objs.p(5, g.handle)
            objs.p(102, "{ACAD_REACTORS"); objs.p(330, groupDict); objs.p(102, "}")
            objs.p(330, groupDict); objs.p(100, "AcDbGroup")
            objs.p(300, dxfEncodeUnicode(g.group.description))
            objs.p(70, g.group.name.hasPrefix("*") ? 1 : 0); objs.p(71, g.group.isSelectable ? 1 : 0)
            for m in g.group.members { if let h = entityHandles[m] { objs.p(340, h) } }
        }
        objs.p(0, "ENDSEC")

        // HEADER (written last so $HANDSEED exceeds every handle).
        var hdr = DXFBuf()
        hdr.p(0, "SECTION"); hdr.p(2, "HEADER")
        func v(_ name: String) { hdr.p(9, name) }
        v("$ACADVER"); hdr.p(1, "AC1018")
        v("$DWGCODEPAGE"); hdr.p(3, "ANSI_1252")
        v("$INSBASE"); hdr.pt(10, .zero)
        v("$EXTMIN"); hdr.pt(10, ext.isEmpty ? .zero : ext.min)
        v("$EXTMAX"); hdr.pt(10, ext.isEmpty ? .zero : ext.max)
        v("$LIMMIN"); hdr.p(10, d.settings.limitsMin.x); hdr.p(20, d.settings.limitsMin.y)
        v("$LIMMAX"); hdr.p(10, d.settings.limitsMax.x); hdr.p(20, d.settings.limitsMax.y)
        v("$LTSCALE"); hdr.p(40, d.settings.ltScale)
        v("$INSUNITS"); hdr.p(70, d.settings.insUnits.rawValue)
        v("$MEASUREMENT"); hdr.p(70, d.settings.insUnits == .inches || d.settings.insUnits == .feet ? 0 : 1)
        v("$CLAYER"); hdr.p(8, dxfEncodeUnicode(d.layer(named: d.settings.currentLayer) != nil ? d.settings.currentLayer : "0"))
        v("$TEXTSIZE"); hdr.p(40, d.settings.textHeight)
        v("$TEXTSTYLE"); hdr.p(7, "Standard")
        v("$DIMSTYLE"); hdr.p(2, "Standard")
        v("$DIMSCALE"); hdr.p(40, ds.scale)
        v("$DIMASZ"); hdr.p(40, ds.arrowSize)
        v("$DIMEXO"); hdr.p(40, ds.extensionOffset)
        v("$DIMEXE"); hdr.p(40, ds.extensionExtend)
        v("$DIMTXT"); hdr.p(40, ds.textHeight)
        v("$DIMGAP"); hdr.p(40, ds.textGap)
        v("$DIMDEC"); hdr.p(70, ds.precision)
        v("$LUNITS"); hdr.p(70, d.settings.units.rawValue)
        v("$LUPREC"); hdr.p(70, d.settings.unitPrecision)
        v("$PDSIZE"); hdr.p(40, d.settings.pointSize)
        v("$FILLETRAD"); hdr.p(40, d.settings.filletRadius)
        let firstPaper = sheets[0].layout.paper
        v("$PLIMMIN"); hdr.p(10, 0.0); hdr.p(20, 0.0)
        v("$PLIMMAX"); hdr.p(10, firstPaper.width); hdr.p(20, firstPaper.height)
        v("$MEASUREMENT"); hdr.p(70, 1)
        v("$HANDSEED"); hdr.p(5, String(nextHandle + 1, radix: 16, uppercase: true))
        hdr.p(0, "ENDSEC")

        var out = hdr.s
        out += "0\nSECTION\n2\nCLASSES\n0\nENDSEC\n"
        out += tables.s
        out += "0\nSECTION\n2\nBLOCKS\n" + blocks.s + "0\nENDSEC\n"
        out += "0\nSECTION\n2\nENTITIES\n" + ents.s + "0\nENDSEC\n"
        out += objs.s
        out += "0\nEOF\n"
        return out
    }

    // MARK: Blocks

    mutating func writeBlock(name: String, record: String, base: Vec2, entities: [Entity], solids: [[Vec2]] = [],
                             paper: Bool, into b: inout DXFBuf) {
        var none: [String] = []
        writeBlock(name: name, record: record, base: base, entities: entities, solids: solids, paper: paper, sheet: nil,
                   lastViewport: &none, into: &b)
    }

    /// Writes a BLOCK definition; with `sheet` its content is that layout's paper space
    /// (and the handle of its overall viewport is appended to `lastViewport`).
    mutating func writeBlock(name: String, record: String, base: Vec2, entities: [Entity], solids: [[Vec2]] = [],
                             paper: Bool, sheet: Layout?, lastViewport: inout [String], into b: inout DXFBuf) {
        let n = dxfEncodeUnicode(name)
        b.p(0, "BLOCK"); b.p(5, handle()); b.p(330, record); b.p(100, "AcDbEntity")
        if paper { b.p(67, 1) }
        b.p(8, "0"); b.p(100, "AcDbBlockBegin"); b.p(2, n)
        let hasAttributes = entities.contains { if case .attdef = $0.kind { return true }; return false }
        b.p(70, (name.hasPrefix("*") && !name.hasPrefix("*Model_Space") && !name.hasPrefix("*Paper_Space") ? 1 : 0) | (hasAttributes ? 2 : 0))
        b.pt(10, base); b.p(3, n); b.p(1, "")
        let saved = paperSpace
        paperSpace = paper
        for e in entities { writeEntity(e, owner: record, into: &b) }
        if let sheet { lastViewport.append(writeSheet(sheet, owner: record, into: &b)) }
        paperSpace = saved
        for s in solids where s.count >= 3 {
            // Filled arrowhead triangle (4th corner repeats the 3rd).
            let e = Entity(.point(PointGeom(position: .zero)), color: .byBlock, linetype: "ByBlock", lineweight: -2)
            begin("SOLID", e, owner: record, "AcDbTrace", into: &b)
            b.pt(10, s[0]); b.pt(11, s[1]); b.pt(12, s[2]); b.pt(13, s.count > 3 ? s[3] : s[2])
        }
        b.p(0, "ENDBLK"); b.p(5, handle()); b.p(330, record); b.p(100, "AcDbEntity")
        if paper { b.p(67, 1) }
        b.p(8, "0"); b.p(100, "AcDbBlockEnd")
    }

    // MARK: Entities

    func snapLineweight(_ mm: Double) -> Int {
        let v = Int((mm * 100).rounded())
        return dxfLineweights.min { abs($0 - v) < abs($1 - v) } ?? 25
    }

    @discardableResult
    mutating func begin(_ type: String, _ e: Entity, owner: String, _ sub: String, into b: inout DXFBuf) -> String {
        let h = handle()
        b.p(0, type); b.p(5, h)
        if entityHandles[e.id] == nil {
            entityHandles[e.id] = h
            if let gs = groupReactors[e.id], !gs.isEmpty {
                b.p(102, "{ACAD_REACTORS")
                for g in gs { b.p(330, g) }
                b.p(102, "}")
            }
        }
        b.p(330, owner); b.p(100, "AcDbEntity")
        if paperSpace { b.p(67, 1) }
        b.p(8, dxfEncodeUnicode(e.layer.isEmpty ? "0" : e.layer))
        let lt = e.linetype.uppercased()
        if lt == "BYBLOCK" { b.p(6, "ByBlock") } else if lt != "BYLAYER" && linetypeNames.contains(lt) { b.p(6, dxfEncodeUnicode(e.linetype)) }
        switch e.color {
        case .byLayer: break
        case .byBlock: b.p(62, 0)
        case .aci(let i): b.p(62, min(max(i, 1), 255))
        case .rgb(let c): b.p(62, nearestACI(c)); b.p(420, c.packed)
        }
        if e.lineweight == -2 { b.p(370, -2) } else if e.lineweight >= 0 { b.p(370, snapLineweight(e.lineweight)) }
        b.p(100, sub)
        return h
    }

    mutating func writeEntity(_ e: Entity, owner: String, into b: inout DXFBuf) {
        switch e.kind {
        case .attdef(let a):
            begin("ATTDEF", e, owner: owner, "AcDbText", into: &b)
            writeAttributeText(a.text, value: a.defaultValue, into: &b)
            b.p(100, "AcDbAttributeDefinition")
            b.p(3, dxfEncodeUnicode(a.prompt)); b.p(2, dxfEncodeUnicode(attributeTag(a.tag)))
            b.p(70, (a.isInvisible ? 1 : 0) | (a.isConstant ? 2 : 0) | (a.isPreset ? 8 : 0))
            b.p(73, 0); b.p(74, a.text.vAlign.rawValue)
        case .viewport(let v):
            guard paperSpace else { return }
            nextViewportID += 1
            writeViewport(v, e, id: nextViewportID, owner: owner, into: &b)
        case .line(let l):
            begin("LINE", e, owner: owner, "AcDbLine", into: &b)
            b.pt(10, l.start); b.pt(11, l.end)
        case .circle(let c):
            begin("CIRCLE", e, owner: owner, "AcDbCircle", into: &b)
            b.pt(10, c.center); b.p(40, c.radius)
        case .arc(let a):
            begin("ARC", e, owner: owner, "AcDbCircle", into: &b)
            b.pt(10, a.center); b.p(40, a.radius)
            b.p(100, "AcDbArc"); b.p(50, degrees(a.startAngle)); b.p(51, degrees(a.endAngle))
        case .polyline(let p):
            guard !p.vertices.isEmpty else { return }
            begin("LWPOLYLINE", e, owner: owner, "AcDbPolyline", into: &b)
            b.p(90, p.vertices.count); b.p(70, p.closed ? 1 : 0); b.p(43, p.width)
            for v in p.vertices {
                b.p(10, v.point.x); b.p(20, v.point.y)
                if v.bulge != 0 { b.p(42, v.bulge) }
            }
        case .ellipse(var el):
            guard el.majorAxis.length > 0, el.ratio > 0 else { return }
            if el.ratio > 1 {
                el = EllipseGeom(center: el.center, majorAxis: el.majorAxis.perp * el.ratio, ratio: 1 / el.ratio,
                                 startParam: el.startParam - .pi / 2, endParam: el.endParam - .pi / 2)
            }
            begin("ELLIPSE", e, owner: owner, "AcDbEllipse", into: &b)
            b.pt(10, el.center); b.pt(11, el.majorAxis)
            b.p(210, 0.0); b.p(220, 0.0); b.p(230, 1.0)
            b.p(40, el.ratio)
            if el.isFull { b.p(41, 0.0); b.p(42, 2 * Double.pi) } else { b.p(41, el.startParam); b.p(42, el.endParam) }
        case .point(let p):
            begin("POINT", e, owner: owner, "AcDbPoint", into: &b)
            b.pt(10, p.position)
        case .text(let t):
            writeText(t, e, owner: owner, into: &b)
        case .spline(let s):
            writeSpline(s, e, owner: owner, into: &b)
        case .hatch(let h):
            writeHatch(h, e, owner: owner, into: &b)
        case .insert(let i):
            guard drawing.blocks[i.blockName] != nil else { return }
            let h = begin("INSERT", e, owner: owner, "AcDbBlockReference", into: &b)
            if !i.attributes.isEmpty { b.p(66, 1) }
            b.p(2, dxfEncodeUnicode(i.blockName)); b.pt(10, i.position)
            b.p(41, i.scaleX); b.p(42, i.scaleY); b.p(43, 1.0); b.p(50, degrees(i.rotation))
            guard !i.attributes.isEmpty else { return }
            // ATTRIBs (owned by the INSERT) take the reference's properties, then SEQEND.
            var props = e
            props.id = UUID()
            for a in i.attributes {
                var ap = props
                if let l = a.layer { ap.layer = l }
                if let c = a.color { ap.color = c }
                begin("ATTRIB", ap, owner: h, "AcDbText", into: &b)
                writeAttributeText(a.text, value: a.value, into: &b)
                b.p(100, "AcDbAttribute")
                b.p(2, dxfEncodeUnicode(attributeTag(a.tag))); b.p(70, a.isInvisible ? 1 : 0)
                b.p(73, 0); b.p(74, a.text.vAlign.rawValue)
            }
            b.p(0, "SEQEND"); b.p(5, handle()); b.p(330, h); b.p(100, "AcDbEntity")
            if paperSpace { b.p(67, 1) }
            b.p(8, dxfEncodeUnicode(e.layer.isEmpty ? "0" : e.layer))
        case .dimension(let dm):
            writeDimension(dm, e, owner: owner, into: &b)
        }
    }

    // MARK: Layouts

    /// Writes a layout's paper space: the overall viewport (id 1) first, then its entities.
    /// Returns the overall viewport's handle.
    mutating func writeSheet(_ l: Layout, owner: String, into b: inout DXFBuf) -> String {
        let p = l.paper
        let c = Vec2(p.width / 2, p.height / 2)
        let overall = ViewportGeom(center: c, width: p.width, height: p.height, viewCenter: c, viewHeight: p.height)
        let h = String(nextHandle, radix: 16, uppercase: true)
        writeViewport(overall, Entity(.viewport(overall)), id: 1, owner: owner, into: &b)
        nextViewportID = 1
        for e in l.entities { writeEntity(e, owner: owner, into: &b) }
        return h
    }

    mutating func writeViewport(_ v: ViewportGeom, _ e: Entity, id: Int, owner: String, into b: inout DXFBuf) {
        begin("VIEWPORT", e, owner: owner, "AcDbViewport", into: &b)
        b.pt(10, v.center); b.p(40, v.width); b.p(41, v.height)
        b.p(68, v.isOn ? id : 0); b.p(69, id)
        b.p(12, v.viewCenter.x); b.p(22, v.viewCenter.y)
        b.p(13, 0.0); b.p(23, 0.0); b.p(14, 10.0); b.p(24, 10.0); b.p(15, 10.0); b.p(25, 10.0)
        b.p(16, 0.0); b.p(26, 0.0); b.p(36, 1.0)
        b.p(17, 0.0); b.p(27, 0.0); b.p(37, 0.0)
        b.p(42, 50.0); b.p(43, 0.0); b.p(44, 0.0)
        b.p(45, v.viewHeight > 0 ? v.viewHeight : v.height)
        b.p(50, 0.0); b.p(51, 0.0); b.p(72, 1000)
        for name in v.frozenLayers {
            if let h = layerHandles[name.uppercased()] { b.p(331, h) }
        }
        b.p(90, 0x8060 | (v.isLocked ? 0x4000 : 0) | (v.isOn ? 0 : 0x20000))
        b.p(1, ""); b.p(281, 0); b.p(71, 1); b.p(74, 0)
        b.p(110, 0.0); b.p(120, 0.0); b.p(130, 0.0)
        b.p(111, 1.0); b.p(121, 0.0); b.p(131, 0.0)
        b.p(112, 0.0); b.p(122, 1.0); b.p(132, 0.0)
        b.p(79, 0); b.p(146, 0.0); b.p(170, 0); b.p(61, 5)
    }

    /// LAYOUT object (plot settings in mm, no rotation).
    mutating func writeLayoutObject(handle h: String, dict: String, name: String, tabOrder: Int, paper p: PaperSetup,
                                    limits: BBox, extents: BBox, record: String, lastViewport: String?, into o: inout DXFBuf) {
        let m = p.margins.count == 4 ? p.margins : [0, 0, 0, 0]
        o.p(0, "LAYOUT"); o.p(5, h)
        o.p(102, "{ACAD_REACTORS"); o.p(330, dict); o.p(102, "}")
        o.p(330, dict)
        o.p(100, "AcDbPlotSettings")
        o.p(1, ""); o.p(2, "none_device"); o.p(4, dxfEncodeUnicode(p.name.replacingOccurrences(of: " ", with: "_"))); o.p(6, "")
        o.p(40, m[0]); o.p(41, m[1]); o.p(42, m[2]); o.p(43, m[3])
        o.p(44, p.width); o.p(45, p.height)
        o.p(46, 0.0); o.p(47, 0.0); o.p(48, 0.0); o.p(49, 0.0)
        o.p(140, 0.0); o.p(141, 0.0); o.p(142, 1.0); o.p(143, 1.0)
        o.p(70, 688); o.p(72, 1); o.p(73, 0); o.p(74, 5); o.p(7, ""); o.p(75, 16); o.p(147, 1.0)
        o.p(76, 0); o.p(77, 2); o.p(78, 300); o.p(148, 0.0); o.p(149, 0.0)
        o.p(100, "AcDbLayout")
        o.p(1, dxfEncodeUnicode(name)); o.p(70, 1); o.p(71, tabOrder)
        o.p(10, limits.min.x); o.p(20, limits.min.y); o.p(11, limits.max.x); o.p(21, limits.max.y)
        o.pt(12, .zero)
        o.pt(14, extents.min); o.pt(15, extents.max)
        o.p(146, 0.0)
        o.pt(13, .zero)
        o.p(16, 1.0); o.p(26, 0.0); o.p(36, 0.0)
        o.p(17, 0.0); o.p(27, 1.0); o.p(37, 0.0)
        o.p(76, 0)
        o.p(330, record)
        if let lastViewport { o.p(331, lastViewport) }
    }

    mutating func writeText(_ t: TextGeom, _ e: Entity, owner: String, into b: inout DXFBuf) {
        let style = styleNames.first { $0.caseInsensitiveCompare(t.style) == .orderedSame } ?? "Standard"
        if t.isMultiline {
            begin("MTEXT", e, owner: owner, "AcDbMText", into: &b)
            b.pt(10, t.position); b.p(40, t.height); b.p(41, t.width)
            let row: Int
            switch t.vAlign {
            case .top, .baseline: row = 0
            case .middle: row = 1
            case .bottom: row = 2
            }
            b.p(71, row * 3 + t.hAlign.rawValue + 1); b.p(72, 1)
            // 250-char chunks; never split an escape sequence (\\, \P, \U+XXXX) across chunks.
            var content = Array(dxfEncodeUnicode(dxfEscapeMText(t.text)))[...]
            while content.count > 250 {
                var cut = content.startIndex + 250
                if let bs = content[(cut - 7)..<cut].lastIndex(of: "\\") {
                    var k = bs
                    while k > content.startIndex && content[k - 1] == "\\" { k -= 1 }
                    // An odd run of backslashes ending at `bs` starts an escape: cut before it.
                    if (bs - k) % 2 == 0 { cut = bs }
                }
                b.p(3, String(content[..<cut]))
                content = content[cut...]
            }
            b.p(1, String(content))
            b.p(7, dxfEncodeUnicode(style))
            b.p(210, 0.0); b.p(220, 0.0); b.p(230, 1.0)
            b.pt(11, Vec2.polar(1, t.rotation))
        } else {
            begin("TEXT", e, owner: owner, "AcDbText", into: &b)
            b.pt(10, t.position); b.p(40, t.height)
            b.p(1, dxfEncodeUnicode(t.text.replacingOccurrences(of: "\n", with: " ")))
            b.p(50, degrees(t.rotation)); b.p(7, dxfEncodeUnicode(style))
            b.p(72, t.hAlign.rawValue)
            if t.hAlign != .left || t.vAlign != .baseline { b.pt(11, t.position) }
            b.p(100, "AcDbText"); b.p(73, t.vAlign.rawValue)
        }
    }

    /// AcDbText part of an ATTRIB/ATTDEF (single line; multiline values are joined).
    func writeAttributeText(_ t: TextGeom, value: String, into b: inout DXFBuf) {
        let style = styleNames.first { $0.caseInsensitiveCompare(t.style) == .orderedSame } ?? "Standard"
        b.pt(10, t.position); b.p(40, t.height > 0 ? t.height : 2.5)
        b.p(1, dxfEncodeUnicode(value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")))
        b.p(50, degrees(t.rotation)); b.p(7, dxfEncodeUnicode(style))
        b.p(72, t.hAlign.rawValue)
        if t.hAlign != .left || t.vAlign != .baseline { b.pt(11, t.position) }
    }

    /// Tags may not be empty or contain spaces.
    func attributeTag(_ tag: String) -> String {
        let t = tag.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        return t.isEmpty ? "TAG" : t
    }

    mutating func writeSpline(_ s: SplineGeom, _ e: Entity, owner: String, into b: inout DXFBuf) {
        var cps = s.controlPoints, knots = s.knots, degree = s.degree
        if cps.isEmpty {
            // Fit-point spline: export the exactly equivalent Bezier-segment B-spline.
            guard s.fitPoints.count >= 2 else { return }
            if s.fitPoints.count == 2 {
                cps = s.fitPoints; degree = 1; knots = [0, 0, 1, 1]
            } else {
                (cps, knots) = catmullRomControlPoints(s.fitPoints, closed: s.closed)
                degree = 3
            }
        } else {
            guard cps.count >= 2 else { return }
            degree = max(1, min(degree, cps.count - 1))
            if knots.count != cps.count + degree + 1 {
                let inner = cps.count - degree - 1
                knots = Array(repeating: 0, count: degree + 1)
                if inner > 0 { for i in 1...inner { knots.append(Double(i) / Double(inner + 1)) } }
                knots += Array(repeating: 1, count: degree + 1)
            }
        }
        begin("SPLINE", e, owner: owner, "AcDbSpline", into: &b)
        b.p(210, 0.0); b.p(220, 0.0); b.p(230, 1.0)
        b.p(70, 8 | (s.closed ? 1 : 0)); b.p(71, degree)
        b.p(72, knots.count); b.p(73, cps.count); b.p(74, s.fitPoints.count)
        b.p(42, 1e-10); b.p(43, 1e-10)
        if !s.fitPoints.isEmpty { b.p(44, 1e-10) }
        for k in knots { b.p(40, k) }
        for c in cps { b.pt(10, c) }
        for f in s.fitPoints { b.pt(11, f) }
    }

    mutating func writeHatch(_ h: HatchGeom, _ e: Entity, owner: String, into b: inout DXFBuf) {
        let loops = h.loops.filter { $0.count >= 2 }
        guard !loops.isEmpty else { return }
        let solid = h.pattern == .solid
        var name = solid ? "SOLID" : (h.patternName.isEmpty || h.patternName.uppercased() == "SOLID" ? "ANSI31" : h.patternName)
        name = name.replacingOccurrences(of: " ", with: "_")
        let user = name.uppercased() == "_USER"
        begin("HATCH", e, owner: owner, "AcDbHatch", into: &b)
        b.pt(10, .zero); b.p(210, 0.0); b.p(220, 0.0); b.p(230, 1.0)
        b.p(2, dxfEncodeUnicode(name)); b.p(70, solid ? 1 : 0); b.p(71, 0)
        b.p(91, loops.count)
        for loop in loops {
            let bulged = loop.contains { $0.bulge != 0 }
            b.p(92, 2); b.p(72, bulged ? 1 : 0); b.p(73, 1); b.p(93, loop.count)
            for v in loop {
                b.p(10, v.point.x); b.p(20, v.point.y)
                if bulged { b.p(42, v.bulge) }
            }
            b.p(97, 0)
        }
        b.p(75, 0); b.p(76, user ? 0 : 1)
        if !solid {
            let spacing = h.spacing > 0 ? h.spacing : 1
            let angleDeg = degrees(h.angle)
            b.p(52, user ? angleDeg : angleDeg - dxfPatternBaseAngle(name))
            b.p(41, user ? spacing : spacing / 3.175)
            b.p(77, 0)
            let angles = h.pattern == .cross ? [h.angle, h.angle + .pi / 2] : [h.angle]
            b.p(78, angles.count)
            for a in angles {
                let off = Vec2.polar(1, a).perp * spacing
                b.p(53, degrees(a)); b.p(43, 0.0); b.p(44, 0.0); b.p(45, off.x); b.p(46, off.y); b.p(79, 0)
            }
        }
        b.p(98, 0)
    }

    mutating func writeDimension(_ dm: DimensionGeom, _ e: Entity, owner: String, into b: inout DXFBuf) {
        // Rendered geometry for the anonymous block.
        let g = dimensionGraphics(dm, style: drawing.settings.dimStyle)
        var parts: [Entity] = []
        func part(_ k: EntityKind) { parts.append(Entity(k, layer: "0", color: .byBlock, linetype: "ByBlock", lineweight: -2)) }
        for p in g.prims {
            switch p {
            case let .seg(a, c): part(.line(LineGeom(start: a, end: c)))
            case let .arc(c, r, s, w):
                if w >= 2 * .pi - 1e-9 { part(.circle(CircleGeom(center: c, radius: r))) }
                else { part(.arc(ArcGeom(center: c, radius: r, startAngle: s, endAngle: s + w))) }
            }
        }
        if !g.text.text.isEmpty { part(.text(g.text)) }
        let blockName = "*D\(dimBlocks.count + 1)"
        dimBlocks.append((blockName, handle(), parts, g.arrows))

        begin("DIMENSION", e, owner: owner, "AcDbDimension", into: &b)
        b.p(2, blockName)
        let type: Int
        var def = dm.p3
        switch dm.kind {
        case .linear: type = 0
        case .aligned: type = 1
        case .angular: type = 5
        case .diameter: type = 3; def = dm.p1 * 2 - dm.p2
        case .radius: type = 4; def = dm.p1
        }
        // Radial dims keep p3 (leader/text point) in code 11 so it survives a round trip.
        let textPt = dm.kind == .radius || dm.kind == .diameter ? dm.p3 : g.text.position
        b.pt(10, def); b.pt(11, textPt)
        b.p(70, type | 32)
        if !dm.textOverride.isEmpty { b.p(1, dxfEncodeUnicode(dm.textOverride)) }
        b.p(3, "Standard")
        switch dm.kind {
        case .linear, .aligned:
            b.p(100, "AcDbAlignedDimension"); b.pt(13, dm.p1); b.pt(14, dm.p2)
            if dm.kind == .linear { b.p(50, degrees(dm.rotation)); b.p(100, "AcDbRotatedDimension") }
        case .angular:
            b.p(100, "AcDb3PointAngularDimension"); b.pt(13, dm.p2); b.pt(14, dm.p4); b.pt(15, dm.p1)
        case .diameter:
            b.p(100, "AcDbDiametricDimension"); b.pt(15, dm.p2); b.p(40, 0.0)
        case .radius:
            b.p(100, "AcDbRadialDimension"); b.pt(15, dm.p2); b.p(40, 0.0)
        }
    }

}
