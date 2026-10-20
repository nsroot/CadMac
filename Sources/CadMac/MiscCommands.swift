import AppKit
import CadCore

// MARK: - Inquiry

final class DistCommand: CadCommand {
    private var a: Vec2?
    override func start() { keepsSelection = true; ask("Specify first point") }
    override func point(_ p: Vec2) {
        guard let s = a else { a = p; ask("Specify second point", base: p); return }
        let d = p - s
        let st = drawing.settings
        c.message("Distance = \(st.formatLengthDetailed(d.length)),  Angle in XY Plane = \(fmt(degrees(normalizeAngle(d.angle))))°")
        c.message("Delta X = \(st.formatLength(d.x)),  Delta Y = \(st.formatLength(d.y))")
        finish()
    }
    override func preview(_ cursor: Vec2) -> [Entity] {
        a.map { [make(.line(LineGeom(start: $0, end: cursor)))] } ?? []
    }
}

final class IdCommand: CadCommand {
    override func start() { keepsSelection = true; ask("Specify point") }
    override func point(_ p: Vec2) {
        let st = drawing.settings
        c.message("X = \(st.formatLength(p.x))     Y = \(st.formatLength(p.y))     Z = 0")
        finish()
    }
}

final class AreaCommand: CadCommand {
    private var pts: [Vec2] = []
    override func start() { ask("Specify first corner point", keywords: ["Object"]) }

    override func keyword(_ k: String) { if k == "Object" { ask("Select objects", .entity) } }

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        let st = drawing.settings
        if let a = drawing.area(of: id) {
            c.message("Area = \(st.formatArea(abs(a))),  Perimeter = \(st.formatLengthDetailed(drawing.perimeter(of: id) ?? 0))")
        } else if let l = drawing.perimeter(of: id) {
            c.message("Object is open. Length = \(st.formatLengthDetailed(l))")
        } else {
            c.message("Area cannot be computed for this object")
        }
        finish()
    }

    override func point(_ p: Vec2) {
        pts.append(p)
        ask("Specify next point (Enter to compute)", base: p)
    }

    override func enter() {
        if pts.count >= 3 {
            let area = abs(polygonArea(pts.map { PolyVertex($0) }))
            let per = zip(pts, pts.dropFirst() + [pts[0]]).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            let st = drawing.settings
            c.message("Area = \(st.formatArea(area)),  Perimeter = \(st.formatLengthDetailed(per))")
        }
        finish()
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        guard !pts.isEmpty else { return [] }
        return [make(.polyline(PolylineGeom(points: pts + [cursor], closed: pts.count >= 2)))]
    }
}

final class ListCommand: SelectionCommand {
    override func afterSelection() {
        for e in selectedEntities {
            c.message("\(e.kind.typeName.uppercased())  Layer: \"\(e.layer)\"  Color: \(e.color.displayName)  Linetype: \(e.linetype)")
            for line in describe(e) { c.message("    " + line) }
        }
        finish()
    }

    private func describe(_ e: Entity) -> [String] {
        let st = drawing.settings
        func L(_ v: Double) -> String { st.formatLength(v) }
        switch e.kind {
        case .line(let l):
            return ["from point \(l.start)", "to point \(l.end)", "Length = \(st.formatLengthDetailed(l.length)), Angle = \(fmt(degrees(normalizeAngle((l.end - l.start).angle))))°"]
        case .circle(let ci):
            return ["center point \(ci.center)", "radius \(L(ci.radius))", "circumference \(L(2 * .pi * ci.radius))", "area \(st.formatArea(.pi * ci.radius * ci.radius))"]
        case .arc(let a):
            return ["center point \(a.center)", "radius \(L(a.radius))", "start angle \(fmt(degrees(a.startAngle)))°", "end angle \(fmt(degrees(a.endAngle)))°", "length \(L(a.length))"]
        case .polyline(let p):
            var out = [p.closed ? "Closed" : "Open", "\(p.vertices.count) vertices"]
            if let a = drawing.area(of: e.id) { out.append("area \(st.formatArea(abs(a)))") }
            if let l = drawing.perimeter(of: e.id) { out.append("length \(st.formatLengthDetailed(l))") }
            return out
        case .text(let t): return ["text \"\(t.text)\"", "position \(t.position)", "height \(L(t.height))", "rotation \(fmt(degrees(t.rotation)))°"]
        case .insert(let i):
            return ["block \"\(i.blockName)\"", "at point \(i.position)", "scale \(fmt(i.scaleX)), \(fmt(i.scaleY))", "rotation \(fmt(degrees(i.rotation)))°"]
                + i.attributes.map { "attribute \($0.tag) = \"\($0.value)\"" }
        case .dimension(let d): return ["\(d.kind.rawValue) measurement \(d.kind == .angular ? fmt(d.measurement) + "°" : L(d.measurement))"]
        case .point(let p): return ["at point \(p.position)"]
        case .ellipse(let el): return ["center \(el.center)", "major axis \(L(el.majorAxis.length * 2))", "ratio \(fmt(el.ratio))"]
        case .hatch(let h): return ["pattern \(h.patternName)", "\(h.loops.count) loop(s)", drawing.area(of: e.id).map { "area \(st.formatArea(abs($0)))" } ?? ""]
        case .spline(let s): return ["\(max(s.fitPoints.count, s.controlPoints.count)) points", s.closed ? "closed" : "open"]
        case .attdef(let a):
            return ["tag \(a.tag)", "prompt \"\(a.prompt)\"", "default \"\(a.defaultValue)\"", "height \(L(a.text.height))",
                    a.isInvisible ? "invisible" : "visible", a.isConstant ? "constant" : "variable"]
        case .viewport(let v):
            return ["center \(v.center)", "size \(L(v.width)) x \(L(v.height))", "scale \(formatViewportScale(v.scale))",
                    "view center \(v.viewCenter)", v.isLocked ? "locked" : "unlocked", v.isOn ? "on" : "off"]
        }
    }
}

/// "1:100" for 0.01, "2:1" for 2, decimal otherwise.
func formatViewportScale(_ s: Double) -> String {
    guard s > 0 else { return "-" }
    if s <= 1 {
        let inv = 1 / s
        if abs(inv - inv.rounded()) < 1e-6 { return "1:\(Int(inv.rounded()))" }
        return "1:\(fmt(inv, precision: 3))"
    }
    if abs(s - s.rounded()) < 1e-6 { return "\(Int(s.rounded())):1" }
    return fmt(s, precision: 4)
}

/// Parses "1:100", "1/100", "100" (→ 1:100 when > 1 is meant as denominator is ambiguous, so plain numbers are factors).
func parseViewportScale(_ text: String) -> Double? {
    let t = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")
    for sep in [":", "/"] where t.contains(sep) {
        let p = t.split(separator: Character(sep))
        guard p.count == 2, let a = Double(p[0]), let b = Double(p[1]), a > 0, b > 0 else { return nil }
        return a / b
    }
    if t.lowercased().hasSuffix("xp"), let v = Double(t.dropLast(2)), v > 0 { return v }
    guard let v = Double(t), v > 0 else { return nil }
    return v
}

// MARK: - UNITS

final class UnitsCommand: CadCommand {
    override func start() {
        keepsSelection = true
        let cur = drawing.settings.insUnits
        c.message("Current drawing units: \(cur.displayName)\(cur == .unitless ? "" : " (\(cur.suffix))"). Changing units does not scale existing geometry.")
        ask("Specify drawing units <\(cur.displayName)>", .text, keywords: ["MIllimeters", "CEntimeters", "MEters", "INches", "FEet", "Unitless"])
    }

    override func keyword(_ k: String) {
        let map: [String: DrawingUnit] = ["MIllimeters": .millimeters, "CEntimeters": .centimeters, "MEters": .meters,
                                          "INches": .inches, "FEet": .feet, "Unitless": .unitless]
        guard let u = map[k] else { return }
        c.perform("Units") { $0.settings.insUnits = u }
        c.message("Drawing units set to \(u.displayName).")
        finish()
    }

    override func value(_ s: String) -> Bool {
        switch s.lowercased() {
        case "mm": keyword("MIllimeters")
        case "cm": keyword("CEntimeters")
        case "m": keyword("MEters")
        case "in", "inch", "\"": keyword("INches")
        case "ft", "'": keyword("FEet")
        default: return false
        }
        return true
    }

    override func enter() { finish() }
}

// MARK: - View

final class ZoomCommand: CadCommand {
    private var corner: Vec2?
    override func start() {
        keepsSelection = true
        ask("Specify corner of window, enter a scale factor (nX), or", keywords: ["All", "Extents", "Window", "Previous"])
    }

    override func keyword(_ k: String) {
        switch k {
        case "All", "Extents": c.delegate?.zoom(.extents); finish()
        case "Previous": c.delegate?.zoom(.previous); finish()
        case "Window": ask("Specify first corner")
        default: break
        }
    }

    override func value(_ s: String) -> Bool {
        var t = s.uppercased()
        if t.hasSuffix("X") || t.hasSuffix("XP") { t = t.replacingOccurrences(of: "XP", with: "").replacingOccurrences(of: "X", with: "") }
        guard let f = Double(t), f > 0 else { return false }
        c.delegate?.zoom(.scale(f))
        finish()
        return true
    }

    override func enter() { c.delegate?.zoom(.extents); finish() }

    override func point(_ p: Vec2) {
        guard let a = corner else { corner = p; ask("Specify opposite corner"); return }
        c.delegate?.zoom(.window(BBox(corner: a, p)))
        finish()
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        guard let a = corner else { return [] }
        return [Entity(.polyline(PolylineGeom(points: [a, Vec2(cursor.x, a.y), cursor, Vec2(a.x, cursor.y)], closed: true)), color: .aci(4))]
    }
}

// MARK: - Layer shortcuts

final class LayerPickCommand: CadCommand {
    enum Action { case off, freeze, lock, unlock, makeCurrent, isolate }
    private let action: Action
    init(_ c: CommandController, name: String, action: Action) { self.action = action; super.init(c, name: name) }

    override func start() { ask("Select an object on the target layer", .entity) }

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        guard let layer = drawing.entity(id)?.layer else { return }
        let current = drawing.settings.currentLayer
        switch action {
        case .off, .freeze:
            guard layer != current else { c.message("Layer \"\(layer)\" is the current layer and cannot be turned off/frozen."); return }
            c.perform(action == .off ? "Layer Off" : "Layer Freeze") { d in
                if let i = d.layers.firstIndex(where: { $0.name == layer }) {
                    if action == .off { d.layers[i].isOn = false } else { d.layers[i].isFrozen = true }
                }
            }
            c.message("Layer \"\(layer)\" has been turned \(action == .off ? "off" : "frozen").")
        case .lock, .unlock:
            c.perform(action == .lock ? "Layer Lock" : "Layer Unlock") { d in
                if let i = d.layers.firstIndex(where: { $0.name == layer }) { d.layers[i].isLocked = action == .lock }
            }
            c.message("Layer \"\(layer)\" has been \(action == .lock ? "locked" : "unlocked").")
            finish(); return
        case .makeCurrent:
            c.perform("Set Current Layer") { $0.settings.currentLayer = layer }
            c.message("\"\(layer)\" is now the current layer.")
            finish(); return
        case .isolate:
            c.perform("Layer Isolate") { d in
                d.settings.currentLayer = layer
                for i in d.layers.indices { d.layers[i].isOn = d.layers[i].name == layer }
            }
            c.message("Layer \"\(layer)\" has been isolated.")
            finish(); return
        }
    }
}

/// Runs a closure immediately (non-interactive commands).
final class ActionCommand: CadCommand {
    private let action: (CommandController) -> Void
    init(_ c: CommandController, name: String, keepSelection: Bool = false, _ action: @escaping (CommandController) -> Void) {
        self.action = action
        super.init(c, name: name)
        keepsSelection = keepSelection
    }
    override func start() {
        action(c)
        finish()
    }
}

// MARK: - SETVAR / numeric system variables

final class SetvarCommand: CadCommand {
    private var variable: String?
    init(_ c: CommandController, name: String, variable: String? = nil) {
        self.variable = variable
        super.init(c, name: name)
    }

    static let variables: [String: (get: (Drawing) -> Double, set: (inout Drawing, Double) -> Void)] = [
        "LTSCALE": ({ $0.settings.ltScale }, { $0.settings.ltScale = max($1, 1e-9) }),
        "TEXTSIZE": ({ $0.settings.textHeight }, { $0.settings.textHeight = max($1, 1e-9) }),
        "DIMSCALE": ({ $0.settings.dimStyle.scale }, { $0.settings.dimStyle.scale = max($1, 1e-9) }),
        "DIMTXT": ({ $0.settings.dimStyle.textHeight }, { $0.settings.dimStyle.textHeight = max($1, 1e-9) }),
        "DIMASZ": ({ $0.settings.dimStyle.arrowSize }, { $0.settings.dimStyle.arrowSize = max($1, 0) }),
        "DIMDEC": ({ Double($0.settings.dimStyle.precision) }, { $0.settings.dimStyle.precision = max(0, min(8, Int($1))) }),
        "DIMEXO": ({ $0.settings.dimStyle.extensionOffset }, { $0.settings.dimStyle.extensionOffset = $1 }),
        "DIMEXE": ({ $0.settings.dimStyle.extensionExtend }, { $0.settings.dimStyle.extensionExtend = $1 }),
        "DIMGAP": ({ $0.settings.dimStyle.textGap }, { $0.settings.dimStyle.textGap = $1 }),
        "FILLETRAD": ({ $0.settings.filletRadius }, { $0.settings.filletRadius = max($1, 0) }),
        "CHAMFERA": ({ $0.settings.chamferDist1 }, { $0.settings.chamferDist1 = max($1, 0) }),
        "CHAMFERB": ({ $0.settings.chamferDist2 }, { $0.settings.chamferDist2 = max($1, 0) }),
        "OFFSETDIST": ({ $0.settings.offsetDistance }, { $0.settings.offsetDistance = $1 }),
        "GRIDUNIT": ({ $0.settings.gridSpacing }, { $0.settings.gridSpacing = max($1, 1e-9) }),
        "SNAPUNIT": ({ $0.settings.snapSpacing }, { $0.settings.snapSpacing = max($1, 1e-9) }),
        "LUPREC": ({ Double($0.settings.unitPrecision) }, { $0.settings.unitPrecision = max(0, min(8, Int($1))) }),
    ]

    override func start() {
        keepsSelection = true
        if let v = variable { askValue(v) } else { ask("Enter variable name", .text) }
    }

    private func askValue(_ v: String) {
        variable = v
        guard let entry = SetvarCommand.variables[v] else { c.message("Unknown variable name."); finish(); return }
        ask("Enter new value for \(v) <\(fmt(entry.get(drawing)))>", .text)
    }

    override func value(_ s: String) -> Bool {
        guard let v = variable else {
            let n = s.uppercased()
            if SetvarCommand.variables[n] == nil { c.message("Unknown variable name. Known: " + SetvarCommand.variables.keys.sorted().joined(separator: ", ")); finish(); return true }
            askValue(n)
            return true
        }
        guard let x = Double(s), let entry = SetvarCommand.variables[v] else { return false }
        c.perform("Set \(v)") { entry.set(&$0, x) }
        finish()
        return true
    }
}

// MARK: - Clipboard

@MainActor
enum CadClipboard {
    static var entities: [Entity] = []
    static var blocks: [String: BlockDef] = [:]
    static var base = Vec2.zero
}

final class PasteCommand: CadCommand {
    override func start() {
        guard !CadClipboard.entities.isEmpty else { c.message("Clipboard is empty"); finish(); return }
        ask("Specify insertion point")
    }
    private func items(at p: Vec2) -> [Entity] {
        CadClipboard.entities.map { $0.transformed(by: .translation(p - CadClipboard.base)).duplicate() }
    }
    override func point(_ p: Vec2) {
        let ents = items(at: p)
        let blocks = CadClipboard.blocks
        c.perform("Paste") { d in
            for (k, b) in blocks where d.blocks[k] == nil { d.blocks[k] = b }
            for e in ents { d.add(e) }
        }
        c.selection = Set(ents.map(\.id))
        finish()
        c.selection = Set(ents.map(\.id))
    }
    override func preview(_ cursor: Vec2) -> [Entity] { items(at: cursor) }
}

// MARK: - SAVETIME

final class SaveTimeCommand: CadCommand {
    override func start() {
        keepsSelection = true
        ask("Enter automatic save interval in minutes (0 = off) <\(fmt(AutoSaveManager.shared.interval))>", .text)
    }
    override func value(_ s: String) -> Bool {
        guard let v = Double(s), v >= 0 else { return false }
        AutoSaveManager.shared.interval = v
        c.message(v == 0 ? "Automatic save is off." : "Drawings are backed up every \(fmt(v)) minutes.")
        finish()
        return true
    }
}
