import AppKit
import CadCore

enum InputKind {
    /// Pick or type a point (also accepts numbers for direct distance entry).
    case point
    /// Build a selection set (click / window / crossing); Enter finishes.
    case selection
    /// Pick a single object.
    case entity
    /// Free text / numbers only.
    case text
}

/// Base class for interactive commands. Subclasses drive a small state machine
/// by calling `ask(...)` and reacting to point/value/keyword callbacks.
@MainActor
class CadCommand {
    unowned let c: CommandController
    let name: String
    private(set) var prompt = ""
    private(set) var keywords: [String] = []
    private(set) var input: InputKind = .point
    /// Rubber-band origin; also the reference for ortho/polar/direct distance.
    var basePoint: Vec2?
    /// TEXT content input accepts spaces literally.
    var allowsSpaces = false
    /// When true the command is transparent to selection (e.g. ZOOM keeps the selection).
    var keepsSelection = false

    init(_ c: CommandController, name: String) {
        self.c = c
        self.name = name
    }

    var drawing: Drawing { c.drawing }

    func start() {}
    func point(_ p: Vec2) {}
    /// Unparsed text input. Return false to report invalid input.
    func value(_ s: String) -> Bool { false }
    func keyword(_ k: String) {}
    /// Empty input (Enter / Space / right click).
    func enter() { finish() }
    func entityPicked(_ id: EntityID, at p: Vec2) {}
    /// Selection phase ended with Enter.
    func selectionDone(_ ids: Set<EntityID>) {}
    /// Temporary entities to draw for the current cursor position.
    func preview(_ cursor: Vec2) -> [Entity] { [] }
    /// Cheap preview: draw these existing entities through a transform (MOVE, ROTATE, ...).
    func previewTransform(_ cursor: Vec2) -> (ids: Set<EntityID>, transform: Transform2D)? { nil }
    func cancelled() {}

    func finish() { c.end(self) }

    /// Sets the current prompt. Keywords use capital letters as their shortcut ("Close" → C, "cEnter" → E).
    func ask(_ prompt: String, _ input: InputKind = .point, keywords: [String] = [], base: Vec2? = nil, keepBase: Bool = false) {
        self.prompt = prompt
        self.input = input
        self.keywords = keywords
        if !keepBase { basePoint = base }
        c.promptChanged()
    }

    var fullPrompt: String {
        var s = Loc.t(prompt)
        if !keywords.isEmpty { s += " [" + keywords.joined(separator: "/") + "]" }
        return s + ":"
    }

    /// Entity with the drawing's current layer/color/linetype/lineweight.
    func make(_ kind: EntityKind) -> Entity {
        let st = drawing.settings
        return Entity(kind, layer: st.currentLayer, color: st.currentColor, linetype: st.currentLinetype, lineweight: st.currentLineweight)
    }
}

/// Shortcut letters of a keyword: an inner capital ("cEnter" → E), the leading
/// capitals ("DElta" → DE, "2P" → 2P), otherwise its first letter.
func keywordShortcut(_ k: String) -> String {
    if k.first?.isLowercase == true, let u = k.first(where: { $0.isUppercase }) { return String(u) }
    let lead = k.prefix { $0.isUppercase || $0.isNumber }
    if lead.count > 1 { return String(lead) }
    return String(k.prefix(1)).uppercased()
}

@MainActor
protocol CommandControllerDelegate: AnyObject {
    func commandLineEcho(_ text: String)
    func promptDidChange(_ prompt: String)
    func needsRedraw(drawingChanged: Bool)
    func zoom(_ op: ZoomOperation)
    func showPanel(_ panel: String)
    func runModal(_ request: ModalRequest)
    func blockEditor(_ action: BlockEditorAction)
    func layout(_ action: LayoutAction)
    /// nil toggles.
    func setCommandLineVisible(_ visible: Bool?)
}

enum LayoutAction {
    case set(String?), new(String?), rename(String, String), delete(String), list, pageSetup
}

enum BlockEditorAction {
    case open(String), save, close
}

enum ZoomOperation {
    case extents, window(BBox), scale(Double), center(Vec2, Double?), previous
}

enum ModalRequest {
    case mtext(initial: String, completion: (String?) -> Void)
    case print
    case exportPDF
    case osnapSettings
    case textFont
    case chat
    case publish
}

/// Owns command state for one drawing window: active command, selection, drafting aids.
@MainActor
final class CommandController {
    let history: DrawingHistory
    weak var delegate: CommandControllerDelegate?

    private(set) var active: CadCommand?
    var selection: Set<EntityID> = [] { didSet { if selection != oldValue { delegate?.needsRedraw(drawingChanged: false); onSelectionChange?() } } }
    var onSelectionChange: (() -> Void)?
    var onModesChange: (() -> Void)?

    // Drafting aids
    var orthoOn = false { didSet { onModesChange?() } }
    var polarOn = true { didSet { onModesChange?() } }
    var gridOn = true { didSet { onModesChange?(); delegate?.needsRedraw(drawingChanged: true) } }
    var snapOn = false { didSet { onModesChange?() } }
    var osnapOn = true { didSet { onModesChange?() } }
    var lineweightOn = false { didSet { onModesChange?(); delegate?.needsRedraw(drawingChanged: true) } }
    /// Object snap tracking: align with acquired snap points.
    var otrackOn = true { didSet { onModesChange?(); if !otrackOn { trackPoints.removeAll() } } }
    /// Dynamic Input: length/angle (or X/Y) fields at the cursor.
    var dynInputOn = true { didSet { onModesChange?() } }

    /// Snap points acquired for tracking (hover ~0.4 s over a snap marker).
    private(set) var trackPoints: [Vec2] = []
    private var hoverSnap: Vec2?
    private var hoverSince = Date()

    func clearTracking() { trackPoints.removeAll(); hoverSnap = nil }
    var osnapModes: Set<SnapKind> = [.endpoint, .midpoint, .center, .intersection, .quadrant, .perpendicular, .node, .insertion]
    var polarIncrement = 45.0

    /// One-shot snap override (typing END, MID, ... during point input).
    var snapOverride: SnapKind?

    /// Last point entered (reference for @ relative input).
    var lastPoint = Vec2.zero
    /// Cursor position in world coordinates (raw, before snapping).
    var cursor = Vec2.zero
    /// Pixels per drawing unit; set by the canvas for snap apertures.
    var viewScale = 1.0

    private(set) var lastCommandName: String?
    var commandHistory: [String] = []

    init(history: DrawingHistory) {
        self.history = history
    }

    var drawing: Drawing { history.drawing }

    private struct ModelKey: Equatable {
        var entities: [Entity]; var layers: [Layer]; var blocks: [String: BlockDef]; var linetypes: [Linetype]; var settings: DrawingSettings
    }
    private var modelKey: ModelKey?
    private var cachedModelScene: Scene?
    private var viewportScenes: [[String]: Scene] = [:]

    /// Scene of model space, independent of the active tab; rebuilt only when model content changes.
    var modelScene: Scene {
        let d = history.drawing
        if !d.isPaperSpace { return scene }
        let key = ModelKey(entities: d.modelEntities, layers: d.layers, blocks: d.blocks, linetypes: d.linetypes, settings: d.settings)
        if let s = cachedModelScene, key == modelKey { return s }
        let s = Scene(drawing: d.modelView, version: history.version, previous: cachedModelScene, hidden: hiddenIDs)
        cachedModelScene = s
        modelKey = key
        viewportScenes.removeAll()
        return s
    }

    /// Model scene with some layers frozen (per-viewport VP freeze).
    func modelScene(frozen: [String]) -> Scene {
        let base = modelScene
        guard !frozen.isEmpty else { return base }
        let key = frozen.map { $0.lowercased() }.sorted()
        if let s = viewportScenes[key] { return s }
        var d = history.drawing.modelView
        for i in d.layers.indices where key.contains(d.layers[i].name.lowercased()) { d.layers[i].isFrozen = true }
        let s = Scene(drawing: d, version: history.version, previous: base, hidden: hiddenIDs)
        viewportScenes[key] = s
        return s
    }

    private var cachedScene: Scene?

    /// View-only hidden objects (ISOLATEOBJECTS/HIDEOBJECTS); never saved or undone.
    var hiddenIDs: Set<EntityID> = [] {
        didSet {
            guard hiddenIDs != oldValue else { return }
            cachedScene = nil; cachedModelScene = nil; modelKey = nil; viewportScenes.removeAll()
            selection.subtract(hiddenIDs)
            delegate?.needsRedraw(drawingChanged: true)
        }
    }

    /// Viewport being panned/zoomed from paper space (rendered with this geometry).
    struct ActiveViewport { var id: EntityID; var geom: ViewportGeom }
    var activeViewportOverride: ActiveViewport?
    /// Render/pick index for the current drawing version (rebuilt lazily, reusing unchanged items).
    var scene: Scene {
        if let s = cachedScene, s.version == history.version { return s }
        let d = history.drawing
        if !d.isPaperSpace {
            // Switching back to Model (or a paper-only change) must not rebuild a big model scene.
            let key = ModelKey(entities: d.modelEntities, layers: d.layers, blocks: d.blocks, linetypes: d.linetypes, settings: d.settings)
            if let m = cachedModelScene, key == modelKey { cachedScene = m; return m }
            let s = Scene(drawing: d, version: history.version, previous: cachedModelScene ?? cachedScene, hidden: hiddenIDs)
            cachedScene = s
            cachedModelScene = s
            modelKey = key
            viewportScenes.removeAll()
            return s
        }
        let s = Scene(drawing: d, version: history.version, previous: cachedScene, hidden: hiddenIDs)
        cachedScene = s
        return s
    }

    // MARK: Output

    private static let echoToStdout = ProcessInfo.processInfo.environment["CADMAC_ECHO"] != nil

    func message(_ s: String) {
        if CommandController.echoToStdout { print("ECHO: \(s)") }
        delegate?.commandLineEcho(Loc.t(s))
    }

    func promptChanged() {
        delegate?.promptDidChange(active?.fullPrompt ?? Loc.t("Command:"))
        delegate?.needsRedraw(drawingChanged: false)
    }

    var inputKind: InputKind? { active?.input }

    // MARK: Editing

    func perform(_ name: String, _ body: (inout Drawing) -> Void) {
        history.perform(name, body)
    }

    func undo() {
        if let n = history.undo() { message("Undo \(n)") } else { message("Nothing to undo") }
        selection = selection.filter { drawing.entity($0) != nil }
    }

    func redo() {
        if let n = history.redo() { message("Redo \(n)") } else { message("Nothing to redo") }
        selection = selection.filter { drawing.entity($0) != nil }
    }

    // MARK: Command lifecycle

    func run(_ commandName: String) {
        var name = commandName.trimmingCharacters(in: .whitespaces).uppercased()
        if name.hasPrefix("_") { name.removeFirst() }
        if name.hasPrefix(".") { name.removeFirst() }
        if active != nil {
            // Transparent commands ('ZOOM) keep the current command; others cancel it.
            if name.hasPrefix("'") {
                name.removeFirst()
                if let t = CommandRegistry.transparent(name, self) { t() ; return }
            }
            cancel()
        }
        if name.hasPrefix("'") { name.removeFirst() }
        guard let cmd = CommandRegistry.make(name, self) else {
            message("Unknown command \"\(name)\". Press F1 for the user guide.")
            return
        }
        message("Command: \(cmd.name)")
        commandHistory.append(cmd.name)
        lastCommandName = cmd.name
        active = cmd
        cmd.start()
        if active === cmd { promptChanged() }
    }

    func end(_ cmd: CadCommand) {
        guard active === cmd else { return }
        active = nil
        clearTracking()
        if !cmd.keepsSelection { selection.removeAll() }
        snapOverride = nil
        promptChanged()
    }

    func cancel() {
        if let a = active {
            a.cancelled()
            message("*Cancel*")
            active = nil
            snapOverride = nil
            promptChanged()
        }
        selection.removeAll()
    }

    // MARK: Input

    /// Handles text submitted from the command line (Enter/Space).
    func submit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let cmd = active else {
            if text.isEmpty {
                if let last = lastCommandName { run(last) }
            } else {
                run(text)
            }
            return
        }
        // Enter goes through enter() so a selection phase is completed, not abandoned.
        if text.isEmpty { enter(); return }
        if text.hasPrefix("'") { run(text); return }
        if cmd.input != .text || !cmd.allowsSpaces {
            echoInput(text)
        }
        if let k = matchKeyword(text, cmd.keywords) { cmd.keyword(k); return }
        if cmd.input == .point || cmd.input == .entity {
            if let kind = snapOverrideKeyword(text) {
                snapOverride = kind
                message("Snap override: \(kind.label)")
                return
            }
            if let p = parsePoint(text) { feedPoint(p, to: cmd); return }
            if let d = Double(text.replacingOccurrences(of: ",", with: ".")), let base = cmd.basePoint, cmd.input == .point {
                var dir = (constrained(cursor, base: base) - base).normalized
                if dir == .zero { dir = Vec2(1, 0) }
                feedPoint(base + dir * d, to: cmd)
                return
            }
        }
        if cmd.input == .selection, let k = selectionKeyword(text) {
            switch k {
            case "ALL":
                selection = Set(drawing.entities.filter { drawing.isEditable($0) }.map(\.id))
                message("\(selection.count) found")
            case "L":
                if let last = drawing.entities.last(where: { drawing.isEditable($0) }) { selection.insert(last.id); message("1 found") }
            case "P":
                selection.formUnion(previousSelection.filter { drawing.entity($0) != nil })
                message("\(selection.count) found")
            default: break
            }
            return
        }
        if !cmd.value(text) { message("Invalid input. \(cmd.fullPrompt)") }
    }

    private(set) var previousSelection: Set<EntityID> = []
    func rememberSelection(_ s: Set<EntityID>) { previousSelection = s }

    private func echoInput(_ text: String) {
        if let cmd = active { message("\(cmd.fullPrompt) \(text)") }
    }

    private func matchKeyword(_ text: String, _ kws: [String]) -> String? {
        let t = text.uppercased()
        for k in kws where k.uppercased() == t { return k }
        for k in kws where keywordShortcut(k) == t { return k }
        return nil
    }

    private func selectionKeyword(_ text: String) -> String? {
        switch text.uppercased() {
        case "ALL": return "ALL"
        case "L", "LAST": return "L"
        case "P", "PREVIOUS": return "P"
        default: return nil
        }
    }

    private func snapOverrideKeyword(_ text: String) -> SnapKind? {
        switch text.uppercased() {
        case "END", "ENDP": return .endpoint
        case "MID": return .midpoint
        case "CEN": return .center
        case "QUA": return .quadrant
        case "INT": return .intersection
        case "PER": return .perpendicular
        case "TAN": return .tangent
        case "NEA": return .nearest
        case "NOD": return .node
        case "INS": return .insertion
        default: return nil
        }
    }

    /// Parses "x,y", "@dx,dy", "@d<a", "d<a" (degrees).
    func parsePoint(_ s: String) -> Vec2? {
        var t = s.replacingOccurrences(of: " ", with: "")
        var relative = false
        if t.hasPrefix("@") { relative = true; t.removeFirst() }
        if t.hasPrefix("#") { t.removeFirst() }
        if t.isEmpty && relative { return lastPoint }
        if t.contains("<") {
            let parts = t.split(separator: "<")
            guard parts.count == 2, let d = Double(parts[0]), let a = Double(parts[1]) else { return nil }
            let v = Vec2.polar(d, radians(a))
            return relative ? lastPoint + v : v
        }
        let parts = t.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return relative ? lastPoint + Vec2(x, y) : Vec2(x, y)
    }

    private func feedPoint(_ p: Vec2, to cmd: CadCommand) {
        lastPoint = p
        clearTracking()
        snapOverride = nil
        if cmd.input == .entity {
            if let id = pickEntity(at: p) { cmd.entityPicked(id, at: p) } else { message("No object found") }
        } else {
            cmd.point(p)
        }
        delegate?.needsRedraw(drawingChanged: false)
    }

    /// Point picked on the canvas (already snapped/constrained).
    func canvasPoint(_ p: Vec2) {
        guard let cmd = active else { return }
        message("\(cmd.fullPrompt) \(fmt(p.x)),\(fmt(p.y))")
        feedPoint(p, to: cmd)
    }

    func canvasEntity(_ id: EntityID, at p: Vec2) {
        guard let cmd = active, cmd.input == .entity else { return }
        snapOverride = nil
        cmd.entityPicked(id, at: p)
        delegate?.needsRedraw(drawingChanged: false)
    }

    /// Enter / right-click.
    func enter() {
        guard let cmd = active else {
            if let last = lastCommandName { run(last) }
            return
        }
        if cmd.input == .selection {
            let s = selection
            message("\(s.count) selected")
            rememberSelection(s)
            cmd.selectionDone(s)
        } else {
            cmd.enter()
        }
    }

    // MARK: Picking & snapping

    /// Entity under the point within `aperture` pixels.
    func pickEntity(at p: Vec2, aperture: Double = 6) -> EntityID? {
        scene.pick(at: p, tolerance: aperture / viewScale)
    }

    /// Applies ortho / polar tracking relative to `base`.
    func constrained(_ p: Vec2, base: Vec2) -> Vec2 {
        let v = p - base
        if orthoOn {
            return abs(v.x) >= abs(v.y) ? Vec2(p.x, base.y) : Vec2(base.x, p.y)
        }
        if polarOn, v.length > 0 {
            let inc = radians(polarIncrement)
            let a = v.angle
            let snapped = (a / inc).rounded() * inc
            if abs(a - snapped) < radians(3) { let u = Vec2.polar(1, snapped); return base + u * v.dot(u) }
        }
        return p
    }

    struct SnapResult {
        var point: Vec2
        var snap: SnapPoint?
        var polarAngle: Double?
        /// Acquired points the cursor is aligned with (tracking lines).
        var tracks: [Vec2] = []
    }

    /// Final point for a raw cursor position: object snap, then ortho/polar, then grid snap.
    func resolve(_ raw: Vec2) -> SnapResult {
        let wantsPoint = active?.input == .point || gripDrag != nil
        if wantsPoint, osnapOn || snapOverride != nil, let s = objectSnap(raw) {
            if otrackOn { acquire(s.point) }
            return SnapResult(point: s.point, snap: s)
        }
        hoverSnap = nil
        if wantsPoint, otrackOn, !trackPoints.isEmpty, let t = tracked(raw) { return t }
        var p = raw
        if snapOn {
            let sp = drawing.settings.snapSpacing
            p = Vec2((p.x / sp).rounded() * sp, (p.y / sp).rounded() * sp)
        }
        if wantsPoint, let base = active?.basePoint ?? gripDrag?.base {
            let c = constrained(p, base: base)
            if c != p {
                return SnapResult(point: c, snap: nil, polarAngle: (c - base).angle)
            }
        }
        return SnapResult(point: p, snap: nil)
    }

    /// Pausing on the same snap point acquires it (again: releases it), like AutoCAD.
    private func acquire(_ p: Vec2) {
        guard let h = hoverSnap, h.isClose(to: p, tol: 1e-9) else { hoverSnap = p; hoverSince = Date(); return }
        guard Date().timeIntervalSince(hoverSince) > 0.4 else { return }
        if let i = trackPoints.firstIndex(where: { $0.isClose(to: p, tol: 1e-9) }) {
            trackPoints.remove(at: i)
        } else {
            trackPoints.append(p)
            if trackPoints.count > 4 { trackPoints.removeFirst() }
        }
        hoverSince = .distantFuture  // one toggle per pause
    }

    /// Snaps to horizontal/vertical alignment with acquired points (and their intersection).
    private func tracked(_ raw: Vec2) -> SnapResult? {
        let tol = 8 / viewScale
        let vx = trackPoints.filter { abs(raw.x - $0.x) < tol }.min { abs(raw.x - $0.x) < abs(raw.x - $1.x) }
        let hy = trackPoints.filter { abs(raw.y - $0.y) < tol }.min { abs(raw.y - $0.y) < abs(raw.y - $1.y) }
        guard vx != nil || hy != nil else { return nil }
        let p = Vec2(vx?.x ?? raw.x, hy?.y ?? raw.y)
        return SnapResult(point: p, snap: nil, tracks: [vx, hy].compactMap { $0 })
    }

    func objectSnap(_ raw: Vec2) -> SnapPoint? {
        let aperture = 10 / viewScale
        let modes: Set<SnapKind> = snapOverride.map { [$0] } ?? osnapModes
        let box = BBox(corner: raw, raw).expanded(by: aperture)
        let sc = scene
        let near = sc.query(box).map { sc.items[$0] }.prefix(400)
        guard !near.isEmpty else { return nil }
        var cands: [SnapPoint] = []
        for it in near {
            cands += drawing.snapPoints(of: it.entity).filter { modes.contains($0.kind) }
        }
        var prims: [Prim] = []
        if modes.contains(.intersection) || modes.contains(.perpendicular) || modes.contains(.nearest) || modes.contains(.tangent) {
            for it in near {
                if case .text = it.entity.kind { continue }
                if case .dimension = it.entity.kind { continue }
                prims += it.prims.filter { $0.distance(to: raw) <= aperture }
            }
        }
        if modes.contains(.intersection), prims.count > 1, prims.count < 200 {
            for i in 0..<prims.count {
                for j in (i + 1)..<prims.count {
                    for p in intersections(prims[i], prims[j]) { cands.append(SnapPoint(p, .intersection)) }
                }
            }
        }
        if let base = active?.basePoint {
            if modes.contains(.perpendicular) {
                for pr in prims { if let f = perpendicularFoot(from: base, to: pr) { cands.append(SnapPoint(f, .perpendicular)) } }
            }
            if modes.contains(.tangent) {
                for pr in prims {
                    if case let .arc(c, r, s, w) = pr {
                        for t in tangentPoints(from: base, center: c, radius: r)
                        where w >= 2 * .pi - 1e-9 || angleOnArc((t - c).angle, start: s, end: s + w) {
                            cands.append(SnapPoint(t, .tangent))
                        }
                    }
                }
            }
        }
        let inRange = cands.filter { $0.point.distance(to: raw) <= aperture }
        if let best = inRange.min(by: { $0.point.distance(to: raw) < $1.point.distance(to: raw) }) { return best }
        if modes.contains(.nearest), let pr = prims.min(by: { $0.distance(to: raw) < $1.distance(to: raw) }) {
            return SnapPoint(pr.closestPoint(to: raw), .nearest)
        }
        return nil
    }

    // MARK: Grip editing (idle mode)

    struct GripDrag { var entity: EntityID; var index: Int; var base: Vec2 }
    var gripDrag: GripDrag?

    func grip(at viewTol: Double, near p: Vec2) -> GripDrag? {
        let tol = viewTol / viewScale
        for id in selection {
            guard let e = drawing.entity(id), drawing.isEditable(e) else { continue }
            for (i, g) in drawing.grips(of: e).enumerated() where g.distance(to: p) <= tol {
                return GripDrag(entity: id, index: i, base: g)
            }
        }
        return nil
    }

    func beginGrip(_ g: GripDrag) {
        gripDrag = g
        lastPoint = g.base
        message("** STRETCH ** Specify stretch point:")
        delegate?.promptDidChange("** STRETCH ** Specify stretch point:")
    }

    func finishGrip(at p: Vec2) {
        guard let g = gripDrag, let e = drawing.entity(g.entity) else { gripDrag = nil; return }
        gripDrag = nil
        let moved = drawing.applyGrip(e, index: g.index, to: p)
        perform("Grip Edit") { $0.replace(moved) }
        lastPoint = p
        promptChanged()
    }

    func cancelGrip() {
        gripDrag = nil
        promptChanged()
    }

    /// Preview entities for the current cursor.
    func previewEntities(at p: Vec2) -> [Entity] {
        if let g = gripDrag, let e = drawing.entity(g.entity) { return [drawing.applyGrip(e, index: g.index, to: p)] }
        return active?.preview(p) ?? []
    }

    // MARK: Selection from canvas

    /// Last crossing/window rectangle used for selection (STRETCH uses it).
    var lastSelectionWindow: BBox?

    func select(window: BBox, crossing: Bool, remove: Bool) {
        lastSelectionWindow = crossing ? window : nil
        let d = drawing
        let ids = scene.select(window: window, crossing: crossing).filter { id in scene.byID[id].map { d.isEditable($0.entity) } ?? false }
        let all = d.expandingGroups(Set(ids))
        if remove { selection.subtract(all) } else { selection.formUnion(all) }
        if active?.input == .selection { message("\(ids.count) found, \(selection.count) total") }
    }

    func toggleSelect(_ id: EntityID, remove: Bool) {
        guard let e = drawing.entity(id), drawing.isEditable(e) else {
            message("Object is on a locked layer")
            return
        }
        let ids = drawing.expandingGroups([id])
        if remove { selection.subtract(ids) } else { selection.formUnion(ids) }
        if active?.input == .selection { message("1 found, \(selection.count) total") }
    }

    func selectAll() {
        selection = Set(drawing.entities.filter { drawing.isEditable($0) }.map(\.id))
    }

    func eraseSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        perform("Erase") { $0.remove(ids: ids) }
        message("\(ids.count) object(s) erased")
        selection.removeAll()
    }
}
