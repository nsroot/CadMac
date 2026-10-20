import Foundation

/// The header variables CadMac uses (spec chapter 9).
struct DWGRHeader {
    var ltScale = 1.0
    var textSize = 2.5
    var filletRad = 0.0
    var pdSize = 0.0
    var lunits = 2
    var luprec = 4
    var clayer: UInt64 = 0
    var limMin: DWGP2 = (0, 0), limMax: DWGP2 = (420, 297)
    var pLimMin: DWGP2 = (0, 0), pLimMax: DWGP2 = (0, 0)
    var dimScale = 1.0, dimAsz = 2.5, dimExo = 0.625, dimExe = 1.25, dimTxt = 2.5, dimGap = 0.625
    var dimDec = 2
    var insUnits = 0
    var hasInsUnits = false
    var blockControl: UInt64 = 0, layerControl: UInt64 = 0, styleControl: UInt64 = 0, ltypeControl: UInt64 = 0
    var groupDictionary: UInt64 = 0, namedObjects: UInt64 = 0, layoutDictionary: UInt64 = 0
    var paperSpace: UInt64 = 0, modelSpace: UInt64 = 0
    var ok = false
}

extension DWGRDecoder {
    func readHeader() -> DWGRHeader {
        var hv = DWGRHeader()
        let d = file.header
        guard d.count > 24 else { return hv }
        let size = Int(dwgReadLE32(d, 16))
        var m: DWGBitReader
        var s: DWGBitReader
        var h: DWGBitReader
        if r2007 {
            let hasHi = r2018 || (r2010 && file.maintenance > 3)
            let bitsField = hasHi ? 24 : 20
            let endbit = bitsField * 8 + Int(dwgReadLE32(d, bitsField))
            guard endbit <= d.count * 8 else { return hv }
            let strStart = DWGRDecoder.stringStreamStart(d, endbit: endbit) ?? (endbit - 1)
            m = DWGBitReader(d, bit: (bitsField + 4) * 8, end: strStart)
            s = DWGBitReader(d, bit: strStart, end: endbit)
            h = DWGBitReader(d, bit: endbit, end: min(d.count, 20 + size + (hasHi ? 4 : 0)) * 8)
        } else {
            let start = (r2010 && file.maintenance > 3) ? 24 : 20
            m = DWGBitReader(d, bit: start * 8, end: min(d.count, 20 + size) * 8)
            s = m
            h = m
        }
        let inline = !r2007
        let enc = file.encoding
        func tv() -> String {
            if inline { return m.text8(enc) }
            return s.textU()
        }
        func hnd() -> UInt64 {
            if inline { return m.handleRef().value }
            return h.handleRef().value
        }
        func cmc() {
            if r2004 {
                _ = m.bs(); _ = m.bl()
                let f = m.rc()
                if f & 1 != 0 { _ = tv() }
                if f & 2 != 0 { _ = tv() }
            } else {
                _ = m.bs()
            }
        }
        func b(_ n: Int) { for _ in 0..<n { _ = m.bit() } }
        func bs(_ n: Int) { for _ in 0..<n { _ = m.bs() } }
        func bl(_ n: Int) { for _ in 0..<n { _ = m.bl() } }
        func bd(_ n: Int) { for _ in 0..<n { _ = m.bd() } }
        func p3(_ n: Int) { for _ in 0..<n { _ = m.bd3() } }

        if r2013 { _ = m.bll() }
        bd(4)
        for _ in 0..<4 { _ = tv() }
        bl(2)
        if r13_14 { bs(1) }
        if !r2004 { _ = hnd() }
        b(2)                          // DIMASO, DIMSHO
        if r13_14 { b(1) }            // DIMSAV
        b(7)                          // PLINEGEN .. LIMCHECK
        if r13_14 { b(1) }            // BLIPMODE
        if r2004 { b(1) }
        b(4)                          // USRTIMER, SKPOLY, ANGDIR, SPLFRAME
        if r13_14 { b(2) }            // ATTREQ, ATTDIA
        b(2)                          // MIRRTEXT, WORLDVIEW
        if r13_14 { b(1) }            // WIREFRAME
        b(3)                          // TILEMODE, PLIMCHECK, VISRETAIN
        if r13_14 { b(1) }            // DELOBJ
        b(2)                          // DISPSILH, PELLIPSE
        bs(1)                         // PROXYGRAPHICS
        if r13_14 { bs(1) }           // DRAGMODE
        bs(1)                         // TREEDEPTH
        hv.lunits = m.bs()
        hv.luprec = m.bs()
        bs(2)                         // AUNITS, AUPREC
        if r13_14 { bs(1) }           // OSMODE
        bs(1)                         // ATTMODE
        if r13_14 { bs(1) }           // COORDS
        bs(1)                         // PDMODE
        if r13_14 { bs(1) }           // PICKSTYLE
        if r2004 { bl(3) }
        bs(19)                        // USERI1 .. TEXTQLTY
        hv.ltScale = m.bd()
        hv.textSize = m.bd()
        bd(2)                         // TRACEWID, SKETCHINC
        hv.filletRad = m.bd()
        bd(2)                         // THICKNESS, ANGBASE
        hv.pdSize = m.bd()
        bd(13)                        // PLINEWID .. CELTSCALE
        _ = tv()                      // MENUNAME
        bl(4)
        if r2004 { bl(3) }
        bl(4)
        cmc()                         // CECOLOR
        _ = m.handleRef()             // HANDSEED (data stream)
        hv.clayer = hnd()
        _ = hnd(); _ = hnd()          // TEXTSTYLE, CELTYPE
        if r2007 { _ = hnd() }        // CMATERIAL
        _ = hnd(); _ = hnd()          // DIMSTYLE, CMLSTYLE
        if r2000 { bd(1) }            // PSVPSCALE
        p3(3)                         // PINSBASE, PEXTMIN, PEXTMAX
        hv.pLimMin = m.rd2()
        hv.pLimMax = m.rd2()
        bd(1)
        p3(3)
        _ = hnd()
        if r2000 {
            _ = hnd(); bs(1); _ = hnd(); p3(6)
        }
        p3(3)                         // INSBASE, EXTMIN, EXTMAX
        hv.limMin = m.rd2()
        hv.limMax = m.rd2()
        bd(1)
        p3(3)
        _ = hnd()
        if r2000 {
            _ = hnd(); bs(1); _ = hnd(); p3(6)
            _ = tv(); _ = tv()        // DIMPOST, DIMAPOST
        }
        if r13_14 {
            b(11)
            _ = m.rc(); _ = m.rc()
            b(2)
            _ = m.rc(); _ = m.rc(); _ = m.rc()
            b(1)
            for _ in 0..<4 { _ = m.rc() }
            bs(2)
            hv.dimDec = m.bs()
            bs(3)
            _ = hnd()
        }
        hv.dimScale = m.bd()
        hv.dimAsz = m.bd()
        hv.dimExo = m.bd()
        bd(1)
        hv.dimExe = m.bd()
        bd(4)                         // DIMRND, DIMDLE, DIMTP, DIMTM
        if r2007 { bd(2); bs(1); cmc() }
        if r2000 { b(6); bs(3) }
        if r2007 { bs(1) }
        hv.dimTxt = m.bd()
        bd(6)                         // DIMCEN .. DIMTFAC
        hv.dimGap = m.bd()
        if r13_14 { for _ in 0..<5 { _ = tv() } }
        if r2000 {
            bd(1); b(1); bs(1); b(4)
        }
        cmc(); cmc(); cmc()
        if r2000 {
            bs(1)
            hv.dimDec = m.bs()
            bs(9)                     // DIMTDEC .. DIMJUST
            b(2)
            bs(4)
            b(1)
            bs(1)
        }
        if r2007 { b(1) }
        if r2010 { b(1); bd(1); _ = tv(); bd(1); _ = tv() }
        if r2000 { for _ in 0..<5 { _ = hnd() } }
        if r2007 { for _ in 0..<3 { _ = hnd() } }
        if r2000 { bs(2) }
        hv.blockControl = hnd()
        hv.layerControl = hnd()
        hv.styleControl = hnd()
        hv.ltypeControl = hnd()
        for _ in 0..<5 { _ = hnd() }  // VIEW, UCS, VPORT, APPID, DIMSTYLE controls
        if !r2004 { _ = hnd() }       // VIEWPORT ENTITY HEADER control (R13-R15)
        hv.groupDictionary = hnd()
        _ = hnd()                     // ACAD_MLINESTYLE
        hv.namedObjects = hnd()
        if r2000 {
            bs(2)
            _ = tv(); _ = tv()
            hv.layoutDictionary = hnd()
            _ = hnd(); _ = hnd()
        }
        if r2004 { _ = hnd(); _ = hnd() }
        if r2007 { _ = hnd() }
        if r2013 { _ = hnd() }
        if r2000 {
            bl(1)
            hv.insUnits = m.bs()
            hv.hasInsUnits = true
            let cepsn = m.bs()
            if cepsn == 3 { _ = hnd() }
            _ = tv(); _ = tv()
        }
        if r2004 {
            for _ in 0..<6 { _ = m.rc() }
            bs(2)
            _ = m.rc(); _ = m.rc()
            _ = tv()
        }
        hv.paperSpace = hnd()
        hv.modelSpace = hnd()
        hv.ok = !m.overflow && !h.overflow
        return hv
    }
}
