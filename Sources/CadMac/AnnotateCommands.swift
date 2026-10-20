import AppKit
import CadCore

// MARK: - DIMLINEAR / DIMALIGNED

final class DimLinearCommand: CadCommand {
    private let aligned: Bool
    private var p1: Vec2?
    private var p2: Vec2?
    private var forced: Double?   // rotation forced by Horizontal/Vertical/Rotated
    static var last: DimensionGeom?

    init(_ c: CommandController, name: String, aligned: Bool) { self.aligned = aligned; super.init(c, name: name) }

    override func start() { ask("Specify first extension line origin", .point, keywords: ["Select object"]) }

    override func keyword(_ k: String) {
        switch k {
        case "Select object": ask("Select object to dimension", .entity)
        case "Horizontal": forced = 0
        case "Vertical": forced = .pi / 2
        case "Rotated": ask("Specify angle of dimension line <0>", .text)
        default: break
        }
    }

    override func value(_ s: String) -> Bool {
        guard prompt.hasPrefix("Specify angle"), let v = Double(s) else { return false }
        forced = radians(v)
        askLocation()
        return true
    }

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        guard let e = drawing.entity(id) else { return }
        switch e.kind {
        case .line(let l): p1 = l.start; p2 = l.end
        case .arc(let a): p1 = a.startPoint; p2 = a.endPoint
        case .circle(let ci): p1 = ci.center - Vec2(ci.radius, 0); p2 = ci.center + Vec2(ci.radius, 0)
        case .polyline(let pl):
            // Use the segment nearest the pick.
            let prims = drawing.prims(of: e)
            guard let seg = prims.min(by: { $0.distance(to: p) < $1.distance(to: p) }) else { return }
            p1 = seg.startPoint; p2 = seg.endPoint
            _ = pl
        default:
            c.message("Object cannot be dimensioned"); return
        }
        askLocation()
    }

    private func askLocation() {
        ask("Specify dimension line location", keywords: aligned ? [] : ["Horizontal", "Vertical", "Rotated"], base: nil)
    }

    private func geom(_ loc: Vec2) -> DimensionGeom? {
        guard let a = p1, let b = p2 else { return nil }
        if aligned { return DimensionGeom(kind: .aligned, p1: a, p2: b, p3: loc) }
        var rot = forced ?? 0
        if forced == nil {
            // Pick horizontal or vertical by where the cursor is relative to the measured points.
            let box = BBox(corner: a, b)
            let outsideX = loc.x < box.min.x || loc.x > box.max.x
            let outsideY = loc.y < box.min.y || loc.y > box.max.y
            if outsideX && !outsideY { rot = .pi / 2 }
            else if outsideX && outsideY {
                rot = abs(loc.x - box.center.x) - box.width / 2 > abs(loc.y - box.center.y) - box.height / 2 ? .pi / 2 : 0
            }
        }
        return DimensionGeom(kind: .linear, p1: a, p2: b, p3: loc, rotation: rot)
    }

    override func point(_ p: Vec2) {
        if p1 == nil { p1 = p; ask("Specify second extension line origin", base: p); return }
        if p2 == nil { p2 = p; askLocation(); return }
        guard let g = geom(p) else { return }
        let e = make(.dimension(g))
        c.perform("Dimension") { $0.add(e) }
        DimLinearCommand.last = g
        c.message("Dimension text = \(fmt(g.measurement))")
        finish()
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        if p2 != nil, let g = geom(cursor) { return [make(.dimension(g))] }
        if let a = p1, p2 == nil { return [make(.line(LineGeom(start: a, end: cursor)))] }
        return []
    }
}

// MARK: - DIMCONTINUE / DIMBASELINE

final class DimContinueCommand: CadCommand {
    private let baseline: Bool
    init(_ c: CommandController, name: String, baseline: Bool) { self.baseline = baseline; super.init(c, name: name) }
    private var prev: DimensionGeom?

    override func start() {
        prev = DimLinearCommand.last
        guard prev != nil else { c.message("No linear dimension to continue. Create one with DIMLINEAR first."); finish(); return }
        ask("Specify a second extension line origin", base: prev?.p2)
    }

    private func next(_ p: Vec2) -> DimensionGeom? {
        guard let d = prev else { return nil }
        var g = d
        if baseline {
            g.p2 = p
            let n = d.kind == .aligned ? (d.p2 - d.p1).normalized.perp : Vec2.polar(1, d.rotation).perp
            let side = (d.p3 - d.p1).dot(n) >= 0 ? 1.0 : -1.0
            g.p3 = d.p3 + n * side * drawing.settings.dimStyle.textHeight * drawing.settings.dimStyle.scale * 3
        } else {
            g.p1 = d.p2
            g.p2 = p
        }
        return g
    }

    override func point(_ p: Vec2) {
        guard let g = next(p) else { return }
        let e = make(.dimension(g))
        c.perform("Dimension") { $0.add(e) }
        prev = g
        DimLinearCommand.last = g
        ask("Specify a second extension line origin", base: p)
    }

    override func preview(_ cursor: Vec2) -> [Entity] { next(cursor).map { [make(.dimension($0))] } ?? [] }
}

// MARK: - DIMRADIUS / DIMDIAMETER

final class DimRadialCommand: CadCommand {
    private let diameter: Bool
    private var center: Vec2?
    private var radius = 0.0
    init(_ c: CommandController, name: String, diameter: Bool) { self.diameter = diameter; super.init(c, name: name) }

    override func start() { ask("Select arc or circle", .entity) }

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        guard let e = drawing.entity(id) else { return }
        switch e.kind {
        case .circle(let ci): center = ci.center; radius = ci.radius
        case .arc(let a): center = a.center; radius = a.radius
        case .polyline:
            if let prim = drawing.prims(of: e).min(by: { $0.distance(to: p) < $1.distance(to: p) }), case let .arc(cc, r, _, _) = prim {
                center = cc; radius = r
            }
        default: break
        }
        guard center != nil else { c.message("Select an arc or circle"); return }
        c.message("Dimension text = \(fmt(diameter ? radius * 2 : radius))")
        ask("Specify dimension line location")
    }

    private func geom(_ loc: Vec2) -> DimensionGeom? {
        guard let cc = center else { return nil }
        var dir = (loc - cc).normalized
        if dir == .zero { dir = Vec2(1, 0) }
        return DimensionGeom(kind: diameter ? .diameter : .radius, p1: cc, p2: cc + dir * radius, p3: loc)
    }

    override func point(_ p: Vec2) {
        guard let g = geom(p) else { return }
        let e = make(.dimension(g))
        c.perform("Dimension") { $0.add(e) }
        finish()
    }

    override func preview(_ cursor: Vec2) -> [Entity] { geom(cursor).map { [make(.dimension($0))] } ?? [] }
}

// MARK: - DIMANGULAR

final class DimAngularCommand: CadCommand {
    private var vertex: Vec2?
    private var leg1: Vec2?
    private var leg2: Vec2?
    private var firstLine: LineGeom?

    override func start() { ask("Select arc, circle, line", .entity) }

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        guard let e = drawing.entity(id) else { return }
        if let l1 = firstLine {
            guard case .line(let l2) = e.kind else { c.message("Select a line"); return }
            guard let (_, _, x) = lineLineIntersection(l1.start, l1.end, l2.start, l2.end) else { c.message("Lines are parallel"); return }
            vertex = x
            // Legs point toward the picked/farther ends.
            leg1 = l1.start.distance(to: x) > l1.end.distance(to: x) ? l1.start : l1.end
            leg2 = l2.start.distance(to: x) > l2.end.distance(to: x) ? l2.start : l2.end
            ask("Specify dimension arc line location")
            return
        }
        switch e.kind {
        case .arc(let a):
            vertex = a.center; leg1 = a.startPoint; leg2 = a.endPoint
            ask("Specify dimension arc line location")
        case .line(let l):
            firstLine = l
            ask("Select second line", .entity)
        default:
            c.message("Select an arc or line")
        }
    }

    private func geom(_ loc: Vec2) -> DimensionGeom? {
        guard let v = vertex, let a = leg1, let b = leg2 else { return nil }
        return DimensionGeom(kind: .angular, p1: v, p2: a, p3: loc, p4: b)
    }

    override func point(_ p: Vec2) {
        guard let g = geom(p) else { return }
        let e = make(.dimension(g))
        c.perform("Dimension") { $0.add(e) }
        c.message("Dimension text = \(fmt(g.measurement))°")
        finish()
    }

    override func preview(_ cursor: Vec2) -> [Entity] { geom(cursor).map { [make(.dimension($0))] } ?? [] }
}

// MARK: - QLEADER (simple leader: polyline + text)

final class LeaderCommand: CadCommand {
    private var pts: [Vec2] = []

    override func start() { ask("Specify leader arrowhead location") }

    override func point(_ p: Vec2) {
        pts.append(p)
        ask("Specify next point (Enter for text)", base: p)
    }

    override func enter() {
        guard pts.count >= 2 else { finish(); return }
        allowsSpaces = true
        ask("Enter annotation text", .text)
    }

    override func value(_ s: String) -> Bool {
        guard input == .text, pts.count >= 2 else { return false }
        let h = drawing.settings.dimStyle.textHeight * drawing.settings.dimStyle.scale
        let a = h, tip = pts[0], next = pts[1]
        let dir = (next - tip).normalized, n = dir.perp * (a / 6)
        let arrow = make(.hatch(HatchGeom(loops: [[PolyVertex(tip), PolyVertex(tip + dir * a + n), PolyVertex(tip + dir * a - n)]])))
        let line = make(.polyline(PolylineGeom(points: pts)))
        let last = pts[pts.count - 1], prev = pts[pts.count - 2]
        let right = last.x >= prev.x
        let text = make(.text(TextGeom(position: last + Vec2(right ? h / 2 : -h / 2, 0), height: h, text: s,
                                       hAlign: right ? .left : .right, vAlign: .middle)))
        c.perform("Leader") { d in d.add(arrow); d.add(line); d.add(text) }
        finish()
        return true
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        guard !pts.isEmpty, input == .point else { return [] }
        return [make(.polyline(PolylineGeom(points: pts + [cursor])))]
    }
}

// MARK: - BLOCK

final class BlockCommand: SelectionCommand {
    private var blockName = ""
    private var base: Vec2?

    override func start() {
        ask("Enter block name", .text)
    }

    override func value(_ s: String) -> Bool {
        guard input == .text else { return false }
        let n = s.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.hasPrefix("*") else { return false }
        if drawing.blocks[n] != nil { c.message("Block \"\(n)\" already exists and will be redefined.") }
        blockName = n
        ask("Specify insertion base point")
        return true
    }

    override func point(_ p: Vec2) {
        base = p
        super.start()
    }

    override func afterSelection() {
        guard let b = base else { return }
        let ents = selectedEntities
        let name = blockName
        let def = BlockDef(name: name, basePoint: b, entities: ents)
        // Selected ATTDEFs become part of the definition; the replacing reference gets their defaults.
        var geom = InsertGeom(blockName: name, position: b)
        geom.attributes = geom.makeAttributes(block: def)
        var insert = make(.insert(geom))
        insert.layer = drawing.settings.currentLayer
        let s = ids
        c.perform("Block") { d in
            d.blocks[name] = def
            d.remove(ids: s)
            d.add(insert)
        }
        c.message("Block \"\(name)\" created with \(ents.count) object(s)")
        finish()
    }
}

// MARK: - INSERT

final class InsertCommand: CadCommand {
    static var lastName: String?
    private var blockName: String?
    private var position: Vec2?
    private var scale = 1.0
    /// Reference waiting for attribute values, the definitions still to prompt and the answers.
    private var pending: InsertGeom?
    private var pendingDefs: [AttDefGeom] = []
    private var attValues: [String: String] = [:]

    override func start() {
        let names = drawing.blocks.keys.sorted()
        guard !names.isEmpty else { c.message("No blocks defined in this drawing. Use BLOCK first."); finish(); return }
        c.message("Blocks: " + names.joined(separator: ", "))
        let def = InsertCommand.lastName.flatMap { drawing.blocks[$0] != nil ? $0 : nil } ?? names[0]
        ask("Enter block name <\(def)>", .text)
    }

    override func enter() {
        if let def = pendingDefs.first, pending != nil {
            attValues[def.tag.uppercased()] = def.defaultValue
            pendingDefs.removeFirst()
            nextAttribute()
            return
        }
        if blockName == nil {
            let names = drawing.blocks.keys.sorted()
            _ = value(InsertCommand.lastName.flatMap { drawing.blocks[$0] != nil ? $0 : nil } ?? names.first ?? "")
        } else if position != nil {
            if prompt.hasPrefix("Specify scale") { ask("Specify rotation angle <0>", .text) } else { commit(0) }
        } else {
            finish()
        }
    }

    override func value(_ s: String) -> Bool {
        if let def = pendingDefs.first, pending != nil {
            attValues[def.tag.uppercased()] = s
            pendingDefs.removeFirst()
            nextAttribute()
            return true
        }
        if blockName == nil {
            guard let match = drawing.blocks.keys.first(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) else {
                c.message("Block \"\(s)\" not found"); return true
            }
            blockName = match
            InsertCommand.lastName = match
            ask("Specify insertion point")
            return true
        }
        guard let v = Double(s) else { return false }
        if prompt.hasPrefix("Specify scale") {
            scale = v
            ask("Specify rotation angle <0>", .text)
        } else {
            commit(radians(v))
        }
        return true
    }

    private func commit(_ rotation: Double) {
        guard let n = blockName, let p = position else { return }
        let geom = InsertGeom(blockName: n, position: p, scaleX: scale, scaleY: scale, rotation: rotation)
        // Prompt for each non-constant, non-preset attribute in definition order.
        pending = geom
        pendingDefs = (drawing.blocks[n]?.variableAttributeDefinitions ?? []).filter { !$0.isPreset }
        attValues = [:]
        nextAttribute()
    }

    private func nextAttribute() {
        if let def = pendingDefs.first {
            allowsSpaces = true
            let label = def.prompt.isEmpty ? def.tag : def.prompt
            ask("Enter \(label) <\(def.defaultValue)>", .text)
            return
        }
        guard var geom = pending, let block = drawing.blocks[geom.blockName] else { finish(); return }
        geom.attributes = geom.makeAttributes(block: block, values: attValues)
        let e = make(.insert(geom))
        c.perform("Insert") { $0.add(e) }
        pending = nil
        finish()
    }

    override func point(_ p: Vec2) {
        position = p
        ask("Specify scale factor <1>", .text)
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        guard let n = blockName, position == nil else { return [] }
        var g = InsertGeom(blockName: n, position: cursor)
        if let b = drawing.blocks[n] { g.attributes = g.makeAttributes(block: b) }
        return [make(.insert(g))]
    }
}

// MARK: - BEDIT

/// Opens a block definition in the Block Editor (selected reference, picked reference or typed name).
final class BlockEditCommand: CadCommand {
    override func start() {
        let d = drawing
        if let id = c.selection.first(where: { id in if case .insert = d.entity(id)?.kind { return true } else { return false } }),
           case .insert(let ins) = d.entity(id)!.kind {
            open(ins.blockName)
            return
        }
        let names = d.blocks.keys.filter { !$0.hasPrefix("*") }.sorted()
        guard !names.isEmpty else { c.message("No blocks defined in this drawing."); finish(); return }
        c.message("Blocks: " + names.joined(separator: ", "))
        ask("Select a block reference or enter block name", .entity, keywords: [])
    }

    private func open(_ name: String) {
        finish()
        c.delegate?.blockEditor(.open(name))
    }

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        guard case .insert(let ins) = drawing.entity(id)?.kind else { c.message("That object is not a block reference."); return }
        open(ins.blockName)
    }

    override func value(_ s: String) -> Bool {
        guard let n = drawing.blocks.keys.first(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) else {
            c.message("Block \"\(s)\" not found.")
            return true
        }
        open(n)
        return true
    }
}

// MARK: - LAYOUT

final class LayoutCommand: CadCommand {
    private var pending: String?

    override func start() {
        keepsSelection = true
        ask("Enter layout option", .text, keywords: ["New", "Rename", "Delete", "Set", "?", "Page setup"])
    }

    override func keyword(_ k: String) {
        pending = k
        switch k {
        case "New": ask("Enter new layout name <auto>", .text)
        case "Rename": ask("Enter layout to rename <\(drawing.activeLayout ?? "")>", .text)
        case "Delete": ask("Enter layout to delete <\(drawing.activeLayout ?? "")>", .text)
        case "Set": ask("Enter layout to make current (or Model)", .text)
        case "?": c.delegate?.layout(.list); finish()
        case "Page setup": c.delegate?.layout(.pageSetup); finish()
        default: break
        }
    }

    private var renameFrom: String?

    override func value(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        switch pending {
        case "New": c.delegate?.layout(.new(t.isEmpty ? nil : t)); finish()
        case "Rename":
            if let from = renameFrom { c.delegate?.layout(.rename(from, t)); finish() } else {
                renameFrom = t.isEmpty ? drawing.activeLayout : t
                ask("Enter new layout name", .text)
            }
        case "Delete":
            if let n = t.isEmpty ? drawing.activeLayout : t { c.delegate?.layout(.delete(n)) }
            finish()
        case "Set": c.delegate?.layout(.set(t.isEmpty ? nil : t)); finish()
        default:
            // Typing a layout name directly switches to it.
            c.delegate?.layout(.set(t)); finish()
        }
        return true
    }

    override func enter() {
        if pending == "New" { _ = value("") } else if pending == "Delete" || pending == "Rename" { _ = value("") } else { finish() }
    }
}

// MARK: - MVIEW

/// Creates a viewport in paper space showing the model extents.
final class MViewCommand: CadCommand {
    private var corner: Vec2?

    override func start() {
        guard drawing.isPaperSpace else {
            c.message("MVIEW works in a layout. Switch to a layout tab first.")
            finish(); return
        }
        ask("Specify corner of viewport", keywords: ["Fit"])
    }

    private func make(_ box: BBox) {
        var vp = ViewportGeom(center: box.center, width: box.width, height: box.height, viewCenter: box.center, viewHeight: box.height)
        vp.fit(c.modelScene.extents)
        let e = make(.viewport(vp))
        c.perform("Viewport") { $0.add(e) }
        c.message("Viewport created at scale \(formatViewportScale(vp.scale)). Double-click inside it to pan/zoom; set an exact scale in Properties.")
        finish()
    }

    override func keyword(_ k: String) {
        if k == "Fit", let paper = drawing.activeLayoutDef?.paper { make(paper.printableBox) }
    }

    override func point(_ p: Vec2) {
        guard let a = corner else { corner = p; ask("Specify opposite corner", base: p); return }
        let box = BBox(corner: a, p)
        guard box.width > 1e-6, box.height > 1e-6 else { return }
        make(box)
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        guard let a = corner else { return [] }
        return [make(.polyline(PolylineGeom(points: [a, Vec2(cursor.x, a.y), cursor, Vec2(a.x, cursor.y)], closed: true)))]
    }
}
