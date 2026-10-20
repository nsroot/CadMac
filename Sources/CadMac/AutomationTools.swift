import AppKit
import CadCore

/// Implementation of the Claude (MCP) tools against one drawing window.
@MainActor
struct AutomationTools {
    typealias Response = AutomationServer.Response
    typealias InputError = AutomationJSON.InputError

    let wc: CadWindowController
    var controller: CommandController { wc.controller }
    var drawing: Drawing { wc.controller.drawing }

    func run(_ tool: String, _ args: [String: Any], reply: @escaping (Response) -> Void) {
        do {
            switch tool {
            case "get_drawing_info": reply(.success(drawingInfo()))
            case "list_entities": reply(.success(try listEntities(args)))
            case "get_selection": reply(.success(selectionInfo()))
            case "measure": reply(.success(try measure(args)))
            case "find_closed_areas": reply(.success(try closedAreas(args)))
            case "screenshot": reply(try screenshot(args))
            case "zoom": reply(.success(try zoom(args)))
            case "select_entities": reply(.success(try select(args)))
            case "add_entities": try propose(args, reply: reply, build: addEntities)
            case "delete_entities": try propose(args, reply: reply, build: deleteEntities)
            case "modify_entities": try propose(args, reply: reply, build: modifyEntities)
            case "create_layer": try propose(args, reply: reply, build: createLayer)
            case "set_current_layer": try propose(args, reply: reply, build: setCurrentLayer)
            case "run_command": try propose(args, reply: reply, build: runCommand)
            default: reply(.failure("Unknown tool '\(tool)'"))
            }
        } catch let e as InputError {
            reply(.failure(e.description))
        } catch {
            reply(.failure("\(error)"))
        }
    }

    // MARK: - Read-only

    private var spaceName: String { drawing.activeLayout.map { "Layout \"\($0)\" (paper space, units are paper mm)" } ?? "Model" }

    func drawingInfo() -> [String: Any] {
        let d = drawing
        let st = d.settings
        var counts: [String: Int] = [:]
        for e in d.entities { counts[AutomationJSON.typeKey(e.kind), default: 0] += 1 }
        var layerUse: [String: Int] = [:]
        for e in d.entities { layerUse[e.layer.lowercased(), default: 0] += 1 }
        var o: [String: Any] = [
            "file": (wc.document as? NSDocument)?.fileURL?.path ?? (wc.document as? NSDocument)?.displayName ?? wc.window?.title ?? "Untitled",
            "units": st.insUnits.displayName,
            "unit_suffix": st.insUnits.suffix,
            "units_note": "All coordinates, lengths and areas are in drawing units (\(st.insUnits.displayName)). Angles are in degrees, counter-clockwise from +X.",
            "current_layer": st.currentLayer,
            "current_color": AutomationJSON.color(st.currentColor),
            "text_height": AutomationJSON.num(st.textHeight),
            "active_space": spaceName,
            "entity_count": d.entities.count,
            "entity_counts": counts,
            "selection_count": controller.selection.count,
            "layers": d.layers.map { l -> [String: Any] in
                ["name": l.name, "color": AutomationJSON.color(l.color), "linetype": l.linetype, "on": l.isOn, "frozen": l.isFrozen,
                 "locked": l.isLocked, "entities": layerUse[l.name.lowercased()] ?? 0]
            },
            "layouts": d.layouts.sorted { $0.tabOrder < $1.tabOrder }.map(\.name),
            "blocks": d.blocks.values.sorted { $0.name < $1.name }.filter { !$0.name.hasPrefix("*") }.prefix(500).map { ["name": $0.name, "entities": $0.entities.count] as [String: Any] },
        ]
        if wc.blockEdit != nil { o["block_editor"] = wc.blockEdit!.name }
        if let ext = AutomationJSON.box(d.extents()) { o["extents"] = ext }
        if d.isPaperSpace, let m = AutomationJSON.box(d.modelView.extents()) { o["model_extents"] = m }
        o["view"] = AutomationJSON.box(wc.canvas.vt.visibleBox) as Any
        return o
    }

    func listEntities(_ a: [String: Any]) throws -> [String: Any] {
        let d = drawing
        let layer = (a["layer"] as? String)?.lowercased()
        let type = (a["type"] as? String).map(AutomationJSON.normalizeTypeFilter)
        let box = AutomationJSON.bbox(a["bbox"])
        if a["bbox"] != nil && box == nil { throw InputError("'bbox' must be [minX, minY, maxX, maxY]") }
        let inside = a["inside_only"] as? Bool ?? false
        let limit = max(0, min(2000, (AutomationJSON.double(a["limit"]).map { Int($0) }) ?? 200))
        let offset = max(0, (AutomationJSON.double(a["offset"]).map { Int($0) }) ?? 0)
        var matched = 0
        var out: [[String: Any]] = []
        for e in d.entities {
            if let layer, e.layer.lowercased() != layer { continue }
            if let type, AutomationJSON.typeKey(e.kind) != type { continue }
            if let box {
                let b = d.bbox(of: e)
                if inside ? !box.contains(b) : !box.intersects(b) { continue }
            }
            matched += 1
            if matched > offset && out.count < limit {
                var o = AutomationJSON.describe(e, in: d)
                if !d.isVisible(e) { o["hidden"] = true }
                out.append(o)
            }
        }
        var r: [String: Any] = ["total_matching": matched, "returned": out.count, "offset": offset, "entities": out]
        if offset + out.count < matched { r["next_offset"] = offset + out.count }
        return r
    }

    func selectionInfo() -> [String: Any] {
        let d = drawing
        let sel = controller.selection
        let es = d.entities.filter { sel.contains($0.id) }
        return ["count": es.count, "entities": es.prefix(2000).map { AutomationJSON.describe($0, in: d) }]
    }

    /// Resolves full UUIDs or unique prefixes (>= 8 chars) against the active space.
    func resolveIDs(_ v: Any?, allowEmpty: Bool = false) throws -> [EntityID] {
        guard let arr = v as? [Any] else { throw InputError("'ids' must be an array of entity id strings") }
        if arr.isEmpty && !allowEmpty { throw InputError("'ids' is empty") }
        guard arr.count <= AutomationJSON.maxEntitiesPerCall else { throw InputError("too many ids (max \(AutomationJSON.maxEntitiesPerCall))") }
        let all = drawing.entities.map(\.id)
        let set = Set(all)
        var lowered: [(String, EntityID)]?
        var out: [EntityID] = []
        var missing: [String] = []
        for item in arr {
            guard let s = (item as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { missing.append("\(item)"); continue }
            if let u = UUID(uuidString: s), set.contains(u) { out.append(u); continue }
            if s.count >= 8 {
                if lowered == nil { lowered = all.map { ($0.uuidString.lowercased(), $0) } }
                let p = s.lowercased()
                let m = lowered!.filter { $0.0.hasPrefix(p) }
                if m.count == 1 { out.append(m[0].1); continue }
                if m.count > 1 { throw InputError("id prefix '\(s)' is ambiguous") }
            }
            missing.append(s)
        }
        if !missing.isEmpty {
            throw InputError("unknown entity id(s) in the active space (\(spaceName)): " + missing.prefix(10).joined(separator: ", "))
        }
        return out
    }

    /// One-entity drawing, so area/perimeter helpers don't scan the whole drawing.
    private func single(_ e: Entity) -> Drawing {
        var d = Drawing()
        d.layouts = []
        d.blocks = drawing.blocks
        d.modelEntities = [e]
        return d
    }

    func measure(_ a: [String: Any]) throws -> [String: Any] {
        let st = drawing.settings
        var o: [String: Any] = [:]
        if a["from"] != nil || a["to"] != nil {
            guard let p = AutomationJSON.point(a["from"]), let q = AutomationJSON.point(a["to"]) else { throw InputError("'from' and 'to' must both be points [x, y]") }
            let v = q - p
            o["distance"] = AutomationJSON.num(v.length)
            o["distance_text"] = st.formatLengthDetailed(v.length)
            o["dx"] = AutomationJSON.num(v.x); o["dy"] = AutomationJSON.num(v.y)
            o["angle"] = AutomationJSON.num(degrees(normalizeAngle(v.angle)))
        }
        if a["id"] != nil {
            let id = try resolveIDs([a["id"]!])[0]
            guard let e = drawing.entity(id) else { throw InputError("entity not found") }
            let sd = single(e)
            o["entity"] = AutomationJSON.describe(e, in: drawing)
            if let area = sd.area(of: id) { o["area"] = AutomationJSON.num(area); o["area_text"] = st.formatArea(area) }
            if let per = sd.perimeter(of: id) {
                o[sd.area(of: id) == nil ? "length" : "perimeter"] = AutomationJSON.num(per)
                o["length_text"] = st.formatLengthDetailed(per)
            }
            if case .dimension(let dm) = e.kind { o["measurement"] = AutomationJSON.num(dm.measurement) }
        }
        if o.isEmpty { throw InputError("give 'from' and 'to' points, and/or an entity 'id'") }
        o["units"] = st.insUnits.displayName
        return o
    }

    func closedAreas(_ a: [String: Any]) throws -> [String: Any] {
        let d = drawing
        let st = d.settings
        if a["point"] != nil {
            guard let p = AutomationJSON.point(a["point"]) else { throw InputError("'point' must be [x, y]") }
            guard let loop = d.boundary(around: p, using: nil) else {
                return ["found": false, "message": "No closed boundary found around \(p). The region must be fully enclosed by lines/arcs/polylines/circles."]
            }
            let area = abs(polygonArea(loop))
            let per = AutomationJSON.polylineLength(loop, closed: true)
            var o: [String: Any] = [
                "found": true, "area": AutomationJSON.num(area), "area_text": st.formatArea(area),
                "perimeter": AutomationJSON.num(per), "perimeter_text": st.formatLengthDetailed(per),
                "centroid": AutomationJSON.pt(AutomationJSON.centroid(loop)),
                "vertex_count": loop.count,
                "vertices": loop.prefix(200).map { AutomationJSON.pt($0.point) },
                "units": st.insUnits.displayName,
            ]
            if loop.contains(where: { abs($0.bulge) > 1e-12 }) { o["bulges"] = loop.prefix(200).map { AutomationJSON.num($0.bulge) } }
            if let b = AutomationJSON.box(BBox(points: loop.map(\.point))) { o["bbox"] = b }
            return o
        }
        let layer = (a["layer"] as? String)?.lowercased()
        let limit = max(1, min(2000, (AutomationJSON.double(a["limit"]).map { Int($0) }) ?? 100))
        var rows: [(Double, [String: Any])] = []
        for e in d.entities where d.isVisible(e) {
            if let layer, e.layer.lowercased() != layer { continue }
            var centroid: Vec2
            switch e.kind {
            case .polyline(let p):
                guard p.closed, p.vertices.count >= 2 else { continue }
                centroid = AutomationJSON.centroid(p.vertices)
            case .circle(let c): centroid = c.center
            case .ellipse(let el): guard el.isFull else { continue }; centroid = el.center
            case .spline(let s): guard s.closed else { continue }; centroid = AutomationJSON.centroid(splinePoints(s).map { PolyVertex($0) })
            case .hatch(let h): guard let l = h.loops.first else { continue }; centroid = AutomationJSON.centroid(l)
            default: continue
            }
            let sd = single(e)
            guard let area = sd.area(of: e.id) else { continue }
            var row: [String: Any] = ["id": e.id.uuidString, "type": e.kind.typeName, "layer": e.layer,
                                      "area": AutomationJSON.num(area), "area_text": st.formatArea(area),
                                      "centroid": AutomationJSON.pt(centroid)]
            if case .hatch = e.kind {
                if case .hatch(let h) = e.kind, let l = h.loops.first { row["perimeter"] = AutomationJSON.num(AutomationJSON.polylineLength(l, closed: true)) }
            } else if let per = sd.perimeter(of: e.id) {
                row["perimeter"] = AutomationJSON.num(per)
            }
            rows.append((area, row))
        }
        rows.sort { $0.0 > $1.0 }
        let total = rows.reduce(0) { $0 + $1.0 }
        return ["count": rows.count, "returned": min(limit, rows.count), "total_area": AutomationJSON.num(total), "total_area_text": st.formatArea(total),
                "units": st.insUnits.displayName, "objects": rows.prefix(limit).map(\.1),
                "note": "Totals may double count overlapping objects (e.g. a hatch and its boundary polyline). Use 'point' to detect a region bounded by separate lines."]
    }

    func screenshot(_ a: [String: Any]) throws -> Response {
        let canvas = wc.canvas
        if a["zoom_extents"] as? Bool == true { canvas.zoom(.extents) }
        let vt = canvas.vt
        guard vt.size.width >= 1, vt.size.height >= 1 else { throw InputError("the drawing view has no size") }
        let maxW = CGFloat(max(200, min(3000, (AutomationJSON.double(a["max_width"]).map { Int($0) }) ?? 1600)))
        let scale = min(2, maxW / vt.size.width)
        let c = controller
        let paper = PaperRenderData.make(c)
        let job = RenderJob(scene: c.scene, drawing: c.drawing, vt: vt, style: canvas.style,
                            grid: c.gridOn && paper == nil ? c.drawing.settings.gridSpacing : nil, scaleFactor: scale, paper: paper)
        guard let base = job.run() else { throw InputError("rendering failed") }
        var image = base
        if !canvas.externalPreview.isEmpty, let cs = CGColorSpace(name: CGColorSpace.sRGB),
           let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
            ctx.scaleBy(x: scale, y: scale)
            var r = Renderer(drawing: c.drawing, vt: vt, ctx: ctx)
            r.style = canvas.style
            for e in canvas.externalPreview { r.draw(e, override: CGColor(red: 0.85, green: 0.45, blue: 1, alpha: 0.95), extraWidth: 1) }
            if let img = ctx.makeImage() { image = img }
        }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw InputError("PNG encoding failed") }
        let box = vt.visibleBox
        let text = "Screenshot of \(spaceName), \(image.width)×\(image.height) px. Visible area: x \(fmt(box.min.x))…\(fmt(box.max.x)), y \(fmt(box.min.y))…\(fmt(box.max.y)) (\(drawing.settings.insUnits.displayName))." +
            (canvas.externalPreview.isEmpty ? "" : " Purple = pending Claude preview.")
        return Response(ok: true, text: text, image: png.base64EncodedString())
    }

    func zoom(_ a: [String: Any]) throws -> String {
        switch (a["mode"] as? String ?? "extents").lowercased() {
        case "extents", "e", "all":
            wc.canvas.zoom(.extents)
        case "window", "w", "bbox":
            guard let b = AutomationJSON.bbox(a["bbox"]), b.width > 0 || b.height > 0 else { throw InputError("mode=window needs 'bbox' [minX, minY, maxX, maxY] with non-zero size") }
            wc.canvas.zoom(.window(b))
        default:
            throw InputError("mode must be 'extents' or 'window'")
        }
        let v = wc.canvas.vt.visibleBox
        return "View now shows x \(fmt(v.min.x))…\(fmt(v.max.x)), y \(fmt(v.min.y))…\(fmt(v.max.y))."
    }

    func select(_ a: [String: Any]) throws -> String {
        let ids = try resolveIDs(a["ids"], allowEmpty: true)
        if a["add"] as? Bool == true { controller.selection.formUnion(ids) } else { controller.selection = Set(ids) }
        return "\(controller.selection.count) object(s) selected."
    }

    // MARK: - Proposals (preview + approval)

    struct Proposal {
        var final: Drawing
        var details: [String: Any] = [:]
        var defaultSummary: String
    }

    private func propose(_ a: [String: Any], reply: @escaping (Response) -> Void, build: ([String: Any], Drawing) throws -> Proposal) throws {
        let base = drawing
        var p = try build(a, base)
        try ensureLinetypes(&p.final)
        var summary = (a["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if summary.isEmpty { summary = p.defaultSummary }
        if summary.count > 300 { summary = String(summary.prefix(300)) + "…" }
        let patch = AutomationPatch(base: base, final: p.final)
        var details = p.details
        if patch.isEmpty {
            details["status"] = "no_change"
            details["message"] = "The drawing would not change, so nothing was proposed."
            reply(.success(details))
            return
        }
        let total = patch.addedCount + patch.changedCount + patch.removedCount
        guard total <= AutomationJSON.maxEntitiesPerCall * 2 else {
            throw InputError("change too large (\(total) entities); split it into smaller steps")
        }
        let proposal = ClaudeProposal(summary: summary, patch: patch, window: wc) { outcome in
            switch outcome {
            case .applied:
                details["status"] = "applied"
                details["message"] = "The user approved; the change is applied as one undo step (\"Claude: \(summary)\")."
                let added = patch.spaces.values.flatMap(\.added)
                details["added"] = added.count
                details["added_ids"] = added.prefix(500).map(\.id.uuidString)
                details["changed"] = patch.changedCount
                details["removed"] = patch.removedCount
                let tc = patch.tableChanges
                if !tc.isEmpty { details["other_changes"] = tc }
            case .rejected(let why):
                details["status"] = "rejected"
                details["message"] = why
            }
            reply(.success(details))
        }
        ClaudeApproval.shared.submit(proposal)
    }

    /// Adds standard linetypes referenced by new/changed entities or layers; rejects unknown ones.
    private func ensureLinetypes(_ d: inout Drawing) throws {
        var names = Set(d.layers.map(\.linetype))
        for e in d.entities { names.insert(e.linetype) }
        for n in names {
            let l = n.lowercased()
            if l == "bylayer" || l == "byblock" || d.linetype(named: n) != nil { continue }
            if let std = Linetype.standard.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
                d.linetypes.append(std)
            } else {
                throw InputError("unknown linetype '\(n)'. Available: " + (d.linetypes.map(\.name) + Linetype.standard.map(\.name)).uniqued().joined(separator: ", "))
            }
        }
    }

    private func checkEditable(_ ids: [EntityID], _ d: Drawing) throws {
        let set = Set(ids)
        let locked = d.entities.filter { set.contains($0.id) && (d.layer(named: $0.layer)?.isLocked ?? false) }
        if !locked.isEmpty {
            throw InputError("\(locked.count) object(s) are on locked layers (\(Set(locked.map(\.layer)).sorted().joined(separator: ", "))); unlock the layer first")
        }
    }

    func addEntities(_ a: [String: Any], _ base: Drawing) throws -> Proposal {
        guard let arr = a["entities"] as? [Any], !arr.isEmpty else { throw InputError("'entities' must be a non-empty array") }
        guard arr.count <= AutomationJSON.maxEntitiesPerCall else { throw InputError("too many entities (max \(AutomationJSON.maxEntitiesPerCall) per call)") }
        var d = base
        var types: [String: Int] = [:]
        for (i, item) in arr.enumerated() {
            guard let o = item as? [String: Any] else { throw InputError("entities[\(i)] must be an object") }
            let e = try AutomationJSON.entity(from: o, index: i, in: d)   // boundary_point sees earlier entities
            if let l = base.layer(named: e.layer), l.isLocked { throw InputError("entities[\(i)]: layer '\(l.name)' is locked") }
            d.add(e)
            types[AutomationJSON.typeKey(e.kind), default: 0] += 1
        }
        let what = types.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        return Proposal(final: d, defaultSummary: "Add \(what)")
    }

    func deleteEntities(_ a: [String: Any], _ base: Drawing) throws -> Proposal {
        let ids = try resolveIDs(a["ids"])
        try checkEditable(ids, base)
        var d = base
        d.remove(ids: Set(ids))
        return Proposal(final: d, defaultSummary: "Delete \(ids.count) object(s)")
    }

    func modifyEntities(_ a: [String: Any], _ base: Drawing) throws -> Proposal {
        let ids = try resolveIDs(a["ids"])
        try checkEditable(ids, base)
        let set = Set(ids)
        let sel = base.entities.filter { set.contains($0.id) }
        let center = sel.reduce(BBox.empty) { $0.union(base.bbox(of: $1)) }.center
        var t = Transform2D.identity
        var ops: [String] = []
        if let s = a["scale"] as? [String: Any] {
            guard let f = AutomationJSON.double(s["factor"]), f > 0 else { throw InputError("scale.factor must be a positive number") }
            let p = AutomationJSON.point(s["base"]) ?? center
            t = t.then(.scale(f, about: p)); ops.append("scale ×\(fmt(f))")
        }
        if let r = a["rotate"] as? [String: Any] {
            guard let ang = AutomationJSON.double(r["angle"]) else { throw InputError("rotate.angle must be a number (degrees)") }
            let p = AutomationJSON.point(r["base"]) ?? center
            t = t.then(.rotation(radians(ang), about: p)); ops.append("rotate \(fmt(ang))°")
        }
        if let m = a["move"] as? [String: Any] {
            let dx = AutomationJSON.double(m["dx"]) ?? 0, dy = AutomationJSON.double(m["dy"]) ?? 0
            t = t.then(.translation(Vec2(dx, dy))); ops.append("move \(fmt(dx)),\(fmt(dy))")
        }
        var layer: String?
        if let l = a["layer"] as? String {
            guard AutomationJSON.validLayerName(l) else { throw InputError("invalid layer name '\(l)'") }
            layer = base.layer(named: l)?.name ?? l.trimmingCharacters(in: .whitespaces)
            if base.layer(named: l)?.isLocked == true { throw InputError("layer '\(l)' is locked") }
            ops.append("layer → \(layer!)")
        }
        let color = try AutomationJSON.parseColor(a["color"])
        if color != nil { ops.append("color") }
        let linetype = a["linetype"] as? String
        if linetype != nil { ops.append("linetype") }
        let text = a["text"] as? String
        if text != nil { ops.append("text") }
        guard !ops.isEmpty else { throw InputError("nothing to change: give layer, color, linetype, text, move, rotate and/or scale") }
        var d = base
        var textless = 0
        let isIdentity = t == .identity
        d.update(ids: set) { e in
            if !isIdentity { e = e.transformed(by: t) }
            if let layer { e.layer = layer }
            if let color { e.color = color }
            if let linetype { e.linetype = linetype }
            if let text {
                switch e.kind {
                case .text(var g): g.text = g.isMultiline ? text : text.replacingOccurrences(of: "\n", with: " "); e.kind = .text(g)
                case .dimension(var g): g.textOverride = text; e.kind = .dimension(g)
                default: textless += 1
                }
            }
        }
        if let layer { d.ensureLayer(layer) }
        var details: [String: Any] = [:]
        if textless > 0 { details["note"] = "\(textless) object(s) have no text; 'text' was ignored for them." }
        return Proposal(final: d, details: details, defaultSummary: "Modify \(ids.count) object(s): " + ops.joined(separator: ", "))
    }

    func createLayer(_ a: [String: Any], _ base: Drawing) throws -> Proposal {
        guard let raw = a["name"] as? String, AutomationJSON.validLayerName(raw) else { throw InputError("'name' must be a valid layer name") }
        let name = raw.trimmingCharacters(in: .whitespaces)
        let color = try AutomationJSON.parseLayerColor(a["color"])
        let lt = a["linetype"] as? String
        var d = base
        if let i = d.layers.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            if let color { d.layers[i].color = color }
            if let lt { d.layers[i].linetype = lt }
        } else {
            d.layers.append(Layer(name: name, color: color ?? .aci(7), linetype: lt ?? "Continuous"))
        }
        if a["make_current"] as? Bool == true { d.settings.currentLayer = d.layer(named: name)!.name }
        return Proposal(final: d, defaultSummary: base.layer(named: name) == nil ? "Create layer \(name)" : "Update layer \(name)")
    }

    func setCurrentLayer(_ a: [String: Any], _ base: Drawing) throws -> Proposal {
        guard let raw = a["name"] as? String, AutomationJSON.validLayerName(raw) else { throw InputError("'name' must be a valid layer name") }
        var d = base
        d.ensureLayer(raw.trimmingCharacters(in: .whitespaces))
        let l = d.layer(named: raw.trimmingCharacters(in: .whitespaces))!
        if l.isFrozen { throw InputError("layer '\(l.name)' is frozen and cannot be made current") }
        d.settings.currentLayer = l.name
        return Proposal(final: d, defaultSummary: "Make layer \(l.name) current")
    }

    func runCommand(_ a: [String: Any], _ base: Drawing) throws -> Proposal {
        guard let script = a["script"] as? String, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InputError("'script' is required") }
        guard script.count <= 1_000_000 else { throw InputError("script too long") }
        let steps = script.replacingOccurrences(of: "\r", with: "").components(separatedBy: CharacterSet(charactersIn: ";\n"))
        guard steps.count <= 20_000 else { throw InputError("too many steps (max 20000)") }

        // Run on a scratch copy so the real drawing and its undo history stay untouched until Apply.
        let capture = AutomationCaptureDelegate()
        let tmp = CommandController(history: DrawingHistory(base))
        tmp.delegate = capture
        tmp.viewScale = controller.viewScale
        tmp.osnapOn = false
        tmp.selection = controller.selection.filter { base.entity($0) != nil }
        for step in steps {
            let s = step.trimmingCharacters(in: .whitespaces)
            if s.isEmpty && tmp.active == nil { continue }   // trailing Enters: don't repeat the last command
            if s.hasPrefix("!") { capture.notes.append("ignored step '\(s)'"); continue }
            tmp.submit(s)
        }
        var unfinished: String?
        if let act = tmp.active {
            unfinished = "\(act.name) was still waiting for input (\(capture.prompt)) and was cancelled; end commands with ';' (Enter)."
            tmp.cancel()
        }
        var final = tmp.drawing
        final.activeLayout = base.activeLayout
        var details: [String: Any] = [:]
        let lines = capture.lines.filter { !$0.hasPrefix("*Cancel*") || unfinished == nil }
        details["output"] = Array(lines.suffix(300))
        if lines.count > 300 { details["output_truncated"] = true }
        if let unfinished { details["warning"] = unfinished }
        if !capture.notes.isEmpty { details["notes"] = capture.notes }
        let first = steps.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespaces).uppercased() ?? "command"
        return Proposal(final: final, details: details, defaultSummary: "Run \(first)")
    }
}

/// Collects command-line output of a scripted command run (no UI).
@MainActor
final class AutomationCaptureDelegate: CommandControllerDelegate {
    var lines: [String] = []
    var notes: [String] = []
    var prompt = ""

    func commandLineEcho(_ text: String) { if lines.count < 5000 { lines.append(text) } }
    func promptDidChange(_ prompt: String) { self.prompt = prompt }
    func needsRedraw(drawingChanged: Bool) {}
    func zoom(_ op: ZoomOperation) {}
    func showPanel(_ panel: String) {}
    func runModal(_ request: ModalRequest) {
        switch request {
        case .mtext(_, let completion):
            notes.append("The MTEXT editor dialog is not available from scripts; use add_entities with type 'mtext' instead.")
            completion(nil)
        default:
            notes.append("Dialogs (print, export, settings) are not available from scripts.")
        }
    }
    func blockEditor(_ action: BlockEditorAction) { notes.append("The Block Editor cannot be driven from scripts.") }
    func layout(_ action: LayoutAction) { notes.append("Layout tab commands are not available from scripts.") }
    func setCommandLineVisible(_ visible: Bool?) {}
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
