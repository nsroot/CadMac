import Foundation

/// Entity encoding (spec 20.2, 20.4.1-20.4.2 and the per-type prescriptions, R2000 variants).
extension DWGWriterImpl {

    struct EntProps {
        var layer: UInt32
        var color: Int
        /// 0 = ByLayer, 1 = ByBlock, 3 = handle follows.
        var ltFlags: Int
        var ltHandle: UInt32
        var lineweight: Int
    }

    /// DWG lineweight index: 0...23 standard weights, 29 ByLayer, 30 ByBlock, 31 Default.
    static func lineweightIndex(_ mm: Double, negative: Int) -> Int {
        if mm == -2 { return 30 }
        if mm < 0 { return negative }
        let v = Int((mm * 100).rounded())
        var best = 0
        for (i, w) in dxfLineweights.enumerated() where abs(w - v) < abs(dxfLineweights[best] - v) { best = i }
        return best
    }

    static func colorIndex(_ c: CadColor) -> Int {
        switch c {
        case .byLayer: return 256
        case .byBlock: return 0
        case .aci(let i): return min(max(i, 1), 255)
        case .rgb(let rgb): return nearestACI(rgb)
        }
    }

    func props(_ e: Entity) -> EntProps {
        var p = EntProps(layer: layerHandle(e.layer.isEmpty ? "0" : e.layer), color: DWGWriterImpl.colorIndex(e.color),
                         ltFlags: 0, ltHandle: 0, lineweight: DWGWriterImpl.lineweightIndex(e.lineweight, negative: 29))
        let lt = e.linetype.uppercased()
        if lt == "BYBLOCK" { p.ltFlags = 1 }
        else if lt != "BYLAYER", let h = ltypeByName[lt] { p.ltFlags = 3; p.ltHandle = h }
        return p
    }

    /// Common entity data and common entity handle data.
    func entityObj(type: Int, handle: UInt32, props p: EntProps, owner: UInt32, entmode: Int,
                   reactors: [UInt32] = [], prev: UInt32 = 0, next: UInt32 = 0) -> DWGWObj {
        var o = DWGWObj(type: type, handle: handle)
        o.d.b(false)            // no graphic image
        o.d.bb(entmode)
        o.d.bl(reactors.count)
        o.d.b(false)            // links stored explicitly
        o.d.cmc(p.color)
        o.d.bd(1)               // linetype scale
        o.d.bb(p.ltFlags)
        o.d.bb(0)               // plot style ByLayer
        o.d.bs(0)               // visible
        o.d.rc(UInt8(p.lineweight))
        if entmode == 0 { o.hs.h(4, owner) }
        for r in reactors { o.hs.h(4, r) }
        o.hs.h(3, 0)            // no xdictionary
        o.hs.h(4, prev)
        o.hs.h(4, next)
        o.hs.h(5, p.layer)
        if p.ltFlags == 3 { o.hs.h(5, p.ltHandle) }
        return o
    }

    // MARK: Blocks

    mutating func encodeBlock(_ b: DWGWBlock) {
        let p0 = EntProps(layer: layers[0].handle, color: 256, ltFlags: 0, ltHandle: 0, lineweight: 29)
        var be = entityObj(type: 4, handle: b.blockEnt, props: p0, owner: b.record, entmode: 0)
        be.d.t(b.name)
        emit(b.blockEnt, be.finish())

        for (i, pe) in b.ents.enumerated() {
            let prev = i > 0 ? b.ents[i - 1].handle : 0
            let next = i + 1 < b.ents.count ? b.ents[i + 1].handle : 0
            encodeEntity(pe, block: b, prev: prev, next: next)
        }

        let ee = entityObj(type: 5, handle: b.endblk, props: p0, owner: b.record, entmode: 0)
        emit(b.endblk, ee.finish())

        // BLOCK_HEADER (BLOCK_RECORD).
        let inserts = insertsByRecord[b.record] ?? []
        var o = DWGWObj.object(type: 0x31, handle: b.record, owner: DWGWH.blockControl)
        o.d.t(b.name)
        o.d.b(false); o.d.bs(0); o.d.b(false)       // 64-flag, xrefindex+1, xdep
        o.d.b(b.anonymous); o.d.b(b.hasAttdefs)
        o.d.b(false); o.d.b(false)                    // xref, overlaid
        o.d.b(false)                                  // loaded bit
        o.d.bd3(b.base)
        o.d.t("")                                     // xref path
        for _ in inserts { o.d.rc(1) }
        o.d.rc(0)
        o.d.t("")                                     // description
        o.d.bl(0)                                     // no preview
        o.hs.h(5, 0)
        o.hs.h(3, b.blockEnt)
        o.hs.h(4, b.ents.first?.handle ?? 0)
        o.hs.h(4, b.ents.last?.handle ?? 0)
        o.hs.h(3, b.endblk)
        for h in inserts { o.hs.h(4, h) }
        o.hs.h(5, b.layout)
        emit(b.record, o.finish())
    }

    // MARK: Entities

    mutating func encodeEntity(_ pe: DWGWEnt, block b: DWGWBlock, prev: UInt32, next: UInt32) {
        let e = pe.e
        let p = props(e)
        func start(_ type: Int) -> DWGWObj {
            entityObj(type: type, handle: pe.handle, props: p, owner: b.record, entmode: b.entmode,
                      reactors: pe.reactors, prev: prev, next: next)
        }
        switch pe.special {
        case .overallViewport(let v):
            var o = start(0x22)
            writeViewport(v, frozen: [], into: &o)
            emit(pe.handle, o.finish())
            return
        case .solid(let s):
            var o = start(0x1F)
            o.d.btZero()
            o.d.bd(0)
            o.d.rd2(s[0]); o.d.rd2(s[1]); o.d.rd2(s[2]); o.d.rd2(s.count > 3 ? s[3] : s[2])
            o.d.beDefault()
            emit(pe.handle, o.finish())
            return
        case .none:
            break
        }

        switch e.kind {
        case .line(let l):
            var o = start(0x13)
            o.d.b(true) // z's are zero
            o.d.rd(l.start.x); o.d.dd(l.end.x, default: l.start.x)
            o.d.rd(l.start.y); o.d.dd(l.end.y, default: l.start.y)
            o.d.btZero(); o.d.beDefault()
            emit(pe.handle, o.finish())

        case .circle(let c):
            var o = start(0x12)
            o.d.bd3(c.center); o.d.bd(c.radius)
            o.d.btZero(); o.d.beDefault()
            emit(pe.handle, o.finish())

        case .arc(let a):
            var o = start(0x11)
            o.d.bd3(a.center); o.d.bd(a.radius)
            o.d.btZero(); o.d.beDefault()
            o.d.bd(a.startAngle); o.d.bd(a.endAngle)
            emit(pe.handle, o.finish())

        case .point(let pt):
            var o = start(0x1B)
            o.d.bd3(pt.position)
            o.d.btZero(); o.d.beDefault()
            o.d.bd(0)
            emit(pe.handle, o.finish())

        case .polyline(let pl):
            var o = start(DWGWClass.lwpolyline)
            let bulged = pl.vertices.contains { $0.bulge != 0 }
            var flag = 0
            if pl.width != 0 { flag |= 4 }
            if bulged { flag |= 16 }
            if pl.closed { flag |= 512 }
            o.d.bs(flag)
            if pl.width != 0 { o.d.bd(pl.width) }
            o.d.bl(pl.vertices.count)
            if bulged { o.d.bl(pl.vertices.count) }
            o.d.rd2(pl.vertices[0].point)
            for i in 1..<max(1, pl.vertices.count) {
                let a = pl.vertices[i - 1].point, c = pl.vertices[i].point
                o.d.dd(c.x, default: a.x); o.d.dd(c.y, default: a.y)
            }
            if bulged { for v in pl.vertices { o.d.bd(v.bulge) } }
            emit(pe.handle, o.finish())

        case .ellipse(var el):
            if el.ratio > 1 {
                el = EllipseGeom(center: el.center, majorAxis: el.majorAxis.perp * el.ratio, ratio: 1 / el.ratio,
                                 startParam: el.startParam - .pi / 2, endParam: el.endParam - .pi / 2)
            }
            var o = start(0x23)
            o.d.bd3(el.center); o.d.bd3(el.majorAxis)
            o.d.bd3(0, 0, 1)
            o.d.bd(el.ratio)
            if el.isFull { o.d.bd(0); o.d.bd(2 * .pi) }
            else { o.d.bd(normalizeAngle(el.startParam)); o.d.bd(normalizeAngle(el.endParam)) }
            emit(pe.handle, o.finish())

        case .spline(let s):
            guard let sp = pe.spline else { return }
            var o = start(0x24)
            o.d.bl(1)                 // scenario: control points + knots
            o.d.bl(sp.degree)
            o.d.b(false)              // rational
            o.d.b(s.closed)
            o.d.b(false)              // periodic
            o.d.bd(1e-10); o.d.bd(1e-10)
            o.d.bl(sp.knots.count); o.d.bl(sp.cps.count)
            o.d.b(false)              // no weights
            for k in sp.knots { o.d.bd(k) }
            for c in sp.cps { o.d.bd3(c) }
            emit(pe.handle, o.finish())

        case .text(let t):
            if t.isMultiline {
                var o = start(0x2C)
                writeMText(t, into: &o)
                emit(pe.handle, o.finish())
            } else {
                var o = start(0x01)
                writeTextData(t, value: t.text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " "), into: &o)
                o.hs.h(5, styleHandle(t.style))
                emit(pe.handle, o.finish())
            }

        case .attdef(let a):
            var o = start(0x03)
            writeTextData(a.text, value: singleLine(a.defaultValue), into: &o)
            o.d.t(DWGWriterImpl.attributeTag(a.tag))
            o.d.bs(0)
            o.d.rc(UInt8((a.isInvisible ? 1 : 0) | (a.isConstant ? 2 : 0) | (a.isPreset ? 8 : 0)))
            o.d.t(singleLine(a.prompt))
            o.hs.h(5, styleHandle(a.text.style))
            emit(pe.handle, o.finish())

        case .insert(let i):
            var o = start(0x07)
            o.d.bd3(i.position)
            if i.scaleX == 1 && i.scaleY == 1 {
                o.d.bb(3)
            } else {
                o.d.bb(0)
                o.d.rd(i.scaleX)
                o.d.dd(i.scaleY, default: i.scaleX)
                o.d.dd(1, default: i.scaleX)
            }
            o.d.bd(i.rotation)
            o.d.bd3(0, 0, 1)
            let hasAttribs = !pe.attribs.isEmpty
            o.d.b(hasAttribs)
            o.hs.h(5, blockRecordByName[i.blockName] ?? 0)
            if hasAttribs {
                o.hs.h(4, pe.attribs.first!)
                o.hs.h(4, pe.attribs.last!)
                o.hs.h(3, pe.seqend)
            }
            emit(pe.handle, o.finish())
            guard hasAttribs else { return }
            for (k, a) in i.attributes.enumerated() {
                var ae = e
                if let l = a.layer, !l.isEmpty { ae.layer = l }
                if let c = a.color { ae.color = c }
                let ap = props(ae)
                var ao = entityObj(type: 0x02, handle: pe.attribs[k], props: ap, owner: pe.handle, entmode: 0,
                                   prev: k > 0 ? pe.attribs[k - 1] : 0,
                                   next: k + 1 < pe.attribs.count ? pe.attribs[k + 1] : 0)
                writeTextData(a.text, value: singleLine(a.value), into: &ao)
                ao.d.t(DWGWriterImpl.attributeTag(a.tag))
                ao.d.bs(0)
                ao.d.rc(a.isInvisible ? 1 : 0)
                ao.hs.h(5, styleHandle(a.text.style))
                emit(pe.attribs[k], ao.finish())
            }
            var sp = props(e)
            sp.color = 256; sp.ltFlags = 0; sp.lineweight = 29
            let so = entityObj(type: 0x06, handle: pe.seqend, props: sp, owner: pe.handle, entmode: 0)
            emit(pe.seqend, so.finish())

        case .dimension(let dm):
            var o = start(DWGWriterImpl.dimensionType(dm))
            writeDimension(dm, pe: pe, into: &o)
            emit(pe.handle, o.finish())

        case .hatch(let h):
            var o = start(DWGWClass.hatch)
            writeHatch(h, into: &o)
            emit(pe.handle, o.finish())

        case .viewport(let v):
            var o = start(0x22)
            let frozen = v.frozenLayers.compactMap { layerByName[$0.uppercased()] }
            writeViewport(v, frozen: frozen, into: &o)
            emit(pe.handle, o.finish())
        }
    }

    func singleLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
    }

    /// Tags may not be empty or contain spaces.
    static func attributeTag(_ tag: String) -> String {
        let t = tag.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        return t.isEmpty ? "TAG" : t
    }

    /// TEXT / ATTRIB / ATTDEF common text data (R2000 data-flags form).
    func writeTextData(_ t: TextGeom, value: String, into o: inout DWGWObj) {
        let aligned = t.hAlign != .left || t.vAlign != .baseline
        var flags: UInt8 = 0x01 | 0x04 | 0x10 | 0x20   // no elevation, oblique, width factor, generation
        if !aligned { flags |= 0x02 }
        if t.rotation == 0 { flags |= 0x08 }
        if t.hAlign == .left { flags |= 0x40 }
        if t.vAlign == .baseline { flags |= 0x80 }
        o.d.rc(flags)
        o.d.rd2(t.position)
        if aligned { o.d.dd(t.position.x, default: t.position.x); o.d.dd(t.position.y, default: t.position.y) }
        o.d.beDefault()
        o.d.btZero()
        if t.rotation != 0 { o.d.rd(t.rotation) }
        o.d.rd(t.height > 0 ? t.height : 2.5)
        o.d.t(value)
        if t.hAlign != .left { o.d.bs(t.hAlign.rawValue) }
        if t.vAlign != .baseline { o.d.bs(t.vAlign.rawValue) }
    }

    func writeMText(_ t: TextGeom, into o: inout DWGWObj) {
        let h = t.height > 0 ? t.height : 2.5
        o.d.bd3(t.position)
        o.d.bd3(0, 0, 1)
        o.d.bd3(cos(t.rotation), sin(t.rotation), 0)
        o.d.bd(t.width)
        o.d.bd(h)
        let row: Int
        switch t.vAlign {
        case .top, .baseline: row = 0
        case .middle: row = 1
        case .bottom: row = 2
        }
        o.d.bs(row * 3 + t.hAlign.rawValue + 1)
        o.d.bs(1)                                       // left to right
        let lines = t.lines
        let longest = lines.map(\.count).max() ?? 0
        o.d.bd(Double(lines.count) * h * 5 / 3)         // extents height (approximate)
        o.d.bd(t.width > 0 ? t.width : Double(longest) * h * 0.7) // extents width (approximate)
        o.d.t(dxfEscapeMText(t.text))
        o.hs.h(5, styleHandle(t.style))
        o.d.bs(1)                                       // linespacing style: at least
        o.d.bd(1)                                       // linespacing factor
        o.d.b(false)
    }

    func writeViewport(_ v: ViewportGeom, frozen: [UInt32], into o: inout DWGWObj) {
        o.d.bd3(v.center)
        o.d.bd(v.width); o.d.bd(v.height)
        o.d.bd3(0, 0, 0)                                // view target
        o.d.bd3(0, 0, 1)                                // view direction
        o.d.bd(0)                                       // twist
        o.d.bd(v.viewHeight > 0 ? v.viewHeight : v.height)
        o.d.bd(50)                                      // lens length
        o.d.bd(0); o.d.bd(0)                            // front / back clip
        o.d.bd(0)                                       // snap angle
        o.d.rd2(v.viewCenter)
        o.d.rd2(.zero)                                  // snap base
        o.d.rd2(Vec2(10, 10)); o.d.rd2(Vec2(10, 10))    // snap / grid spacing
        o.d.bs(1000)                                    // circle zoom
        o.d.bl(frozen.count)
        o.d.bl(0x8060 | (v.isLocked ? 0x4000 : 0) | (v.isOn ? 0 : 0x20000))
        o.d.t("")                                       // style sheet
        o.d.rc(0)                                       // render mode
        o.d.b(false)                                    // UCS at origin
        o.d.b(true)                                     // UCS per viewport
        o.d.bd3(0, 0, 0); o.d.bd3(1, 0, 0); o.d.bd3(0, 1, 0)
        o.d.bd(0)                                       // UCS elevation
        o.d.bs(0)                                       // orthographic type
        for h in frozen { o.hs.h(5, h) }
        o.hs.h(4, 0)                                    // clip boundary
        o.hs.h(5, 0)                                    // viewport entity header
        o.hs.h(5, 0)                                    // named UCS
        o.hs.h(5, 0)                                    // base UCS
    }

    func writeHatch(_ h: HatchGeom, into o: inout DWGWObj) {
        let loops = h.loops.filter { $0.count >= 2 }
        let solid = h.pattern == .solid
        var name = solid ? "SOLID" : (h.patternName.isEmpty || h.patternName.uppercased() == "SOLID" ? "ANSI31" : h.patternName)
        name = name.replacingOccurrences(of: " ", with: "_")
        let user = name.uppercased() == "_USER"
        o.d.bd(0)                                       // elevation
        o.d.bd3(0, 0, 1)
        o.d.t(name)
        o.d.b(solid)
        o.d.b(false)                                    // not associative
        o.d.bl(loops.count)
        for loop in loops {
            let bulged = loop.contains { $0.bulge != 0 }
            o.d.bl(2)                                   // polyline path
            o.d.b(bulged)
            o.d.b(true)                                 // closed
            o.d.bl(loop.count)
            for v in loop {
                o.d.rd2(v.point)
                if bulged { o.d.bd(v.bulge) }
            }
            o.d.bl(0)                                   // no boundary objects
        }
        o.d.bs(0)                                       // odd parity
        o.d.bs(user ? 0 : 1)
        if !solid {
            let spacing = h.spacing > 0 ? h.spacing : 1
            o.d.bd(user ? h.angle : h.angle - dxfPatternBaseAngle(name) * .pi / 180)
            o.d.bd(user ? spacing : spacing / 3.175)
            o.d.b(false)                                // not double
            let angles = h.pattern == .cross ? [h.angle, h.angle + .pi / 2] : [h.angle]
            o.d.bs(angles.count)
            for a in angles {
                let off = Vec2.polar(1, a).perp * spacing
                o.d.bd(a)
                o.d.bd2(.zero)
                o.d.bd2(off)
                o.d.bs(0)
            }
        }
        o.d.bl(0)                                       // no seed points
    }

    static func dimensionType(_ dm: DimensionGeom) -> Int {
        switch dm.kind {
        case .linear: return 0x15
        case .aligned: return 0x16
        case .angular: return 0x17
        case .diameter: return 0x1A
        case .radius: return 0x19
        }
    }

    func writeDimension(_ dm: DimensionGeom, pe: DWGWEnt, into o: inout DWGWObj) {
        let g = dimensionGraphics(dm, style: drawing.settings.dimStyle)
        var def = dm.p3
        if dm.kind == .diameter { def = dm.p1 * 2 - dm.p2 }
        if dm.kind == .radius { def = dm.p1 }
        let textPt = dm.kind == .radius || dm.kind == .diameter ? dm.p3 : g.text.position
        o.d.bd3(0, 0, 1)                                // extrusion
        o.d.rd2(textPt)
        o.d.bd(0)                                       // elevation
        o.d.rc(3)                                       // flags 1: default text position, block used by this dim only
        o.d.t(dm.textOverride)
        o.d.bd(0); o.d.bd(0)                            // text rotation, horizontal direction
        o.d.bd(1); o.d.bd(1); o.d.bd(1); o.d.bd(0)      // block insertion scale / rotation
        o.d.bs(5)                                       // attachment: middle center
        o.d.bs(1); o.d.bd(1)                            // line spacing
        o.d.bd(dm.kind == .angular ? dm.measurement * .pi / 180 : dm.measurement)
        o.d.rd2(.zero)                                  // 12: block insertion point
        switch dm.kind {
        case .linear:
            o.d.bd3(dm.p1); o.d.bd3(dm.p2); o.d.bd3(def); o.d.bd(0); o.d.bd(dm.rotation)
        case .aligned:
            o.d.bd3(dm.p1); o.d.bd3(dm.p2); o.d.bd3(def); o.d.bd(0)
        case .angular:
            o.d.bd3(dm.p3); o.d.bd3(dm.p2); o.d.bd3(dm.p4); o.d.bd3(dm.p1)
        case .radius:
            o.d.bd3(def); o.d.bd3(dm.p2); o.d.bd(0)
        case .diameter:
            o.d.bd3(dm.p2); o.d.bd3(def); o.d.bd(0)
        }
        o.hs.h(5, DWGWH.dimstyleStandard)
        o.hs.h(5, pe.dimBlock)
    }
}
