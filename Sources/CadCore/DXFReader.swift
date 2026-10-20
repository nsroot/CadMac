import Foundation

public enum DXFReader {
    public static func read(string: String) throws -> Drawing {
        try read(data: Data(string.utf8))
    }

    public static func read(data: Data) throws -> Drawing {
        // Entity handles are only needed to resolve GROUP members and FIELD owners.
        let records = try dxfRecords(from: data, keepHandles: dxfContains(data, "AcDbGroup") || dxfContains(data, "AcDbField"))
        guard records.contains(where: { $0.type == "SECTION" }) else { throw DXFError.notDXF }
        var p = DXFParser()
        p.run(records)
        return p.finish()
    }
}

// MARK: - Parser

/// A LAYOUT object from the OBJECTS section.
private struct DXFLayoutInfo {
    var handle = ""
    var name = ""
    var tabOrder = 0
    var paperName = ""
    var pageSetup = ""
    /// Margins left, bottom, right, top in mm (unrotated).
    var margins = [0.0, 0, 0, 0]
    /// Paper width/height in mm (unrotated).
    var width = 0.0, height = 0.0
    /// Plot paper units: 0 inches, 1 mm, 2 pixels.
    var units = 1
    /// Plot rotation 0..3 (quarter turns).
    var rotation = 0
    var limMin: Vec2?, limMax: Vec2?
    /// Handle of the paper space BLOCK_RECORD.
    var blockRecord = ""
    var order = 0
}

/// Viewport data needed after all entities are read.
private struct DXFViewportMeta {
    var id: Int
    var status: Int
    var frozenHandles: [String]
}

private struct DXFParser {
    var drawing = Drawing()
    var layers: [Layer] = []
    var linetypes: [Linetype] = []
    /// LAYER handle -> name.
    var layerHandles: [String: String] = [:]
    /// BLOCK_RECORD handle -> (name, LAYOUT handle).
    var blockRecords: [String: (name: String, layout: String)] = [:]
    var layoutInfos: [DXFLayoutInfo] = []
    /// Paper space entities by owning block name (uppercased): "*PAPER_SPACE" holds the
    /// active layout (ENTITIES with 67=1), "*PAPER_SPACE<N>" the others.
    var paperSpaces: [String: [Entity]] = [:]
    var paperSpaceOrder: [String] = []
    var viewportMeta: [EntityID: DXFViewportMeta] = [:]
    var paperLimits: BBox?
    /// Entity handle -> converted entity ids (only filled when the file has groups).
    var handleIDs: [String: [EntityID]] = [:]
    /// DICTIONARY handle -> (key, value handle) entries.
    var dictionaries: [String: [(key: String, handle: String)]] = [:]
    /// Handle of the ACAD_GROUP dictionary (from the root dictionary).
    var groupDictHandle: String?
    var rawGroups: [(handle: String, description: String, unnamed: Bool, selectable: Bool, members: [String])] = []
    /// DICTIONARY handle -> owner handle (entity extension dictionaries hold fields).
    var dictionaryOwners: [String: String] = [:]
    /// FIELD handle -> owner, expression (code 2) and cached value (302).
    var fields: [String: (owner: String, expression: String, cached: String?)] = [:]
    /// ATTRIB handle -> (insert ids, attribute index), for fields inside attributes.
    var attribHandles: [String: (ids: [EntityID], index: Int)] = [:]

    init() {
        drawing.modelEntities = []
        drawing.layouts = []
        drawing.activeLayout = nil
        drawing.blocks = [:]
    }

    mutating func run(_ records: [DXFRecord]) {
        var i = 0
        while i < records.count {
            let r = records[i]
            i += 1
            guard r.type == "SECTION" else { continue }
            let name = (r.s(2) ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            var j = i
            while j < records.count && records[j].type != "ENDSEC" && records[j].type != "EOF" { j += 1 }
            let body = records[i..<j]
            switch name {
            case "HEADER": parseHeader(r)
            case "TABLES": parseTables(body)
            case "BLOCKS": parseBlocks(body)
            case "ENTITIES":
                let (model, paper) = convert(body, splitSpaces: true)
                drawing.modelEntities += model
                addPaper(paper, to: "*PAPER_SPACE")
            case "OBJECTS": parseObjects(body)
            default: break
            }
            i = j + 1
        }
    }

    mutating func addPaper(_ es: [Entity], to block: String) {
        let key = block.uppercased()
        if paperSpaces[key] == nil { paperSpaceOrder.append(key) }
        paperSpaces[key, default: []] += es
    }

    mutating func finish() -> Drawing {
        if !layers.isEmpty { drawing.layers = layers }
        if drawing.layer(named: "0") == nil { drawing.layers.insert(Layer(name: "0"), at: 0) }
        if !linetypes.isEmpty {
            drawing.linetypes = linetypes
            for lt in Linetype.standard where drawing.linetype(named: lt.name) == nil { drawing.linetypes.append(lt) }
        }
        buildLayouts()
        applySheetFields()
        buildGroups()
        var used = Set<String>()
        for space in drawing.allSpaces { for e in space { used.insert(e.layer) } }
        for b in drawing.blocks.values { for e in b.entities { used.insert(e.layer) } }
        for l in used.sorted() { drawing.ensureLayer(l) }
        if drawing.layer(named: drawing.settings.currentLayer) == nil { drawing.settings.currentLayer = "0" }
        drawing.activeLayout = nil
        return drawing
    }

    // MARK: Header

    mutating func parseHeader(_ r: DXFRecord) {
        var vars: [String: [Int: DXFPair]] = [:]
        var cur = ""
        for p in r.pairs {
            if p.code == 9 { cur = p.value.trimmingCharacters(in: .whitespaces).uppercased(); continue }
            if !cur.isEmpty && vars[cur]?[p.code] == nil { vars[cur, default: [:]][p.code] = p }
        }
        func num(_ n: String, _ code: Int = 40) -> Double? { vars[n]?[code]?.double }
        var s = drawing.settings
        if let v = num("$LTSCALE"), v > 0 { s.ltScale = v }
        if let v = vars["$CLAYER"]?[8]?.value, !v.isEmpty { s.currentLayer = dxfDecodeUnicode(v) }
        if let v = num("$TEXTSIZE"), v > 0 { s.textHeight = v }
        if let v = num("$DIMSCALE"), v > 0 { s.dimStyle.scale = v }
        if let v = num("$DIMTXT"), v > 0 { s.dimStyle.textHeight = v }
        if let v = num("$DIMASZ"), v > 0 { s.dimStyle.arrowSize = v }
        if let v = num("$DIMEXO"), v >= 0 { s.dimStyle.extensionOffset = v }
        if let v = num("$DIMEXE"), v >= 0 { s.dimStyle.extensionExtend = v }
        if let v = num("$DIMGAP") { s.dimStyle.textGap = abs(v) }
        if let v = vars["$DIMDEC"]?[70]?.int, v >= 0, v <= 8 { s.dimStyle.precision = v }
        if let v = vars["$LUNITS"]?[70]?.int, let u = LengthUnits(rawValue: v) { s.units = u }
        if let v = vars["$LUPREC"]?[70]?.int, v >= 0, v <= 8 { s.unitPrecision = v }
        if let v = num("$PDSIZE") { s.pointSize = v }
        if let a = num("$LIMMIN", 10), let b = num("$LIMMIN", 20) { s.limitsMin = Vec2(a, b) }
        if let a = num("$LIMMAX", 10), let b = num("$LIMMAX", 20) { s.limitsMax = Vec2(a, b) }
        if let v = num("$FILLETRAD"), v >= 0 { s.filletRadius = v }
        if let a = num("$PLIMMIN", 10), let b = num("$PLIMMIN", 20), let c = num("$PLIMMAX", 10), let e = num("$PLIMMAX", 20),
           c > a, e > b {
            paperLimits = BBox(min: Vec2(a, b), max: Vec2(c, e))
        }
        // A file whose header omits $INSUNITS is unitless (AutoCAD's default).
        s.insUnits = (vars["$INSUNITS"]?[70]?.int).flatMap { DrawingUnit(rawValue: $0) } ?? .unitless
        drawing.settings = s
    }

    // MARK: Tables

    mutating func parseTables(_ body: ArraySlice<DXFRecord>) {
        for r in body {
            switch r.type {
            case "LAYER":
                guard let name = r.s(2), !name.isEmpty else { continue }
                if let h = r.first(5)?.value { layerHandles[dxfHandle(h)] = name }
                guard !layers.contains(where: { $0.name == name }) else { continue }
                let aci = r.i(62, 7)
                var color = CadColor.aci(aci == 0 ? 7 : min(255, abs(aci)))
                if let tc = r.first(420) { color = .rgb(RGB(packed: tc.int)) }
                let flags = r.i(70)
                let lw = r.i(370, -3)
                layers.append(Layer(name: name, color: color, linetype: r.s(6) ?? "Continuous",
                                    lineweight: lw >= 0 ? Double(lw) / 100 : -1,
                                    isOn: aci >= 0, isFrozen: flags & 1 != 0, isLocked: flags & 4 != 0,
                                    isPlottable: r.i(290, 1) != 0 && name.caseInsensitiveCompare("Defpoints") != .orderedSame))
            case "LTYPE":
                guard let name = r.s(2), !name.isEmpty else { continue }
                let upper = name.uppercased()
                if upper == "BYLAYER" || upper == "BYBLOCK" || linetypes.contains(where: { $0.name.uppercased() == upper }) { continue }
                linetypes.append(Linetype(name: name, description: r.s(3) ?? "", pattern: r.all(49).map(\.double)))
            case "BLOCK_RECORD":
                guard let h = r.first(5)?.value, let name = r.s(2) else { continue }
                blockRecords[dxfHandle(h)] = (name, r.first(340).map { dxfHandle($0.value) } ?? "")
            default: break
            }
        }
    }

    // MARK: Blocks

    mutating func parseBlocks(_ body: ArraySlice<DXFRecord>) {
        var i = body.startIndex
        while i < body.endIndex {
            let r = body[i]
            i += 1
            guard r.type == "BLOCK" else { continue }
            var j = i
            while j < body.endIndex && body[j].type != "ENDBLK" { j += 1 }
            let name = r.s(2) ?? r.s(3) ?? ""
            let upper = name.uppercased()
            if upper.hasPrefix("*PAPER_SPACE") || upper.hasPrefix("$PAPER_SPACE") {
                addPaper(convert(body[i..<j], splitSpaces: false, paper: true).paper, to: "*" + upper.dropFirst())
            } else {
                let skip = name.isEmpty || upper.hasPrefix("*MODEL_SPACE") || upper.hasPrefix("$MODEL_SPACE")
                    || upper.hasPrefix("*D") || r.i(70) & 4 != 0
                if !skip {
                    drawing.blocks[name] = BlockDef(name: name, basePoint: r.pt(10), entities: convert(body[i..<j], splitSpaces: false).model)
                }
            }
            i = j + 1
        }
    }

    // MARK: Layouts

    mutating func parseObjects(_ body: ArraySlice<DXFRecord>) {
        for r in body where r.type == "DICTIONARY" {
            guard let h = r.first(5)?.value else { continue }
            var entries: [(key: String, handle: String)] = []
            var key: String?
            for p in r.pairs {
                if p.code == 3 { key = dxfDecodeUnicode(p.value) }
                else if (p.code == 350 || p.code == 360), let k = key { entries.append((k, dxfHandle(p.value))); key = nil }
            }
            dictionaries[dxfHandle(h)] = entries
            if let o = r.owner { dictionaryOwners[dxfHandle(h)] = dxfHandle(o) }
            if groupDictHandle == nil, let g = entries.first(where: { $0.key.uppercased() == "ACAD_GROUP" }) { groupDictHandle = g.handle }
        }
        for r in body where r.type == "FIELD" {
            guard let h = r.first(5)?.value, let o = r.owner else { continue }
            let cached = r.all(302).last { !$0.value.isEmpty }.map { dxfDecodeUnicode($0.value) }
            fields[dxfHandle(h)] = (dxfHandle(o), r.s(2) ?? "", cached)
        }
        for r in body where r.type == "GROUP" {
            rawGroups.append((dxfHandle(r.first(5)?.value ?? ""), r.s(300) ?? "", r.i(70) & 1 != 0, r.i(71, 1) != 0,
                              r.all(340).map { dxfHandle($0.value) }))
        }
        for r in body where r.type == "LAYOUT" {
            var info = DXFLayoutInfo()
            info.order = layoutInfos.count
            var sub = ""
            var lmin = Vec2.zero, lmax = Vec2.zero, hasMin = false, hasMax = false
            for p in r.pairs {
                if p.code == 100 { sub = p.value.trimmingCharacters(in: .whitespaces); continue }
                switch (sub, p.code) {
                case ("", 5): info.handle = dxfHandle(p.value)
                case ("AcDbPlotSettings", 1): info.pageSetup = dxfDecodeUnicode(p.value)
                case ("AcDbPlotSettings", 4): info.paperName = dxfDecodeUnicode(p.value)
                case ("AcDbPlotSettings", 40): info.margins[0] = p.double
                case ("AcDbPlotSettings", 41): info.margins[1] = p.double
                case ("AcDbPlotSettings", 42): info.margins[2] = p.double
                case ("AcDbPlotSettings", 43): info.margins[3] = p.double
                case ("AcDbPlotSettings", 44): info.width = p.double
                case ("AcDbPlotSettings", 45): info.height = p.double
                case ("AcDbPlotSettings", 72): info.units = p.int
                case ("AcDbPlotSettings", 73): info.rotation = p.int
                case ("AcDbLayout", 1): info.name = dxfDecodeUnicode(p.value)
                case ("AcDbLayout", 71): info.tabOrder = p.int
                case ("AcDbLayout", 10): lmin.x = p.double; hasMin = true
                case ("AcDbLayout", 20): lmin.y = p.double
                case ("AcDbLayout", 11): lmax.x = p.double; hasMax = true
                case ("AcDbLayout", 21): lmax.y = p.double
                case ("AcDbLayout", 330): if info.blockRecord.isEmpty { info.blockRecord = dxfHandle(p.value) }
                default: break
                }
            }
            if hasMin && hasMax { info.limMin = lmin; info.limMax = lmax }
            layoutInfos.append(info)
        }
    }

    /// Builds `drawing.layouts` from LAYOUT objects and the collected paper space entities.
    mutating func buildLayouts() {
        // Viewport layer freezes are stored as LAYER handles.
        func resolve(_ es: [Entity], active: Bool) -> [Entity] {
            es.map { e in
                guard case .viewport(var v) = e.kind, let m = viewportMeta[e.id] else { return e }
                v.frozenLayers = m.frozenHandles.compactMap { layerHandles[$0] }
                if active && m.status == 0 { v.isOn = false }
                var o = e
                o.kind = .viewport(v)
                return o
            }
        }
        for k in paperSpaceOrder { paperSpaces[k] = resolve(paperSpaces[k] ?? [], active: k == "*PAPER_SPACE") }

        let modelRecord = blockRecords.first { $0.value.name.uppercased() == "*MODEL_SPACE" }?.key
        let infos = layoutInfos.filter {
            $0.name.caseInsensitiveCompare("Model") != .orderedSame && ($0.blockRecord.isEmpty || $0.blockRecord != modelRecord)
        }
        var built: [(layout: Layout, order: Int)] = []
        if infos.isEmpty {
            let all = paperSpaceOrder.flatMap { paperSpaces[$0] ?? [] }
            if !all.isEmpty {
                let (paper, origin) = paperSetup(nil, entities: all, limits: paperLimits)
                built.append((Layout(name: "Layout1", tabOrder: 1, paper: paper, entities: finishSheet(all, paper: paper, origin: origin)), 0))
            }
        } else {
            var claimed = Set<String>()
            var assigned: [String?] = []
            for info in infos {
                var rec = blockRecords[info.blockRecord]?.name
                if rec == nil, !info.handle.isEmpty {
                    rec = blockRecords.values.first { $0.layout == info.handle }?.name
                }
                let key = rec.map { $0.uppercased().replacingOccurrences(of: "$PAPER_SPACE", with: "*PAPER_SPACE") }
                if let k = key, paperSpaces[k] != nil { claimed.insert(k); assigned.append(k) } else { assigned.append(nil) }
            }
            // Paper spaces no LAYOUT points to go to layouts without content, in tab order.
            var spare = paperSpaceOrder.filter { !claimed.contains($0) && !(paperSpaces[$0] ?? []).isEmpty }
            let byTab = infos.indices.sorted { (infos[$0].tabOrder, $0) < (infos[$1].tabOrder, $1) }
            for i in byTab where assigned[i] == nil && !spare.isEmpty { assigned[i] = spare.removeFirst() }
            for (i, info) in infos.enumerated() {
                let es = assigned[i].flatMap { paperSpaces[$0] } ?? []
                let lim = info.limMin.flatMap { a in info.limMax.map { BBox(min: a, max: $0) } }
                let (paper, origin) = paperSetup(info, entities: es, limits: lim)
                let layout = Layout(name: info.name, tabOrder: info.tabOrder, paper: paper, entities: finishSheet(es, paper: paper, origin: origin))
                built.append((layout, i))
            }
        }
        if built.isEmpty {
            let ext = drawing.extents(of: drawing.modelEntities)
            drawing.layouts = [Layout.withDefaultViewport(name: "Layout1", tabOrder: 1,
                                                          showing: ext.isEmpty ? BBox(min: .zero, max: Vec2(420, 297)) : ext)]
            return
        }
        built.sort { ($0.layout.tabOrder, $0.order) < ($1.layout.tabOrder, $1.order) }
        var names = Set<String>()
        var out: [Layout] = []
        for (n, b) in built.enumerated() {
            var l = b.layout
            l.tabOrder = n + 1
            var name = l.name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "Layout\(n + 1)" }
            var unique = name, k = 2
            while names.contains(unique.lowercased()) { unique = "\(name) (\(k))"; k += 1 }
            names.insert(unique.lowercased())
            l.name = unique
            out.append(l)
        }
        drawing.layouts = out
    }

    /// Evaluates `\AcVar ctab` fields (current layout name, e.g. sheet numbers in title
    /// blocks) for texts and block attributes placed directly on a layout. Files store one
    /// cached value for every sheet, so each layout substitutes its own name.
    mutating func applySheetFields() {
        var texts: [EntityID: [String?]] = [:]
        var attribs: [EntityID: [(index: Int, cached: String?)]] = [:]
        for f in fields.values where f.expression.lowercased().contains("\\acvar ctab") {
            // FIELD -> parent FIELD(s) -> ACAD_FIELD dictionary -> extension dictionary -> entity.
            var cur = f.owner, depth = 0
            while depth < 16, let next = fields[cur]?.owner ?? dictionaryOwners[cur] { cur = next; depth += 1 }
            for id in handleIDs[cur] ?? [] { texts[id, default: []].append(f.cached) }
            if let a = attribHandles[cur] { for id in a.ids { attribs[id, default: []].append((a.index, f.cached)) } }
        }
        guard !texts.isEmpty || !attribs.isEmpty else { return }
        func substitute(_ s: String, _ cached: String?, _ name: String) -> String {
            if let c = cached, !c.isEmpty, s.contains(c) { return s.replacingOccurrences(of: c, with: name) }
            return s.isEmpty ? name : s
        }
        for li in drawing.layouts.indices {
            let name = drawing.layouts[li].name
            for ei in drawing.layouts[li].entities.indices {
                var e = drawing.layouts[li].entities[ei]
                if let cs = texts[e.id], case .text(var t) = e.kind {
                    for c in cs { t.text = substitute(t.text, c, name) }
                    e.kind = .text(t)
                } else if let list = attribs[e.id], case .insert(var g) = e.kind {
                    for a in list where a.index < g.attributes.count {
                        g.attributes[a.index].text.text = substitute(g.attributes[a.index].text.text, a.cached, name)
                    }
                    e.kind = .insert(g)
                } else {
                    continue
                }
                drawing.layouts[li].entities[ei] = e
            }
        }
    }

    /// Builds `drawing.groups` from GROUP objects; names come from the ACAD_GROUP dictionary.
    /// Unnamed groups ("*A1", ...) are kept under their dictionary names.
    mutating func buildGroups() {
        guard !rawGroups.isEmpty else { return }
        var names: [String: String] = [:]
        if let gd = groupDictHandle, let entries = dictionaries[gd] {
            for e in entries where names[e.handle] == nil { names[e.handle] = e.key }
        }
        var used = Set<String>()
        var anon = 1
        for g in rawGroups {
            var seen = Set<EntityID>()
            let members = g.members.flatMap { handleIDs[$0] ?? [] }.filter { seen.insert($0).inserted }
            guard !members.isEmpty else { continue }
            var name = names[g.handle] ?? ""
            if name.isEmpty || used.contains(name.uppercased()) {
                repeat { name = "*A\(anon)"; anon += 1 } while used.contains(name.uppercased())
            }
            used.insert(name.uppercased())
            drawing.groups.append(EntityGroup(name: name, description: g.description, members: members, isSelectable: g.selectable))
        }
    }

    /// Paper setup in paper space units plus the paper space point at the sheet's lower-left corner.
    func paperSetup(_ info: DXFLayoutInfo?, entities: [Entity], limits: BBox?) -> (PaperSetup, Vec2) {
        let validLimits = limits.flatMap { $0.width > 1e-9 && $0.height > 1e-9 && $0.width.isFinite && $0.height.isFinite ? $0 : nil }
        if let info, info.width > 1e-9, info.height > 1e-9 {
            // 44/45 and margins are always mm; inch layouts draw in inches.
            let f = info.units == 0 ? 1 / 25.4 : 1
            var w = info.width * f, h = info.height * f
            let m = info.margins.map { $0 * f }
            var margins = m
            switch info.rotation {
            case 1: swap(&w, &h); margins = [m[3], m[0], m[1], m[2]]
            case 2: margins = [m[2], m[3], m[0], m[1]]
            case 3: swap(&w, &h); margins = [m[1], m[2], m[3], m[0]]
            default: break
            }
            var name = info.paperName.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = info.pageSetup.isEmpty ? "Custom (\(dxfNum(w)) x \(dxfNum(h)))" : info.pageSetup }
            let paper = PaperSetup(name: name, width: w, height: h, margins: margins)
            // Paper space (0,0) is normally the printable area's lower-left corner; the
            // layout limits, when they match the sheet, give the sheet corner exactly.
            let tol = max(w, h) * 0.01
            var origin = Vec2(-margins[0], -margins[1])
            if let l = validLimits, abs(l.width - w) <= tol, abs(l.height - h) <= tol { origin = l.min }
            return (paper, origin)
        }
        let box: BBox? = validLimits ?? {
            let ext = drawing.extents(of: entities.filter { if case .viewport = $0.kind { return false }; return true })
            let all = ext.isEmpty ? drawing.extents(of: entities) : ext
            return all.isEmpty || all.width <= 1e-9 || all.height <= 1e-9 ? nil : all
        }()
        guard let b = box else { return (.a3Landscape, .zero) }
        let paper = PaperSetup(name: "Custom (\(dxfNum(b.width)) x \(dxfNum(b.height)))", width: b.width, height: b.height,
                               margins: [0, 0, 0, 0])
        return (paper, b.min)
    }

    /// Drops the overall paper space viewport and moves the sheet's lower-left corner to (0,0).
    func finishSheet(_ es: [Entity], paper: PaperSetup, origin: Vec2) -> [Entity] {
        var out = es
        if let i = out.firstIndex(where: { if case .viewport = $0.kind { return true }; return false }),
           case .viewport(let v) = out[i].kind {
            let m = viewportMeta[out[i].id]
            let tol = 1e-6 * max(1, v.height)
            let showsPaper = v.center.isClose(to: v.viewCenter, tol: tol) && abs(v.viewHeight - v.height) <= tol
            let sheet = BBox(min: origin, max: origin + Vec2(paper.width, paper.height))
            let slack = 0.01 * max(paper.width, paper.height)
            let covers = v.frame.min.x <= sheet.min.x + slack && v.frame.min.y <= sheet.min.y + slack
                && v.frame.max.x >= sheet.max.x - slack && v.frame.max.y >= sheet.max.y - slack
            if m?.id == 1 || showsPaper || (m?.status == 1 && covers) { out.remove(at: i) }
        }
        if origin != .zero {
            let t = Transform2D.translation(-origin)
            out = out.map { $0.transformed(by: t) }
        }
        return out
    }

    // MARK: Entities

    /// Converts entity records. With `splitSpaces` (ENTITIES section) records flagged 67=1 go
    /// to paper space; otherwise everything goes to `paper` or model (block content).
    /// VIEWPORT entities are only kept in paper space.
    mutating func convert(_ recs: ArraySlice<DXFRecord>, splitSpaces: Bool, paper: Bool = false) -> (model: [Entity], paper: [Entity]) {
        var model: [Entity] = [], ps: [Entity] = []
        var k = recs.startIndex
        while k < recs.endIndex {
            let r = recs[k]
            k += 1
            // Collect trailing VERTEX / ATTRIB records and the closing SEQEND.
            var children: [DXFRecord] = []
            let isInsert = r.type == "INSERT" || r.type == "MINSERT"
            if r.type == "POLYLINE" || isInsert {
                let child = r.type == "POLYLINE" ? "VERTEX" : "ATTRIB"
                while k < recs.endIndex && recs[k].type == child {
                    children.append(recs[k]); k += 1
                }
                if k < recs.endIndex && recs[k].type == "SEQEND" && (!isInsert || r.i(66) == 1 || !children.isEmpty) { k += 1 }
            }
            if r.type == "ATTRIB" || r.type == "SEQEND" { continue }
            let toPaper = splitSpaces ? r.i(67) == 1 : paper
            if r.type == "VIEWPORT" {
                if toPaper, let vp = viewport(from: r) {
                    ps.append(vp)
                    if let h = r.first(5)?.value { handleIDs[dxfHandle(h), default: []].append(vp.id) }
                }
                continue
            }
            if r.i(60) == 1 { continue }
            let es = entities(from: r, children: children)
            if !es.isEmpty, let h = r.first(5)?.value { handleIDs[dxfHandle(h), default: []] += es.map(\.id) }
            if isInsert && !es.isEmpty {
                for (n, a) in children.enumerated() { if let h = a.first(5)?.value { attribHandles[dxfHandle(h)] = (es.map(\.id), n) } }
            }
            if toPaper { ps += es } else { model += es }
        }
        return (model, ps)
    }

    /// VIEWPORT entity; its id/status/frozen layer handles are kept in `viewportMeta`.
    mutating func viewport(from r: DXFRecord) -> Entity? {
        let w = r.d(40), h = r.d(41)
        guard w > 0, h > 0 else { return nil }
        let flags = r.i(90)
        var vh = r.d(45)
        if !(vh > 0) { vh = h }
        // 12/22 is the view center in display coordinates, relative to the view target (17/27).
        var dcsCenter = r.pt(12)
        let twist = r.d(51)
        if abs(twist) > 1e-12 { dcsCenter = dcsCenter.rotated(by: twist) }
        let vp = ViewportGeom(center: r.pt(10), width: w, height: h, viewCenter: r.pt(17) + dcsCenter, viewHeight: vh,
                              isOn: flags & 0x20000 == 0, isLocked: flags & 0x4000 != 0)
        let e = Entity(.viewport(vp), layer: layerName(r), color: color(r), linetype: r.s(6) ?? "ByLayer", lineweight: lineweight(r))
        viewportMeta[e.id] = DXFViewportMeta(id: r.i(69, 2), status: r.i(68, 1), frozenHandles: r.all(331).map { dxfHandle($0.value) })
        return e
    }

    func entities(from r: DXFRecord, children: [DXFRecord]) -> [Entity] {
        func make(_ kind: EntityKind, ocs: Bool = false) -> [Entity] {
            var e = Entity(kind, layer: layerName(r), color: color(r), linetype: r.s(6) ?? "ByLayer", lineweight: lineweight(r))
            if ocs && r.isMirroredOCS { e = e.transformed(by: Transform2D(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0)) }
            return [e]
        }
        switch r.type {
        case "LINE":
            return make(.line(LineGeom(start: r.pt(10), end: r.pt(11))))
        case "POINT":
            return make(.point(PointGeom(position: r.pt(10))))
        case "CIRCLE":
            guard r.d(40) > 0 else { return [] }
            return make(.circle(CircleGeom(center: r.pt(10), radius: r.d(40))), ocs: true)
        case "ARC":
            guard r.d(40) > 0 else { return [] }
            return make(.arc(ArcGeom(center: r.pt(10), radius: r.d(40), startAngle: radians(r.d(50)), endAngle: radians(r.d(51)))), ocs: true)
        case "LWPOLYLINE":
            var verts: [PolyVertex] = []
            for p in r.pairs {
                switch p.code {
                case 10: verts.append(PolyVertex(Vec2(p.double, 0)))
                case 20: if !verts.isEmpty { verts[verts.count - 1].point.y = p.double }
                case 42: if !verts.isEmpty { verts[verts.count - 1].bulge = p.double }
                default: break
                }
            }
            guard !verts.isEmpty else { return [] }
            return make(.polyline(PolylineGeom(vertices: verts, closed: r.i(70) & 1 != 0, width: r.d(43))), ocs: true)
        case "POLYLINE":
            let flags = r.i(70)
            if flags & (16 | 64) != 0 { return [] }
            let verts = children.filter { $0.type == "VERTEX" && $0.i(70) & (16 | 128) == 0 }
                .map { PolyVertex($0.pt(10), bulge: $0.d(42)) }
            guard !verts.isEmpty else { return [] }
            let w = r.d(40) == r.d(41) ? r.d(40) : 0
            return make(.polyline(PolylineGeom(vertices: verts, closed: flags & 1 != 0, width: w)), ocs: flags & 8 == 0)
        case "LEADER":
            let pts = zip(r.all(10), r.all(20)).map { Vec2($0.double, $1.double) }
            guard pts.count >= 2 else { return [] }
            return make(.polyline(PolylineGeom(points: pts)))
        case "ELLIPSE":
            var major = r.pt(11), ratio = r.d(40, 1)
            guard major.length > 0, ratio > 0 else { return [] }
            var s = r.d(41, 0), e = r.d(42, 2 * .pi)
            if ratio > 1 { major = major.perp * ratio; ratio = 1 / ratio; s -= .pi / 2; e -= .pi / 2 }
            if r.d(230, 1) < 0 { (s, e) = (-e, -s) }
            let full = abs(abs(e - s) - 2 * .pi) < 1e-9 || abs(e - s) < 1e-12
            return make(.ellipse(EllipseGeom(center: r.pt(10), majorAxis: major, ratio: ratio,
                                             startParam: full ? 0 : normalizeAngle(s), endParam: full ? 2 * .pi : normalizeAngle(e))))
        case "TEXT":
            let raw = r.s(1) ?? ""
            guard !raw.isEmpty else { return [] }
            return make(.text(textGeom(r, text: dxfDecodeTextControls(raw), vCode: 73)), ocs: true)
        case "ATTDEF":
            guard let a = attributeText(r) else { return [] }
            let tag = (a.own.subclassValue("AcDbAttributeDefinition", 2) ?? r.s(2) ?? "").trimmingCharacters(in: .whitespaces)
            let prompt = a.own.subclassValue("AcDbAttributeDefinition", 3) ?? r.s(3) ?? ""
            var t = a.text
            let value = t.text
            t.text = tag
            let flags = a.flags
            return make(.attdef(AttDefGeom(tag: tag, prompt: prompt, defaultValue: value, text: t,
                                           isInvisible: flags & 1 != 0, isConstant: flags & 2 != 0, isPreset: flags & 8 != 0)),
                        ocs: !a.isMultiline)
        case "MTEXT":
            guard let t = mtextGeom(r) else { return [] }
            return make(.text(t))
        case "SPLINE":
            let cps = zip(r.all(10), r.all(20)).map { Vec2($0.double, $1.double) }
            let fits = zip(r.all(11), r.all(21)).map { Vec2($0.double, $1.double) }
            guard cps.count >= 2 || fits.count >= 2 else { return [] }
            let closed = r.i(70) & 1 != 0
            var sp = SplineGeom(controlPoints: cps, fitPoints: fits, degree: r.i(71, 3), knots: r.all(40).map(\.double), closed: closed)
            // Recognize our own Catmull-Rom export and keep only the fit points.
            if fits.count > 2 && !cps.isEmpty {
                let cr = catmullRomControlPoints(fits, closed: closed).cps
                let tol = 1e-7 * max(1, BBox(points: fits).width, BBox(points: fits).height)
                if cr.count == cps.count && zip(cr, cps).allSatisfy({ $0.isClose(to: $1, tol: tol) }) {
                    sp.controlPoints = []; sp.knots = []; sp.degree = 3
                }
            } else if fits.count == 2 && cps.count == 2 && sp.degree == 1 && zip(fits, cps).allSatisfy({ $0.isClose(to: $1, tol: 1e-9) }) {
                sp.controlPoints = []; sp.knots = []; sp.degree = 3
            }
            return make(.spline(sp))
        case "HATCH":
            guard let h = parseHatch(r) else { return [] }
            return make(.hatch(h), ocs: true)
        case "SOLID", "TRACE":
            var pts = [r.pt(10), r.pt(11), r.pt(13), r.pt(12)]
            if !r.has(13) { pts.remove(at: 2) }
            var loop: [PolyVertex] = []
            for p in pts where loop.last.map({ !$0.point.isClose(to: p, tol: 1e-12) }) ?? true { loop.append(PolyVertex(p)) }
            if loop.count > 1 && loop[0].point.isClose(to: loop[loop.count - 1].point, tol: 1e-12) { loop.removeLast() }
            guard loop.count >= 3 else { return [] }
            return make(.hatch(HatchGeom(loops: [loop])), ocs: true)
        case "DIMENSION":
            guard let d = parseDimension(r) else { return [] }
            return make(.dimension(d))
        case "INSERT", "MINSERT", "ACAD_TABLE":
            guard let name = r.s(2), !name.isEmpty else { return [] }
            let sx = r.d(41, 1), sy = r.d(42, 1), rot = radians(r.d(50))
            let cols = max(1, r.i(70, 1)), rows = max(1, r.i(71, 1))
            let dx = r.d(44), dy = r.d(45)
            // Attributes are stored in world coordinates; MINSERT copies them to every
            // instance, shifted by the instance offset.
            let attribs = children.compactMap(attribute)
            var out: [Entity] = []
            for row in 0..<min(rows, 1000) {
                for col in 0..<min(cols, 1000) {
                    let off = Vec2(Double(col) * dx, Double(row) * dy).rotated(by: rot)
                    let ins = InsertGeom(blockName: name, position: r.pt(10) + off, scaleX: sx == 0 ? 1 : sx,
                                         scaleY: sy == 0 ? 1 : sy, rotation: normalizeAngle(rot))
                    for var e in make(.insert(ins), ocs: true) {
                        if !attribs.isEmpty, case .insert(var g) = e.kind {
                            g.attributes = attribs.map { a in
                                var a = a
                                a.text.position = a.text.position + off
                                return a
                            }
                            e.kind = .insert(g)
                        }
                        out.append(e)
                    }
                }
            }
            return out
        default:
            return []
        }
    }

    // MARK: Text and attributes

    /// TEXT-style placement (also ATTRIB/ATTDEF, whose vertical alignment is code 74).
    func textGeom(_ r: DXFRecord, text: String, vCode: Int) -> TextGeom {
        let h = r.i(72), v = r.i(vCode)
        var pos = r.pt(10)
        var ha = TextHAlign.left, va = TextVAlign(rawValue: min(max(v, 0), 3)) ?? .baseline
        switch h {
        case 1: ha = .center
        case 2: ha = .right
        case 3, 5: ha = .center; va = .baseline
        case 4: ha = .center; va = .middle
        default: break
        }
        if h != 0 || v != 0, r.has(11) {
            pos = (h == 3 || h == 5) ? (r.pt(10) + r.pt(11)) / 2 : r.pt(11)
        }
        let style = r.s(7).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "Standard"
        return TextGeom(position: pos, height: r.d(40, 2.5), text: text,
                        rotation: normalizeAngle(radians(r.d(50))), hAlign: ha, vAlign: va, style: style)
    }

    func mtextGeom(_ r: DXFRecord) -> TextGeom? {
        let raw = (r.all(3) + r.all(1)).map(\.value).joined()
        let text = dxfDecodeTextControls(dxfStripMText(dxfDecodeUnicode(raw)))
        guard !text.isEmpty else { return nil }
        let att = min(max(r.i(71, 1), 1), 9)
        let ha = TextHAlign(rawValue: (att - 1) % 3) ?? .left
        let va: TextVAlign = att <= 3 ? .top : (att <= 6 ? .middle : .bottom)
        var rot = radians(r.d(50))
        if r.has(11) {
            let x = r.pt(11)
            if x.length > 1e-12 { rot = x.angle }
        }
        let style = r.s(7).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "Standard"
        return TextGeom(position: r.pt(10), height: r.d(40, 2.5), text: text, rotation: normalizeAngle(rot),
                        hAlign: ha, vAlign: va, isMultiline: true, width: max(0, r.d(41)), style: style)
    }

    /// Text (value in `text.text`) and flags of an ATTRIB/ATTDEF. Multiline attributes
    /// (R2018, 71 = 2/4 or only an embedded MTEXT) take the embedded MTEXT's plain text.
    func attributeText(_ r: DXFRecord) -> (own: DXFRecord, text: TextGeom, flags: Int, isMultiline: Bool)? {
        let (own, embedded) = r.splitEmbedded()
        let sub = own.type == "ATTDEF" ? "AcDbAttributeDefinition" : "AcDbAttribute"
        let flags = Int(own.subclassValue(sub, 70) ?? "") ?? own.i(70)
        let mtextFlag = Int(own.subclassValue(sub, 71)?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        let raw = own.s(1) ?? ""
        if let em = embedded, mtextFlag == 2 || mtextFlag == 4 || raw.isEmpty, var t = mtextGeom(em) {
            if own.has(7) { t.style = textGeom(own, text: "", vCode: 74).style }
            return (own, t, flags, true)
        }
        var t = textGeom(own, text: dxfDecodeTextControls(raw), vCode: 74)
        // Prefer the attribute subclass' 74 (vertical alignment) over stray codes.
        if let vs = own.subclassValue(sub, 74), let vi = Int(vs.trimmingCharacters(in: .whitespaces)) {
            t.vAlign = TextVAlign(rawValue: min(max(vi, 0), 3)) ?? t.vAlign
        }
        return (own, t, flags, false)
    }

    /// ATTRIB following an INSERT, in world coordinates.
    func attribute(_ r: DXFRecord) -> AttribValue? {
        guard r.type == "ATTRIB", let a = attributeText(r) else { return nil }
        let tag = (a.own.subclassValue("AcDbAttribute", 2) ?? r.s(2) ?? "").trimmingCharacters(in: .whitespaces)
        var t = a.text
        if !a.isMultiline && a.own.isMirroredOCS, case .text(let m) = EntityKind.text(t).transformed(by: Transform2D(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0)) {
            t = m
        }
        return AttribValue(tag: tag, text: t, isInvisible: a.flags & 1 != 0 || a.own.i(60) == 1,
                           layer: layerName(r), color: color(r))
    }

    // MARK: Common properties

    func layerName(_ r: DXFRecord) -> String {
        let n = (r.s(8) ?? "0").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "0" : n
    }

    func color(_ r: DXFRecord) -> CadColor {
        if let tc = r.first(420) { return .rgb(RGB(packed: tc.int)) }
        guard let c = r.first(62)?.int else { return .byLayer }
        switch c {
        case 0: return .byBlock
        case 256: return .byLayer
        case 1...255: return .aci(c)
        case -255 ... -1: return .aci(-c)
        default: return .byLayer
        }
    }

    func lineweight(_ r: DXFRecord) -> Double {
        let lw = r.i(370, -1)
        if lw >= 0 { return Double(lw) / 100 }
        return lw == -2 ? -2 : -1
    }

    // MARK: Dimension

    func parseDimension(_ r: DXFRecord) -> DimensionGeom? {
        let type = r.i(70) & 7
        var text = r.s(1) ?? ""
        if text == "<>" { text = "" }
        let p10 = r.pt(10), p13 = r.pt(13), p14 = r.pt(14), p15 = r.pt(15)
        let textPt = r.has(11) ? r.pt(11) : p15
        switch type {
        case 0:
            return DimensionGeom(kind: .linear, p1: p13, p2: p14, p3: p10, rotation: normalizeAngle(radians(r.d(50))), textOverride: text)
        case 1:
            return DimensionGeom(kind: .aligned, p1: p13, p2: p14, p3: p10, textOverride: text)
        case 2:
            guard let (_, _, v) = lineLineIntersection(p13, p14, p15, p10) else { return nil }
            let leg1 = p13.distance(to: v) > p14.distance(to: v) ? p13 : p14
            let leg2 = p15.distance(to: v) > p10.distance(to: v) ? p15 : p10
            return DimensionGeom(kind: .angular, p1: v, p2: leg1, p3: r.pt(16), p4: leg2, textOverride: text)
        case 5:
            return DimensionGeom(kind: .angular, p1: p15, p2: p13, p3: p10, p4: p14, textOverride: text)
        case 3:
            let c = (p10 + p15) / 2
            return DimensionGeom(kind: .diameter, p1: c, p2: p15, p3: textPt, textOverride: text)
        case 4:
            return DimensionGeom(kind: .radius, p1: p10, p2: p15, p3: textPt, textOverride: text)
        default:
            return nil
        }
    }

    // MARK: Hatch

    func parseHatch(_ r: DXFRecord) -> HatchGeom? {
        let ps = r.pairs
        var k = 0
        var name = "", solid = false
        while k < ps.count && ps[k].code != 91 {
            if ps[k].code == 2 { name = dxfDecodeUnicode(ps[k].value).trimmingCharacters(in: .whitespaces) }
            if ps[k].code == 70 { solid = ps[k].int & 1 != 0 }
            k += 1
        }
        guard k < ps.count else { return nil }
        let nPaths = ps[k].int
        k += 1
        var loops: [[PolyVertex]] = []

        func seek(_ code: Int) -> DXFPair? {
            while k < ps.count {
                let p = ps[k]
                k += 1
                if p.code == code { return p }
            }
            return nil
        }
        /// Reads fields of a fixed-layout edge; stops at the first repeated or foreign code.
        func fields(_ allowed: Set<Int>) -> [Int: Double] {
            var f: [Int: Double] = [:]
            while k < ps.count, allowed.contains(ps[k].code), f[ps[k].code] == nil {
                f[ps[k].code] = ps[k].double
                k += 1
            }
            return f
        }

        for _ in 0..<max(0, min(nPaths, 100_000)) {
            guard let flag = seek(92)?.int else { break }
            var loop: [PolyVertex] = []
            if flag & 2 != 0 {
                var nv = 0
                while k < ps.count && ps[k].code != 93 { k += 1 }
                if k < ps.count { nv = ps[k].int; k += 1 }
                while k < ps.count {
                    let p = ps[k]
                    if p.code == 10 { if loop.count == nv { break }; loop.append(PolyVertex(Vec2(p.double, 0))) }
                    else if p.code == 20 { if !loop.isEmpty { loop[loop.count - 1].point.y = p.double } }
                    else if p.code == 42 { if !loop.isEmpty { loop[loop.count - 1].bulge = p.double } }
                    else if p.code != 30 { break }
                    k += 1
                }
            } else {
                guard let ne = seek(93)?.int else { break }
                for _ in 0..<max(0, min(ne, 100_000)) {
                    guard k < ps.count, ps[k].code == 72 else { break }
                    let type = ps[k].int
                    k += 1
                    switch type {
                    case 1:
                        let f = fields([10, 20, 11, 21])
                        loop.append(PolyVertex(Vec2(f[10] ?? 0, f[20] ?? 0)))
                    case 2:
                        let f = fields([10, 20, 40, 50, 51, 73])
                        let c = Vec2(f[10] ?? 0, f[20] ?? 0), rad = f[40] ?? 0
                        let ccw = (f[73] ?? 1) != 0
                        let s = radians(f[50] ?? 0), e = radians(f[51] ?? 360)
                        let sweep = ccwSweep(from: s, to: e)
                        let a0 = ccw ? s : -s
                        let b = tan(sweep / 4) * (ccw ? 1 : -1)
                        if sweep > 2 * .pi - 1e-9 {
                            let half = ccw ? 1.0 : -1.0
                            loop.append(PolyVertex(c + .polar(rad, a0), bulge: half))
                            loop.append(PolyVertex(c + .polar(rad, a0 + .pi), bulge: half))
                        } else {
                            loop.append(PolyVertex(c + .polar(rad, a0), bulge: b))
                        }
                    case 3:
                        let f = fields([10, 20, 11, 21, 40, 50, 51, 73])
                        let ratio = f[40] ?? 1
                        let ccw = (f[73] ?? 1) != 0
                        func param(_ deg: Double) -> Double {
                            let a = radians(deg)
                            return atan2(sin(a) / max(ratio, 1e-12), cos(a))
                        }
                        var s = param(f[50] ?? 0), e = param(f[51] ?? 360)
                        if (f[51] ?? 360) - (f[50] ?? 0) >= 360 - 1e-9 { s = 0; e = 2 * .pi }
                        if !ccw { (s, e) = (-e, -s) }
                        let el = EllipseGeom(center: Vec2(f[10] ?? 0, f[20] ?? 0), majorAxis: Vec2(f[11] ?? 1, f[21] ?? 0),
                                             ratio: ratio, startParam: s, endParam: e)
                        var pts = ellipsePoints(el, segments: 64)
                        if !ccw { pts.reverse() }
                        loop += pts.dropLast().map { PolyVertex($0) }
                    case 4:
                        let f = fields([94, 73, 74, 95, 96])
                        let rational = (f[73] ?? 0) != 0
                        let nk = Int(f[95] ?? 0), nc = Int(f[96] ?? 0)
                        var knots: [Double] = [], cps: [Vec2] = []
                        while k < ps.count && ps[k].code == 40 && knots.count < nk { knots.append(ps[k].double); k += 1 }
                        while k < ps.count && cps.count < nc && ps[k].code == 10 {
                            var p = Vec2(ps[k].double, 0)
                            k += 1
                            if k < ps.count && ps[k].code == 20 { p.y = ps[k].double; k += 1 }
                            if rational && k < ps.count && ps[k].code == 42 { k += 1 }
                            cps.append(p)
                        }
                        // Optional fit data (R2010+): 97 count, 11/21 points, 12/22 and 13/23 tangents.
                        if k + 1 < ps.count && ps[k].code == 97 {
                            let nf = ps[k].int
                            let next = ps[k + 1].code
                            if (nf > 0 && next == 11) || (nf == 0 && [97, 72, 12].contains(next)) {
                                k += 1
                                while k < ps.count && [11, 21].contains(ps[k].code) { k += 1 }
                            }
                        }
                        while k < ps.count && [12, 22, 13, 23].contains(ps[k].code) { k += 1 }
                        let sp = SplineGeom(controlPoints: cps, degree: Int(f[94] ?? 3), knots: knots)
                        if cps.count >= 2 { loop += splinePoints(sp).dropLast().map { PolyVertex($0) } }
                    default:
                        break
                    }
                }
            }
            if loop.count > 1 && loop[0].point.isClose(to: loop[loop.count - 1].point, tol: 1e-12) { loop.removeLast() }
            if loop.count >= 2 { loops.append(loop) }
            // Source boundary objects.
            if k < ps.count && ps[k].code == 97 {
                let n = ps[k].int
                k += 1
                var c = 0
                while c < n && k < ps.count && ps[k].code == 330 { k += 1; c += 1 }
            }
        }
        guard !loops.isEmpty else { return nil }

        // Pattern data after the boundary paths.
        var angle52: Double?, scale41: Double?
        var defLines: [(angle: Double, offset: Vec2)] = []
        while k < ps.count {
            let p = ps[k]
            switch p.code {
            case 52: if angle52 == nil { angle52 = p.double }
            case 41: if scale41 == nil { scale41 = p.double }
            case 53: defLines.append((p.double, .zero))
            case 45: if !defLines.isEmpty { defLines[defLines.count - 1].offset.x = p.double }
            case 46: if !defLines.isEmpty { defLines[defLines.count - 1].offset.y = p.double }
            case 98: k = ps.count
            default: break
            }
            k += 1
        }
        if solid || name.uppercased() == "SOLID" {
            return HatchGeom(loops: loops, pattern: .solid, patternName: "SOLID")
        }
        let upper = name.uppercased()
        var kind = HatchPatternKind.lines
        if dxfCrossPatterns.contains(upper) { kind = .cross }
        if defLines.count == 2, abs(abs(sin(radians(defLines[1].angle - defLines[0].angle))) - 1) < 1e-6 { kind = .cross }
        var angle = radians((angle52 ?? 0) + dxfPatternBaseAngle(name))
        var spacing = upper == "_USER" ? (scale41 ?? 1) : 3.175 * (scale41 ?? 1)
        if let l = defLines.first {
            angle = radians(l.angle)
            let s = abs(l.offset.dot(Vec2.polar(1, angle).perp))
            if s > 1e-9 { spacing = s }
        }
        if !(spacing > 0) { spacing = 3.175 }
        return HatchGeom(loops: loops, pattern: kind, patternName: name.isEmpty ? "ANSI31" : name,
                         angle: normalizeAngle(angle), spacing: spacing)
    }
}

/// True when `data` contains the ASCII string `s`.
private func dxfContains(_ data: Data, _ s: String) -> Bool {
    let needle = Array(s.utf8)
    return data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress, raw.count >= needle.count else { return false }
        return needle.withUnsafeBytes { n in memmem(base, raw.count, n.baseAddress, n.count) != nil }
    }
}

extension DXFRecord {
    /// First value of `code` after the subclass marker `sub` (100).
    func subclassValue(_ sub: String, _ code: Int) -> String? {
        var inSub = false
        for p in pairs {
            if p.code == 100 { inSub = p.value.trimmingCharacters(in: .whitespaces) == sub; continue }
            if inSub && p.code == code { return dxfDecodeUnicode(p.value) }
        }
        return nil
    }
}

/// Normalized handle string (uppercase hex without padding).
private func dxfHandle(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespaces).uppercased()
    while t.count > 1 && t.hasPrefix("0") { t.removeFirst() }
    return t
}
