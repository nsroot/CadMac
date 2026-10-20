import Foundation

/// Emits decoded DWG objects as an in-memory ASCII DXF stream, so the drawing is converted
/// by `DXFReader` with exactly the same rules as a DXF file (layouts, viewports, groups,
/// fields, hatch boundaries, text cleanup, ...).
struct DWGRDXFEmitter {
    var out: [UInt8] = []
    let objects: [UInt64: DWGRObject]
    let header: DWGRHeader
    let r2004: Bool

    var layerNames: [UInt64: String] = [:]
    var ltypeNames: [UInt64: String] = [:]
    var styleNames: [UInt64: String] = [:]
    var blockNames: [UInt64: String] = [:]
    /// Entity types the file holds but CadMac's model cannot represent, by DXF name. Counted while
    /// emitting, so the user can be told what an imported drawing lost instead of finding out later.
    var dropped: [String: Int] = [:]
    /// Objects written as part of a parent entity (their own record is not a dropped drawing object).
    private static let childTypes: Set<Int> = [
        DWGObjectType.attrib, DWGObjectType.vertex2D, DWGObjectType.vertex3D, DWGObjectType.vertexMesh,
        DWGObjectType.vertexPFace, DWGObjectType.vertexPFaceFace, DWGObjectType.seqend,
        DWGObjectType.block, DWGObjectType.endblk,
    ]
    /// Objects referenced by GROUP members / FIELD owners need handles; we always write them.

    init(objects: [UInt64: DWGRObject], header: DWGRHeader, r2004: Bool) {
        self.objects = objects
        self.header = header
        self.r2004 = r2004
        out.reserveCapacity(max(1 << 20, objects.count * 256))
        for (h, o) in objects {
            switch o.data {
            case .layer(let l): layerNames[h] = l.name
            case .ltype(let l): ltypeNames[h] = l.name
            case .style(let s): styleNames[h] = s
            case .blockHeader(let b): blockNames[h] = b.name
            default: break
            }
        }
        // DWG names every paper space block record "*Paper_Space"; DXF numbers all but the
        // active one ("*Paper_Space0", "*Paper_Space1", ...).
        var n = 0
        let paper = objects.values.filter { o in
            guard case .blockHeader(let b) = o.data else { return false }
            return b.name.uppercased().hasPrefix("*PAPER_SPACE")
        }.sorted { $0.handle < $1.handle }
        for o in paper where o.handle != header.paperSpace {
            blockNames[o.handle] = "*Paper_Space\(n)"
            n += 1
        }
        if let a = paper.first(where: { $0.handle == header.paperSpace }) { blockNames[a.handle] = "*Paper_Space" }
    }

    // MARK: Low-level output

    @inline(__always) mutating func raw(_ s: String) {
        out.append(contentsOf: s.utf8)
    }

    /// Cached ASCII bytes for DXF group codes, so a numeric pair allocates no String for its code.
    static let codeBytes: [[UInt8]] = (0...1200).map { Array(String($0).utf8) }

    @inline(__always) mutating func emitCode(_ code: Int) {
        if code >= 0 && code <= 1200 { out.append(contentsOf: Self.codeBytes[code]) }
        else { out.append(contentsOf: String(code).utf8) }
        out.append(0x0A)
    }

    mutating func pair(_ code: Int, _ value: String) {
        emitCode(code)
        if value.utf8.contains(where: { $0 == 0x0A || $0 == 0x0D }) {
            raw(value.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))
        } else {
            raw(value)
        }
        out.append(0x0A)
    }

    // Numeric pairs never contain a newline, so they skip the scan and the per-pair code String.
    mutating func pair(_ code: Int, _ v: Double) {
        emitCode(code)
        out.append(contentsOf: (v.isFinite ? String(v) : "0").utf8)
        out.append(0x0A)
    }

    mutating func pair(_ code: Int, _ v: Int) {
        emitCode(code)
        out.append(contentsOf: String(v).utf8)
        out.append(0x0A)
    }

    mutating func hex(_ code: Int, _ h: UInt64) {
        emitCode(code)
        out.append(contentsOf: String(h, radix: 16, uppercase: true).utf8)
        out.append(0x0A)
    }

    mutating func p2(_ code: Int, _ p: DWGP2) { pair(code, p.x); pair(code + 10, p.y) }
    mutating func p3(_ code: Int, _ p: DWGP3) { pair(code, p.x); pair(code + 10, p.y); pair(code + 20, p.z) }

    mutating func ext(_ e: DWGP3) {
        if abs(e.x) > 1e-12 || abs(e.y) > 1e-12 || abs(e.z - 1) > 1e-12 { p3(210, e) }
    }

    static func deg(_ r: Double) -> Double { r * 180 / .pi }

    // MARK: Sections

    mutating func emitHeader(currentLayer: String) {
        pair(0, "SECTION"); pair(2, "HEADER")
        if header.hasInsUnits { pair(9, "$INSUNITS"); pair(70, header.insUnits) }
        pair(9, "$LTSCALE"); pair(40, header.ltScale)
        pair(9, "$CLAYER"); pair(8, currentLayer)
        pair(9, "$TEXTSIZE"); pair(40, header.textSize)
        pair(9, "$DIMSCALE"); pair(40, header.dimScale)
        pair(9, "$DIMTXT"); pair(40, header.dimTxt)
        pair(9, "$DIMASZ"); pair(40, header.dimAsz)
        pair(9, "$DIMEXO"); pair(40, header.dimExo)
        pair(9, "$DIMEXE"); pair(40, header.dimExe)
        pair(9, "$DIMGAP"); pair(40, header.dimGap)
        pair(9, "$DIMDEC"); pair(70, header.dimDec)
        pair(9, "$LUNITS"); pair(70, header.lunits)
        pair(9, "$LUPREC"); pair(70, header.luprec)
        pair(9, "$PDSIZE"); pair(40, header.pdSize)
        pair(9, "$LIMMIN"); p2(10, header.limMin)
        pair(9, "$LIMMAX"); p2(10, header.limMax)
        pair(9, "$FILLETRAD"); pair(40, header.filletRad)
        pair(9, "$PLIMMIN"); p2(10, header.pLimMin)
        pair(9, "$PLIMMAX"); p2(10, header.pLimMax)
        pair(0, "ENDSEC")
    }

    mutating func emitTables(_ sorted: [DWGRObject]) {
        pair(0, "SECTION"); pair(2, "TABLES")
        pair(0, "TABLE"); pair(2, "LTYPE")
        for o in sorted {
            guard case .ltype(let l) = o.data else { continue }
            pair(0, "LTYPE"); hex(5, o.handle); pair(2, l.name); pair(70, 0); pair(3, l.description)
            pair(72, 65); pair(73, l.dashes.count)
            for d in l.dashes { pair(49, d) }
        }
        pair(0, "ENDTAB")
        pair(0, "TABLE"); pair(2, "LAYER")
        for o in sorted {
            guard case .layer(let l) = o.data else { continue }
            pair(0, "LAYER"); hex(5, o.handle); pair(2, l.name)
            pair(70, (l.frozen ? 1 : 0) | (l.locked ? 4 : 0))
            let off = !l.on || l.colorIndexNegative
            switch l.color {
            case .aci(let i): pair(62, off ? -i : i)
            case .rgb(let rgb): pair(62, off ? -7 : 7); pair(420, rgb)
            default: pair(62, off ? -7 : 7)
            }
            pair(6, ltypeNames[l.ltype] ?? "Continuous")
            pair(370, l.lineweight)
            pair(290, l.plot ? 1 : 0)
        }
        pair(0, "ENDTAB")
        pair(0, "TABLE"); pair(2, "BLOCK_RECORD")
        for o in sorted {
            guard case .blockHeader(let b) = o.data else { continue }
            pair(0, "BLOCK_RECORD"); hex(5, o.handle); pair(2, blockNames[o.handle] ?? b.name)
            if b.layout != 0 { hex(340, b.layout) }
        }
        pair(0, "ENDTAB")
        pair(0, "ENDSEC")
    }

    mutating func emitObjects(_ sorted: [DWGRObject]) {
        pair(0, "SECTION"); pair(2, "OBJECTS")
        for o in sorted {
            switch o.data {
            case .dictionary(let entries):
                pair(0, "DICTIONARY"); hex(5, o.handle)
                if o.owner != 0 { hex(330, o.owner) }
                pair(100, "AcDbDictionary")
                for (k, h) in entries { pair(3, k); hex(350, h) }
            case .group(let g):
                pair(0, "GROUP"); hex(5, o.handle)
                if o.owner != 0 { hex(330, o.owner) }
                pair(100, "AcDbGroup")
                pair(300, g.description)
                pair(70, g.unnamed ? 1 : 0)
                pair(71, g.selectable ? 1 : 0)
                for m in g.members { hex(340, m) }
            case .layout(let l):
                pair(0, "LAYOUT"); hex(5, o.handle)
                if o.owner != 0 { hex(330, o.owner) }
                pair(100, "AcDbPlotSettings")
                pair(1, l.pageSetup)
                pair(4, l.paperName)
                pair(40, l.margins[0]); pair(41, l.margins[1]); pair(42, l.margins[2]); pair(43, l.margins[3])
                pair(44, l.width); pair(45, l.height)
                pair(72, l.units); pair(73, l.rotation)
                pair(100, "AcDbLayout")
                pair(1, l.name)
                pair(71, l.tabOrder)
                p2(10, l.limMin); p2(11, l.limMax)
                if l.blockRecord != 0 { hex(330, l.blockRecord) }
            case .field(let f):
                pair(0, "FIELD"); hex(5, o.handle)
                if o.owner != 0 { hex(330, o.owner) }
                pair(100, "AcDbField")
                pair(1, f.evaluator)
                pair(2, f.code)
                pair(302, f.value)
            default:
                break
            }
        }
        pair(0, "ENDSEC")
    }

    // MARK: Entities

    mutating func common(_ type: String, _ o: DWGRObject, paper: Bool = false) {
        pair(0, type)
        hex(5, o.handle)
        pair(8, layerNames[o.layer] ?? "0")
        switch o.ltypeFlags {
        case 1: pair(6, "ByBlock")
        case 2: pair(6, "Continuous")
        case 3: if let n = ltypeNames[o.ltype] { pair(6, n) }
        default: break
        }
        switch o.color {
        case .byLayer: break
        case .byBlock: pair(62, 0)
        case .aci(let i): pair(62, i)
        case .rgb(let rgb): pair(420, rgb)
        }
        if o.lineweight != -1 { pair(370, o.lineweight) }
        if o.invisible { pair(60, 1) }
        if paper { pair(67, 1) }
    }

    /// Subentities of a POLYLINE / INSERT: owned handles (R2004+) or a first..last chain.
    func children(owned: [UInt64], first: UInt64, last: UInt64) -> [DWGRObject] {
        if !owned.isEmpty || r2004 { return owned.compactMap { objects[$0] } }
        return chain(first: first, last: last)
    }

    /// Follows next-entity links (R13-R2000) from `first` to `last`.
    func chain(first: UInt64, last: UInt64) -> [DWGRObject] {
        var out: [DWGRObject] = []
        var seen = Set<UInt64>()
        var cur = first
        while cur != 0, seen.insert(cur).inserted, let o = objects[cur], out.count < 10_000_000 {
            out.append(o)
            if cur == last { break }
            cur = o.nolinks ? cur &+ 1 : o.next
        }
        return out
    }

    /// Writes one entity (with its ATTRIB/VERTEX children).
    mutating func entity(_ o: DWGRObject, viewportIndex: inout Int) {
        switch o.data {
        case .line(let a, let b):
            common("LINE", o); p3(10, a); p3(11, b)
        case .circle(let c, let r, let e):
            common("CIRCLE", o); p3(10, c); pair(40, r); ext(e)
        case .arc(let c, let r, let s, let en, let e):
            common("ARC", o); p3(10, c); pair(40, r); pair(50, Self.deg(s)); pair(51, Self.deg(en)); ext(e)
        case .point(let p):
            common("POINT", o); p3(10, p)
        case .ellipse(let c, let mj, let e, let ratio, let s, let en):
            common("ELLIPSE", o); p3(10, c); p3(11, mj); pair(40, ratio); pair(41, s); pair(42, en); ext(e)
        case .lwpolyline(let p):
            common("LWPOLYLINE", o)
            pair(90, p.points.count)
            pair(70, p.flags70)
            if p.constWidth != 0 { pair(43, p.constWidth) }
            if p.elevation != 0 { pair(38, p.elevation) }
            for (k, pt) in p.points.enumerated() {
                p2(10, pt)
                if k < p.bulges.count, p.bulges[k] != 0 { pair(42, p.bulges[k]) }
            }
            ext(p.ext)
        case .text(let t) where o.type == DWGObjectType.text:
            common("TEXT", o)
            textBody(t)
        case .text(let t) where o.type == DWGObjectType.attdef:
            common("ATTDEF", o)
            attribBody(t, def: true)
        case .mtext(let t):
            common("MTEXT", o)
            mtextBody(t)
        case .insert(let g):
            insert(o, g)
        case .polyline(let p):
            common("POLYLINE", o)
            pair(66, 1)
            p3(10, (0, 0, p.elevation))
            pair(70, p.flags)
            if p.startWidth != 0 { pair(40, p.startWidth) }
            if p.endWidth != 0 { pair(41, p.endWidth) }
            ext(p.ext)
            for vo in children(owned: p.vertices, first: p.firstVertex, last: p.lastVertex) {
                guard case .vertex(let vx) = vo.data else { continue }
                common("VERTEX", vo)
                p3(10, vx.pt)
                if vx.bulge != 0 { pair(42, vx.bulge) }
                pair(70, vx.flags)
            }
            pair(0, "SEQEND"); pair(8, layerNames[o.layer] ?? "0")
        case .spline(let s):
            common("SPLINE", o)
            pair(70, s.flags70); pair(71, s.degree)
            pair(72, s.knots.count); pair(73, s.control.count); pair(74, s.fit.count)
            for k in s.knots { pair(40, k) }
            for (k, c) in s.control.enumerated() {
                p3(10, c)
                if k < s.weights.count { pair(41, s.weights[k]) }
            }
            for f in s.fit { p3(11, f) }
        case .solid(let pts, let elev, let e):
            common(o.type == DWGObjectType.trace ? "TRACE" : "SOLID", o)
            for (k, p) in pts.enumerated() { p3(10 + k, (p.x, p.y, elev)) }
            ext(e)
        case .dimension(let d):
            common("DIMENSION", o)
            p3(10, d.p10)
            p3(11, (d.textMid.x, d.textMid.y, 0))
            pair(70, d.dxfType)
            if !d.userText.isEmpty { pair(1, d.userText) }
            p3(13, d.p13); p3(14, d.p14); p3(15, d.p15)
            p3(16, (d.p16.x, d.p16.y, 0))
            pair(50, Self.deg(d.rotation))
            ext(d.ext)
        case .hatch(let h):
            common("HATCH", o)
            hatch(h)
        case .viewport(let vp):
            viewportIndex += 1
            common("VIEWPORT", o)
            p3(10, vp.center)
            pair(40, vp.width); pair(41, vp.height)
            let off = vp.status & 0x20000 != 0
            pair(68, off ? 0 : (viewportIndex == 1 ? 1 : 2))
            pair(69, viewportIndex)
            if vp.hasView {
                p2(12, vp.viewCenter)
                p3(17, vp.target)
                pair(45, vp.viewHeight)
                pair(51, Self.deg(vp.twist))
                pair(90, vp.status)
                for f in vp.frozen { hex(331, f) }
            } else {
                p2(12, (vp.center.x, vp.center.y))
                pair(45, vp.height)
            }
        case .leader(let pts):
            common("LEADER", o)
            for p in pts { p3(10, p) }
        default:
            if !Self.childTypes.contains(o.type) { dropped[o.name, default: 0] += 1 }
        }
    }

    mutating func textBody(_ t: DWGRText) {
        p3(10, (t.ins.x, t.ins.y, t.elevation))
        pair(40, t.height)
        pair(1, t.text)
        if t.rotation != 0 { pair(50, Self.deg(t.rotation)) }
        if t.widthFactor != 1 { pair(41, t.widthFactor) }
        if let s = styleNames[t.style] { pair(7, s) }
        if t.hAlign != 0 { pair(72, t.hAlign) }
        p3(11, (t.align.x, t.align.y, t.elevation))
        ext(t.ext)
        if t.vAlign != 0 { pair(73, t.vAlign) }
    }

    mutating func attribBody(_ t: DWGRText, def: Bool) {
        pair(100, "AcDbText")
        p3(10, (t.ins.x, t.ins.y, t.elevation))
        pair(40, t.height)
        pair(1, t.text)
        if t.rotation != 0 { pair(50, Self.deg(t.rotation)) }
        if t.widthFactor != 1 { pair(41, t.widthFactor) }
        if let s = styleNames[t.style] { pair(7, s) }
        if t.hAlign != 0 { pair(72, t.hAlign) }
        p3(11, (t.align.x, t.align.y, t.elevation))
        ext(t.ext)
        pair(100, def ? "AcDbAttributeDefinition" : "AcDbAttribute")
        if def { pair(3, t.prompt) }
        pair(2, t.tag)
        pair(70, t.flags)
        if t.vAlign != 0 { pair(74, t.vAlign) }
        if let mt = t.mtext {
            pair(71, def ? 4 : 2)
            pair(101, "Embedded Object")
            mtextBody(mt)
        }
    }

    mutating func mtextBody(_ t: DWGRMText) {
        p3(10, t.ins)
        pair(40, t.height)
        pair(41, t.rectWidth)
        pair(71, t.attachment)
        pair(72, t.drawingDir)
        let text = t.text.replacingOccurrences(of: "\r\n", with: "\\P").replacingOccurrences(of: "\n", with: "\\P")
            .replacingOccurrences(of: "\r", with: "\\P")
        pair(1, text)
        if let s = styleNames[t.style] { pair(7, s) }
        ext(t.ext)
        p3(11, t.xdir)
    }

    mutating func insert(_ o: DWGRObject, _ g: DWGRInsert) {
        guard let name = blockNames[g.block] else { return }
        let atts = g.hasAttribs ? children(owned: g.attribs, first: g.firstAttrib, last: g.lastAttrib) : []
        common(g.isMInsert ? "MINSERT" : "INSERT", o)
        if !atts.isEmpty { pair(66, 1) }
        pair(2, name)
        p3(10, g.ins)
        if g.scale.x != 1 { pair(41, g.scale.x) }
        if g.scale.y != 1 { pair(42, g.scale.y) }
        if g.scale.z != 1 { pair(43, g.scale.z) }
        if g.rotation != 0 { pair(50, Self.deg(g.rotation)) }
        if g.isMInsert {
            pair(70, g.cols); pair(71, g.rows)
            pair(44, g.colSpacing); pair(45, g.rowSpacing)
        }
        ext(g.ext)
        guard !atts.isEmpty else { return }
        for a in atts {
            guard a.type == DWGObjectType.attrib, case .text(let t) = a.data else { continue }
            common("ATTRIB", a)
            attribBody(t, def: false)
        }
        pair(0, "SEQEND"); pair(8, layerNames[o.layer] ?? "0")
    }

    mutating func hatch(_ h: DWGRHatch) {
        p3(10, (0, 0, h.elevation))
        ext(h.ext)
        pair(2, h.name)
        pair(70, h.solid ? 1 : 0)
        pair(71, h.associative ? 1 : 0)
        pair(91, h.paths.count)
        for p in h.paths {
            pair(92, p.flags)
            if p.flags & 2 != 0 {
                pair(72, p.hasBulges ? 1 : 0)
                pair(73, p.closed ? 1 : 0)
                pair(93, p.polyline.count)
                for (pt, b) in p.polyline {
                    p2(10, pt)
                    if p.hasBulges { pair(42, b) }
                }
            } else {
                pair(93, p.edges.count)
                for e in p.edges {
                    switch e {
                    case .line(let a, let b):
                        pair(72, 1); p2(10, a); p2(11, b)
                    case .arc(let c, let r, let s, let en, let ccw):
                        pair(72, 2); p2(10, c); pair(40, r); pair(50, Self.deg(s)); pair(51, Self.deg(en)); pair(73, ccw ? 1 : 0)
                    case .ellipse(let c, let mj, let ratio, let s, let en, let ccw):
                        pair(72, 3); p2(10, c); p2(11, mj); pair(40, ratio)
                        pair(50, Self.deg(s)); pair(51, Self.deg(en)); pair(73, ccw ? 1 : 0)
                    case .spline(let deg, let rational, let periodic, let knots, let cps, let ws):
                        pair(72, 4); pair(94, deg); pair(73, rational ? 1 : 0); pair(74, periodic ? 1 : 0)
                        pair(95, knots.count); pair(96, cps.count)
                        for k in knots { pair(40, k) }
                        for (i, c) in cps.enumerated() {
                            p2(10, c)
                            if rational { pair(42, i < ws.count ? ws[i] : 1) }
                        }
                    }
                }
            }
            pair(97, 0)
        }
        pair(75, h.style)
        pair(76, h.patternType)
        if !h.solid {
            pair(52, Self.deg(h.angle))
            pair(41, h.scale)
            pair(77, h.double ? 1 : 0)
            pair(78, h.defLines.count)
            for l in h.defLines {
                pair(53, Self.deg(l.angle))
                pair(43, l.base.x); pair(44, l.base.y)
                pair(45, l.offset.x); pair(46, l.offset.y)
                pair(79, l.dashes.count)
                for d in l.dashes { pair(49, d) }
            }
        }
        pair(98, 0)
    }
}
