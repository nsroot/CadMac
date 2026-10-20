import Foundation

/// Native AutoCAD 2000 (AC1015) DWG writer, implemented from the Open Design Alliance
/// "Open Design Specification for .dwg files" (v5.4.1).
///
/// The object graph mirrors `DXFWriter`: block records for *Model_Space, *Paper_Space,
/// *Paper_SpaceN and user blocks, LAYOUT objects in ACAD_LAYOUT, an overall paper viewport per
/// layout, GROUPs in ACAD_GROUP, INSERT + ATTRIB + SEQEND, anonymous *D blocks holding the
/// rendered dimension geometry, and the standard tables and named-object dictionaries.
/// True colors are written as the nearest ACI (R2000 entities have no true color).
public enum NativeDWGWriter {
    public static func write(_ d: Drawing) throws -> Data {
        var w = DWGWriterImpl(drawing: d)
        return try w.run()
    }

    public static func write(_ d: Drawing, to url: URL) throws {
        try write(d).write(to: url, options: .atomic)
    }
}

public enum DWGWriteError: Error, LocalizedError {
    case fileTooLarge

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge: return "The drawing is too large for the AutoCAD 2000 DWG format."
        }
    }
}

// MARK: - Plan

/// Something drawn by an entity record that is not a plain `Entity`.
enum DWGWSpecial {
    case none
    /// Overall paper-space viewport (id 1) of a layout.
    case overallViewport(ViewportGeom)
    /// Filled dimension arrowhead.
    case solid([Vec2])
}

struct DWGWEnt {
    var handle: UInt32
    var e: Entity
    var special: DWGWSpecial = .none
    var reactors: [UInt32] = []
    /// INSERT: ATTRIB handles and the SEQEND handle.
    var attribs: [UInt32] = []
    var seqend: UInt32 = 0
    /// DIMENSION: block record of its anonymous block.
    var dimBlock: UInt32 = 0
    /// Spline control data resolved during planning.
    var spline: (cps: [Vec2], knots: [Double], degree: Int)? = nil
}

struct DWGWBlock {
    var name: String
    var record: UInt32
    var blockEnt: UInt32 = 0
    var endblk: UInt32 = 0
    var base: Vec2 = .zero
    var ents: [DWGWEnt] = []
    /// 2 = model space, 1 = active paper space, 0 = everything else (owner handle stored).
    var entmode = 0
    var layout: UInt32 = 0
    var anonymous = false
    var hasAttdefs = false
    var isPaper = false
}

struct DWGWLayout {
    var handle: UInt32
    var name: String
    var tabOrder: Int
    var paper: PaperSetup
    var limits: BBox
    var extents: BBox
    var record: UInt32
    var lastViewport: UInt32
}

/// Fixed handles of the control objects and root dictionaries.
enum DWGWH {
    static let blockControl: UInt32 = 0x1
    static let layerControl: UInt32 = 0x2
    static let styleControl: UInt32 = 0x3
    static let ltypeControl: UInt32 = 0x5
    static let viewControl: UInt32 = 0x6
    static let ucsControl: UInt32 = 0x7
    static let vportControl: UInt32 = 0x8
    static let appidControl: UInt32 = 0x9
    static let dimstyleControl: UInt32 = 0xA
    static let vxControl: UInt32 = 0xB
    static let nod: UInt32 = 0xC
    static let groupDict: UInt32 = 0xD
    static let plotStyleDict: UInt32 = 0xE
    static let placeholder: UInt32 = 0xF
    static let layoutDict: UInt32 = 0x10
    static let mlineDict: UInt32 = 0x11
    static let mlineStandard: UInt32 = 0x12
    static let plotSettingsDict: UInt32 = 0x13
    static let ltByBlock: UInt32 = 0x14
    static let ltByLayer: UInt32 = 0x15
    static let ltContinuous: UInt32 = 0x16
    static let appidACAD: UInt32 = 0x17
    static let dimstyleStandard: UInt32 = 0x18
    static let vportActive: UInt32 = 0x19
    static let firstDynamic: UInt32 = 0x20
}

/// Class numbers (object types) of the non-fixed classes this writer uses.
enum DWGWClass {
    static let dictionaryWithDefault = 500
    static let placeholder = 501
    static let layout = 502
    static let lwpolyline = 503
    static let hatch = 504
    /// (dxf name, C++ name, app name, is entity)
    static let all: [(String, String, String, Bool)] = [
        ("ACDBDICTIONARYWDFLT", "AcDbDictionaryWithDefault", "ObjectDBX Classes", false),
        ("ACDBPLACEHOLDER", "AcDbPlaceHolder", "ObjectDBX Classes", false),
        ("LAYOUT", "AcDbLayout", "ObjectDBX Classes", false),
        ("LWPOLYLINE", "AcDbPolyline", "AutoCAD 2000", true),
        ("HATCH", "AcDbHatch", "AutoCAD 2000", true),
    ]
}

struct DWGWriterImpl {
    let drawing: Drawing
    var nextHandle: UInt32 = DWGWH.firstDynamic

    // Tables
    var layers: [(layer: Layer, handle: UInt32)] = []
    var layerByName: [String: UInt32] = [:]
    /// Layer records by their name exactly as written. Files do hold `yazı` and `YAZI` as two
    /// layers, so the table keeps names as they came while references match case-insensitively.
    var layerByExactName: [String: UInt32] = [:]
    var ltypes: [(lt: Linetype, handle: UInt32)] = []
    var ltypeByName: [String: UInt32] = [:]
    var styles: [(name: String, handle: UInt32)] = []
    var styleByName: [String: UInt32] = [:]

    // Blocks / layouts / groups
    var blocks: [DWGWBlock] = []
    var dimBlocks: [DWGWBlock] = []
    var layoutObjs: [DWGWLayout] = []
    var groups: [(group: EntityGroup, handle: UInt32)] = []
    var blockRecordByName: [String: UInt32] = [:]
    var insertsByRecord: [UInt32: [UInt32]] = [:]
    var entityHandles: [EntityID: UInt32] = [:]
    var groupReactors: [EntityID: [UInt32]] = [:]
    var usedBlockNames: Set<String> = []
    var paperSpaceRecord: UInt32 = 0
    /// User block being planned (to reject recursive inserts).
    var currentBlock: String? = nil
    var modelSpaceRecord: UInt32 = 0

    /// Encoded objects: handle -> bytes (MS size + data + CRC).
    var objects: [(handle: UInt32, bytes: [UInt8])] = []

    init(drawing: Drawing) { self.drawing = drawing }

    mutating func alloc() -> UInt32 {
        defer { nextHandle += 1 }
        return nextHandle
    }

    // MARK: Run

    mutating func run() throws -> Data {
        collectTables()
        planBlocksAndLayouts()
        encodeAll()
        return try assemble()
    }

    // MARK: Tables

    mutating func collectTables() {
        let d = drawing
        // Linetypes (ByBlock/ByLayer/Continuous have fixed handles).
        ltypeByName["CONTINUOUS"] = DWGWH.ltContinuous
        for lt in d.linetypes where !["CONTINUOUS", "BYLAYER", "BYBLOCK"].contains(lt.name.uppercased()) && !lt.name.isEmpty {
            let key = lt.name.uppercased()
            guard ltypeByName[key] == nil else { continue }
            let h = alloc()
            ltypes.append((lt, h))
            ltypeByName[key] = h
        }

        // Layers: the drawing's, plus any referenced by entities but missing from the table.
        var ls = d.layers
        if !ls.contains(where: { $0.name == "0" }) { ls.insert(Layer(name: "0"), at: 0) }
        if let i = ls.firstIndex(where: { $0.name == "0" }), i != 0 { ls.insert(ls.remove(at: i), at: 0) }
        var seen = Set<String>()
        /// Adds a layer record. Table entries are kept by exact name (two layers may differ only by
        /// case); a name seen only in a reference never adds a second record for a layer that exists.
        func addLayer(_ l: Layer, fromTable: Bool = false) {
            guard !l.name.isEmpty else { return }
            let upper = l.name.uppercased()
            if fromTable { guard !seen.contains(l.name) else { return } } else { guard layerByName[upper] == nil else { return } }
            seen.insert(l.name)
            let h = alloc()
            layers.append((l, h))
            layerByName[upper] = layerByName[upper] ?? h
            layerByExactName[l.name] = h
        }
        for l in ls { addLayer(l, fromTable: true) }
        func scanLayers(_ es: [Entity]) {
            for e in es {
                addLayer(Layer(name: e.layer))
                if case .insert(let i) = e.kind {
                    for a in i.attributes { addLayer(Layer(name: a.layer ?? "")) }
                }
            }
        }
        for space in d.allSpaces { scanLayers(space) }
        for b in d.blocks.values { scanLayers(b.entities) }

        // Text styles.
        func addStyle(_ s: String) {
            let key = s.uppercased()
            guard !s.isEmpty, styleByName[key] == nil else { return }
            let h = alloc()
            styles.append((s, h))
            styleByName[key] = h
        }
        addStyle("Standard")
        func scanStyles(_ es: [Entity]) {
            for e in es {
                switch e.kind {
                case .text(let t): addStyle(t.style)
                case .attdef(let a): addStyle(a.text.style)
                case .insert(let i): for a in i.attributes { addStyle(a.text.style) }
                default: break
                }
            }
        }
        for space in d.allSpaces { scanStyles(space) }
        for b in d.blocks.values { scanStyles(b.entities) }
    }

    func styleHandle(_ name: String) -> UInt32 { styleByName[name.uppercased()] ?? styleByName["STANDARD"]! }
    func layerHandle(_ name: String) -> UInt32 {
        layerByExactName[name] ?? layerByName[name.uppercased()] ?? layers[0].handle
    }

    // MARK: Blocks and layouts

    mutating func planBlocksAndLayouts() {
        let d = drawing
        let sortedLayouts = d.layouts.enumerated()
            .sorted { ($0.element.tabOrder, $0.offset) < ($1.element.tabOrder, $1.offset) }.map(\.element)
        var sheets = sortedLayouts
        if sheets.isEmpty { sheets = [Layout(name: "Layout1", tabOrder: 1)] }
        // Layout names are dictionary keys: unique, and never "Model".
        var layoutNames: Set<String> = ["MODEL"]
        for i in sheets.indices {
            var name = sheets[i].name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "Layout\(i + 1)" }
            var candidate = name, n = 2
            while layoutNames.contains(candidate.uppercased()) { candidate = "\(name) (\(n))"; n += 1 }
            layoutNames.insert(candidate.uppercased())
            sheets[i].name = candidate
        }
        let userBlocks = d.blocks.values.filter { !$0.name.isEmpty }.sorted { $0.name < $1.name }

        // Records first (so INSERTs can reference any block).
        let msRecord = alloc(), modelLayout = alloc()
        modelSpaceRecord = msRecord
        var model = DWGWBlock(name: "*Model_Space", record: msRecord)
        model.entmode = 2
        model.layout = modelLayout
        blocks.append(model)
        usedBlockNames.insert("*MODEL_SPACE")
        var sheetLayoutHandles: [UInt32] = []
        for (i, _) in sheets.enumerated() {
            var b = DWGWBlock(name: i == 0 ? "*Paper_Space" : "*Paper_Space\(i - 1)", record: alloc())
            b.entmode = i == 0 ? 1 : 0
            b.isPaper = true
            b.layout = alloc()
            sheetLayoutHandles.append(b.layout)
            usedBlockNames.insert(b.name.uppercased())
            blocks.append(b)
        }
        paperSpaceRecord = blocks[1].record
        for ub in userBlocks {
            guard !usedBlockNames.contains(ub.name.uppercased()) else { continue }
            var b = DWGWBlock(name: ub.name, record: alloc())
            b.base = ub.basePoint
            b.anonymous = ub.name.hasPrefix("*")
            b.hasAttdefs = ub.entities.contains { if case .attdef = $0.kind { return true }; return false }
            usedBlockNames.insert(ub.name.uppercased())
            blockRecordByName[ub.name] = b.record
            blocks.append(b)
        }

        // Groups: members must share one space (first member's space wins), like DXFWriter.
        var spaceOf: [EntityID: Int] = [:]
        for (k, space) in (d.allSpaces + userBlocks.map(\.entities)).enumerated() {
            for e in space where spaceOf[e.id] == nil { spaceOf[e.id] = k }
        }
        var groupNames = Set<String>()
        for g in d.groups {
            var seenIDs = Set<EntityID>()
            let space = g.members.lazy.compactMap { spaceOf[$0] }.first
            let members = g.members.filter { spaceOf[$0] != nil && spaceOf[$0] == space && seenIDs.insert($0).inserted }
            let key = g.name.uppercased()
            guard !members.isEmpty, !g.name.isEmpty, !groupNames.contains(key) else { continue }
            groupNames.insert(key)
            var gg = g
            gg.members = members
            let h = alloc()
            groups.append((gg, h))
            for m in members { groupReactors[m, default: []].append(h) }
        }

        // Entities.
        blocks[0].ents = plan(d.modelEntities, sheet: false)
        for (i, sh) in sheets.enumerated() {
            let p = sh.paper
            let c = Vec2(p.width / 2, p.height / 2)
            let overall = ViewportGeom(center: c, width: p.width, height: p.height, viewCenter: c, viewHeight: p.height)
            var ents = [DWGWEnt(handle: alloc(), e: Entity(.viewport(overall)), special: .overallViewport(overall))]
            ents += plan(sh.entities, sheet: true)
            blocks[1 + i].ents = ents
        }
        for k in (1 + sheets.count)..<blocks.count {
            guard let ub = d.blocks[blocks[k].name] else { continue }
            currentBlock = ub.name
            blocks[k].ents = plan(ub.entities, sheet: false)
            currentBlock = nil
        }
        blocks += dimBlocks
        dimBlocks = []
        for k in blocks.indices {
            blocks[k].blockEnt = alloc()
            blocks[k].endblk = alloc()
        }

        // LAYOUT objects.
        let ext = d.extents(of: d.modelEntities)
        let limits = BBox(min: d.settings.limitsMin, max: d.settings.limitsMax)
        layoutObjs.append(DWGWLayout(handle: modelLayout, name: "Model", tabOrder: 0, paper: .a3Landscape, limits: limits,
                                     extents: ext.isEmpty ? limits : ext, record: msRecord, lastViewport: 0))
        for (i, sh) in sheets.enumerated() {
            let p = sh.paper
            let box = BBox(min: .zero, max: Vec2(p.width, p.height))
            let e = d.extents(of: sh.entities)
            layoutObjs.append(DWGWLayout(handle: sheetLayoutHandles[i], name: sh.name, tabOrder: i + 1, paper: p, limits: box,
                                         extents: e.isEmpty ? box : e, record: blocks[1 + i].record,
                                         lastViewport: blocks[1 + i].ents[0].handle))
        }
    }

    /// True if block `from` is `target` or inserts it (directly or through nested blocks).
    func reaches(_ from: String, _ target: String) -> Bool {
        var seen = Set<String>(), stack = [from]
        while let b = stack.popLast() {
            if b == target { return true }
            guard seen.insert(b).inserted, let def = drawing.blocks[b] else { continue }
            for e in def.entities { if case .insert(let i) = e.kind { stack.append(i.blockName) } }
        }
        return false
    }

    /// Assigns handles to the writable entities of one space or block.
    mutating func plan(_ es: [Entity], sheet: Bool) -> [DWGWEnt] {
        var out: [DWGWEnt] = []
        for e in es {
            var spline: (cps: [Vec2], knots: [Double], degree: Int)? = nil
            switch e.kind {
            case .viewport(let v): guard sheet, v.width > 0, v.height > 0 else { continue }
            case .polyline(let p): guard !p.vertices.isEmpty else { continue }
            case .ellipse(let el): guard el.majorAxis.length > 0, el.ratio > 0 else { continue }
            case .circle(let c): guard c.radius > 0 else { continue }
            case .arc(let a): guard a.radius > 0 else { continue }
            case .hatch(let h): guard h.loops.contains(where: { $0.count >= 2 }) else { continue }
            case .insert(let i):
                guard blockRecordByName[i.blockName] != nil else { continue }
                // A block may not (indirectly) contain itself.
                if let cur = currentBlock, reaches(i.blockName, cur) { continue }
            case .spline(let s):
                guard let sp = DWGWriterImpl.splineData(s) else { continue }
                spline = sp
            default: break
            }
            var pe = DWGWEnt(handle: alloc(), e: e)
            pe.spline = spline
            if entityHandles[e.id] == nil {
                entityHandles[e.id] = pe.handle
                pe.reactors = groupReactors[e.id] ?? []
            }
            switch e.kind {
            case .insert(let i):
                insertsByRecord[blockRecordByName[i.blockName]!, default: []].append(pe.handle)
                if !i.attributes.isEmpty {
                    pe.attribs = i.attributes.map { _ in alloc() }
                    pe.seqend = alloc()
                }
            case .dimension(let dm):
                pe.dimBlock = planDimensionBlock(dm)
            default: break
            }
            out.append(pe)
        }
        return out
    }

    /// Creates the anonymous *D block with the rendered dimension geometry.
    mutating func planDimensionBlock(_ dm: DimensionGeom) -> UInt32 {
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
        var n = 1
        while usedBlockNames.contains("*D\(n)") { n += 1 }
        let name = "*D\(n)"
        usedBlockNames.insert(name)
        var b = DWGWBlock(name: name, record: alloc())
        b.anonymous = true
        b.ents = plan(parts, sheet: false)
        for s in g.arrows where s.count >= 3 {
            let e = Entity(.point(PointGeom(position: .zero)), color: .byBlock, linetype: "ByBlock", lineweight: -2)
            b.ents.append(DWGWEnt(handle: alloc(), e: e, special: .solid(s)))
        }
        dimBlocks.append(b)
        return b.record
    }

    /// Control points, knots and degree for a spline (fit-point splines become the equivalent
    /// Bezier-segment B-spline, like DXFWriter). Nil if it cannot be written.
    static func splineData(_ s: SplineGeom) -> (cps: [Vec2], knots: [Double], degree: Int)? {
        var cps = s.controlPoints, knots = s.knots, degree = s.degree
        if cps.isEmpty {
            guard s.fitPoints.count >= 2 else { return nil }
            if s.fitPoints.count == 2 {
                cps = s.fitPoints; degree = 1; knots = [0, 0, 1, 1]
            } else {
                (cps, knots) = catmullRomControlPoints(s.fitPoints, closed: s.closed)
                degree = 3
            }
        } else {
            guard cps.count >= 2 else { return nil }
            degree = max(1, min(degree, cps.count - 1))
            if knots.count != cps.count + degree + 1 {
                let inner = cps.count - degree - 1
                knots = Array(repeating: 0, count: degree + 1)
                if inner > 0 { for i in 1...inner { knots.append(Double(i) / Double(inner + 1)) } }
                knots += Array(repeating: 1, count: degree + 1)
            }
        }
        return (cps, knots, degree)
    }

    // MARK: Encoding

    mutating func emit(_ handle: UInt32, _ bytes: [UInt8]) { objects.append((handle, bytes)) }

    mutating func encodeAll() {
        encodeControlObjects()
        encodeTableRecords()
        encodeDictionaries()
        for b in blocks { encodeBlock(b) }
    }

    // MARK: File assembly

    func assemble() throws -> Data {
        let header = headerVariablesSection()
        let classes = classesSection()
        var file = [UInt8](repeating: 0, count: 0x58)
        let headerAt = file.count
        file += header
        let classesAt = file.count
        file += classes
        // R13C3+ padding.
        file += [UInt8](repeating: 0, count: 0x200)

        // Objects, in handle order.
        let objectsAt = file.count
        var locations: [(handle: UInt32, loc: Int)] = []
        for o in objects.sorted(by: { $0.handle < $1.handle }) {
            locations.append((o.handle, file.count))
            file += o.bytes
        }

        // Object map.
        let mapAt = file.count
        file += DWGWriterImpl.objectMap(locations)
        let mapSize = file.count - mapAt

        // Object free space (section locator 3).
        let freeAt = file.count
        var free = DWGBitWriter()
        free.rl(0)
        free.rl(locations.count + 3)
        let (jd, ms) = DWGWriterImpl.julian(Date())
        free.rl(jd); free.rl(ms)
        free.rl(objectsAt)
        free.rc(4)
        for v: UInt32 in [0x32, 0, 0x64, 0, 0x200, 0, 0xFFFF_FFFF, 0] { free.rl(v) }
        file += free.bytes
        let freeSize = file.count - freeAt

        // Second file header.
        let secondAt = file.count
        file += secondHeader(at: secondAt, sections: [(headerAt, header.count), (classesAt, classes.count), (mapAt, mapSize), (freeAt, freeSize)])

        // Template (section locator 4): MEASUREMENT.
        let templateAt = file.count
        let metric = drawing.settings.insUnits == .inches || drawing.settings.insUnits == .feet ? 0 : 1
        file += [0, 0, UInt8(metric), 0]

        // Empty preview image area.
        let imageAt = file.count
        file += DWGWriterImpl.imageStart
        file += [1, 0, 0, 0, 0]
        file += DWGWriterImpl.imageEnd

        guard file.count < Int(Int32.max) else { throw DWGWriteError.fileTooLarge }

        // File header.
        var fh = DWGBitWriter()
        fh.rawBytes(Array("AC1015".utf8))
        fh.rawBytes([0, 0, 0, 0, 0, 0, 1])
        fh.rl(imageAt)
        fh.rawBytes([0, 0])
        fh.rs(30) // ANSI_1252
        fh.rl(5)
        let recs: [(Int, Int)] = [(headerAt, header.count), (classesAt, classes.count), (mapAt, mapSize),
                                  (freeAt, freeSize), (templateAt, 4)]
        for (i, r) in recs.enumerated() { fh.rc(UInt8(i)); fh.rl(r.0); fh.rl(r.1) }
        let crc = DWGBitWriter.crc(0, fh.bytes) ^ 0x3CC4
        fh.rs(crc)
        fh.rawBytes(DWGWriterImpl.fileHeaderEnd)
        precondition(fh.bytes.count == 0x58)
        file.replaceSubrange(0..<0x58, with: fh.bytes)
        return Data(file)
    }

    /// Object map: sections of at most 2032 bytes; each restarts the handle/offset deltas.
    static func objectMap(_ locations: [(handle: UInt32, loc: Int)]) -> [UInt8] {
        var out: [UInt8] = []
        var section: [UInt8] = []
        var lastHandle = 0, lastLoc = 0
        func flush() {
            let size = section.count + 2
            var s: [UInt8] = [UInt8(size >> 8), UInt8(size & 0xFF)] + section
            let crc = DWGBitWriter.crc(0xC0C1, s)
            s += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
            out += s
            section = []
            lastHandle = 0; lastLoc = 0
        }
        for l in locations {
            var pair = DWGBitWriter.modularChar(Int(l.handle) - lastHandle) + DWGBitWriter.modularChar(l.loc - lastLoc)
            if section.count + pair.count > 2030 {
                flush()
                pair = DWGBitWriter.modularChar(Int(l.handle)) + DWGBitWriter.modularChar(l.loc)
            }
            section += pair
            lastHandle = Int(l.handle); lastLoc = l.loc
        }
        if !section.isEmpty { flush() }
        flush() // final empty section
        return out
    }

    /// Second file header (spec chapter 26).
    func secondHeader(at loc: Int, sections: [(Int, Int)]) -> [UInt8] {
        var w = DWGBitWriter()
        w.rawBytes(Array("AC1015".utf8))
        w.rawBytes([0, 0, 0, 0, 0, 0])
        w.bits(0, 4)
        w.rawBytes([0x18, 0x78, 0x01, 0x06])
        for (i, s) in sections.enumerated() { w.rc(UInt8(i)); w.rl(s.0); w.rl(s.1) }
        w.rs(14)
        let handles: [UInt32] = [nextHandle, DWGWH.blockControl, DWGWH.layerControl, DWGWH.styleControl, DWGWH.ltypeControl,
                                 DWGWH.viewControl, DWGWH.ucsControl, DWGWH.vportControl, DWGWH.appidControl,
                                 DWGWH.dimstyleControl, DWGWH.vxControl, DWGWH.nod, DWGWH.mlineStandard, DWGWH.groupDict]
        for (i, h) in handles.enumerated() {
            var hb: [UInt8] = []
            var v = h
            while v != 0 { hb.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            w.rc(UInt8(hb.count)); w.rc(UInt8(i)); w.rawBytes(hb)
        }
        var body = w.bytes
        // size + location precede the body.
        var pre = DWGBitWriter()
        pre.rl(body.count)
        pre.rl(loc)
        body = pre.bytes + body
        let crc = DWGBitWriter.crc(0xC0C1, body)
        return DWGWriterImpl.secondStart + body + [UInt8(crc & 0xFF), UInt8(crc >> 8)] + DWGWriterImpl.secondEnd
    }

    /// Julian day number and milliseconds since local midnight (AutoCAD's TDCREATE form).
    static func julian(_ date: Date) -> (Int, Int) {
        let t = date.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: date))
        let jd = 2440588 + t / 86400
        let day = floor(jd)
        return (Int(day), Int(((jd - day) * 86_400_000).rounded(.down)))
    }

    static let fileHeaderEnd: [UInt8] = [0x95, 0xA0, 0x4E, 0x28, 0x99, 0x82, 0x1A, 0xE5, 0x5E, 0x41, 0xE0, 0x5F, 0x9D, 0x3A, 0x4D, 0x00]
    static let headerStart: [UInt8] = [0xCF, 0x7B, 0x1F, 0x23, 0xFD, 0xDE, 0x38, 0xA9, 0x5F, 0x7C, 0x68, 0xB8, 0x4E, 0x6D, 0x33, 0x5F]
    static let headerEnd: [UInt8] = [0x30, 0x84, 0xE0, 0xDC, 0x02, 0x21, 0xC7, 0x56, 0xA0, 0x83, 0x97, 0x47, 0xB1, 0x92, 0xCC, 0xA0]
    static let classesStart: [UInt8] = [0x8D, 0xA1, 0xC4, 0xB8, 0xC4, 0xA9, 0xF8, 0xC5, 0xC0, 0xDC, 0xF4, 0x5F, 0xE7, 0xCF, 0xB6, 0x8A]
    static let classesEnd: [UInt8] = [0x72, 0x5E, 0x3B, 0x47, 0x3B, 0x56, 0x07, 0x3A, 0x3F, 0x23, 0x0B, 0xA0, 0x18, 0x30, 0x49, 0x75]
    static let secondStart: [UInt8] = [0xD4, 0x7B, 0x21, 0xCE, 0x28, 0x93, 0x9F, 0xBF, 0x53, 0x24, 0x40, 0x09, 0x12, 0x3C, 0xAA, 0x01]
    static let secondEnd: [UInt8] = [0x2B, 0x84, 0xDE, 0x31, 0xD7, 0x6C, 0x60, 0x40, 0xAC, 0xDB, 0xBF, 0xF6, 0xED, 0xC3, 0x55, 0xFE]
    static let imageStart: [UInt8] = [0x1F, 0x25, 0x6D, 0x07, 0xD4, 0x36, 0x28, 0x28, 0x9D, 0x57, 0xCA, 0x3F, 0x9D, 0x44, 0x10, 0x2B]
    static let imageEnd: [UInt8] = [0xE0, 0xDA, 0x92, 0xF8, 0x2B, 0xC9, 0xD7, 0xD7, 0x62, 0xA8, 0x35, 0xC0, 0x62, 0xBB, 0xEF, 0xD4]
}

// MARK: - Object encoder

/// Builds one object: data stream (type, bit size, handle, EED, fields) and handle stream.
struct DWGWObj {
    var d = DWGBitWriter()
    var hs = DWGBitWriter()
    private var rlPos = 0

    /// Common prefix of every object: type, size-in-bits placeholder, handle, empty EED.
    init(type: Int, handle: UInt32) {
        d.bs(type)
        rlPos = d.bitCount
        d.rl(0)
        d.h(0, handle)
        d.bs(0)
    }

    /// Non-entity object: reactors count; handle stream starts with parent, reactors, xdictionary.
    static func object(type: Int, handle: UInt32, owner: UInt32, reactors: [UInt32] = []) -> DWGWObj {
        var o = DWGWObj(type: type, handle: handle)
        o.d.bl(reactors.count)
        o.hs.h(4, owner)
        for r in reactors { o.hs.h(4, r) }
        o.hs.h(3, 0)
        return o
    }

    /// MS size + bytes + CRC.
    func finish() -> [UInt8] {
        var w = d
        w.patchRL(at: rlPos, UInt32(d.bitCount))
        w.append(hs)
        let body = Array(w.bytes.prefix((w.bitCount + 7) / 8))
        var out = DWGBitWriter.modularShort(body.count) + body
        let crc = DWGBitWriter.crc(0xC0C1, out)
        out += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        return out
    }
}
