import AppKit
import CadCore

/// Commands that start by building a selection set (noun-verb or verb-noun).
class SelectionCommand: CadCommand {
    var ids: Set<EntityID> = []

    override func start() {
        let pre = c.selection.filter { id in drawing.entity(id).map(drawing.isEditable) ?? false }
        if !pre.isEmpty {
            ids = pre
            c.rememberSelection(pre)
            afterSelection()
        } else {
            c.selection.removeAll()
            ask("Select objects", .selection)
        }
    }

    override func selectionDone(_ s: Set<EntityID>) {
        guard !s.isEmpty else { finish(); return }
        ids = s
        afterSelection()
    }

    func afterSelection() {}

    var selectedEntities: [Entity] { drawing.entities.filter { ids.contains($0.id) } }

    func transformed(_ t: Transform2D) -> [Entity] { selectedEntities.map { $0.transformed(by: t) } }

    func apply(_ name: String, _ t: Transform2D, copy: Bool = false) {
        let moved = transformed(t)
        c.perform(name) { d in
            for e in moved {
                if copy { d.add(e.duplicate()) } else { d.replace(e) }
            }
        }
    }
}

// MARK: - ERASE

final class EraseCommand: SelectionCommand {
    override func afterSelection() {
        let s = ids
        c.perform("Erase") { $0.remove(ids: s) }
        c.message("\(s.count) object(s) erased")
        finish()
    }
}

// MARK: - MOVE / COPY

final class MoveCommand: SelectionCommand {
    private let copyMode: Bool
    private var base: Vec2?
    init(_ c: CommandController, name: String, copy: Bool) { copyMode = copy; super.init(c, name: name) }

    override func afterSelection() {
        ask("Specify base point", keywords: copyMode ? [] : ["Displacement"])
    }

    override func keyword(_ k: String) {
        switch k {
        case "Displacement": base = .zero; ask("Specify displacement (dx,dy)", .text)
        case "Exit": finish()
        case "Undo": c.undo(); ask("Specify second point", keywords: ["Exit", "Undo"], base: base)
        default: break
        }
    }

    override func value(_ s: String) -> Bool {
        guard let d = c.parsePoint(s), base == .zero else { return false }
        apply(copyMode ? "Copy" : "Move", .translation(d), copy: copyMode)
        finish()
        return true
    }

    override func point(_ p: Vec2) {
        guard let b = base else {
            base = p
            ask("Specify second point", keywords: copyMode ? ["Exit"] : [], base: p)
            return
        }
        apply(copyMode ? "Copy" : "Move", .translation(p - b), copy: copyMode)
        if copyMode {
            ask("Specify second point", keywords: ["Exit", "Undo"], base: b)
        } else {
            finish()
        }
    }

    override func enter() { finish() }

    override func previewTransform(_ cursor: Vec2) -> (ids: Set<EntityID>, transform: Transform2D)? {
        guard let b = base, input == .point else { return nil }
        return (ids, .translation(cursor - b))
    }
}

// MARK: - ROTATE

final class RotateCommand: SelectionCommand {
    private var base: Vec2?
    private var copyMode = false
    private var refAngle: Double?
    private var refStart: Vec2?

    override func afterSelection() { ask("Specify base point") }

    override func keyword(_ k: String) {
        switch k {
        case "Copy": copyMode.toggle(); c.message(copyMode ? "Rotating a copy of the selected objects." : "Rotating selected objects."); askAngle()
        case "Reference": ask("Specify the reference angle <0>", .point, base: base)
        default: break
        }
    }

    private func askAngle() { ask("Specify rotation angle", keywords: ["Copy", "Reference"], base: base) }

    private func rotate(_ ang: Double) {
        guard let b = base else { return }
        apply("Rotate", .rotation(ang - (refAngle ?? 0), about: b), copy: copyMode)
        finish()
    }

    override func point(_ p: Vec2) {
        guard let b = base else { base = p; askAngle(); return }
        if prompt.hasPrefix("Specify the reference angle") {
            if refStart == nil { refStart = p; ask("Specify second point", base: p); return }
        }
        if prompt.hasPrefix("Specify second point"), let rs = refStart {
            refAngle = (p - rs).angle
            ask("Specify the new angle", base: b)
            return
        }
        rotate((p - b).angle)
    }

    override func value(_ s: String) -> Bool {
        guard let v = Double(s) else { return false }
        if prompt.hasPrefix("Specify the reference angle") {
            refAngle = radians(v)
            ask("Specify the new angle", base: base)
            return true
        }
        rotate(radians(v))
        return true
    }

    override func previewTransform(_ cursor: Vec2) -> (ids: Set<EntityID>, transform: Transform2D)? {
        guard let b = base, input == .point, !prompt.hasPrefix("Specify the reference"), !prompt.hasPrefix("Specify second") else { return nil }
        return (ids, .rotation((cursor - b).angle - (refAngle ?? 0), about: b))
    }
}

// MARK: - SCALE

final class ScaleCommand: SelectionCommand {
    private var base: Vec2?
    private var copyMode = false
    private var refLength: Double?

    override func afterSelection() { ask("Specify base point") }

    private func askFactor() { ask("Specify scale factor", keywords: ["Copy", "Reference"], base: base) }

    override func keyword(_ k: String) {
        switch k {
        case "Copy": copyMode.toggle(); askFactor()
        case "Reference": ask("Specify reference length <1>", .text)
        default: break
        }
    }

    private func scale(_ f: Double) {
        guard let b = base, f > 0 else { return }
        apply("Scale", .scale(f / (refLength ?? 1), about: b), copy: copyMode)
        finish()
    }

    override func point(_ p: Vec2) {
        guard let b = base else { base = p; askFactor(); return }
        scale(b.distance(to: p))
    }

    override func value(_ s: String) -> Bool {
        guard let v = Double(s), v > 0 else { return false }
        if prompt.hasPrefix("Specify reference length") {
            refLength = v
            ask("Specify new length", base: base)
            return true
        }
        scale(v)
        return true
    }

    override func previewTransform(_ cursor: Vec2) -> (ids: Set<EntityID>, transform: Transform2D)? {
        guard let b = base, input == .point else { return nil }
        let f = b.distance(to: cursor) / (refLength ?? 1)
        return f > 1e-9 ? (ids, .scale(f, about: b)) : nil
    }
}

// MARK: - MIRROR

final class MirrorCommand: SelectionCommand {
    private var p1: Vec2?
    private var p2: Vec2?

    override func afterSelection() { ask("Specify first point of mirror line") }

    override func point(_ p: Vec2) {
        if p1 == nil { p1 = p; ask("Specify second point of mirror line", base: p); return }
        guard let a = p1, !a.isClose(to: p) else { return }
        p2 = p
        ask("Erase source objects? <No>", .text, keywords: ["Yes", "No"])
    }

    private func commit(erase: Bool) {
        guard let a = p1, let b = p2 else { return }
        apply("Mirror", .mirror(a, b), copy: !erase)
        finish()
    }

    override func keyword(_ k: String) { commit(erase: k == "Yes") }
    override func enter() { if p2 != nil { commit(erase: false) } else { finish() } }

    override func previewTransform(_ cursor: Vec2) -> (ids: Set<EntityID>, transform: Transform2D)? {
        guard let a = p1, p2 == nil, !a.isClose(to: cursor) else { return nil }
        return (ids, .mirror(a, cursor))
    }
}

// MARK: - STRETCH

final class StretchCommand: SelectionCommand {
    private var base: Vec2?
    private var window: BBox?

    override func start() {
        c.message("Select objects to stretch by crossing-window...")
        c.selection.removeAll()
        ask("Select objects", .selection)
    }

    override func afterSelection() {
        window = c.lastSelectionWindow
        guard window != nil else {
            c.message("Use a crossing window (drag right-to-left) to select objects to stretch.")
            finish()
            return
        }
        ask("Specify base point")
    }

    override func point(_ p: Vec2) {
        guard let b = base else { base = p; ask("Specify second point", base: p); return }
        guard let w = window else { return }
        let updated = drawing.stretch(ids, window: w, delta: p - b)
        c.perform("Stretch") { d in for e in updated { d.replace(e) } }
        finish()
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        guard let b = base, let w = window else { return [] }
        return drawing.stretch(ids, window: w, delta: cursor - b)
    }
}

// MARK: - OFFSET

final class OffsetCommand: CadCommand {
    private var distance: Double?
    private var through = false
    private var target: EntityID?

    override func start() {
        let d = drawing.settings.offsetDistance
        ask("Specify offset distance <\(fmt(d))>", .point, keywords: ["Through"])
    }

    override func keyword(_ k: String) {
        switch k {
        case "Through": through = true; askObject()
        case "Exit": finish()
        default: break
        }
    }

    private func askObject() {
        target = nil
        c.selection.removeAll()
        ask("Select object to offset", .entity, keywords: ["Exit"])
    }

    private var firstDistancePoint: Vec2?

    override func value(_ s: String) -> Bool {
        guard distance == nil, !through, let v = Double(s), v > 0 else { return false }
        setDistance(v)
        return true
    }

    private func setDistance(_ v: Double) {
        distance = v
        c.perform("Offset distance") { $0.settings.offsetDistance = v }
        askObject()
    }

    override func enter() {
        if distance == nil && !through { setDistance(drawing.settings.offsetDistance) } else { finish() }
    }

    override func point(_ p: Vec2) {
        if distance == nil && !through {
            // Distance by two points.
            if let a = firstDistancePoint { setDistance(a.distance(to: p)) } else { firstDistancePoint = p; ask("Specify second point", base: p) }
            return
        }
        guard let id = target else { return }
        do {
            let e = through ? try drawing.offsetThrough(id, point: p) : try drawing.offset(id, distance: distance ?? 0, side: p)
            c.perform("Offset") { $0.add(e) }
        } catch {
            c.message(error.localizedDescription)
        }
        askObject()
    }

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        target = id
        c.selection = [id]
        ask(through ? "Specify through point" : "Specify point on side to offset", .point, keywords: ["Exit"])
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        guard let id = target, input == .point else { return [] }
        let e = through ? try? drawing.offsetThrough(id, point: cursor) : try? drawing.offset(id, distance: distance ?? 0, side: cursor)
        return e.map { [$0] } ?? []
    }
}

// MARK: - TRIM / EXTEND

final class TrimExtendCommand: CadCommand {
    private let extendMode: Bool
    private var edges: Set<EntityID>?
    init(_ c: CommandController, name: String, extend: Bool) { extendMode = extend; super.init(c, name: name) }

    override func start() {
        c.message("Current settings: Mode=Quick, all objects are \(extendMode ? "boundary edges" : "cutting edges")")
        askPick()
    }

    private func askPick() {
        c.selection.removeAll()
        ask(extendMode ? "Select object to extend" : "Select object to trim", .entity,
            keywords: [extendMode ? "Boundary edges" : "cuTting edges", "Undo"])
    }

    override func keyword(_ k: String) {
        switch k {
        case "cuTting edges", "Boundary edges":
            ask("Select edges <ALL>", .selection)
        case "Undo":
            c.undo()
            askPick()
        default: break
        }
    }

    override func selectionDone(_ s: Set<EntityID>) {
        edges = s.isEmpty ? nil : s
        c.message(s.isEmpty ? "All objects will be used as edges" : "\(s.count) edge(s) selected")
        askPick()
    }

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        guard let e = drawing.entity(id), drawing.isEditable(e) else { return }
        do {
            if extendMode {
                let out = try drawing.extend(id, pick: p, boundaries: edges)
                c.perform("Extend") { $0.replace(out) }
            } else {
                let pieces = try drawing.trim(id, pick: p, cuttingEdges: edges)
                c.perform("Trim") { d in
                    d.remove(ids: [id])
                    for piece in pieces { d.add(piece) }
                }
            }
        } catch {
            c.message(error.localizedDescription)
        }
        askPick()
    }
}

// MARK: - FILLET / CHAMFER

final class FilletChamferCommand: CadCommand {
    private let chamferMode: Bool
    private var first: (EntityID, Vec2)?
    init(_ c: CommandController, name: String, chamfer: Bool) { chamferMode = chamfer; super.init(c, name: name) }

    override func start() {
        let s = drawing.settings
        if chamferMode {
            c.message("(TRIM mode) Current chamfer Dist1 = \(fmt(s.chamferDist1)), Dist2 = \(fmt(s.chamferDist2))")
        } else {
            c.message("Current settings: Mode = TRIM, Radius = \(fmt(s.filletRadius))")
        }
        askFirst()
    }

    private func askFirst() {
        first = nil
        c.selection.removeAll()
        ask(chamferMode ? "Select first line" : "Select first object", .entity,
            keywords: chamferMode ? ["Distance", "Polyline"] : ["Radius", "Polyline"])
    }

    override func keyword(_ k: String) {
        switch k {
        case "Radius": ask("Specify fillet radius <\(fmt(drawing.settings.filletRadius))>", .text)
        case "Distance": ask("Specify first chamfer distance <\(fmt(drawing.settings.chamferDist1))>", .text)
        case "Polyline": ask("Select 2D polyline", .entity)
        default: break
        }
    }

    override func value(_ s: String) -> Bool {
        guard let v = Double(s), v >= 0 else { return false }
        if prompt.hasPrefix("Specify fillet radius") {
            c.perform("Fillet radius") { $0.settings.filletRadius = v }
            askFirst()
        } else if prompt.hasPrefix("Specify first chamfer") {
            c.perform("Chamfer distance") { $0.settings.chamferDist1 = v; $0.settings.chamferDist2 = v }
            ask("Specify second chamfer distance <\(fmt(v))>", .text)
        } else if prompt.hasPrefix("Specify second chamfer") {
            c.perform("Chamfer distance") { $0.settings.chamferDist2 = v }
            askFirst()
        } else {
            return false
        }
        return true
    }

    override func enter() {
        if input == .text { askFirst() } else { finish() }
    }

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        if prompt.hasPrefix("Select 2D polyline") {
            do {
                guard !chamferMode else { c.message("Polyline chamfer is not supported yet"); askFirst(); return }
                let out = try drawing.filletPolyline(id, radius: drawing.settings.filletRadius)
                c.perform("Fillet") { $0.replace(out) }
                finish()
            } catch { c.message(error.localizedDescription); askFirst() }
            return
        }
        guard let (id1, p1) = first else {
            first = (id, p)
            c.selection = [id]
            ask(chamferMode ? "Select second line" : "Select second object", .entity)
            return
        }
        do {
            let s = drawing.settings
            let result = chamferMode
                ? try drawing.chamfer(id1, pick1: p1, id, pick2: p, d1: s.chamferDist1, d2: s.chamferDist2)
                : try drawing.fillet(id1, pick1: p1, id, pick2: p, radius: s.filletRadius)
            let template = drawing.entity(id1)
            c.perform(chamferMode ? "Chamfer" : "Fillet") { d in
                for m in result.modified { d.replace(m) }
                for var a in result.added {
                    if let t = template { a.layer = t.layer; a.color = t.color; a.linetype = t.linetype; a.lineweight = t.lineweight }
                    d.add(a)
                }
            }
            finish()
        } catch {
            c.message(error.localizedDescription)
            askFirst()
        }
    }
}

// MARK: - BREAK

final class BreakCommand: CadCommand {
    private var target: EntityID?
    private var first: Vec2?

    override func start() { ask("Select object", .entity) }

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        target = id
        first = p
        c.selection = [id]
        ask("Specify second break point (Enter = break at point)", .point, keywords: ["First point"])
    }

    override func keyword(_ k: String) {
        if k == "First point" { first = nil; ask("Specify first break point") }
    }

    override func point(_ p: Vec2) {
        guard first != nil else { first = p; ask("Specify second break point"); return }
        commit(p)
    }

    override func enter() {
        if let f = first, target != nil { commit(f) } else { finish() }
    }

    private func commit(_ p2: Vec2) {
        guard let id = target, let p1 = first else { return }
        do {
            let pieces = try drawing.breakEntity(id, p1, p2)
            c.perform("Break") { d in
                d.remove(ids: [id])
                for piece in pieces { d.add(piece) }
            }
        } catch {
            c.message(error.localizedDescription)
        }
        finish()
    }
}

// MARK: - JOIN / EXPLODE

final class JoinCommand: SelectionCommand {
    override func afterSelection() {
        do {
            let r = try drawing.join(Array(ids))
            c.perform("Join") { d in
                d.remove(ids: r.removed)
                for e in r.added { d.add(e) }
            }
            c.message("\(r.removed.count) objects joined into \(r.added.count)")
        } catch {
            c.message(error.localizedDescription)
        }
        finish()
    }
}

final class ExplodeCommand: SelectionCommand {
    override func afterSelection() {
        var removed: Set<EntityID> = []
        var added: [Entity] = []
        for id in ids {
            if let parts = drawing.explode(id) { removed.insert(id); added += parts }
        }
        if removed.isEmpty {
            c.message("Selected objects cannot be exploded")
        } else {
            c.perform("Explode") { d in
                d.remove(ids: removed)
                for e in added { d.add(e) }
            }
            c.message("\(removed.count) object(s) exploded")
        }
        finish()
    }
}

// MARK: - LENGTHEN

final class LengthenCommand: CadCommand {
    static var mode: LengthenMode = .delta(10)

    override func start() { askPick() }

    private func askPick() {
        ask("Select an object to change", .entity, keywords: ["DElta", "Percent", "Total"])
    }

    override func keyword(_ k: String) {
        switch k {
        case "DElta": ask("Enter delta length", .text)
        case "Percent": ask("Enter percentage length", .text)
        case "Total": ask("Specify total length", .text)
        default: break
        }
    }

    override func value(_ s: String) -> Bool {
        guard let v = Double(s) else { return false }
        if prompt.hasPrefix("Enter delta") { LengthenCommand.mode = .delta(v) }
        else if prompt.hasPrefix("Enter percentage") { LengthenCommand.mode = .percent(v) }
        else if prompt.hasPrefix("Specify total") { LengthenCommand.mode = .total(v) }
        else { return false }
        askPick()
        return true
    }

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        do {
            let e = try drawing.lengthen(id, pick: p, mode: LengthenCommand.mode)
            c.perform("Lengthen") { $0.replace(e) }
        } catch {
            c.message(error.localizedDescription)
        }
        askPick()
    }
}

// MARK: - ARRAY

final class ArrayCommand: SelectionCommand {
    enum Kind { case ask, rectangular, polar, path }
    private var kind: Kind
    private var rows = 3, cols = 4
    private var rowSpacing = 0.0, colSpacing = 0.0
    private var center: Vec2?
    private var count = 6
    private var fill = 360.0

    init(_ c: CommandController, name: String, kind: Kind) { self.kind = kind; super.init(c, name: name) }

    override func afterSelection() {
        let b = drawing.extents(of: selectedEntities)
        colSpacing = max(b.width * 1.5, 1)
        rowSpacing = max(b.height * 1.5, 1)
        switch kind {
        case .ask: ask("Enter array type <Rectangular>", .text, keywords: ["Rectangular", "PAth", "POlar"])
        case .rectangular: ask("Enter number of rows <\(rows)>", .text)
        case .polar: ask("Specify center point of array")
        case .path: ask("Select path curve", .entity)
        }
    }

    override func keyword(_ k: String) {
        switch k {
        case "Rectangular": kind = .rectangular; afterSelection()
        case "POlar": kind = .polar; afterSelection()
        case "PAth": kind = .path; afterSelection()
        default: break
        }
    }

    override func enter() {
        if input == .text {
            if kind == .ask { kind = .rectangular; afterSelection(); return }
            _ = value("")
        } else {
            finish()
        }
    }

    override func value(_ s: String) -> Bool {
        let v = s.isEmpty ? nil : Double(s)
        if !s.isEmpty && v == nil { return false }
        if prompt.hasPrefix("Enter number of rows") {
            if let v { rows = max(1, Int(v)) }
            ask("Enter number of columns <\(cols)>", .text)
        } else if prompt.hasPrefix("Enter number of columns") {
            if let v { cols = max(1, Int(v)) }
            ask("Specify the distance between rows <\(fmt(rowSpacing))>", .text)
        } else if prompt.hasPrefix("Specify the distance between rows") {
            if let v { rowSpacing = v }
            ask("Specify the distance between columns <\(fmt(colSpacing))>", .text)
        } else if prompt.hasPrefix("Specify the distance between columns") {
            if let v { colSpacing = v }
            commit(drawing.rectangularArray(ids, rows: rows, columns: cols, rowSpacing: rowSpacing, columnSpacing: colSpacing))
        } else if prompt.hasPrefix("Enter number of items along path") {
            if let v { count = max(2, Int(v)) }
            guard let path = pathID else { return false }
            commit(drawing.pathArray(ids, path: path, count: count, alignItems: true))
        } else if prompt.hasPrefix("Enter number of items") {
            if let v { count = max(2, Int(v)) }
            ask("Specify the angle to fill (+=ccw, -=cw) <\(fmt(fill))>", .text)
        } else if prompt.hasPrefix("Specify the angle to fill") {
            if let v { fill = v }
            guard let cc = center else { return false }
            commit(drawing.polarArray(ids, center: cc, count: count, fillAngle: radians(fill), rotateItems: true))
        } else {
            return false
        }
        return true
    }

    private var pathID: EntityID?

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        pathID = id
        ask("Enter number of items along path <\(count)>", .text)
    }

    override func point(_ p: Vec2) {
        center = p
        ask("Enter number of items <\(count)>", .text)
    }

    private func commit(_ items: [Entity]) {
        c.perform("Array") { d in for e in items { d.add(e) } }
        c.message("\(items.count) item(s) created")
        finish()
    }
}

// MARK: - MATCHPROP

final class MatchPropCommand: CadCommand {
    private var source: Entity?

    override func start() { ask("Select source object", .entity) }

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        guard let src = source else {
            source = drawing.entity(id)
            c.message("Current active settings: Color Layer Ltype Lineweight")
            ask("Select destination object(s)", .entity)
            return
        }
        guard var e = drawing.entity(id), drawing.isEditable(e) else { return }
        e.layer = src.layer; e.color = src.color; e.linetype = src.linetype; e.lineweight = src.lineweight
        c.perform("Match Properties") { $0.replace(e) }
    }
}

// MARK: - DIVIDE / MEASURE

final class DivideMeasureCommand: CadCommand {
    private let measureMode: Bool
    private var target: EntityID?
    init(_ c: CommandController, name: String, measure: Bool) { measureMode = measure; super.init(c, name: name) }

    override func start() { ask(measureMode ? "Select object to measure" : "Select object to divide", .entity) }

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        target = id
        ask(measureMode ? "Specify length of segment" : "Enter the number of segments", .text)
    }

    override func value(_ s: String) -> Bool {
        guard let id = target, let v = Double(s), v > 0 else { return false }
        let pts = measureMode ? drawing.measure(id, length: v) : drawing.divide(id, segments: Int(v))
        let ents = pts.map { make(.point(PointGeom(position: $0))) }
        c.perform(measureMode ? "Measure" : "Divide") { d in for e in ents { d.add(e) } }
        c.message("\(ents.count) point(s) placed")
        finish()
        return true
    }
}
