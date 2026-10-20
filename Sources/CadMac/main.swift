import AppKit
import CadCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let menu = MenuBuilder.build()
        Loc.localize(menu)
        NSApp.mainMenu = menu
        Loc.installWindowObserver()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        AutomationServer.shared.start()
        AutoSaveManager.shared.start()
        if ProcessInfo.processInfo.environment["CADMAC_SCRIPT"] == nil {
            DispatchQueue.main.async { AutoSaveManager.shared.offerRecovery() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.runAutomation() }
    }

    /// Test hook: CADMAC_SCRIPT="LINE;0,0;100,0;;" runs commands (';' = Enter),
    /// CADMAC_SNAPSHOT=/path.png saves the window, CADMAC_EXIT=1 quits afterwards.
    private func runAutomation() {
        let env = ProcessInfo.processInfo.environment
        guard env["CADMAC_SCRIPT"] != nil || env["CADMAC_SNAPSHOT"] != nil else { return }
        if env["CADMAC_OPEN"] == nil {
            // Ignore windows restored from a previous session; script runs on a fresh drawing.
            for d in NSDocumentController.shared.documents { d.close() }
            _ = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        }
        if let path = env["CADMAC_OPEN"] {
            // Replace the untitled window with the opened document.
            for d in NSDocumentController.shared.documents { d.close() }
            let dc = NSDocumentController.shared
            let url = URL(fileURLWithPath: path)
            print("CADMAC: classes=\(dc.documentClassNames) type=\((try? dc.typeForContents(of: url)) ?? "nil") default=\(dc.defaultType ?? "nil")")
            var opened = false
            dc.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { print("CADMAC: failed to open \(path): \(error.localizedDescription)") }
                opened = true
            }
            while !opened { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        }
        guard let wc = (NSDocumentController.shared.documents.last?.windowControllers.first as? CadWindowController) ?? NSApp.windows.compactMap({ $0.windowController as? CadWindowController }).first else { return }
        var edWC: CadWindowController?
        var helpShown = false
        for step in (env["CADMAC_SCRIPT"] ?? "").components(separatedBy: ";") {
            // After !bedit, plain commands go to the Block Editor window.
            if let ed = edWC, !step.hasPrefix("!") { ed.controller.submit(step); continue }
            if step.hasPrefix("!zoom") { wc.canvas.zoom(.extents); continue }
            if step.hasPrefix("!save "), let doc = wc.document as? CadDocument {
                // Same path as File > Save As: the extension picks DXF or DWG.
                let url = URL(fileURLWithPath: String(step.dropFirst(6)))
                do { try doc.write(to: url, ofType: url.pathExtension.lowercased() == "dwg" ? "com.autodesk.dwg" : "com.autodesk.dxf") }
                catch { print("CADMAC: save failed \(error)") }
                continue
            }
            if step == "!bench" {
                let c = wc.controller
                func ms(_ t0: Date) -> String { String(format: "%.1f ms", Date().timeIntervalSince(t0) * 1000) }
                var t0 = Date()
                let scene = Scene(drawing: c.drawing, version: -1, previous: nil)
                print("CADMAC: bench scene build (cold) \(ms(t0)), items=\(scene.items.count), batches=\(scene.strokes.count)")
                t0 = Date()
                _ = Scene(drawing: c.drawing, version: -2, previous: scene)
                print("CADMAC: bench scene rebuild (reuse) \(ms(t0))")
                if ProcessInfo.processInfo.environment["CADMAC_BATCHPROFILE"] != nil {
                    let vt = wc.canvas.vt
                    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                    let ctx = CGContext(data: nil, width: Int(vt.size.width * 2), height: Int(vt.size.height * 2), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
                    ctx.scaleBy(x: 2, y: 2)
                    let r = Renderer(drawing: c.drawing, vt: vt, ctx: ctx)
                    var timings: [(Double, StrokeBatch)] = []
                    for b in scene.strokes {
                        let t1 = Date()
                        ctx.setLineWidth(b.style.width > 0 ? max(1, CGFloat(b.style.width * vt.scale)) : 1)
                        r.applyPattern(scene.linetypes[b.style.linetype], ltScale: scene.ltScale)
                        r.addWorldPath(b.path)
                        ctx.strokePath()
                        timings.append((Date().timeIntervalSince(t1), b))
                        if Date().timeIntervalSince(t0) > 60 { break }
                    }
                    for (t, b) in timings.sorted(by: { $0.0 > $1.0 }).prefix(8) {
                        print("CADMAC: batch \(String(format: "%.0f ms", t * 1000)) lt=\(b.style.linetype) width=\(b.style.width) bbox=\(fmt(b.bbox.width))x\(fmt(b.bbox.height)) scale=\(vt.scale) ltscale=\(scene.ltScale) pattern=\(scene.linetypes[b.style.linetype]?.pattern ?? [])")
                    }
                    print("CADMAC: profiled \(timings.count)/\(scene.strokes.count) batches, fills=\(scene.fills.count), texts=\(scene.texts.count)")
                } else {
                    let job = RenderJob(scene: scene, drawing: c.drawing, vt: wc.canvas.vt, style: wc.canvas.style, grid: 10, scaleFactor: 2)
                    t0 = Date()
                    _ = job.run()
                    print("CADMAC: bench full render \(ms(t0))")
                }
                let box = scene.extents
                t0 = Date()
                for k in 0..<100 { _ = scene.pick(at: box.min.lerp(to: box.max, Double(k) / 100), tolerance: box.width / 500) }
                print("CADMAC: bench 100 picks \(ms(t0))")
                c.viewScale = wc.canvas.vt.scale
                t0 = Date()
                for k in 0..<100 { _ = c.objectSnap(box.min.lerp(to: box.max, Double(k) / 100)) }
                print("CADMAC: bench 100 osnap queries \(ms(t0))")
                continue
            }
            if step.hasPrefix("!bedit ") {
                wc.openBlockEditor(String(step.dropFirst(7)))
                if let ed = NSApp.windows.compactMap({ $0.windowController as? CadWindowController }).first(where: { $0.blockEdit != nil }) {
                    edWC = ed
                }
                continue
            }
            if step == "!bsave" { edWC?.saveBlockEdit(); continue }
            if step == "!help" { HelpWindowController.shared.show(); helpShown = true; continue }
            if step.hasPrefix("!layout") {
                let n = String(step.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                wc.switchSpace(n.isEmpty || n == "Model" ? nil : n)
                continue
            }
            if step == "!cmdline off" { wc.setCommandLine(visible: false); continue }
            if step == "!cmdline on" { wc.setCommandLine(visible: true); continue }
            if step.hasPrefix("!type ") { wc.canvas.dynamicText = String(step.dropFirst(6)); continue }
            if step.hasPrefix("!publish ") {
                let path = String(step.dropFirst(9))
                let pages = Publisher.pages(wc.controller)
                let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: nil, nil)!
                for page in pages {
                    var box = CGRect(x: 0, y: 0, width: page.data.paper.width * 72 / 25.4, height: page.data.paper.height * 72 / 25.4)
                    ctx.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
                    var vt = ViewTransform(); vt.size = box.size; vt.scale = 72 / 25.4
                    vt.center = Vec2(page.data.paper.width / 2, page.data.paper.height / 2)
                    page.data.draw(ctx, vt: vt, paperScene: page.scene, drawing: wc.controller.drawing, background: false)
                    ctx.endPDFPage()
                }
                ctx.closePDF()
                print("CADMAC: published \(pages.count) pages")
                continue
            }
            if step.hasPrefix("!di ") { wc.canvas.diType(String(step.dropFirst(4))); continue }
            if step.hasPrefix("!resolve "), let p = wc.controller.parsePoint(String(step.dropFirst(9))) {
                wc.controller.viewScale = wc.canvas.vt.scale
                let r = wc.controller.resolve(p)
                print("CADMAC: resolve \(p) -> \(r.point) snap=\(r.snap?.kind.rawValue ?? "-") tracks=\(r.tracks) acquired=\(wc.controller.trackPoints)")
                continue
            }
            if step.hasPrefix("!sleep ") { Thread.sleep(forTimeInterval: Double(step.dropFirst(7)) ?? 0); continue }
            if step == "!ditab" { wc.canvas.diTab(); continue }
            if step == "!disubmit" { wc.controller.submit(wc.canvas.diSubmission()); continue }
            if step == "!cmds" {
                // Simulates the user pressing ⌘S in the drawing window.
                wc.window?.makeKeyAndOrderFront(nil)
                wc.window?.makeFirstResponder(wc.canvas)
                let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                          windowNumber: wc.window?.windowNumber ?? 0, context: nil, characters: "s",
                                          charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)!
                let item = NSApp.mainMenu?.items.compactMap { $0.submenu }.flatMap { $0.items }.first { $0.keyEquivalent == "s" && $0.keyEquivalentModifierMask == .command }
                print("CADMAC: menu item for cmd+s = \(item?.title ?? "none"), action = \(item?.action.map(NSStringFromSelector) ?? "nil")")
                let target = item?.action.flatMap { NSApp.target(forAction: $0, to: nil, from: item) }
                print("CADMAC: action target = \(target.map { String(describing: type(of: $0)) } ?? "nil")")
                if let item, let t = target as? NSMenuItemValidation { print("CADMAC: validates = \(t.validateMenuItem(item))") }
                if let t = target as? NSDocument { print("CADMAC: validateUserInterfaceItem = \(t.validateUserInterfaceItem(item!))") }
                let handled = NSApp.mainMenu?.performKeyEquivalent(with: ev) ?? false
                print("CADMAC: cmd+s handled by menu = \(handled)")
                continue
            }
            if step.hasPrefix("!saveas "), let doc = wc.document as? CadDocument {
                // Like finishing the Save As panel with this file name.
                let url = URL(fileURLWithPath: String(step.dropFirst(8)))
                var done = false
                doc.save(to: url, ofType: url.pathExtension.lowercased() == "dwg" ? "com.autodesk.dwg" : "com.autodesk.dxf", for: .saveAsOperation) { e in
                    if let e { print("CADMAC: save as failed \(e)") }
                    done = true
                }
                while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                continue
            }
            if step == "!docstate", let doc = wc.document as? CadDocument {
                print("CADMAC: doc url=\(doc.fileURL?.lastPathComponent ?? "nil") type=\(doc.fileType ?? "nil") edited=\(doc.isDocumentEdited) owns=\(doc.ownsDWGFile) savePanelOpen=\(wc.window?.attachedSheet != nil)")
                continue
            }
            if step == "!autosave" { AutoSaveManager.shared.saveAll(); continue }
            if step == "!leftovers" { print("CADMAC: leftovers=\(AutoSaveManager.shared.leftovers().map { $0.1.displayName })"); continue }
            if step == "!left" { wc.toggleToolSets(nil); continue }
            if step == "!right" { wc.toggleInspector(nil); continue }
            if step.hasPrefix("!select ") {
                let parts = step.dropFirst(8).split(separator: " ").compactMap { wc.controller.parsePoint(String($0)) }
                if parts.count == 2 { wc.controller.select(window: BBox(corner: parts[0], parts[1]), crossing: true, remove: false) }
                continue
            }
            if step.hasPrefix("!pick ") {
                if let p = wc.controller.parsePoint(String(step.dropFirst(6))) {
                    if wc.controller.inputKind == .entity, let id = wc.controller.pickEntity(at: p, aperture: 1e-6 * wc.controller.viewScale + 3) {
                        wc.controller.canvasEntity(id, at: p)
                    } else {
                        wc.controller.canvasPoint(p)
                    }
                }
                continue
            }
            wc.controller.submit(step)
        }
        if env["CADMAC_SCRIPT"]?.contains("!zoom") != true { wc.canvas.zoom(.extents) }
        print("CADMAC: \(wc.controller.drawing.entities.count) entities, \(wc.controller.drawing.layers.count) layers")
        if helpShown, let path = env["CADMAC_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                HelpWindowController.shared.snapshot(to: path, search: env["CADMAC_HELPSEARCH"]) {
                    if env["CADMAC_EXIT"] != nil { exit(0) }
                }
            }
            return
        }
        let delay = Double(env["CADMAC_SNAPDELAY"] ?? "") ?? 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let target: NSWindowController = helpShown ? HelpWindowController.shared : (env["CADMAC_SNAPSHOT_EDITOR"] != nil ? (edWC ?? wc) : wc)
            if let path = env["CADMAC_SNAPSHOT"], let view = target.window?.contentView?.superview ?? target.window?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            if env["CADMAC_EXIT"] != nil { exit(0) }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    @objc func showHelp(_ sender: Any?) { HelpWindowController.shared.show() }

    @objc func setLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let l = AppLanguage(rawValue: raw), l != AppLanguage.current else { return }
        AppLanguage.current = l
        for i in sender.menu?.items ?? [] { i.state = (i.representedObject as? String) == raw ? .on : .off }
        let alert = NSAlert()
        alert.messageText = Loc.isTurkish ? "Dil değişikliği CadMac yeniden başlatılınca uygulanır." : "The language change takes effect after restarting CadMac."
        alert.runModal()
    }
    @objc func showHelpSection(_ sender: NSMenuItem) { HelpWindowController.shared.show(anchor: sender.representedObject as? String) }
}

@MainActor
enum MenuBuilder {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(commandMenu("Draw", [
            ("Line", "LINE", ""), ("Polyline", "PLINE", ""), ("Rectangle", "RECTANG", ""), ("Polygon", "POLYGON", ""),
            nil, ("Circle", "CIRCLE", ""), ("Arc", "ARC", ""), ("Ellipse", "ELLIPSE", ""), ("Spline", "SPLINE", ""), ("Donut", "DONUT", ""),
            nil, ("Construction Line", "XLINE", ""), ("Ray", "RAY", ""), ("Point", "POINT", ""), ("Divide", "DIVIDE", ""), ("Measure", "MEASURE", ""),
            nil, ("Hatch…", "HATCH", ""), ("Revision Cloud", "REVCLOUD", ""),
            nil, ("Single Line Text", "TEXT", ""), ("Multiline Text", "MTEXT", ""),
            nil, ("Make Block", "BLOCK", ""), ("Insert Block", "INSERT", ""), ("Block Editor", "BEDIT", ""), ("Save Block", "BSAVE", ""), ("Close Block Editor", "BCLOSE", ""),
        ])))
        main.addItem(submenu(commandMenu("Modify", [
            ("Erase", "ERASE", ""), ("Move", "MOVE", ""), ("Copy", "COPY", ""), ("Rotate", "ROTATE", ""), ("Scale", "SCALE", ""),
            ("Mirror", "MIRROR", ""), ("Stretch", "STRETCH", ""),
            nil, ("Offset", "OFFSET", ""), ("Trim", "TRIM", ""), ("Extend", "EXTEND", ""), ("Lengthen", "LENGTHEN", ""),
            ("Break", "BREAK", ""), ("Join", "JOIN", ""), ("Fillet", "FILLET", ""), ("Chamfer", "CHAMFER", ""),
            nil, ("Rectangular Array", "ARRAYRECT", ""), ("Polar Array", "ARRAYPOLAR", ""), ("Path Array", "ARRAYPATH", ""),
            nil, ("Explode", "EXPLODE", ""), ("Match Properties", "MATCHPROP", ""), ("Properties", "PROPERTIES", ""),
        ])))
        main.addItem(submenu(commandMenu("Dimension", [
            ("Linear", "DIMLINEAR", ""), ("Aligned", "DIMALIGNED", ""), ("Angular", "DIMANGULAR", ""),
            ("Radius", "DIMRADIUS", ""), ("Diameter", "DIMDIAMETER", ""),
            nil, ("Continue", "DIMCONTINUE", ""), ("Baseline", "DIMBASELINE", ""), ("Leader", "QLEADER", ""),
            nil, ("Dimension Scale…", "DIMSCALE", ""), ("Dimension Text Height…", "DIMTXT", ""), ("Arrow Size…", "DIMASZ", ""), ("Decimal Places…", "DIMDEC", ""),
        ])))
        main.addItem(submenu(commandMenu("Format", [
            ("Layers…", "LAYER", ""), ("Make Object's Layer Current", "LAYMCUR", ""), ("Layer Off", "LAYOFF", ""), ("Layer Isolate", "LAYISO", ""),
            ("All Layers On", "LAYON", ""), ("Thaw All Layers", "LAYTHW", ""), ("Lock Layer", "LAYLCK", ""), ("Unlock Layer", "LAYULK", ""),
            nil, ("Text Height…", "TEXTSIZE", ""), ("Text Font…", "TEXTFONT", ""), ("Linetype Scale…", "LTSCALE", ""), ("Grid Spacing…", "GRIDUNIT", ""), ("Snap Spacing…", "SNAPUNIT", ""),
            nil, ("Purge Unused…", "PURGE", ""),
        ])))
        main.addItem(submenu(commandMenu("Tools", [
            ("Distance", "DIST", ""), ("Area", "AREA", ""), ("Point Coordinates", "ID", ""), ("List", "LIST", ""),
            nil, ("Object Snap Settings…", "OSNAP", ""), ("Set Variable…", "SETVAR", ""),
            nil, ("Command List", "COMMANDS", ""),
        ])))
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        main.addItem(submenu(window))
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "CadMac Kullanım Kılavuzu", action: #selector(AppDelegate.showHelp(_:)), keyEquivalent: "?")
        let f1 = help.addItem(withTitle: "Kılavuz (F1)", action: #selector(AppDelegate.showHelp(_:)), keyEquivalent: String(Character(UnicodeScalar(NSF1FunctionKey)!)))
        f1.keyEquivalentModifierMask = []
        help.addItem(.separator())
        for (title, anchor) in [("Klavye Kısayolları", "klavye"), ("Koordinat Girişi", "koordinat"), ("Block Editor", "blok"), ("Layout'lar ve Viewport'lar", "layout"),
                               ("Otomatik Kaydetme", "yedek"), ("Claude ile Çizim (MCP)", "claude"), ("Tüm Komutlar", "komutlar")] {
            let item = help.addItem(withTitle: title, action: #selector(AppDelegate.showHelpSection(_:)), keyEquivalent: "")
            item.representedObject = anchor
        }
        NSApp.helpMenu = help
        main.addItem(submenu(help))
        return main
    }

    private static func submenu(_ m: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
        item.submenu = m
        return item
    }

    private static func appMenu() -> NSMenu {
        let m = NSMenu(title: "CadMac")
        m.addItem(withTitle: "About CadMac", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Settings…", action: #selector(CadWindowController.showSettings(_:)), keyEquivalent: ",")
        m.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let sm = NSMenu(title: "Services")
        services.submenu = sm
        NSApp.servicesMenu = sm
        m.addItem(services)
        m.addItem(.separator())
        let lang = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let lm = NSMenu(title: "Language")
        for l in AppLanguage.allCases {
            let i = lm.addItem(withTitle: l.title, action: #selector(AppDelegate.setLanguage(_:)), keyEquivalent: "")
            i.representedObject = l.rawValue
            i.state = AppLanguage.current == l ? .on : .off
        }
        lang.submenu = lm
        m.addItem(lang)
        m.addItem(.separator())
        m.addItem(withTitle: "Hide CadMac", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let other = m.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        other.keyEquivalentModifierMask = [.command, .option]
        m.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit CadMac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return m
    }

    private static func fileMenu() -> NSMenu {
        let m = NSMenu(title: "File")
        m.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        m.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let rm = NSMenu(title: "Open Recent")
        rm.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        recent.submenu = rm
        m.addItem(recent)
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        m.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let saveAs = m.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        m.addItem(withTitle: "Revert to Saved", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        m.addItem(.separator())
        let pdf = m.addItem(withTitle: "Export as PDF…", action: #selector(CadWindowController.exportPDF(_:)), keyEquivalent: "e")
        pdf.keyEquivalentModifierMask = [.command, .shift]
        let pub = m.addItem(withTitle: "Publish All Layouts to PDF…", action: #selector(CadWindowController.publishLayouts(_:)), keyEquivalent: "p")
        pub.keyEquivalentModifierMask = [.command, .shift]
        m.addItem(withTitle: "Print / Plot…", action: #selector(CadWindowController.printDrawing(_:)), keyEquivalent: "p")
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu(title: "Edit")
        m.addItem(withTitle: "Undo", action: #selector(CadWindowController.cadUndo(_:)), keyEquivalent: "z")
        let redo = m.addItem(withTitle: "Redo", action: #selector(CadWindowController.cadRedo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        m.addItem(.separator())
        m.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        m.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return m
    }

    private static func viewMenu() -> NSMenu {
        let m = NSMenu(title: "View")
        let ext = m.addItem(withTitle: "Zoom Extents", action: #selector(CadWindowController.zoomExtents(_:)), keyEquivalent: "0")
        ext.keyEquivalentModifierMask = [.command]
        m.addItem(withTitle: "Zoom In", action: #selector(CadWindowController.zoomIn(_:)), keyEquivalent: "+")
        m.addItem(withTitle: "Zoom Out", action: #selector(CadWindowController.zoomOut(_:)), keyEquivalent: "-")
        let zw = NSMenuItem(title: "Zoom Window", action: #selector(CadWindowController.runCommand(_:)), keyEquivalent: "")
        zw.representedObject = "ZOOM"
        m.addItem(zw)
        let rg = NSMenuItem(title: "Regenerate", action: #selector(CadWindowController.runCommand(_:)), keyEquivalent: "")
        rg.representedObject = "REGEN"
        m.addItem(rg)
        m.addItem(.separator())
        func toggle(_ t: String, _ sel: Selector, _ key: Int) {
            let i = m.addItem(withTitle: t, action: sel, keyEquivalent: String(Character(UnicodeScalar(key)!)))
            i.keyEquivalentModifierMask = []
        }
        toggle("Object Snap (F3)", #selector(CadWindowController.toggleOsnap(_:)), NSF3FunctionKey)
        toggle("Grid (F7)", #selector(CadWindowController.toggleGrid(_:)), NSF7FunctionKey)
        toggle("Ortho (F8)", #selector(CadWindowController.toggleOrtho(_:)), NSF8FunctionKey)
        toggle("Snap (F9)", #selector(CadWindowController.toggleSnap(_:)), NSF9FunctionKey)
        toggle("Polar Tracking (F10)", #selector(CadWindowController.togglePolar(_:)), NSF10FunctionKey)
        toggle("Object Snap Tracking (F11)", #selector(CadWindowController.toggleOtrack(_:)), NSF11FunctionKey)
        toggle("Dynamic Input (F12)", #selector(CadWindowController.toggleDyn(_:)), NSF12FunctionKey)
        m.addItem(.separator())
        let ts = m.addItem(withTitle: "Hide Tool Sets", action: #selector(CadWindowController.toggleToolSets(_:)), keyEquivalent: "1")
        ts.keyEquivalentModifierMask = [.command, .option]
        let ins = m.addItem(withTitle: "Hide Inspector", action: #selector(CadWindowController.toggleInspector(_:)), keyEquivalent: "2")
        ins.keyEquivalentModifierMask = [.command, .option]
        let cl = m.addItem(withTitle: "Hide Command Line", action: #selector(CadWindowController.toggleCommandLine(_:)), keyEquivalent: "3")
        cl.keyEquivalentModifierMask = [.command, .option]
        // AutoCAD's Ctrl+9, kept as a hidden alternate shortcut.
        let cl9 = m.addItem(withTitle: "Toggle Command Line", action: #selector(CadWindowController.toggleCommandLine(_:)), keyEquivalent: "9")
        cl9.keyEquivalentModifierMask = [.control]
        cl9.isHidden = true
        cl9.allowsKeyEquivalentWhenHidden = true
        m.addItem(.separator())
        m.addItem(withTitle: "Dark Background", action: #selector(CadWindowController.toggleBackground(_:)), keyEquivalent: "")
        let fs = m.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        return m
    }

    private static func commandMenu(_ title: String, _ items: [(String, String, String)?]) -> NSMenu {
        let m = NSMenu(title: title)
        for it in items {
            guard let (t, cmd, key) = it else { m.addItem(.separator()); continue }
            let alias = CommandRegistry.lookup(cmd)?.aliases.first
            let item = NSMenuItem(title: alias.map { "\(t)    \($0)" } ?? t, action: #selector(CadWindowController.runCommand(_:)), keyEquivalent: key)
            item.representedObject = cmd
            if let info = CommandRegistry.lookup(cmd) { item.toolTip = info.summary }
            m.addItem(item)
        }
        return m
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
