import Foundation

// MARK: - Decoded objects

typealias DWGP3 = (x: Double, y: Double, z: Double)
typealias DWGP2 = (x: Double, y: Double)

struct DWGRText {
    var ins: DWGP2 = (0, 0)
    var align: DWGP2 = (0, 0)
    var elevation = 0.0
    var ext: DWGP3 = (0, 0, 1)
    var oblique = 0.0
    var rotation = 0.0
    var height = 0.0
    var widthFactor = 1.0
    var text = ""
    var generation = 0
    var hAlign = 0
    var vAlign = 0
    var style: UInt64 = 0
    // ATTRIB / ATTDEF
    var tag = ""
    var flags = 0
    var prompt = ""
    var lockPosition = false
    /// R2018 multi-line attribute content.
    var mtext: DWGRMText?
}

struct DWGRMText {
    var ins: DWGP3 = (0, 0, 0)
    var ext: DWGP3 = (0, 0, 1)
    var xdir: DWGP3 = (1, 0, 0)
    var rectWidth = 0.0
    var height = 0.0
    var attachment = 1
    var drawingDir = 1
    var text = ""
    var style: UInt64 = 0
}

struct DWGRInsert {
    var ins: DWGP3 = (0, 0, 0)
    var scale: DWGP3 = (1, 1, 1)
    var rotation = 0.0
    var ext: DWGP3 = (0, 0, 1)
    var hasAttribs = false
    var block: UInt64 = 0
    var attribs: [UInt64] = []
    var firstAttrib: UInt64 = 0, lastAttrib: UInt64 = 0
    var cols = 1, rows = 1
    var colSpacing = 0.0, rowSpacing = 0.0
    var isMInsert = false
}

struct DWGRPolyline {
    /// DXF 70 flags.
    var flags = 0
    var startWidth = 0.0, endWidth = 0.0
    var elevation = 0.0
    var ext: DWGP3 = (0, 0, 1)
    var vertices: [UInt64] = []
    var firstVertex: UInt64 = 0, lastVertex: UInt64 = 0
}

struct DWGRVertex {
    var flags = 0
    var pt: DWGP3 = (0, 0, 0)
    var bulge = 0.0
    var startWidth = 0.0, endWidth = 0.0
}

struct DWGRLWPolyline {
    var flags70 = 0
    var constWidth = 0.0
    var elevation = 0.0
    var ext: DWGP3 = (0, 0, 1)
    var points: [DWGP2] = []
    var bulges: [Double] = []
}

struct DWGRSpline {
    var flags70 = 0
    var degree = 3
    var knots: [Double] = []
    var control: [DWGP3] = []
    var weights: [Double] = []
    var fit: [DWGP3] = []
}

struct DWGRDimension {
    /// DXF 70 type (0 linear .. 6 ordinate) plus flag bits.
    var dxfType = 0
    var ext: DWGP3 = (0, 0, 1)
    var textMid: DWGP2 = (0, 0)
    var userText = ""
    var p10: DWGP3 = (0, 0, 0), p13: DWGP3 = (0, 0, 0), p14: DWGP3 = (0, 0, 0), p15: DWGP3 = (0, 0, 0)
    var p16: DWGP2 = (0, 0)
    var rotation = 0.0
    var hasTextMid = true
}

enum DWGRHatchEdge {
    case line(DWGP2, DWGP2)
    case arc(center: DWGP2, radius: Double, start: Double, end: Double, ccw: Bool)
    case ellipse(center: DWGP2, major: DWGP2, ratio: Double, start: Double, end: Double, ccw: Bool)
    case spline(degree: Int, rational: Bool, periodic: Bool, knots: [Double], control: [DWGP2], weights: [Double])
}

struct DWGRHatchPath {
    var flags = 0
    var edges: [DWGRHatchEdge] = []
    var polyline: [(DWGP2, Double)] = []
    var hasBulges = false
    var closed = false
}

struct DWGRHatch {
    var name = ""
    var solid = false
    var associative = false
    var elevation = 0.0
    var ext: DWGP3 = (0, 0, 1)
    var paths: [DWGRHatchPath] = []
    var style = 0
    var patternType = 1
    var angle = 0.0
    var scale = 1.0
    var double = false
    var defLines: [(angle: Double, base: DWGP2, offset: DWGP2, dashes: [Double])] = []
}

struct DWGRViewport {
    var center: DWGP3 = (0, 0, 0)
    var width = 0.0, height = 0.0
    var target: DWGP3 = (0, 0, 0)
    var direction: DWGP3 = (0, 0, 1)
    var twist = 0.0
    var viewHeight = 0.0
    var viewCenter: DWGP2 = (0, 0)
    var status = 0
    var frozen: [UInt64] = []
    var hasView = false
}

struct DWGRBlockHeader {
    var name = ""
    var anonymous = false, hasAttdefs = false, isXref = false, overlaid = false, xdep = false
    var base: DWGP3 = (0, 0, 0)
    var entities: [UInt64] = []
    var firstEntity: UInt64 = 0, lastEntity: UInt64 = 0
    var blockEntity: UInt64 = 0, endblk: UInt64 = 0
    var layout: UInt64 = 0
    var description = ""
}

struct DWGRLayer {
    var name = ""
    var frozen = false, on = true, locked = false, plot = true
    var lineweight = -3
    var color: DWGReadColor = .aci(7)
    var colorIndexNegative = false
    var ltype: UInt64 = 0
}

struct DWGRLtype {
    var name = ""
    var description = ""
    var dashes: [Double] = []
}

struct DWGRLayout {
    var pageSetup = "", paperName = ""
    var margins = [0.0, 0, 0, 0]
    var width = 0.0, height = 0.0
    var units = 1, rotation = 0
    var name = ""
    var tabOrder = 0
    var limMin: DWGP2 = (0, 0), limMax: DWGP2 = (0, 0)
    var blockRecord: UInt64 = 0
}

struct DWGRGroup {
    var description = ""
    var unnamed = false, selectable = true
    var members: [UInt64] = []
}

struct DWGRField {
    var evaluator = ""
    var code = ""
    var value = ""
    var children: [UInt64] = []
}

enum DWGRData {
    case none
    case text(DWGRText)          // TEXT, ATTRIB, ATTDEF
    case mtext(DWGRMText)
    case insert(DWGRInsert)
    case polyline(DWGRPolyline)
    case vertex(DWGRVertex)
    case lwpolyline(DWGRLWPolyline)
    case line(DWGP3, DWGP3)
    case circle(center: DWGP3, radius: Double, ext: DWGP3)
    case arc(center: DWGP3, radius: Double, start: Double, end: Double, ext: DWGP3)
    case point(DWGP3)
    case ellipse(center: DWGP3, major: DWGP3, ext: DWGP3, ratio: Double, start: Double, end: Double)
    case spline(DWGRSpline)
    case solid(pts: [DWGP2], elevation: Double, ext: DWGP3)
    case dimension(DWGRDimension)
    case hatch(DWGRHatch)
    case viewport(DWGRViewport)
    case leader([DWGP3])
    case block(String)
    case blockHeader(DWGRBlockHeader)
    case layer(DWGRLayer)
    case ltype(DWGRLtype)
    case style(String)
    case dictionary([(String, UInt64)])
    case layout(DWGRLayout)
    case group(DWGRGroup)
    case field(DWGRField)
    case control([UInt64])
}

final class DWGRObject {
    let handle: UInt64
    let type: Int
    let name: String
    let isEntity: Bool
    var owner: UInt64 = 0
    var xdic: UInt64 = 0
    var entmode = 2
    var color: DWGReadColor = .byLayer
    var layer: UInt64 = 0
    var ltypeFlags = 0
    var ltype: UInt64 = 0
    /// Hundredths of mm; -1 ByLayer, -2 ByBlock, -3 Default.
    var lineweight = -1
    var invisible = false
    var nolinks = true
    var prev: UInt64 = 0, next: UInt64 = 0
    var data: DWGRData = .none
    /// Unread bits left in the data stream after decoding (diagnostics; negative = overrun).
    var slack = 0
    var crcOK = true

    init(handle: UInt64, type: Int, name: String, isEntity: Bool) {
        self.handle = handle; self.type = type; self.name = name; self.isEntity = isEntity
    }
}

struct DWGRClass {
    var number: Int
    var dxfName: String
    var cppName: String
    var isEntity: Bool
}

// MARK: - Streams of one object

/// The data, string (R2007+) and handle streams of one object.
struct DWGRStreams {
    var m: DWGBitReader
    var s: DWGBitReader
    var h: DWGBitReader
    var hasStrings: Bool
    let unicode: Bool
    let encoding: String.Encoding
    let ref: UInt64

    mutating func tv() -> String {
        if unicode { return hasStrings ? s.textU() : "" }
        return m.text8(encoding)
    }

    mutating func hnd() -> UInt64 { h.handle(relativeTo: ref) }
    mutating func hnds(_ n: Int) -> [UInt64] {
        var out: [UInt64] = []
        let n = max(0, min(n, h.bitsLeft / 8 + 1))
        out.reserveCapacity(n)
        for _ in 0..<n {
            if h.bitsLeft < 8 { break }
            out.append(hnd())
        }
        return out
    }

    /// Clamps a count read from the file against the bits left in the data stream.
    func count(_ n: Int, bitsEach: Int = 2) -> Int {
        max(0, min(n, m.bitsLeft / max(1, bitsEach) + 1))
    }
}

// MARK: - Object decoder

struct DWGRDecoder {
    let file: DWGReadFile
    let v: DWGVersion
    var classes: [Int: DWGRClass] = [:]
    let r13_14: Bool, r2000: Bool, r2004: Bool, r2007: Bool, r2010: Bool, r2013: Bool, r2018: Bool

    init(file: DWGReadFile) {
        self.file = file
        v = file.version
        r13_14 = v <= .r14
        r2000 = v >= .r2000
        r2004 = v >= .r2004
        r2007 = v >= .r2007
        r2010 = v >= .r2010
        r2013 = v >= .r2013
        r2018 = v >= .r2018
    }

    // MARK: Object map

    /// Parses AcDb:Handles into handle -> offset. Returns the map and the number of CRC errors.
    static func objectMap(_ d: [UInt8]) -> (map: [UInt64: Int], order: [UInt64], crcErrors: Int) {
        var map: [UInt64: Int] = [:]
        var order: [UInt64] = []
        var crcErrors = 0
        var i = 0
        while i + 2 <= d.count {
            let size = Int(d[i]) << 8 | Int(d[i + 1])
            if size <= 2 { break }
            let end = min(i + size, d.count)
            if i + size + 2 <= d.count {
                let crc = UInt16(d[i + size]) << 8 | UInt16(d[i + size + 1])
                if DWGReadCRC.crc16(d, i..<(i + size), seed: 0xC0C1) != crc { crcErrors += 1 }
            }
            var j = i + 2
            var lastH: Int = 0, lastLoc = 0
            while j < end {
                guard let dh = dwgReadModularChar(d, &j, signed: false), let dl = dwgReadModularChar(d, &j, signed: true) else { break }
                lastH += dh
                lastLoc += dl
                if lastH >= 0, map[UInt64(lastH)] == nil { order.append(UInt64(lastH)) }
                if lastH >= 0 { map[UInt64(lastH)] = lastLoc }
            }
            i += size + 2
        }
        return (map, order, crcErrors)
    }

    // MARK: Classes

    mutating func readClasses() {
        let d = file.classes
        guard d.count > 24 else { return }
        let size = Int(dwgReadLE32(d, 16))
        if !r2007 {
            let start = r2004 && (r2010 && file.maintenance > 3) ? 24 : 20
            let end = min(d.count, 20 + size) * 8
            for wide in [false, true] {
                var m = DWGBitReader(d, bit: start * 8, end: end)
                var list: [Int: DWGRClass] = [:]
                if r2004 { _ = m.bs(); _ = m.rc(); _ = m.rc(); _ = m.bit() }
                var ok = true
                while m.bitsLeft > 18 {
                    let num = m.bs()
                    _ = m.bs()
                    _ = m.text8(file.encoding)
                    let cpp = m.text8(file.encoding)
                    let dxf = m.text8(file.encoding)
                    _ = m.bit()
                    let item = m.bs()
                    if r2004 {
                        _ = m.bl()
                        if wide { _ = m.bl(); _ = m.bl() } else { _ = m.bs(); _ = m.bs() }
                        _ = m.bl(); _ = m.bl()
                    }
                    if m.overflow || num < 500 || num > 5000 || dxf.isEmpty { ok = list.count > 0 && !m.overflow; break }
                    list[num] = DWGRClass(number: num, dxfName: dxf.uppercased(), cppName: cpp, isEntity: item == 0x1F2)
                }
                if ok || wide || !r2004 {
                    if list.count >= classes.count { classes = list }
                    if ok { break }
                }
            }
            return
        }
        // R2007+: data stream, string stream at the end (located from the bit size).
        let hasHi = r2018 || (r2010 && file.maintenance > 3)
        let bitsField = hasHi ? 24 : 20
        let bitSize = Int(dwgReadLE32(d, bitsField))
        let endbit = bitsField * 8 + bitSize
        guard let strStart = DWGRDecoder.stringStreamStart(d, endbit: endbit) else { return }
        var m = DWGBitReader(d, bit: (bitsField + 4) * 8, end: strStart)
        var s = DWGBitReader(d, bit: strStart, end: endbit)
        let maxClass = m.bs()
        _ = m.rc(); _ = m.rc(); _ = m.bit()
        while m.bitsLeft > 18 {
            let num = m.bs()
            _ = m.bs()
            _ = s.textU()
            let cpp = s.textU()
            let dxf = s.textU()
            _ = m.bit()
            let item = m.bs()
            _ = m.bl(); _ = m.bl(); _ = m.bl(); _ = m.bl(); _ = m.bl()
            if m.overflow || s.overflow { break }
            classes[num] = DWGRClass(number: num, dxfName: dxf.uppercased(), cppName: cpp, isEntity: item == 0x1F2)
            if num >= maxClass { break }
        }
    }

    /// Start of the R2007+ string stream that ends at `endbit` (spec 20.1), or nil if absent.
    static func stringStreamStart(_ d: [UInt8], endbit: Int) -> Int? {
        var r = DWGBitReader(d, bit: endbit - 1, end: endbit)
        guard endbit > 17, r.bit() else { return nil }
        var p = endbit - 1 - 16
        r = DWGBitReader(d, bit: p, end: p + 16)
        var size = Int(UInt16(bitPattern: r.rs()))
        if size & 0x8000 != 0 {
            p -= 16
            guard p >= 0 else { return nil }
            r = DWGBitReader(d, bit: p, end: p + 16)
            let hi = Int(UInt16(bitPattern: r.rs()))
            size = (size & 0x7FFF) | (hi << 15)
        }
        let start = p - size
        return start >= 0 ? start : nil
    }

    func typeName(_ t: Int) -> (String, Bool) {
        if t >= 500, let c = classes[t] { return (c.dxfName, c.isEntity) }
        if let n = DWGObjectType.names[t] { return (n, DWGObjectType.isEntity(t)) }
        return ("UNKNOWN\(t)", false)
    }

    // MARK: One object

    func decode(handle: UInt64, at offset: Int, full: Bool = true) -> DWGRObject? {
        let d = file.objects
        guard offset >= 0, offset < d.count else { return nil }
        var i = offset
        guard let size = dwgReadModularShort(d, &i), size > 0, i + size <= d.count else { return nil }
        var hsBits = 0
        if r2010 {
            guard let hb = dwgReadModularChar(d, &i, signed: false) else { return nil }
            hsBits = hb
        }
        let start = i
        let objEnd = (start + size) * 8
        var m = DWGBitReader(d, bit: start * 8, end: objEnd)
        let type = r2010 ? m.ot2010() : m.bs()
        var endbit = objEnd
        if r2010 {
            endbit = objEnd - hsBits
        } else if r2000 {
            endbit = start * 8 + Int(UInt32(bitPattern: m.rl()))
        }
        let (code, hv) = m.handleRef()
        guard code == 0 || hv == handle, hv == handle || code == 0 else { return nil }
        let (name, isEntity) = typeName(type)
        let o = DWGRObject(handle: hv, type: type, name: name, isEntity: isEntity)
        if start + size + 2 <= d.count {
            let crc = DWGReadCRC.crc16(d, offset..<(start + size), seed: 0xC0C1)
            o.crcOK = crc == dwgReadLE16(d, start + size)
        }
        // Extended entity data.
        while !m.overflow {
            let n = m.bs()
            if n <= 0 { break }
            _ = m.handleRef()
            m.skipBytes(n)
        }
        if isEntity {
            if m.bit() {
                let n = r2010 ? Int(clamping: m.bll()) : Int(UInt32(bitPattern: m.rl()))
                m.skipBytes(n)
            }
        }
        if r13_14 { endbit = start * 8 + Int(UInt32(bitPattern: m.rl())) }
        guard endbit > m.pos, endbit <= objEnd else { return nil }

        var strStart = endbit
        var hasStrings = false
        if r2007, let s = DWGRDecoder.stringStreamStart(d, endbit: endbit), s >= m.pos {
            strStart = s
            hasStrings = true
        } else if r2007 {
            strStart = endbit - 1
        }
        m.end = strStart
        var st = DWGRStreams(m: m, s: DWGBitReader(d, bit: strStart, end: hasStrings ? endbit - 1 : strStart),
                             h: DWGBitReader(d, bit: endbit, end: objEnd), hasStrings: hasStrings,
                             unicode: r2007, encoding: file.encoding, ref: hv)

        var ltypeFlags = 0, plotFlags = 0, materialFlags = 0
        var vsFull = false, vsFace = false, vsEdge = false
        var hasBook = false
        var numReactors = 0
        var xdicMissing = false
        var isByLayerLt = true
        if isEntity {
            o.entmode = st.m.bb()
            numReactors = st.m.bl()
            if r2004 { xdicMissing = st.m.bit() }
            if r2013 { _ = st.m.bit() }
            if r13_14 { isByLayerLt = st.m.bit() }
            if !r2004 { o.nolinks = st.m.bit() }
            if r2004 {
                let c = st.m.enc()
                o.color = c.color
                hasBook = c.hasBook
            } else {
                o.color = DWGReadColor.index(st.m.bs())
            }
            _ = st.m.bd()
            if r2000 {
                ltypeFlags = st.m.bb()
                plotFlags = st.m.bb()
            }
            if r2007 {
                materialFlags = st.m.bb()
                _ = st.m.rc()
            }
            if r2010 {
                vsFull = st.m.bit(); vsFace = st.m.bit(); vsEdge = st.m.bit()
            }
            o.invisible = st.m.bs() & 1 != 0
            if r2000 { o.lineweight = dwgReadLineweight(index: Int(st.m.rc())) }
        } else {
            numReactors = st.m.bl()
            if r2004 { xdicMissing = st.m.bit() }
            if r2013 { _ = st.m.bit() }
        }
        o.ltypeFlags = r2000 ? ltypeFlags : (isByLayerLt ? 0 : 3)

        // Common handles.
        if !isEntity || o.entmode == 0 { o.owner = st.hnd() }
        for _ in 0..<max(0, min(numReactors, 100_000)) { _ = st.hnd() }
        if !xdicMissing { o.xdic = st.hnd() }
        if isEntity {
            if r13_14 {
                o.layer = st.hnd()
                if !isByLayerLt { o.ltype = st.hnd() }
            }
            if !r2004 && !o.nolinks {
                o.prev = st.hnd()
                o.next = st.hnd()
            }
            if r2004 && hasBook { _ = st.hnd() }
            if r2000 {
                o.layer = st.hnd()
                if ltypeFlags == 3 { o.ltype = st.hnd() }
                if r2007 && materialFlags == 3 { _ = st.hnd() }
                if plotFlags == 3 { _ = st.hnd() }
            }
            if r2010 {
                if vsFull { _ = st.hnd() }
                if vsFace { _ = st.hnd() }
                if vsEdge { _ = st.hnd() }
            }
        }
        guard full else { return o }
        decodeData(o, &st)
        o.slack = st.m.overflow ? -1 : st.m.bitsLeft
        return o
    }

    // MARK: Type dispatch

    func decodeData(_ o: DWGRObject, _ st: inout DWGRStreams) {
        switch o.type {
        case DWGObjectType.text: o.data = .text(text(&st))
        case DWGObjectType.attrib: o.data = .text(attrib(&st, def: false))
        case DWGObjectType.attdef: o.data = .text(attrib(&st, def: true))
        case DWGObjectType.block: o.data = .block(st.tv())
        case DWGObjectType.insert: o.data = .insert(insert(&st, minsert: false))
        case DWGObjectType.minsert: o.data = .insert(insert(&st, minsert: true))
        case DWGObjectType.vertex2D: o.data = .vertex(vertex2D(&st))
        case DWGObjectType.vertex3D, DWGObjectType.vertexMesh, DWGObjectType.vertexPFace:
            var vx = DWGRVertex()
            vx.flags = Int(st.m.rc())
            vx.pt = st.m.bd3()
            o.data = .vertex(vx)
        case DWGObjectType.vertexPFaceFace:
            var vx = DWGRVertex()
            for _ in 0..<4 { _ = st.m.bs() }
            vx.flags = 128
            o.data = .vertex(vx)
        case DWGObjectType.polyline2D, DWGObjectType.polyline3D, DWGObjectType.polylinePFace, DWGObjectType.polylineMesh:
            o.data = .polyline(polyline(&st, type: o.type))
        case DWGObjectType.arc:
            let c = st.m.bd3(), r = st.m.bd()
            _ = st.m.bt(r2000: r2000)
            let e = st.m.be(r2000: r2000)
            let a0 = st.m.bd(), a1 = st.m.bd()
            o.data = .arc(center: c, radius: r, start: a0, end: a1, ext: e)
        case DWGObjectType.circle:
            let c = st.m.bd3(), r = st.m.bd()
            _ = st.m.bt(r2000: r2000)
            o.data = .circle(center: c, radius: r, ext: st.m.be(r2000: r2000))
        case DWGObjectType.line:
            o.data = line(&st)
        case DWGObjectType.point:
            let p = st.m.bd3()
            _ = st.m.bt(r2000: r2000)
            _ = st.m.be(r2000: r2000)
            _ = st.m.bd()
            o.data = .point(p)
        case DWGObjectType.solid, DWGObjectType.trace:
            _ = st.m.bt(r2000: r2000)
            let elev = st.m.bd()
            let pts = (0..<4).map { _ in st.m.rd2() }.map { DWGP2($0.0, $0.1) }
            o.data = .solid(pts: pts, elevation: elev, ext: st.m.be(r2000: r2000))
        case DWGObjectType.ellipse:
            let c = st.m.bd3(), mj = st.m.bd3(), e = st.m.bd3()
            let ratio = st.m.bd(), s = st.m.bd(), en = st.m.bd()
            o.data = .ellipse(center: c, major: mj, ext: e, ratio: ratio, start: s, end: en)
        case DWGObjectType.spline: o.data = .spline(spline(&st))
        case DWGObjectType.viewport: o.data = .viewport(viewport(&st))
        case DWGObjectType.mtext: o.data = .mtext(mtext(&st))
        case DWGObjectType.leader: o.data = .leader(leader(&st))
        case DWGObjectType.dimOrdinate...DWGObjectType.dimDiameter: o.data = .dimension(dimension(&st, type: o.type))
        case DWGObjectType.blockControl, DWGObjectType.layerControl, DWGObjectType.styleControl, DWGObjectType.ltypeControl:
            let n = st.m.bl()
            var list = st.hnds(n)
            if o.type == DWGObjectType.blockControl || o.type == DWGObjectType.ltypeControl { list += st.hnds(2) }
            o.data = .control(list)
        case DWGObjectType.blockHeader: o.data = .blockHeader(blockHeader(&st))
        case DWGObjectType.layer: o.data = .layer(layer(&st))
        case DWGObjectType.ltype: o.data = .ltype(ltype(&st))
        case DWGObjectType.style:
            let name = tableEntry(&st).name
            _ = st.m.bit(); _ = st.m.bit()
            _ = st.m.bd(); _ = st.m.bd(); _ = st.m.bd()
            _ = st.m.rc()
            _ = st.m.bd()
            _ = st.tv(); _ = st.tv()
            o.data = .style(name)
        case DWGObjectType.dictionary: o.data = .dictionary(dictionary(&st))
        case DWGObjectType.group: o.data = .group(group(&st))
        case DWGObjectType.lwpolyline: o.data = .lwpolyline(lwpolyline(&st))
        case DWGObjectType.hatch: o.data = .hatch(hatch(&st))
        case DWGObjectType.layout: o.data = .layout(layout(&st))
        default:
            switch o.name {
            case "LWPOLYLINE": o.data = .lwpolyline(lwpolyline(&st))
            case "HATCH": o.data = .hatch(hatch(&st))
            case "LAYOUT": o.data = .layout(layout(&st))
            case "GROUP": o.data = .group(group(&st))
            case "ACDBDICTIONARYWDFLT", "DICTIONARYWDFLT": o.data = .dictionary(dictionary(&st))
            case "FIELD": o.data = .field(field(&st))
            default: break
            }
        }
    }

    // MARK: Entities

    func text(_ st: inout DWGRStreams) -> DWGRText {
        var t = DWGRText()
        if r2000 {
            let f = Int(st.m.rc())
            if f & 1 == 0 { t.elevation = st.m.rd() }
            t.ins = st.m.rd2()
            if f & 2 == 0 { t.align = (st.m.dd(t.ins.x), st.m.dd(t.ins.y)) } else { t.align = t.ins }
            t.ext = st.m.be(r2000: true)
            _ = st.m.bt(r2000: true)
            if f & 4 == 0 { t.oblique = st.m.rd() }
            if f & 8 == 0 { t.rotation = st.m.rd() }
            t.height = st.m.rd()
            if f & 0x10 == 0 { t.widthFactor = st.m.rd() }
            t.text = st.tv()
            if f & 0x20 == 0 { t.generation = st.m.bs() }
            if f & 0x40 == 0 { t.hAlign = st.m.bs() }
            if f & 0x80 == 0 { t.vAlign = st.m.bs() }
        } else {
            t.elevation = st.m.bd()
            t.ins = st.m.rd2()
            t.align = st.m.rd2()
            t.ext = st.m.bd3()
            _ = st.m.bd()
            t.oblique = st.m.bd()
            t.rotation = st.m.bd()
            t.height = st.m.bd()
            t.widthFactor = st.m.bd()
            t.text = st.tv()
            t.generation = st.m.bs()
            t.hAlign = st.m.bs()
            t.vAlign = st.m.bs()
        }
        t.style = st.hnd()
        return t
    }

    func attrib(_ st: inout DWGRStreams, def: Bool) -> DWGRText {
        // TEXT part (the style handle is read after the text data, before any MTEXT handles).
        var t = text(&st)
        if r2010 { _ = st.m.rc() }
        var multiline = false
        if r2018 {
            let kind = Int(st.m.rc())
            multiline = kind == 2 || kind == 4
        }
        if multiline {
            // Embedded MTEXT (spec 20.4.4), then annotative data, tag, flags.
            var mt = mtextBody(&st, embedded: true)
            mt.style = t.style
            t.mtext = mt
            let annSize = st.m.bs()
            if annSize > 0 {
                st.m.skipBytes(annSize)
                _ = st.hnd()
                _ = st.m.bs()
            }
            t.tag = st.tv()
            _ = st.m.bs()
            t.flags = Int(st.m.rc())
            t.lockPosition = st.m.bit()
            // Fall back to the single-line value if the embedded MTEXT could not be decoded.
            if st.m.overflow { t.mtext = nil }
        } else {
            t.tag = st.tv()
            _ = st.m.bs()
            t.flags = Int(st.m.rc())
            if r2007 { t.lockPosition = st.m.bit() }
        }
        if def {
            if r2010 { _ = st.m.rc() }
            t.prompt = st.tv()
        }
        return t
    }

    func insert(_ st: inout DWGRStreams, minsert: Bool) -> DWGRInsert {
        var g = DWGRInsert()
        g.isMInsert = minsert
        g.ins = st.m.bd3()
        if r2000 {
            switch st.m.bb() {
            case 3: g.scale = (1, 1, 1)
            case 1: g.scale = (1, st.m.dd(1), st.m.dd(1))
            case 2: let x = st.m.rd(); g.scale = (x, x, x)
            default:
                let x = st.m.rd()
                g.scale = (x, st.m.dd(x), st.m.dd(x))
            }
        } else {
            g.scale = st.m.bd3()
        }
        g.rotation = st.m.bd()
        g.ext = st.m.bd3()
        g.hasAttribs = st.m.bit()
        var owned = 0
        // The owned-object count is only present when attributes follow.
        if r2004 && g.hasAttribs { owned = st.m.bl() }
        if minsert {
            g.cols = st.m.bs(); g.rows = st.m.bs()
            g.colSpacing = st.m.bd(); g.rowSpacing = st.m.bd()
        }
        g.block = st.hnd()
        if g.hasAttribs {
            if r2004 {
                g.attribs = st.hnds(owned)
            } else {
                g.firstAttrib = st.hnd()
                g.lastAttrib = st.hnd()
            }
            _ = st.hnd()
        }
        return g
    }

    func vertex2D(_ st: inout DWGRStreams) -> DWGRVertex {
        var vx = DWGRVertex()
        vx.flags = Int(st.m.rc())
        vx.pt = st.m.bd3()
        let sw = st.m.bd()
        if sw < 0 { vx.startWidth = -sw; vx.endWidth = -sw } else { vx.startWidth = sw; vx.endWidth = st.m.bd() }
        vx.bulge = st.m.bd()
        if r2010 { _ = st.m.bl() }
        _ = st.m.bd()
        return vx
    }

    func polyline(_ st: inout DWGRStreams, type: Int) -> DWGRPolyline {
        var p = DWGRPolyline()
        switch type {
        case DWGObjectType.polyline2D:
            p.flags = st.m.bs()
            _ = st.m.bs()
            p.startWidth = st.m.bd()
            p.endWidth = st.m.bd()
            _ = st.m.bt(r2000: r2000)
            p.elevation = st.m.bd()
            p.ext = st.m.be(r2000: r2000)
            p.flags &= ~(8 | 16 | 64)
        case DWGObjectType.polyline3D:
            let a = Int(st.m.rc()), b = Int(st.m.rc())
            p.flags = 8 | (b & 1) | (a & 3 != 0 ? 4 : 0)
        case DWGObjectType.polylinePFace:
            _ = st.m.bs(); _ = st.m.bs()
            p.flags = 64
        default:
            p.flags = (st.m.bs() & ~64) | 16
            _ = st.m.bs(); _ = st.m.bs(); _ = st.m.bs(); _ = st.m.bs(); _ = st.m.bs()
        }
        var owned = 0
        if r2004 { owned = st.m.bl() }
        if r2004 {
            p.vertices = st.hnds(owned)
        } else {
            p.firstVertex = st.hnd()
            p.lastVertex = st.hnd()
        }
        _ = st.hnd()
        return p
    }

    func line(_ st: inout DWGRStreams) -> DWGRData {
        var a: DWGP3 = (0, 0, 0), b: DWGP3 = (0, 0, 0)
        if r2000 {
            let zZero = st.m.bit()
            a.x = st.m.rd(); b.x = st.m.dd(a.x)
            a.y = st.m.rd(); b.y = st.m.dd(a.y)
            if !zZero { a.z = st.m.rd(); b.z = st.m.dd(a.z) }
        } else {
            a = st.m.bd3(); b = st.m.bd3()
        }
        _ = st.m.bt(r2000: r2000)
        _ = st.m.be(r2000: r2000)
        return .line(a, b)
    }

    func spline(_ st: inout DWGRStreams) -> DWGRSpline {
        var sp = DWGRSpline()
        var scenario = st.m.bl()
        var splineFlags = 0
        if r2013 {
            splineFlags = st.m.bl()
            let knotParam = st.m.bl()
            // Control points when the knot parameter is custom or there is no fit data.
            scenario = (knotParam == 15 || splineFlags & 1 == 0) ? 1 : 2
        }
        sp.degree = st.m.bl()
        var nKnots = 0, nCtrl = 0, nFit = 0
        var weighted = false
        if scenario == 2 {
            _ = st.m.bd()
            _ = st.m.bd3(); _ = st.m.bd3()
            nFit = st.m.bl()
            sp.flags70 = 8
        } else {
            let rational = st.m.bit(), closed = st.m.bit(), periodic = st.m.bit()
            _ = st.m.bd(); _ = st.m.bd()
            nKnots = st.m.bl()
            nCtrl = st.m.bl()
            weighted = st.m.bit()
            sp.flags70 = (closed ? 1 : 0) | (periodic ? 2 : 0) | (rational ? 4 : 0)
        }
        if r2013 && splineFlags & 4 != 0 { sp.flags70 |= 1 }
        for _ in 0..<st.count(nKnots) { sp.knots.append(st.m.bd()) }
        for _ in 0..<st.count(nCtrl, bitsEach: 6) {
            sp.control.append(st.m.bd3())
            if weighted { sp.weights.append(st.m.bd()) }
        }
        for _ in 0..<st.count(nFit, bitsEach: 6) { sp.fit.append(st.m.bd3()) }
        return sp
    }

    func viewport(_ st: inout DWGRStreams) -> DWGRViewport {
        var vp = DWGRViewport()
        vp.center = st.m.bd3()
        vp.width = st.m.bd()
        vp.height = st.m.bd()
        guard r2000 else { return vp }
        vp.hasView = true
        vp.target = st.m.bd3()
        vp.direction = st.m.bd3()
        vp.twist = st.m.bd()
        vp.viewHeight = st.m.bd()
        _ = st.m.bd(); _ = st.m.bd(); _ = st.m.bd(); _ = st.m.bd()
        vp.viewCenter = st.m.rd2()
        _ = st.m.rd2(); _ = st.m.rd2(); _ = st.m.rd2()
        _ = st.m.bs()
        if r2007 { _ = st.m.bs() }
        let nFrozen = st.m.bl()
        vp.status = st.m.bl()
        _ = st.tv()
        _ = st.m.rc()
        _ = st.m.bit(); _ = st.m.bit()
        _ = st.m.bd3(); _ = st.m.bd3(); _ = st.m.bd3()
        _ = st.m.bd()
        _ = st.m.bs()
        if r2004 { _ = st.m.bs() }
        if r2007 {
            _ = st.m.bit(); _ = st.m.rc(); _ = st.m.bd(); _ = st.m.bd()
            _ = st.m.cmc2004 { $0.textU() }
        }
        vp.frozen = st.hnds(nFrozen)
        return vp
    }

    /// MTEXT entity data. With `embedded` (R2018 multi-line ATTRIB/ATTDEF) the style handle
    /// is not part of the stream.
    func mtextBody(_ st: inout DWGRStreams, embedded: Bool) -> DWGRMText {
        var t = DWGRMText()
        t.ins = st.m.bd3()
        t.ext = st.m.bd3()
        t.xdir = st.m.bd3()
        t.rectWidth = st.m.bd()
        if r2007 { _ = st.m.bd() }
        t.height = st.m.bd()
        t.attachment = st.m.bs()
        t.drawingDir = st.m.bs()
        _ = st.m.bd(); _ = st.m.bd()
        t.text = st.tv()
        if !embedded { t.style = st.hnd() }
        if r2000 {
            _ = st.m.bs(); _ = st.m.bd(); _ = st.m.bit()
        }
        if r2004 {
            let bg = st.m.bl()
            if bg & 1 != 0 || (r2018 && bg & 0x10 != 0) {
                _ = st.m.bd()   // scale factor (a double; the spec lists BL)
                _ = st.m.cmc2004 { r in r.textU() }
                _ = st.m.bl()
            }
        }
        if r2018 {
            let notAnnotative = st.m.bit()
            if notAnnotative {
                _ = st.m.bs(); _ = st.m.bit()
                _ = st.hnd()
                _ = st.m.bl()
                _ = st.m.bd3(); _ = st.m.bd3()
                _ = st.m.bd(); _ = st.m.bd(); _ = st.m.bd(); _ = st.m.bd()
                let colType = st.m.bs()
                if colType != 0 {
                    let n = st.m.bl()
                    _ = st.m.bd(); _ = st.m.bd()
                    let auto = st.m.bit()
                    _ = st.m.bit()
                    if !auto && colType == 2 { for _ in 0..<st.count(n) { _ = st.m.bd() } }
                }
            }
        }
        return t
    }

    func mtext(_ st: inout DWGRStreams) -> DWGRMText { mtextBody(&st, embedded: false) }

    func leader(_ st: inout DWGRStreams) -> [DWGP3] {
        _ = st.m.bit()
        _ = st.m.bs(); _ = st.m.bs()
        let n = st.m.bl()
        var pts: [DWGP3] = []
        for _ in 0..<st.count(n, bitsEach: 6) { pts.append(st.m.bd3()) }
        // Remaining fields are not needed; consume them to keep diagnostics meaningful.
        _ = st.m.bd3(); _ = st.m.bd3(); _ = st.m.bd3(); _ = st.m.bd3()
        if v >= .r14 { _ = st.m.bd3() }
        if r13_14 { _ = st.m.bd() }
        _ = st.m.bd(); _ = st.m.bd()
        _ = st.m.bit(); _ = st.m.bit()
        if r13_14 {
            _ = st.m.bs(); _ = st.m.bd(); _ = st.m.bit(); _ = st.m.bit(); _ = st.m.bs(); _ = st.m.bs(); _ = st.m.bit(); _ = st.m.bit()
        } else {
            _ = st.m.bs(); _ = st.m.bit(); _ = st.m.bit()
        }
        return pts
    }

    func dimension(_ st: inout DWGRStreams, type: Int) -> DWGRDimension {
        var dm = DWGRDimension()
        if r2010 { _ = st.m.rc() }
        dm.ext = st.m.bd3()
        dm.textMid = st.m.rd2()
        _ = st.m.bd()
        let flags1 = Int(st.m.rc())
        dm.userText = st.tv()
        _ = st.m.bd(); _ = st.m.bd()
        _ = st.m.bd(); _ = st.m.bd(); _ = st.m.bd(); _ = st.m.bd()
        if r2000 {
            _ = st.m.bs(); _ = st.m.bs(); _ = st.m.bd(); _ = st.m.bd()
        }
        if r2007 { _ = st.m.bit(); _ = st.m.bit(); _ = st.m.bit() }
        _ = st.m.rd2()
        var base = 0
        switch type {
        case DWGObjectType.dimOrdinate:
            base = 6
            dm.p10 = st.m.bd3(); dm.p13 = st.m.bd3(); dm.p14 = st.m.bd3()
            if st.m.rc() & 1 != 0 { base |= 64 }
        case DWGObjectType.dimLinear:
            base = 0
            dm.p13 = st.m.bd3(); dm.p14 = st.m.bd3(); dm.p10 = st.m.bd3()
            _ = st.m.bd()
            dm.rotation = st.m.bd()
        case DWGObjectType.dimAligned:
            base = 1
            dm.p13 = st.m.bd3(); dm.p14 = st.m.bd3(); dm.p10 = st.m.bd3()
            _ = st.m.bd()
        case DWGObjectType.dimAng3Pt:
            base = 5
            dm.p10 = st.m.bd3(); dm.p13 = st.m.bd3(); dm.p14 = st.m.bd3(); dm.p15 = st.m.bd3()
        case DWGObjectType.dimAng2Ln:
            base = 2
            dm.p16 = st.m.rd2()
            dm.p13 = st.m.bd3(); dm.p14 = st.m.bd3(); dm.p15 = st.m.bd3(); dm.p10 = st.m.bd3()
        case DWGObjectType.dimRadius:
            base = 4
            dm.p10 = st.m.bd3(); dm.p15 = st.m.bd3()
            _ = st.m.bd()
        default:
            base = 3
            dm.p15 = st.m.bd3(); dm.p10 = st.m.bd3()
            _ = st.m.bd()
        }
        if flags1 & 1 == 0 { base |= 128 }
        dm.dxfType = base
        return dm
    }

    func lwpolyline(_ st: inout DWGRStreams) -> DWGRLWPolyline {
        var p = DWGRLWPolyline()
        let f = st.m.bs()
        if f & 4 != 0 { p.constWidth = st.m.bd() }
        if f & 8 != 0 { p.elevation = st.m.bd() }
        if f & 2 != 0 { _ = st.m.bd() }
        if f & 1 != 0 { p.ext = st.m.bd3() }
        let n = st.m.bl()
        var nb = 0, nid = 0, nw = 0
        if f & 16 != 0 { nb = st.m.bl() }
        if r2010 && f & 1024 != 0 { nid = st.m.bl() }
        if f & 32 != 0 { nw = st.m.bl() }
        p.flags70 = (f & 512 != 0 ? 1 : 0) | (f & 256 != 0 ? 128 : 0)
        let count = st.count(n, bitsEach: 4)
        p.points.reserveCapacity(count)
        if r2000 {
            var last: DWGP2 = (0, 0)
            for k in 0..<count {
                if k == 0 { last = st.m.rd2() } else { last = (st.m.dd(last.x), st.m.dd(last.y)) }
                p.points.append(last)
            }
        } else {
            for _ in 0..<count { p.points.append(st.m.rd2()) }
        }
        for _ in 0..<st.count(nb) { p.bulges.append(st.m.bd()) }
        for _ in 0..<st.count(nid) { _ = st.m.bl() }
        for _ in 0..<st.count(nw, bitsEach: 4) { _ = st.m.bd(); _ = st.m.bd() }
        return p
    }

    func hatch(_ st: inout DWGRStreams) -> DWGRHatch {
        var h = DWGRHatch()
        if r2004 {
            _ = st.m.bl(); _ = st.m.bl(); _ = st.m.bd(); _ = st.m.bd(); _ = st.m.bl(); _ = st.m.bd()
            let nc = st.m.bl()
            for _ in 0..<st.count(nc, bitsEach: 8) { _ = st.m.bd(); _ = st.m.bs(); _ = st.m.bl(); _ = st.m.rc() }
            _ = st.tv()
        }
        h.elevation = st.m.bd()
        h.ext = st.m.bd3()
        h.name = st.tv()
        h.solid = st.m.bit()
        h.associative = st.m.bit()
        let np = st.m.bl()
        var anyPixel = false
        var nBoundary = 0
        for _ in 0..<st.count(np, bitsEach: 4) {
            var path = DWGRHatchPath()
            path.flags = st.m.bl()
            if path.flags & 4 != 0 { anyPixel = true }
            if path.flags & 2 == 0 {
                let ne = st.m.bl()
                for _ in 0..<st.count(ne, bitsEach: 8) {
                    let kind = Int(st.m.rc())
                    switch kind {
                    case 1:
                        let a = st.m.rd2(), b = st.m.rd2()
                        path.edges.append(.line(a, b))
                    case 2:
                        let c = st.m.rd2(), r = st.m.bd(), s = st.m.bd(), e = st.m.bd(), ccw = st.m.bit()
                        path.edges.append(.arc(center: c, radius: r, start: s, end: e, ccw: ccw))
                    case 3:
                        let c = st.m.rd2(), mj = st.m.rd2(), ratio = st.m.bd(), s = st.m.bd(), e = st.m.bd(), ccw = st.m.bit()
                        path.edges.append(.ellipse(center: c, major: mj, ratio: ratio, start: s, end: e, ccw: ccw))
                    case 4:
                        let deg = st.m.bl()
                        let rational = st.m.bit(), periodic = st.m.bit()
                        let nk = st.m.bl(), nc = st.m.bl()
                        var knots: [Double] = [], cps: [DWGP2] = [], ws: [Double] = []
                        for _ in 0..<st.count(nk) { knots.append(st.m.bd()) }
                        for _ in 0..<st.count(nc, bitsEach: 16) {
                            cps.append(st.m.rd2())
                            if rational { ws.append(st.m.bd()) }
                        }
                        if r2010 {
                            let nf = st.m.bl()
                            for _ in 0..<st.count(nf, bitsEach: 16) { _ = st.m.rd2() }
                            if nf > 0 { _ = st.m.rd2(); _ = st.m.rd2() }
                        }
                        path.edges.append(.spline(degree: deg, rational: rational, periodic: periodic, knots: knots, control: cps, weights: ws))
                    default:
                        st.m.overflow = true
                    }
                    if st.m.overflow { break }
                }
            } else {
                path.hasBulges = st.m.bit()
                path.closed = st.m.bit()
                let n = st.m.bl()
                for _ in 0..<st.count(n, bitsEach: 16) {
                    let p = st.m.rd2()
                    let b = path.hasBulges ? st.m.bd() : 0
                    path.polyline.append((p, b))
                }
            }
            nBoundary += max(0, st.m.bl())
            h.paths.append(path)
            if st.m.overflow { break }
        }
        h.style = st.m.bs()
        h.patternType = st.m.bs()
        if !h.solid {
            h.angle = st.m.bd()
            h.scale = st.m.bd()
            h.double = st.m.bit()
            let nd = st.m.bs()
            for _ in 0..<st.count(nd, bitsEach: 8) {
                let a = st.m.bd(), b = st.m.bd2(), o = st.m.bd2()
                let n = st.m.bs()
                var dashes: [Double] = []
                for _ in 0..<st.count(n) { dashes.append(st.m.bd()) }
                h.defLines.append((a, b, o, dashes))
            }
        }
        if anyPixel { _ = st.m.bd() }
        let ns = st.m.bl()
        for _ in 0..<st.count(ns, bitsEach: 16) { _ = st.m.rd2() }
        _ = nBoundary
        return h
    }

    // MARK: Table records and objects

    /// Common start of table records: name, 64-flag, xref index, xdep.
    func tableEntry(_ st: inout DWGRStreams) -> (name: String, xdep: Bool) {
        let name = st.tv()
        _ = st.m.bit()
        // R2007+ drops the xref index (verified on AutoCAD 2018 files; the spec lists it).
        if !r2007 { _ = st.m.bs() }
        let xdep = st.m.bit()
        return (name, xdep)
    }

    func blockHeader(_ st: inout DWGRStreams) -> DWGRBlockHeader {
        var b = DWGRBlockHeader()
        let e = tableEntry(&st)
        b.name = e.name
        b.xdep = e.xdep
        b.anonymous = st.m.bit()
        b.hasAttdefs = st.m.bit()
        b.isXref = st.m.bit()
        b.overlaid = st.m.bit()
        if r2000 { _ = st.m.bit() }
        var owned = 0
        if r2004 { owned = st.m.bl() }
        b.base = st.m.bd3()
        _ = st.tv()
        var inserts = 0
        if r2000 {
            while st.m.bitsLeft >= 8 {
                if st.m.rc() == 0 { break }
                inserts += 1
            }
            b.description = st.tv()
            let preview = st.m.bl()
            if preview > 0 { st.m.skipBytes(preview) }
        }
        if r2007 { _ = st.m.bs(); _ = st.m.bit(); _ = st.m.rc() }
        _ = st.hnd()
        b.blockEntity = st.hnd()
        if r2004 {
            b.entities = st.hnds(owned)
        } else if !b.isXref && !b.overlaid {
            b.firstEntity = st.hnd()
            b.lastEntity = st.hnd()
        }
        b.endblk = st.hnd()
        if r2000 {
            _ = st.hnds(inserts)
            b.layout = st.hnd()
        }
        return b
    }

    func layer(_ st: inout DWGRStreams) -> DWGRLayer {
        var l = DWGRLayer()
        l.name = tableEntry(&st).name
        if r2000 {
            let f = st.m.bs()
            l.frozen = f & 1 != 0
            l.on = f & 2 == 0
            l.locked = f & 8 != 0
            l.plot = f & 16 != 0
            l.lineweight = dwgReadLineweight(index: (f & 0x3E0) >> 5)
        } else {
            l.frozen = st.m.bit()
            l.on = st.m.bit()
            _ = st.m.bit()
            l.locked = st.m.bit()
        }
        if r2004 {
            let index = st.m.bs()
            let rgb = UInt32(truncatingIfNeeded: st.m.bl())
            let flags = st.m.rc()
            if flags & 1 != 0 { _ = st.tv() }
            if flags & 2 != 0 { _ = st.tv() }
            l.color = DWGReadColor(fromCMC: rgb, index: abs(index))
            if index < 0 { l.colorIndexNegative = true }
        } else {
            let c = st.m.bs()
            if c < 0 { l.colorIndexNegative = true }
            l.color = .aci(max(1, min(255, abs(c))))
        }
        _ = st.hnd()
        if r2000 { _ = st.hnd() }
        if r2007 { _ = st.hnd() }
        l.ltype = st.hnd()
        return l
    }

    func ltype(_ st: inout DWGRStreams) -> DWGRLtype {
        var t = DWGRLtype()
        t.name = tableEntry(&st).name
        t.description = st.tv()
        _ = st.m.bd()
        _ = st.m.rc()
        let n = Int(st.m.rc())
        var textArea = false
        for _ in 0..<n {
            t.dashes.append(st.m.bd())
            _ = st.m.bs()
            _ = st.m.rd(); _ = st.m.rd()
            _ = st.m.bd(); _ = st.m.bd()
            let sf = st.m.bs()
            if sf & 2 != 0 { textArea = true }
        }
        if !r2007 { st.m.skipBytes(256) } else if textArea { st.m.skipBytes(512) }
        return t
    }

    func dictionary(_ st: inout DWGRStreams) -> [(String, UInt64)] {
        let n = st.m.bl()
        if v == .r14 { _ = st.m.rc() }
        if r2000 { _ = st.m.bs(); _ = st.m.rc() }
        let count = st.count(n, bitsEach: 2)
        var names: [String] = []
        names.reserveCapacity(count)
        for _ in 0..<count { names.append(st.tv()) }
        let hs = st.hnds(count)
        return zip(names, hs).map { ($0, $1) }
    }

    func group(_ st: inout DWGRStreams) -> DWGRGroup {
        var g = DWGRGroup()
        g.description = st.tv()
        g.unnamed = st.m.bs() != 0
        g.selectable = st.m.bs() != 0
        let n = st.m.bl()
        g.members = st.hnds(n)
        return g
    }

    func layout(_ st: inout DWGRStreams) -> DWGRLayout {
        var l = DWGRLayout()
        l.pageSetup = st.tv()
        _ = st.tv()
        _ = st.m.bs()
        l.margins = [st.m.bd(), st.m.bd(), st.m.bd(), st.m.bd()]
        l.width = st.m.bd()
        l.height = st.m.bd()
        l.paperName = st.tv()
        _ = st.m.bd2()
        l.units = st.m.bs()
        l.rotation = st.m.bs()
        _ = st.m.bs()
        _ = st.m.bd2(); _ = st.m.bd2()
        if !r2004 { _ = st.tv() }
        _ = st.m.bd(); _ = st.m.bd()
        _ = st.tv()
        _ = st.m.bs()
        _ = st.m.bd()
        _ = st.m.bd2()
        if r2004 { _ = st.m.bs(); _ = st.m.bs(); _ = st.m.bs() }
        l.name = st.tv()
        l.tabOrder = st.m.bl()
        _ = st.m.bs()
        _ = st.m.bd3()
        l.limMin = st.m.rd2()
        l.limMax = st.m.rd2()
        _ = st.m.bd3(); _ = st.m.bd3(); _ = st.m.bd3()
        _ = st.m.bd()
        _ = st.m.bs()
        _ = st.m.bd3(); _ = st.m.bd3()
        if r2004 { _ = st.m.bl() }   // viewport count (BL; the spec says RL)
        if r2004 { _ = st.hnd() }
        if r2007 { _ = st.hnd() }
        l.blockRecord = st.hnd()
        return l
    }

    func field(_ st: inout DWGRStreams) -> DWGRField {
        var f = DWGRField()
        f.evaluator = st.tv()
        f.code = st.tv()
        let nc = st.m.bl()
        f.children = st.hnds(nc)
        let no = st.m.bl()
        _ = st.hnds(no)
        if !r2007 { _ = st.tv() }
        _ = st.m.bl(); _ = st.m.bl(); _ = st.m.bl(); _ = st.m.bl(); _ = st.m.bl()
        _ = st.tv()
        f.value = fieldValue(&st)
        let s301 = st.tv()
        if f.value.isEmpty { f.value = s301 }
        _ = st.m.bl()                      // value string length
        let nChild = st.m.bl()
        for _ in 0..<st.count(nChild, bitsEach: 4) {
            _ = st.tv()
            _ = fieldValue(&st)
        }
        return f
    }

    /// Field value (spec 20.4.99); returns the value string.
    func fieldValue(_ st: inout DWGRStreams) -> String {
        var flags = 0
        if r2007 { flags = st.m.bl() }
        let type = st.m.bl()
        var str = ""
        if flags & 1 == 0 {
            switch type {
            case 1: _ = st.m.bl()
            case 2: _ = st.m.bd()
            case 4: str = st.tv()
            case 8, 16, 32, 512:
                let n = st.m.bl()
                st.m.skipBytes(n)
            case 64: _ = st.hnd()
            case 0: _ = st.m.bl()
            default: break
            }
        }
        if r2007 {
            _ = st.m.bl()
            _ = st.tv()
            let valueString = st.tv()
            if !valueString.isEmpty { return valueString }
        }
        return str
    }
}
