import Foundation

/// Non-entity objects (control objects, table records, dictionaries, layouts, groups),
/// the header variables section and the classes section.
extension DWGWriterImpl {

    // MARK: Control objects

    mutating func encodeControlObjects() {
        func control(_ type: Int, _ handle: UInt32, _ entries: [UInt32], hard: [UInt32] = []) {
            var o = DWGWObj.object(type: type, handle: handle, owner: 0)
            o.d.bl(entries.count)
            for e in entries { o.hs.h(2, e) }
            for e in hard { o.hs.h(3, e) }
            emit(handle, o.finish())
        }
        let ms = blocks[0].record, ps = blocks[1].record
        control(0x30, DWGWH.blockControl, blocks.dropFirst(2).map(\.record), hard: [ms, ps])
        control(0x32, DWGWH.layerControl, layers.map(\.handle))
        control(0x34, DWGWH.styleControl, styles.map(\.handle))
        control(0x38, DWGWH.ltypeControl, [DWGWH.ltContinuous] + ltypes.map(\.handle), hard: [DWGWH.ltByLayer, DWGWH.ltByBlock])
        control(0x3C, DWGWH.viewControl, [])
        control(0x3E, DWGWH.ucsControl, [])
        control(0x40, DWGWH.vportControl, [DWGWH.vportActive])
        control(0x42, DWGWH.appidControl, [DWGWH.appidACAD])
        control(0x44, DWGWH.dimstyleControl, [DWGWH.dimstyleStandard])
        control(0x46, DWGWH.vxControl, [])
    }

    // MARK: Table records

    /// Common table record start: name, 64-flag, xref index + 1, xref-dependent.
    func tableRecord(_ type: Int, _ handle: UInt32, control: UInt32, name: String) -> DWGWObj {
        var o = DWGWObj.object(type: type, handle: handle, owner: control)
        o.d.t(name)
        o.d.b(false); o.d.bs(0); o.d.b(false)
        return o
    }

    mutating func encodeTableRecords() {
        let d = drawing
        // LTYPE
        func ltype(_ h: UInt32, _ name: String, _ desc: String, _ pattern: [Double]) {
            var o = tableRecord(0x39, h, control: DWGWH.ltypeControl, name: name)
            o.d.t(desc)
            o.d.bd(pattern.reduce(0) { $0 + abs($1) })
            o.d.rc(65)
            o.d.rc(UInt8(min(pattern.count, 255)))
            for v in pattern.prefix(255) {
                o.d.bd(v); o.d.bs(0); o.d.rd(0); o.d.rd(0); o.d.bd(1); o.d.bd(0); o.d.bs(0)
            }
            o.d.rawBytes([UInt8](repeating: 0, count: 256))
            o.hs.h(5, 0)
            for _ in pattern.prefix(255) { o.hs.h(5, 0) }
            emit(h, o.finish())
        }
        ltype(DWGWH.ltByBlock, "ByBlock", "", [])
        ltype(DWGWH.ltByLayer, "ByLayer", "", [])
        ltype(DWGWH.ltContinuous, "Continuous", "Solid line", [])
        for (lt, h) in ltypes { ltype(h, lt.name, lt.description, lt.pattern) }

        // LAYER
        for (l, h) in layers {
            var o = tableRecord(0x33, h, control: DWGWH.layerControl, name: l.name)
            var aci = 7
            switch l.color {
            case .aci(let i): aci = min(max(i, 1), 255)
            case .rgb(let c): aci = nearestACI(c)
            default: break
            }
            let lw = DWGWriterImpl.lineweightIndex(l.lineweight, negative: 31)
            // Bit 2 marks a layer that is OFF in AutoCAD-written files (the spec calls it "on").
            let flags = (l.isFrozen ? 1 : 0) | (l.isOn ? 0 : 2) | (l.isLocked ? 8 : 0) | (l.isPlottable ? 16 : 0) | (lw << 5)
            o.d.bs(flags)
            o.d.cmc(l.isOn ? aci : -aci)
            o.hs.h(5, 0)                                // xref block
            o.hs.h(5, DWGWH.placeholder)                // plot style "Normal"
            o.hs.h(5, ltypeByName[l.linetype.uppercased()] ?? DWGWH.ltContinuous)
            o.hs.h(5, 0)
            emit(h, o.finish())
        }

        // STYLE
        for (s, h) in styles {
            var o = tableRecord(0x35, h, control: DWGWH.styleControl, name: s)
            o.d.b(false); o.d.b(false)                  // vertical, shape file
            o.d.bd(0); o.d.bd(1); o.d.bd(0)             // fixed height, width factor, oblique
            o.d.rc(0)                                   // generation
            o.d.bd(d.settings.textHeight > 0 ? d.settings.textHeight : 2.5)
            o.d.t("txt"); o.d.t("")
            o.hs.h(5, 0)
            emit(h, o.finish())
        }

        // APPID
        do {
            var o = tableRecord(0x43, DWGWH.appidACAD, control: DWGWH.appidControl, name: "ACAD")
            o.d.rc(0)
            o.hs.h(5, 0)
            emit(DWGWH.appidACAD, o.finish())
        }

        // DIMSTYLE
        do {
            let ds = d.settings.dimStyle
            var o = tableRecord(0x45, DWGWH.dimstyleStandard, control: DWGWH.dimstyleControl, name: "Standard")
            o.d.t(""); o.d.t("")                        // DIMPOST, DIMAPOST
            o.d.bd(ds.scale); o.d.bd(ds.arrowSize); o.d.bd(ds.extensionOffset); o.d.bd(3.75)
            o.d.bd(ds.extensionExtend); o.d.bd(0); o.d.bd(0); o.d.bd(0); o.d.bd(0)
            for _ in 0..<6 { o.d.b(false) }             // DIMTOL..DIMSE2
            o.d.bs(1); o.d.bs(8); o.d.bs(0)             // DIMTAD, DIMZIN, DIMAZIN
            o.d.bd(ds.textHeight); o.d.bd(2.5); o.d.bd(0); o.d.bd(0.03937007874)
            o.d.bd(1); o.d.bd(0); o.d.bd(1); o.d.bd(ds.textGap)
            o.d.bd(0)                                   // DIMALTRND
            o.d.b(false); o.d.bs(2)                     // DIMALT, DIMALTD
            o.d.b(true); o.d.b(false); o.d.b(false); o.d.b(false) // DIMTOFL, DIMSAH, DIMTIX, DIMSOXD
            o.d.bs(0); o.d.bs(0); o.d.bs(0)             // DIMCLRD/E/T ByBlock
            o.d.bs(0)                                   // DIMADEC
            o.d.bs(ds.precision); o.d.bs(ds.precision)  // DIMDEC, DIMTDEC
            o.d.bs(2); o.d.bs(2); o.d.bs(0); o.d.bs(0)  // DIMALTU, DIMALTTD, DIMAUNIT, DIMFRAC
            o.d.bs(2); o.d.bs(46); o.d.bs(0); o.d.bs(0) // DIMLUNIT, DIMDSEP '.', DIMTMOVE, DIMJUST
            o.d.b(false); o.d.b(false)                  // DIMSD1, DIMSD2
            o.d.bs(1); o.d.bs(0); o.d.bs(0); o.d.bs(0)  // DIMTOLJ, DIMTZIN, DIMALTZ, DIMALTTZ
            o.d.b(false)                                // DIMUPT
            o.d.bs(3)                                   // DIMFIT (DIMATFIT)
            o.d.bs(-2); o.d.bs(-2)                      // DIMLWD, DIMLWE
            o.d.b(false)
            o.hs.h(5, 0)
            o.hs.h(5, styleByName["STANDARD"]!)         // DIMTXSTY
            for _ in 0..<4 { o.hs.h(5, 0) }             // DIMLDRBLK, DIMBLK, DIMBLK1, DIMBLK2
            emit(DWGWH.dimstyleStandard, o.finish())
        }

        // VPORT *Active
        do {
            let ext = d.extents(of: d.modelEntities)
            let vb = ext.isEmpty ? BBox(min: d.settings.limitsMin, max: d.settings.limitsMax) : ext
            let height = max(vb.height, vb.width / 1.5, 1) * 1.1
            var o = tableRecord(0x41, DWGWH.vportActive, control: DWGWH.vportControl, name: "*Active")
            o.d.bd(height); o.d.bd(height * 1.5)
            o.d.rd2(vb.center)
            o.d.bd3(0, 0, 0); o.d.bd3(0, 0, 1)
            o.d.bd(0); o.d.bd(50); o.d.bd(0); o.d.bd(0)
            o.d.b(false); o.d.b(false); o.d.b(false); o.d.b(true) // view mode
            o.d.rc(0)                                   // render mode
            o.d.rd2(.zero); o.d.rd2(Vec2(1, 1))
            o.d.b(false)                                // UCSFOLLOW
            o.d.bs(1000)                                // circle zoom
            o.d.b(true)                                 // fast zoom
            o.d.b(true); o.d.b(true)                    // UCSICON
            o.d.b(false)                                // grid off
            o.d.rd2(Vec2(d.settings.gridSpacing, d.settings.gridSpacing))
            o.d.b(false); o.d.b(false)                  // snap off, standard style
            o.d.bs(0); o.d.bd(0)                        // isopair, snap rotation
            o.d.rd2(.zero)
            o.d.rd2(Vec2(d.settings.snapSpacing, d.settings.snapSpacing))
            o.d.b(false); o.d.b(false)                  // unknown, UCS per viewport
            o.d.bd3(0, 0, 0); o.d.bd3(1, 0, 0); o.d.bd3(0, 1, 0)
            o.d.bd(0); o.d.bs(0)
            o.hs.h(5, 0)                                // xref block
            o.hs.h(5, 0); o.hs.h(5, 0)                  // named UCS, base UCS
            emit(DWGWH.vportActive, o.finish())
        }
    }

    // MARK: Dictionaries, layouts, groups

    func dictionary(_ handle: UInt32, owner: UInt32, entries: [(String, UInt32)], type: Int = 0x2A,
                    defaultEntry: UInt32? = nil) -> [UInt8] {
        var o = DWGWObj.object(type: type, handle: handle, owner: owner, reactors: owner == 0 ? [] : [owner])
        o.d.bl(entries.count)
        o.d.bs(1)                                       // cloning: keep existing
        o.d.rc(0)                                       // not hard owner
        for (n, _) in entries { o.d.t(n) }
        for (_, h) in entries { o.hs.h(2, h) }
        if let def = defaultEntry { o.hs.h(5, def) }
        return o.finish()
    }

    mutating func encodeDictionaries() {
        emit(DWGWH.nod, dictionary(DWGWH.nod, owner: 0, entries: [
            ("ACAD_GROUP", DWGWH.groupDict), ("ACAD_LAYOUT", DWGWH.layoutDict), ("ACAD_MLINESTYLE", DWGWH.mlineDict),
            ("ACAD_PLOTSETTINGS", DWGWH.plotSettingsDict), ("ACAD_PLOTSTYLENAME", DWGWH.plotStyleDict),
        ]))
        emit(DWGWH.groupDict, dictionary(DWGWH.groupDict, owner: DWGWH.nod, entries: groups.map { ($0.group.name, $0.handle) }))
        emit(DWGWH.layoutDict, dictionary(DWGWH.layoutDict, owner: DWGWH.nod, entries: layoutObjs.map { ($0.name, $0.handle) }))
        emit(DWGWH.mlineDict, dictionary(DWGWH.mlineDict, owner: DWGWH.nod, entries: [("Standard", DWGWH.mlineStandard)]))
        emit(DWGWH.plotSettingsDict, dictionary(DWGWH.plotSettingsDict, owner: DWGWH.nod, entries: []))
        emit(DWGWH.plotStyleDict, dictionary(DWGWH.plotStyleDict, owner: DWGWH.nod, entries: [("Normal", DWGWH.placeholder)],
                                             type: DWGWClass.dictionaryWithDefault, defaultEntry: DWGWH.placeholder))
        // PLACEHOLDER "Normal"
        let ph = DWGWObj.object(type: DWGWClass.placeholder, handle: DWGWH.placeholder, owner: DWGWH.plotStyleDict,
                                reactors: [DWGWH.plotStyleDict])
        emit(DWGWH.placeholder, ph.finish())

        // MLINESTYLE "Standard"
        do {
            var o = DWGWObj.object(type: 0x49, handle: DWGWH.mlineStandard, owner: DWGWH.mlineDict, reactors: [DWGWH.mlineDict])
            o.d.t("Standard"); o.d.t("")
            o.d.bs(0)
            o.d.cmc(256)
            o.d.bd(.pi / 2); o.d.bd(.pi / 2)
            o.d.rc(2)
            for off in [0.5, -0.5] { o.d.bd(off); o.d.cmc(256); o.d.bs(32767) }
            emit(DWGWH.mlineStandard, o.finish())
        }

        for l in layoutObjs { encodeLayout(l) }

        for (g, h) in groups {
            var o = DWGWObj.object(type: 0x48, handle: h, owner: DWGWH.groupDict, reactors: [DWGWH.groupDict])
            let members = g.members.compactMap { entityHandles[$0] }
            o.d.t(g.description)
            o.d.bs(g.name.hasPrefix("*") ? 1 : 0)
            o.d.bs(g.isSelectable ? 1 : 0)
            o.d.bl(members.count)
            for m in members { o.hs.h(5, m) }
            emit(h, o.finish())
        }
    }

    mutating func encodeLayout(_ l: DWGWLayout) {
        let p = l.paper
        let m = p.margins.count == 4 ? p.margins : [0, 0, 0, 0]
        var o = DWGWObj.object(type: DWGWClass.layout, handle: l.handle, owner: DWGWH.layoutDict, reactors: [DWGWH.layoutDict])
        // AcDbPlotSettings
        o.d.t("")                                       // page setup name
        o.d.t("none_device")
        o.d.bs(688)
        o.d.bd(m[0]); o.d.bd(m[1]); o.d.bd(m[2]); o.d.bd(m[3])
        o.d.bd(p.width); o.d.bd(p.height)
        o.d.t(p.name.replacingOccurrences(of: " ", with: "_"))
        o.d.bd2(.zero)                                  // plot origin
        o.d.bs(1); o.d.bs(0); o.d.bs(5)                 // mm, no rotation, plot layout
        o.d.bd2(.zero); o.d.bd2(.zero)                  // plot window
        o.d.t("")                                       // plot view name
        o.d.bd(1); o.d.bd(1)                            // custom scale 1:1
        o.d.t("")                                       // style sheet
        o.d.bs(16); o.d.bd(1)                           // scale type 1:1, factor
        o.d.bd2(.zero)                                  // paper image origin
        // AcDbLayout
        o.d.t(l.name)
        o.d.bl(l.tabOrder)
        o.d.bs(1)
        o.d.bd3(0, 0, 0)                                // UCS origin
        o.d.rd2(l.limits.min); o.d.rd2(l.limits.max)
        o.d.bd3(0, 0, 0)                                // insertion base
        o.d.bd3(1, 0, 0); o.d.bd3(0, 1, 0)
        o.d.bd(0); o.d.bs(0)
        o.d.bd3(l.extents.min); o.d.bd3(l.extents.max)
        o.hs.h(4, l.record)
        o.hs.h(4, l.lastViewport)
        o.hs.h(5, 0); o.hs.h(5, 0)                      // base UCS, named UCS
        emit(l.handle, o.finish())
    }

    // MARK: Header variables (spec chapter 9, R2000 subset)

    func headerVariablesSection() -> [UInt8] {
        let d = drawing
        let s = d.settings
        let ds = s.dimStyle
        var w = DWGBitWriter()
        w.bd(412148564080.0); w.bd(1); w.bd(1); w.bd(1)
        w.t(""); w.t(""); w.t(""); w.t("")
        w.bl(24); w.bl(0)
        w.h(5, 0)                                       // current viewport entity header
        w.b(true); w.b(true)                            // DIMASO, DIMSHO
        w.b(false); w.b(false); w.b(true); w.b(true)    // PLINEGEN, ORTHOMODE, REGENMODE, FILLMODE
        w.b(false); w.b(true); w.b(false)               // QTEXTMODE, PSLTSCALE, LIMCHECK
        w.b(true); w.b(false); w.b(false); w.b(false)   // USRTIMER, SKPOLY, ANGDIR, SPLFRAME
        w.b(false); w.b(true)                           // MIRRTEXT, WORLDVIEW
        w.b(true); w.b(false); w.b(true)                // TILEMODE, PLIMCHECK, VISRETAIN
        w.b(false); w.b(false)                          // DISPSILH, PELLIPSE
        w.bs(1)                                         // PROXYGRAPHICS
        w.bs(3020)                                      // TREEDEPTH
        w.bs(s.units.rawValue); w.bs(s.unitPrecision)   // LUNITS, LUPREC
        w.bs(0); w.bs(0)                                // AUNITS, AUPREC
        w.bs(1)                                         // ATTMODE
        w.bs(0)                                         // PDMODE
        for _ in 0..<5 { w.bs(0) }                      // USERI1-5
        w.bs(8); w.bs(6); w.bs(6); w.bs(6); w.bs(6); w.bs(6) // SPLINESEGS, SURFU, SURFV, SURFTYPE, SURFTAB1, SURFTAB2
        w.bs(6); w.bs(3); w.bs(70); w.bs(0); w.bs(64)   // SPLINETYPE, SHADEDGE, SHADEDIF, UNITMODE, MAXACTVP
        w.bs(4); w.bs(0); w.bs(50)                      // ISOLINES, CMLJUST, TEXTQLTY
        w.bd(s.ltScale > 0 ? s.ltScale : 1)
        w.bd(s.textHeight > 0 ? s.textHeight : 2.5)
        w.bd(1); w.bd(1)                                // TRACEWID, SKETCHINC
        w.bd(s.filletRadius); w.bd(0); w.bd(0)          // FILLETRAD, THICKNESS, ANGBASE
        w.bd(s.pointSize); w.bd(0)                      // PDSIZE, PLINEWID
        for _ in 0..<5 { w.bd(0) }                      // USERR1-5
        w.bd(s.chamferDist1); w.bd(s.chamferDist2); w.bd(0); w.bd(0) // CHAMFERA-D
        w.bd(0.5); w.bd(20); w.bd(1)                    // FACETRES, CMLSCALE, CELTSCALE
        w.t("acad")                                     // MENUNAME
        let (jd, ms) = DWGWriterImpl.julian(Date())
        w.bl(jd); w.bl(ms); w.bl(jd); w.bl(ms)          // TDCREATE, TDUPDATE
        w.bl(0); w.bl(0); w.bl(0); w.bl(0)              // TDINDWG, TDUSRTIMER
        w.cmc(DWGWriterImpl.colorIndex(s.currentColor))
        w.h(0, nextHandle)                              // HANDSEED
        w.h(5, layerHandle(s.currentLayer))
        w.h(5, styleHandle(s.textStyle))
        let celtype = s.currentLinetype.uppercased()
        w.h(5, celtype == "BYBLOCK" ? DWGWH.ltByBlock : (ltypeByName[celtype] ?? DWGWH.ltByLayer))
        w.h(5, DWGWH.dimstyleStandard)
        w.h(5, DWGWH.mlineStandard)
        w.bd(0)                                         // PSVPSCALE

        // Paper space.
        let first = layoutObjs.count > 1 ? layoutObjs[1] : layoutObjs[0]
        let pext = first.extents
        w.bd3(0, 0, 0)
        w.bd3(pext.min); w.bd3(pext.max)
        w.rd2(.zero); w.rd2(Vec2(first.paper.width, first.paper.height))
        w.bd(0)
        w.bd3(0, 0, 0); w.bd3(1, 0, 0); w.bd3(0, 1, 0)
        w.h(5, 0)                                       // UCSNAME
        w.h(5, 0); w.bs(0); w.h(5, 0)                   // PUCSORTHOREF, PUCSORTHOVIEW, PUCSBASE
        for _ in 0..<6 { w.bd3(0, 0, 0) }

        // Model space.
        let ext = d.extents(of: d.modelEntities)
        w.bd3(0, 0, 0)
        if ext.isEmpty { w.bd3(1e20, 1e20, 1e20); w.bd3(-1e20, -1e20, -1e20) } else { w.bd3(ext.min); w.bd3(ext.max) }
        w.rd2(s.limitsMin); w.rd2(s.limitsMax)
        w.bd(0)
        w.bd3(0, 0, 0); w.bd3(1, 0, 0); w.bd3(0, 1, 0)
        w.h(5, 0)
        w.h(5, 0); w.bs(0); w.h(5, 0)
        for _ in 0..<6 { w.bd3(0, 0, 0) }

        // Dimension variables.
        w.t(ds.suffix.isEmpty ? "" : "<>" + ds.suffix); w.t("")   // DIMPOST, DIMAPOST
        w.bd(ds.scale); w.bd(ds.arrowSize); w.bd(ds.extensionOffset); w.bd(3.75)   // DIMSCALE, DIMASZ, DIMEXO, DIMDLI
        w.bd(ds.extensionExtend); w.bd(0); w.bd(0); w.bd(0); w.bd(0)          // DIMEXE, DIMRND, DIMDLE, DIMTP, DIMTM
        for _ in 0..<6 { w.b(false) }                   // DIMTOL, DIMLIM, DIMTIH, DIMTOH, DIMSE1, DIMSE2
        w.bs(1); w.bs(8); w.bs(0)                       // DIMTAD, DIMZIN, DIMAZIN
        w.bd(ds.textHeight); w.bd(2.5); w.bd(0); w.bd(0.03937007874) // DIMTXT, DIMCEN, DIMTSZ, DIMALTF
        w.bd(1); w.bd(0); w.bd(1); w.bd(ds.textGap)     // DIMLFAC, DIMTVP, DIMTFAC, DIMGAP
        w.bd(0)                                         // DIMALTRND
        w.b(false); w.bs(2)                             // DIMALT, DIMALTD
        w.b(true); w.b(false); w.b(false); w.b(false)   // DIMTOFL, DIMSAH, DIMTIX, DIMSOXD
        w.cmc(0); w.cmc(0); w.cmc(0)                    // DIMCLRD, DIMCLRE, DIMCLRT
        w.bs(0); w.bs(ds.precision); w.bs(ds.precision) // DIMADEC, DIMDEC, DIMTDEC
        w.bs(2); w.bs(2); w.bs(0); w.bs(0)              // DIMALTU, DIMALTTD, DIMAUNIT, DIMFRAC
        w.bs(2); w.bs(46); w.bs(0); w.bs(0)             // DIMLUNIT, DIMDSEP, DIMTMOVE, DIMJUST
        w.b(false); w.b(false)                          // DIMSD1, DIMSD2
        w.bs(1); w.bs(0); w.bs(0); w.bs(0)              // DIMTOLJ, DIMTZIN, DIMALTZ, DIMALTTZ
        w.b(false)                                      // DIMUPT
        w.bs(3)                                         // DIMATFIT
        w.h(5, styleByName["STANDARD"]!)                // DIMTXSTY
        for _ in 0..<4 { w.h(5, 0) }                    // DIMLDRBLK, DIMBLK, DIMBLK1, DIMBLK2
        w.bs(-2); w.bs(-2)                              // DIMLWD, DIMLWE

        // Control objects and dictionaries.
        for h in [DWGWH.blockControl, DWGWH.layerControl, DWGWH.styleControl, DWGWH.ltypeControl, DWGWH.viewControl,
                  DWGWH.ucsControl, DWGWH.vportControl, DWGWH.appidControl, DWGWH.dimstyleControl, DWGWH.vxControl] {
            w.h(3, h)
        }
        w.h(5, DWGWH.groupDict)
        w.h(5, DWGWH.mlineDict)
        w.h(3, DWGWH.nod)
        w.bs(1); w.bs(70)                               // TSTACKALIGN, TSTACKSIZE
        w.t(""); w.t("")                                // HYPERLINKBASE, STYLESHEET
        w.h(5, DWGWH.layoutDict)
        w.h(5, DWGWH.plotSettingsDict)
        w.h(5, DWGWH.plotStyleDict)
        // CELWEIGHT (index) | LWDISPLAY off | EXTNAMES | PSTYLEMODE (color dependent).
        let celweight = DWGWriterImpl.lineweightIndex(s.currentLineweight, negative: 29)
        w.bl(celweight | 0x0200 | 0x0800 | 0x2000)
        w.bs(s.insUnits.rawValue)
        w.bs(0)                                         // CEPSNTYPE ByLayer
        w.t("{" + UUID().uuidString + "}")              // FINGERPRINTGUID
        w.t("{" + UUID().uuidString + "}")              // VERSIONGUID
        w.h(5, paperSpaceRecord)
        w.h(5, modelSpaceRecord)
        w.h(5, DWGWH.ltByLayer)
        w.h(5, DWGWH.ltByBlock)
        w.h(5, DWGWH.ltContinuous)
        // Four undocumented shorts (spec: "R14+ unknown"); values as found in an AutoCAD-written file.
        for v in [22133, -24364, -26160, 28343] { w.bs(v) }

        var sizeW = DWGBitWriter()
        sizeW.rl(w.bytes.count)
        let body = sizeW.bytes + w.bytes
        let crc = DWGBitWriter.crc(0xC0C1, body)
        return DWGWriterImpl.headerStart + body + [UInt8(crc & 0xFF), UInt8(crc >> 8)] + DWGWriterImpl.headerEnd
    }

    // MARK: Classes (spec 10.1)

    func classesSection() -> [UInt8] {
        var w = DWGBitWriter()
        for (i, c) in DWGWClass.all.enumerated() {
            w.bs(500 + i)
            w.bs(0)                                     // proxy flags
            w.t(c.2); w.t(c.1); w.t(c.0)
            w.b(false)                                  // was a zombie
            w.bs(c.3 ? 0x1F2 : 0x1F3)
        }
        var sizeW = DWGBitWriter()
        sizeW.rl(w.bytes.count)
        let body = sizeW.bytes + w.bytes
        let crc = DWGBitWriter.crc(0xC0C1, body)
        return DWGWriterImpl.classesStart + body + [UInt8(crc & 0xFF), UInt8(crc >> 8)] + DWGWriterImpl.classesEnd
    }
}
