import Foundation

// MARK: - Table records

public struct Layer: Hashable, Codable, Identifiable {
    public var name: String
    /// Always .aci or .rgb (never ByLayer/ByBlock).
    public var color: CadColor
    public var linetype: String
    /// Lineweight in mm; negative = default.
    public var lineweight: Double
    public var isOn: Bool
    public var isFrozen: Bool
    public var isLocked: Bool
    public var isPlottable: Bool

    public var id: String { name }
    public var isVisible: Bool { isOn && !isFrozen }

    public init(name: String, color: CadColor = .aci(7), linetype: String = "Continuous", lineweight: Double = -1,
                isOn: Bool = true, isFrozen: Bool = false, isLocked: Bool = false, isPlottable: Bool = true) {
        self.name = name; self.color = color; self.linetype = linetype; self.lineweight = lineweight
        self.isOn = isOn; self.isFrozen = isFrozen; self.isLocked = isLocked; self.isPlottable = isPlottable
    }
}

public struct Linetype: Hashable, Codable, Identifiable {
    public var name: String
    public var description: String
    /// Dash pattern in drawing units: positive = dash, negative = gap, 0 = dot.
    public var pattern: [Double]
    public var id: String { name }
    public init(name: String, description: String, pattern: [Double]) {
        self.name = name; self.description = description; self.pattern = pattern
    }

    public static let standard: [Linetype] = [
        Linetype(name: "Continuous", description: "Solid line", pattern: []),
        Linetype(name: "DASHED", description: "Dashed __ __ __ __", pattern: [12.7, -6.35]),
        Linetype(name: "HIDDEN", description: "Hidden __ __ __ __", pattern: [6.35, -3.175]),
        Linetype(name: "CENTER", description: "Center ____ _ ____ _", pattern: [31.75, -6.35, 6.35, -6.35]),
        Linetype(name: "DASHDOT", description: "Dash dot __ . __ . __", pattern: [12.7, -6.35, 0, -6.35]),
        Linetype(name: "DOT", description: "Dot . . . . . . . .", pattern: [0, -6.35]),
        Linetype(name: "PHANTOM", description: "Phantom ______  __  __", pattern: [31.75, -6.35, 6.35, -6.35, 6.35, -6.35]),
        Linetype(name: "BORDER", description: "Border __ __ . __ __ .", pattern: [12.7, -6.35, 12.7, -6.35, 0, -6.35]),
    ]
}

public struct BlockDef: Hashable, Codable, Identifiable {
    public var name: String
    public var basePoint: Vec2
    public var entities: [Entity]
    public var id: String { name }
    public init(name: String, basePoint: Vec2 = .zero, entities: [Entity] = []) {
        self.name = name; self.basePoint = basePoint; self.entities = entities
    }
}

public struct DimStyle: Hashable, Codable {
    public var name: String = "ISO-25"
    public var textHeight: Double = 2.5
    public var arrowSize: Double = 2.5
    public var extensionOffset: Double = 0.625
    public var extensionExtend: Double = 1.25
    public var textGap: Double = 0.625
    public var precision: Int = 2
    /// Overall scale (DIMSCALE).
    public var scale: Double = 1
    public var suffix: String = ""
    public init() {}

    public func format(_ v: Double, kind: DimensionKind) -> String {
        var s = String(format: "%.\(max(0, precision))f", v)
        if kind == .angular { s += "°" }
        if kind == .radius { s = "R" + s }
        if kind == .diameter { s = "Ø" + s }
        return s + suffix
    }
}

public enum LengthUnits: Int, Codable, CaseIterable {
    case scientific = 1, decimal = 2, engineering = 3, architectural = 4, fractional = 5
}

/// Drawing insertion units (DXF $INSUNITS): what one drawing unit means in the real world.
public enum DrawingUnit: Int, Codable, CaseIterable {
    case unitless = 0, inches = 1, feet = 2, millimeters = 4, centimeters = 5, meters = 6

    public var suffix: String {
        switch self {
        case .unitless: return ""
        case .inches: return "in"
        case .feet: return "ft"
        case .millimeters: return "mm"
        case .centimeters: return "cm"
        case .meters: return "m"
        }
    }

    public var displayName: String {
        switch self {
        case .unitless: return "Unitless"
        case .inches: return "Inches"
        case .feet: return "Feet"
        case .millimeters: return "Millimeters"
        case .centimeters: return "Centimeters"
        case .meters: return "Meters"
        }
    }

    /// Meters per drawing unit (nil when unitless).
    public var meters: Double? {
        switch self {
        case .unitless: return nil
        case .inches: return 0.0254
        case .feet: return 0.3048
        case .millimeters: return 0.001
        case .centimeters: return 0.01
        case .meters: return 1
        }
    }
}

public struct DrawingSettings: Hashable, Codable {
    public var currentLayer: String = "0"
    public var currentColor: CadColor = .byLayer
    public var currentLinetype: String = "ByLayer"
    public var currentLineweight: Double = -1
    public var ltScale: Double = 1
    public var textHeight: Double = 2.5
    public var textStyle: String = "Standard"
    public var dimStyle = DimStyle()
    public var units: LengthUnits = .decimal
    /// Real-world unit of one drawing unit; new drawings are metric (mm) like acadiso.dwt.
    public var insUnits: DrawingUnit = .millimeters
    public var unitPrecision: Int = 4
    public var gridSpacing: Double = 10
    public var snapSpacing: Double = 10
    public var limitsMin = Vec2(0, 0)
    public var limitsMax = Vec2(420, 297)
    public var pointSize: Double = 0
    public var filletRadius: Double = 0
    public var chamferDist1: Double = 0
    public var chamferDist2: Double = 0
    public var offsetDistance: Double = 10
    public init() {}
}

// MARK: - Unit formatting

extension DrawingSettings {
    /// "1250 mm" (or just the number when unitless).
    public func formatLength(_ v: Double, precision: Int? = nil) -> String {
        let n = fmt(v, precision: precision ?? unitPrecision)
        return insUnits == .unitless ? n : "\(n) \(insUnits.suffix)"
    }

    /// Length in the drawing unit plus the other metric units, e.g. "1250 mm (125 cm · 1.25 m)".
    public func formatLengthDetailed(_ v: Double) -> String {
        let main = formatLength(v)
        guard let m = insUnits.meters else { return main }
        let meters = v * m
        let metric: [DrawingUnit] = [.millimeters, .centimeters, .meters]
        var others = metric.filter { $0 != insUnits }.map { u in "\(fmt(meters / u.meters!, precision: 4)) \(u.suffix)" }
        if insUnits == .inches || insUnits == .feet { others = ["\(fmt(meters * 1000, precision: 2)) mm", "\(fmt(meters, precision: 4)) m"] }
        return "\(main) (\(others.joined(separator: " · ")))"
    }

    /// "15000 mm² (0.015 m²)".
    public func formatArea(_ a: Double) -> String {
        let n = fmt(a, precision: unitPrecision)
        guard let m = insUnits.meters else { return n }
        var s = "\(n) \(insUnits.suffix)²"
        if insUnits != .meters { s += " (\(fmt(a * m * m, precision: 6)) m²)" }
        return s
    }
}

// MARK: - Drawing (pure value)

/// Paper size and margins of a layout, in paper units (mm), as displayed (landscape = wide).
public struct PaperSetup: Hashable, Codable {
    public var name: String
    public var width: Double
    public var height: Double
    /// Unprintable margins: left, bottom, right, top.
    public var margins: [Double]

    public init(name: String, width: Double, height: Double, margins: [Double] = [7.5, 20, 7.5, 20]) {
        self.name = name; self.width = width; self.height = height; self.margins = margins
    }

    public static let a3Landscape = PaperSetup(name: "ISO A3 (420.00 x 297.00 MM)", width: 420, height: 297)

    /// Common sheet sizes (portrait width × height in mm).
    public static let standardSizes: [(String, Double, Double)] = [
        ("ISO A4", 210, 297), ("ISO A3", 297, 420), ("ISO A2", 420, 594), ("ISO A1", 594, 841), ("ISO A0", 841, 1189),
        ("Letter", 215.9, 279.4), ("Legal", 215.9, 355.6), ("Tabloid", 279.4, 431.8), ("ARCH D", 609.6, 914.4),
    ]

    /// Printable area inside the margins.
    public var printableBox: BBox {
        BBox(min: Vec2(margins[0], margins[1]), max: Vec2(width - margins[2], height - margins[3]))
    }
}

/// Named selection set (GROUP): picking one member selects all members when `isSelectable`.
public struct EntityGroup: Hashable, Codable, Identifiable {
    public var name: String
    public var description: String
    public var members: [EntityID]
    public var isSelectable: Bool
    public var id: String { name }
    public init(name: String, description: String = "", members: [EntityID], isSelectable: Bool = true) {
        self.name = name; self.description = description; self.members = members; self.isSelectable = isSelectable
    }
}

/// A paper-space sheet ("Layout1") with its own entities, including viewports.
public struct Layout: Hashable, Codable, Identifiable {
    public var name: String
    public var tabOrder: Int
    public var paper: PaperSetup
    public var entities: [Entity]
    public var id: String { name }

    public init(name: String, tabOrder: Int, paper: PaperSetup = .a3Landscape, entities: [Entity] = []) {
        self.name = name; self.tabOrder = tabOrder; self.paper = paper; self.entities = entities
    }

    /// A new layout with one viewport filling the printable area, like AutoCAD's default sheet.
    public static func withDefaultViewport(name: String, tabOrder: Int, paper: PaperSetup = .a3Landscape, showing model: BBox) -> Layout {
        let area = paper.printableBox
        var vp = ViewportGeom(center: area.center, width: area.width, height: area.height, viewCenter: area.center, viewHeight: area.height)
        vp.fit(model)
        return Layout(name: name, tabOrder: tabOrder, paper: paper, entities: [Entity(.viewport(vp))])
    }
}

public struct Drawing: Hashable, Codable {
    public var layers: [Layer]
    public var linetypes: [Linetype]
    public var blocks: [String: BlockDef]
    /// Model space entities.
    public var modelEntities: [Entity]
    /// Paper space sheets, in tab order.
    public var layouts: [Layout]
    /// Name of the layout being edited; nil = Model.
    public var activeLayout: String?
    /// Named groups (members may live in any space).
    public var groups: [EntityGroup] = []
    public var settings: DrawingSettings

    /// Entities of the active space (model or the active layout). All editing goes through this.
    public var entities: [Entity] {
        get {
            if let n = activeLayout, let i = layoutIndex(n) { return layouts[i].entities }
            return modelEntities
        }
        set {
            if let n = activeLayout, let i = layoutIndex(n) { layouts[i].entities = newValue } else { modelEntities = newValue }
        }
    }

    public var isPaperSpace: Bool { activeLayout.flatMap(layoutIndex) != nil }
    public func layoutIndex(_ name: String) -> Int? { layouts.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    public var activeLayoutDef: Layout? { activeLayout.flatMap(layoutIndex).map { layouts[$0] } }

    /// This drawing showing model space (for rendering viewports).
    public var modelView: Drawing {
        var d = self
        d.activeLayout = nil
        return d
    }

    /// Every entity in model space and all layouts.
    public var allSpaces: [[Entity]] { [modelEntities] + layouts.map(\.entities) }

    public init() {
        layers = [Layer(name: "0"), Layer(name: "Defpoints", isPlottable: false)]
        linetypes = Linetype.standard
        blocks = [:]
        modelEntities = []
        layouts = [Layout.withDefaultViewport(name: "Layout1", tabOrder: 1, showing: BBox(min: .zero, max: Vec2(420, 297)))]
        activeLayout = nil
        settings = DrawingSettings()
    }

    // MARK: Lookup

    public func layer(named n: String) -> Layer? {
        if let exact = layers.first(where: { $0.name == n }) { return exact }
        return layers.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }
    }
    public func linetype(named n: String) -> Linetype? {
        if let exact = linetypes.first(where: { $0.name == n }) { return exact }
        return linetypes.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }
    }
    public func index(of id: EntityID) -> Int? { entities.firstIndex { $0.id == id } }
    public func entity(_ id: EntityID) -> Entity? { entities.first { $0.id == id } }

    public func isEditable(_ e: Entity) -> Bool {
        guard let l = layer(named: e.layer) else { return true }
        return l.isVisible && !l.isLocked
    }
    public func isVisible(_ e: Entity) -> Bool { layer(named: e.layer)?.isVisible ?? true }

    // MARK: Mutation helpers

    public mutating func ensureLayer(_ name: String) {
        if layer(named: name) == nil { layers.append(Layer(name: name)) }
    }

    @discardableResult
    public mutating func add(_ e: Entity) -> EntityID {
        ensureLayer(e.layer)
        entities.append(e)
        return e.id
    }

    public mutating func remove(ids: Set<EntityID>) {
        entities.removeAll { ids.contains($0.id) }
        if !groups.isEmpty {
            for i in groups.indices { groups[i].members.removeAll { ids.contains($0) } }
            groups.removeAll { $0.members.isEmpty }
        }
    }

    /// All members of selectable groups containing `ids`, plus `ids` themselves.
    public func expandingGroups(_ ids: Set<EntityID>) -> Set<EntityID> {
        guard !groups.isEmpty else { return ids }
        var out = ids
        for g in groups where g.isSelectable && g.members.contains(where: { ids.contains($0) }) { out.formUnion(g.members) }
        return out
    }

    public mutating func replace(_ e: Entity) {
        if let i = index(of: e.id) { entities[i] = e }
    }

    public mutating func update(ids: Set<EntityID>, _ body: (inout Entity) -> Void) {
        for i in entities.indices where ids.contains(entities[i].id) { body(&entities[i]) }
    }

    public mutating func renameLayer(_ old: String, to new: String) {
        guard old != "0", let i = layers.firstIndex(where: { $0.name == old }), layer(named: new) == nil else { return }
        layers[i].name = new
        func rename(_ es: inout [Entity]) { for j in es.indices where es[j].layer == old { es[j].layer = new } }
        rename(&modelEntities)
        for k in layouts.indices { rename(&layouts[k].entities) }
        for k in blocks.keys { rename(&blocks[k]!.entities) }
        if settings.currentLayer == old { settings.currentLayer = new }
    }

    /// Removes unused layers, blocks and linetypes. Returns number of items purged.
    @discardableResult
    public mutating func purge() -> Int {
        var usedLayers: Set<String> = ["0", "Defpoints", settings.currentLayer]
        var usedBlocks = Set<String>()
        var usedLinetypes: Set<String> = ["Continuous", "ByLayer", "ByBlock"]
        func scan(_ es: [Entity]) {
            for e in es {
                usedLayers.insert(e.layer)
                usedLinetypes.insert(e.linetype)
                if case .insert(let ins) = e.kind, !usedBlocks.contains(ins.blockName) {
                    usedBlocks.insert(ins.blockName)
                    if let b = blocks[ins.blockName] { scan(b.entities) }
                }
            }
        }
        for space in allSpaces { scan(space) }
        for l in layers { usedLinetypes.insert(l.linetype) }
        let before = layers.count + blocks.count + linetypes.count
        layers.removeAll { !usedLayers.contains($0.name) }
        blocks = blocks.filter { usedBlocks.contains($0.key) }
        linetypes.removeAll { !usedLinetypes.contains($0.name) }
        return before - (layers.count + blocks.count + linetypes.count)
    }

    // MARK: Extents

    public func extents(of es: [Entity]? = nil) -> BBox {
        var b = BBox.empty
        for e in es ?? entities where isVisible(e) { b = b.union(bbox(of: e)) }
        return b
    }
}

// MARK: - Undo history

/// Owns a drawing plus snapshot-based undo/redo.
public final class DrawingHistory {
    public private(set) var drawing: Drawing
    private var undoStack: [(name: String, drawing: Drawing)] = []
    private var redoStack: [(name: String, drawing: Drawing)] = []
    public var maxUndo = 200
    /// Incremented on every change; lets caches detect a stale drawing cheaply.
    public private(set) var version = 0
    /// Called after any change (perform/undo/redo/replace).
    public var onChange: (() -> Void)?

    public init(_ d: Drawing = Drawing()) { drawing = d }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    /// Applies a mutation as one undoable step. No-op mutations are not recorded.
    public func perform(_ name: String, _ body: (inout Drawing) -> Void) {
        var d = drawing
        body(&d)
        guard d != drawing else { return }
        undoStack.append((name, drawing))
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
        drawing = d
        version += 1
        onChange?()
    }

    @discardableResult
    public func undo() -> String? {
        guard let last = undoStack.popLast() else { return nil }
        redoStack.append((last.name, drawing))
        drawing = keepingActiveSpace(last.drawing)
        version += 1
        onChange?()
        return last.name
    }

    @discardableResult
    public func redo() -> String? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append((next.name, drawing))
        drawing = keepingActiveSpace(next.drawing)
        version += 1
        onChange?()
        return next.name
    }

    /// Undo/redo restore content but stay on the tab the user is looking at.
    private func keepingActiveSpace(_ d: Drawing) -> Drawing {
        var d = d
        if let n = drawing.activeLayout, d.layoutIndex(n) != nil { d.activeLayout = n } else { d.activeLayout = nil }
        return d
    }

    private var transientBase: Drawing?

    /// Live edit (e.g. panning inside a viewport) that is not yet an undo step.
    public func transientUpdate(_ body: (inout Drawing) -> Void) {
        if transientBase == nil { transientBase = drawing }
        var d = drawing
        body(&d)
        guard d != drawing else { return }
        drawing = d
        version += 1
        onChange?()
    }

    /// Turns all transient edits since the first `transientUpdate` into one undo step.
    public func commitTransient(_ name: String) {
        guard let base = transientBase else { return }
        transientBase = nil
        guard base != drawing else { return }
        undoStack.append((name, base))
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Switches model/layout tab without creating an undo step.
    public func setActiveLayout(_ name: String?) {
        guard drawing.activeLayout != name else { return }
        drawing.activeLayout = name
        version += 1
        onChange?()
    }

    /// Replaces the drawing and clears history (used after load).
    public func reset(_ d: Drawing) {
        drawing = d
        undoStack.removeAll(); redoStack.removeAll()
        version += 1
        onChange?()
    }
}
