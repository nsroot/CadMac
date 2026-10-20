import AppKit
import CadCore

/// Extra drafting tools (QSELECT, ALIGN, DRAWORDER, GROUP, ...). Registered via `CommandRegistry`.
@MainActor
enum ToolCommands {
    private static func info(_ name: String, _ aliases: [String], _ summary: String, _ f: @escaping (CommandController, String) -> CadCommand) -> CommandInfo {
        CommandInfo(name: name, aliases: aliases, summary: summary) { f($0, name) }
    }

    static let all: [CommandInfo] = [
        info("ISOLATEOBJECTS", ["ISOLATE"], "Temporarily hides everything except the selected objects", { IsolateCommand($0, name: $1, isolate: true) }),
        info("HIDEOBJECTS", ["HIDE"], "Temporarily hides the selected objects", { IsolateCommand($0, name: $1, isolate: false) }),
        CommandInfo(name: "UNISOLATEOBJECTS", aliases: ["UNISOLATE", "UNHIDE"], summary: "Shows objects hidden by ISOLATEOBJECTS/HIDEOBJECTS") { c in
            ActionCommand(c, name: "UNISOLATEOBJECTS") { c in
                let n = c.hiddenIDs.count
                c.hiddenIDs = []
                c.message(n == 0 ? "No objects are hidden." : "\(n) object(s) shown again.")
            }
        },
        info("QSELECT", [], "Selects objects by type and property", { QSelectCommand($0, name: $1) }),
        info("ALIGN", ["AL"], "Moves, rotates and optionally scales objects to align with others", { AlignCommand($0, name: $1) }),
        info("DRAWORDER", ["DR"], "Changes the draw order of objects", { DrawOrderCommand($0, name: $1, preset: nil) }),
        info("BRINGTOFRONT", [], "Brings objects to the front of the draw order", { DrawOrderCommand($0, name: $1, preset: .front) }),
        info("SENDTOBACK", [], "Sends objects to the back of the draw order", { DrawOrderCommand($0, name: $1, preset: .back) }),
        info("BRINGABOVE", [], "Places objects above reference objects", { DrawOrderCommand($0, name: $1, preset: .above) }),
        info("SENDUNDER", [], "Places objects under reference objects", { DrawOrderCommand($0, name: $1, preset: .under) }),
        info("TEXTTOFRONT", [], "Brings text and dimensions to the front", { TextToFrontCommand($0, name: $1) }),
        info("GROUP", ["G"], "Creates a named group of objects", { GroupCommand($0, name: $1) }),
        info("UNGROUP", [], "Removes a group (the objects remain)", { UngroupCommand($0, name: $1) }),
        info("GROUPEDIT", [], "Adds or removes group members, or renames a group", { GroupEditCommand($0, name: $1) }),
        CommandInfo(name: "GROUPSELECT", aliases: [], summary: "Toggles group selection on or off") { c in
            ActionCommand(c, name: "GROUPSELECT", keepSelection: true) { c in
                guard !c.drawing.groups.isEmpty else { c.message("No groups in the drawing."); return }
                var on = true
                c.perform("Group Selection") { on = $0.toggleGroupSelection() }
                c.message(on ? "<Groups on>" : "<Groups off>")
            }
        },
        info("OVERKILL", [], "Deletes duplicate objects and merges overlapping lines", { OverkillCommand($0, name: $1) }),
        info("COUNT", [], "Counts block references", { CountCommand($0, name: $1) }),
        info("FIND", [], "Finds (and optionally replaces) text", { FindCommand($0, name: $1) }),
    ]

    /// Window to attach sheets to (the drawing window, not a floating panel).
    static var sheetWindow: NSWindow? {
        if let k = NSApp.keyWindow, !(k is NSPanel) { return k }
        return NSApp.mainWindow ?? NSApp.keyWindow
    }

    static func listGroups(_ c: CommandController) {
        let gs = c.drawing.groups
        guard !gs.isEmpty else { c.message("No groups defined."); return }
        for g in gs {
            let desc = g.description.isEmpty ? "" : " — \(g.description)"
            c.message("Group \"\(g.name)\": \(g.members.count) member(s), \(g.isSelectable ? "selectable" : "not selectable")\(desc)")
        }
    }
}

// MARK: - QSELECT

final class QSelectCommand: CadCommand {
    override init(_ c: CommandController, name: String) {
        super.init(c, name: name)
        keepsSelection = true
    }

    override func start() {
        guard let window = ToolCommands.sheetWindow else {
            c.message("QSELECT needs a drawing window.")
            finish()
            return
        }
        let pre = c.selection
        let dialog = QuickSelectDialog(drawing: drawing, preselection: pre)
        let alert = NSAlert()
        alert.messageText = "Quick Select"
        alert.informativeText = "Select objects by type and property."
        alert.accessoryView = dialog.makeView()
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let controller = c
        alert.beginSheetModal(for: window) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            let d = controller.drawing
            let cr = dialog.criteria
            let applyTo: Set<EntityID>? = dialog.applyToSelection ? pre : nil
            let result = d.quickSelect(cr, mode: dialog.mode, applyTo: applyTo, current: pre)
            controller.selection = result
            controller.message("\(result.count) object(s) selected")
        }
        finish()
    }
}

/// Accessory view + state for the Quick Select sheet.
@MainActor
final class QuickSelectDialog: NSObject {
    let drawing: Drawing
    let preselection: Set<EntityID>
    private let applyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let typePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let propPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let opPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let valueBox = NSComboBox(frame: .zero)
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var types: [String] = []
    private var props: [QSelectProperty] = []
    private var ops: [QSelectOperator] = []

    init(drawing: Drawing, preselection: Set<EntityID>) {
        self.drawing = drawing
        self.preselection = preselection
        super.init()
    }

    var applyToSelection: Bool { !preselection.isEmpty && applyPopup.indexOfSelectedItem == 1 }
    var objectType: String? {
        let i = typePopup.indexOfSelectedItem
        return i <= 0 || i > types.count ? nil : types[i - 1]
    }
    var property: QSelectProperty { props.indices.contains(propPopup.indexOfSelectedItem) ? props[propPopup.indexOfSelectedItem] : .layer }
    var op: QSelectOperator { ops.indices.contains(opPopup.indexOfSelectedItem) ? ops[opPopup.indexOfSelectedItem] : .equals }
    var mode: QSelectMode { QSelectMode.allCases[max(0, modePopup.indexOfSelectedItem)] }
    var criteria: QSelectCriteria {
        QSelectCriteria(objectType: objectType, property: property, op: op, value: valueBox.stringValue)
    }

    func makeView() -> NSView {
        applyPopup.addItems(withTitles: ["Entire drawing"] + (preselection.isEmpty ? [] : ["Current selection (\(preselection.count))"]))
        if !preselection.isEmpty { applyPopup.selectItem(at: 1) }
        types = drawing.qselectTypes()
        typePopup.addItems(withTitles: ["Multiple"] + types)
        typePopup.target = self; typePopup.action = #selector(typeChanged)
        propPopup.target = self; propPopup.action = #selector(propertyChanged)
        opPopup.target = self; opPopup.action = #selector(operatorChanged)
        valueBox.completes = true
        valueBox.numberOfVisibleItems = 12
        modePopup.addItems(withTitles: QSelectMode.allCases.map(\.rawValue))
        for v in [applyPopup, typePopup, propPopup, opPopup, modePopup] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }
        valueBox.translatesAutoresizingMaskIntoConstraints = false
        valueBox.widthAnchor.constraint(equalToConstant: 240).isActive = true

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            return l
        }
        let grid = NSGridView(views: [
            [label("Apply to:"), applyPopup],
            [label("Object type:"), typePopup],
            [label("Properties:"), propPopup],
            [label("Operator:"), opPopup],
            [label("Value:"), valueBox],
            [label("How to apply:"), modePopup],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        typeChanged()
        grid.layoutSubtreeIfNeeded()
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        return grid
    }

    @objc func typeChanged() {
        let current = props.indices.contains(propPopup.indexOfSelectedItem) ? props[propPopup.indexOfSelectedItem] : nil
        props = Drawing.qselectProperties(forType: objectType)
        propPopup.removeAllItems()
        propPopup.addItems(withTitles: props.map(\.rawValue))
        if let cur = current, let i = props.firstIndex(of: cur) { propPopup.selectItem(at: i) }
        propertyChanged()
    }

    @objc func propertyChanged() {
        let prop = property
        let currentOp = op
        ops = prop.operators
        opPopup.removeAllItems()
        opPopup.addItems(withTitles: ops.map(\.rawValue))
        if let i = ops.firstIndex(of: currentOp) { opPopup.selectItem(at: i) }
        valueBox.removeAllItems()
        let choices = drawing.qselectValueChoices(prop, type: objectType)
        valueBox.addItems(withObjectValues: choices)
        if prop == .layer {
            valueBox.stringValue = drawing.settings.currentLayer
        } else if let f = choices.first {
            valueBox.stringValue = f
        } else {
            valueBox.stringValue = ""
        }
        operatorChanged()
    }

    @objc func operatorChanged() {
        valueBox.isEnabled = op != .selectAll
    }
}

// MARK: - ALIGN

final class AlignCommand: SelectionCommand {
    private var s1: Vec2?, d1: Vec2?, s2: Vec2?, d2: Vec2?
    private var askingScale = false

    override func afterSelection() { ask("Specify first source point") }

    override func point(_ p: Vec2) {
        guard !askingScale else { return }
        if s1 == nil { s1 = p; ask("Specify first destination point", base: p); return }
        if d1 == nil { d1 = p; ask("Specify second source point or <continue>"); return }
        if s2 == nil { s2 = p; ask("Specify second destination point", base: p); return }
        if d2 == nil { d2 = p; ask("Specify third source point or <continue>"); return }
        // A third pair only matters in 3D.
        c.message("Third point pair is ignored for 2D alignment.")
        askScale()
    }

    private func askScale() {
        askingScale = true
        ask("Scale objects based on alignment points? <N>", .text, keywords: ["Yes", "No"])
    }

    override func keyword(_ k: String) {
        guard askingScale else { return }
        align(scale: k == "Yes")
    }

    override func value(_ s: String) -> Bool { false }

    override func enter() {
        if askingScale { align(scale: false); return }
        guard s1 != nil, d1 != nil else { finish(); return }
        if s2 != nil && d2 != nil { askScale(); return }
        align(scale: false)
    }

    /// Current transform; `cursor` stands in for the destination point being picked.
    private func transform(scale: Bool, cursor: Vec2? = nil) -> Transform2D? {
        guard let s1 else { return nil }
        guard let d1 else { return cursor.map { alignTransform(source: s1, destination: $0) } }
        guard let s2, let d2 = d2 ?? cursor else { return alignTransform(source: s1, destination: d1) }
        return alignTransform(source: s1, destination: d1, source2: s2, destination2: d2, scale: scale)
    }

    private func align(scale: Bool) {
        if let t = transform(scale: scale) { apply("Align", t) }
        finish()
    }

    /// Source → destination link lines already defined.
    override func preview(_ cursor: Vec2) -> [Entity] {
        var out: [Entity] = []
        if let s1, let d1 { out.append(Entity(.line(LineGeom(start: s1, end: d1)))) }
        if let s2, let d2 { out.append(Entity(.line(LineGeom(start: s2, end: d2)))) }
        return out
    }

    override func previewTransform(_ cursor: Vec2) -> (ids: Set<EntityID>, transform: Transform2D)? {
        guard s1 != nil else { return nil }
        if d1 == nil { return transform(scale: false, cursor: cursor).map { (ids, $0) } }
        if s2 != nil, d2 == nil { return transform(scale: false, cursor: cursor).map { (ids, $0) } }
        return transform(scale: false).map { (ids, $0) }
    }
}

// MARK: - DRAWORDER

final class DrawOrderCommand: SelectionCommand {
    enum Preset { case front, back, above, under }
    private let preset: Preset?
    private var refMode: Preset?

    init(_ c: CommandController, name: String, preset: Preset?) {
        self.preset = preset
        super.init(c, name: name)
    }

    override func afterSelection() {
        if let p = preset { choose(p); return }
        ask("Enter object ordering option <Front>", .text, keywords: ["Above objects", "Under objects", "Front", "Back"])
    }

    private func choose(_ p: Preset) {
        switch p {
        case .front: reorder(.front)
        case .back: reorder(.back)
        case .above, .under:
            refMode = p
            c.selection.removeAll()
            ask("Select reference objects", .selection)
        }
    }

    override func keyword(_ k: String) {
        switch k {
        case "Above objects": choose(.above)
        case "Under objects": choose(.under)
        case "Back": choose(.back)
        default: choose(.front)
        }
    }

    override func enter() {
        if refMode == nil, input == .text { choose(.front) } else { finish() }
    }

    override func selectionDone(_ s: Set<EntityID>) {
        guard let m = refMode else { super.selectionDone(s); return }
        let refs = s.subtracting(ids)
        guard !refs.isEmpty else { c.message("No reference objects selected."); finish(); return }
        reorder(m == .above ? .above(refs) : .under(refs))
    }

    private func reorder(_ p: DrawOrderPlacement) {
        let moving = ids
        c.perform("Draw Order") { $0.drawOrder(moving, p) }
        c.message("\(moving.count) object(s) reordered")
        finish()
    }
}

final class TextToFrontCommand: CadCommand {
    override func start() {
        ask("Bring to front <All>", .text, keywords: ["Text", "Dimensions", "All"])
    }

    override func keyword(_ k: String) {
        run(TextToFrontKind(rawValue: k) ?? .all)
    }

    override func enter() { run(.all) }

    private func run(_ kind: TextToFrontKind) {
        var n = 0
        c.perform("Text to Front") { n = $0.textToFront(kind) }
        c.message("\(n) object(s) brought to front")
        finish()
    }
}

// MARK: - GROUP

final class GroupCommand: CadCommand {
    private var groupName: String?
    private var groupDescription = ""
    private enum Phase { case select, name, description }
    private var phase = Phase.select

    override func start() {
        let pre = c.selection.filter { id in drawing.entity(id).map(drawing.isEditable) ?? false }
        if !pre.isEmpty { create(pre); return }
        c.selection.removeAll()
        askSelect()
    }

    private func askSelect() {
        phase = .select
        allowsSpaces = false
        ask("Select objects", .selection, keywords: ["Name", "Description"])
    }

    override func keyword(_ k: String) {
        switch k {
        case "Name":
            phase = .name
            ask("Enter a group name or [?]", .text)
        case "Description":
            phase = .description
            allowsSpaces = true
            ask("Enter group description", .text)
        default: break
        }
    }

    override func value(_ s: String) -> Bool {
        switch phase {
        case .name:
            if s == "?" { ToolCommands.listGroups(c); return true }
            guard Drawing.isValidGroupName(s) else { c.message("Invalid group name."); return true }
            if drawing.groupIndex(named: s) != nil { c.message("A group named \"\(s)\" already exists."); return true }
            groupName = s
            askSelect()
            return true
        case .description:
            groupDescription = s
            askSelect()
            return true
        case .select:
            return false
        }
    }

    override func enter() {
        // Empty name/description: back to selecting.
        askSelect()
    }

    override func selectionDone(_ s: Set<EntityID>) {
        guard !s.isEmpty else { finish(); return }
        create(s)
    }

    private func create(_ s: Set<EntityID>) {
        let n = groupName, desc = groupDescription
        var result: Result<String, Error> = .failure(GroupError.empty)
        c.perform("Group") { d in result = Result { try d.createGroup(name: n, description: desc, members: s) } }
        switch result {
        case .success(let name):
            c.message(name.hasPrefix("*") ? "Unnamed group \"\(name)\" created with \(s.count) object(s)."
                                          : "Group \"\(name)\" created with \(s.count) object(s).")
        case .failure(let e):
            c.message(e.localizedDescription)
        }
        finish()
    }
}

final class UngroupCommand: CadCommand {
    override func start() {
        let pre = c.selection.filter { id in drawing.entity(id) != nil }
        if !pre.isEmpty { ungroup(pre); return }
        c.selection.removeAll()
        ask("Select group", .selection, keywords: ["Name"])
    }

    override func keyword(_ k: String) {
        if k == "Name" { ask("Enter a group name or [?]", .text) }
    }

    override func value(_ s: String) -> Bool {
        if s == "?" { ToolCommands.listGroups(c); return true }
        guard drawing.groupIndex(named: s) != nil else { c.message("Group \"\(s)\" not found."); return true }
        c.perform("Ungroup") { try? $0.deleteGroup(named: s) }
        c.message("Group \"\(s)\" exploded.")
        finish()
        return true
    }

    override func enter() {
        if input == .text { finish() }
    }

    override func selectionDone(_ s: Set<EntityID>) {
        guard !s.isEmpty else { finish(); return }
        ungroup(s)
    }

    private func ungroup(_ s: Set<EntityID>) {
        var names: [String] = []
        c.perform("Ungroup") { names = $0.ungroup(containing: s) }
        if names.isEmpty {
            c.message("Selected objects are not in a group.")
        } else {
            for n in names { c.message("Group \"\(n)\" exploded.") }
        }
        finish()
    }
}

final class GroupEditCommand: CadCommand {
    private var groupName: String?
    private enum Phase { case pickGroup, name, option, add, remove, rename }
    private var phase = Phase.pickGroup
    private var toRemove: Set<EntityID> = []

    override func start() {
        c.selection.removeAll()
        guard !drawing.groups.isEmpty else { c.message("No groups in the drawing."); finish(); return }
        phase = .pickGroup
        ask("Select group", .entity, keywords: ["Name"])
    }

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        switch phase {
        case .pickGroup:
            let names = drawing.groupNames(containing: [id])
            guard let first = names.first else { c.message("Object is not a member of any group."); return }
            if names.count > 1 { c.message("Object belongs to groups \(names.joined(separator: ", ")); editing \"\(first)\".") }
            useGroup(first)
        case .remove:
            guard let g = groupName, let gi = drawing.groupIndex(named: g), drawing.groups[gi].members.contains(id) else {
                c.message("Object is not a member of the group.")
                return
            }
            toRemove.insert(id)
            c.selection = toRemove
            c.message("\(toRemove.count) object(s) to remove")
        default: break
        }
    }

    private func useGroup(_ name: String) {
        groupName = name
        if let gi = drawing.groupIndex(named: name) { c.selection = Set(drawing.groups[gi].members) }
        phase = .option
        ask("Enter an option", .text, keywords: ["Add objects", "Remove objects", "REName"])
    }

    override func keyword(_ k: String) {
        switch k {
        case "Name":
            phase = .name
            ask("Enter a group name or [?]", .text)
        case "Add objects":
            phase = .add
            c.selection.removeAll()
            ask("Select objects to add to the group", .selection)
        case "Remove objects":
            phase = .remove
            toRemove = []
            c.selection.removeAll()
            ask("Select objects to remove from the group", .entity)
        case "REName":
            phase = .rename
            ask("Enter new name for group <\(groupName ?? "")>", .text)
        default: break
        }
    }

    override func value(_ s: String) -> Bool {
        switch phase {
        case .name:
            if s == "?" { ToolCommands.listGroups(c); return true }
            guard let gi = drawing.groupIndex(named: s) else { c.message("Group \"\(s)\" not found."); return true }
            useGroup(drawing.groups[gi].name)
            return true
        case .rename:
            guard let old = groupName else { finish(); return true }
            var err: Error?
            c.perform("Rename Group") { d in do { try d.renameGroup(old, to: s) } catch { err = error } }
            if let err { c.message(err.localizedDescription); return true }
            c.message("Group \"\(old)\" renamed to \"\(s)\".")
            finish()
            return true
        default:
            return false
        }
    }

    override func selectionDone(_ s: Set<EntityID>) {
        guard phase == .add, let g = groupName, !s.isEmpty else { finish(); return }
        var n = 0
        c.perform("Group Edit") { d in n = (try? d.addToGroup(g, s)) ?? 0 }
        c.message("\(n) object(s) added to group \"\(g)\".")
        finish()
    }

    override func enter() {
        if phase == .remove, let g = groupName, !toRemove.isEmpty {
            let s = toRemove
            var n = 0
            c.perform("Group Edit") { d in n = (try? d.removeFromGroup(g, s)) ?? 0 }
            c.message("\(n) object(s) removed from group \"\(g)\".")
        }
        finish()
    }
}

// MARK: - OVERKILL

final class OverkillCommand: SelectionCommand {
    override func afterSelection() {
        let s = ids
        var r = OverkillResult()
        c.perform("Overkill") { r = $0.applyOverkill(s) }
        c.message("\(r.duplicates) duplicate(s) deleted")
        c.message("\(r.merged) overlapping object(s) or segment(s) deleted")
        finish()
    }
}

// MARK: - COUNT

final class CountCommand: CadCommand {
    override func start() {
        let pre = c.selection.filter { drawing.entity($0) != nil }
        if !pre.isEmpty {
            keepsSelection = true
            list(in: pre)
            finish()
            return
        }
        ask("Select a block reference to count <List>", .entity, keywords: ["List"])
    }

    private func list(in ids: Set<EntityID>? = nil) {
        let counts = drawing.blockCounts(in: ids)
        guard !counts.isEmpty else { c.message("No block references found."); return }
        for (name, n) in counts { c.message("\(name): \(n)") }
        c.message("Total: \(counts.reduce(0) { $0 + $1.count }) block reference(s), \(counts.count) block(s)")
    }

    override func keyword(_ k: String) { list(); finish() }
    override func enter() { list(); finish() }

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        guard let e = drawing.entity(id), case .insert(let ins) = e.kind else {
            c.message("Object is not a block reference.")
            return
        }
        let refs = drawing.blockReferences(named: ins.blockName)
        keepsSelection = true
        c.selection = Set(refs)
        c.message("\(refs.count) reference(s) of block \"\(ins.blockName)\" found.")
        finish()
    }
}

// MARK: - FIND

final class FindCommand: CadCommand {
    private var query: String?
    private var matches: [EntityID] = []
    private var scope: Set<EntityID>?

    override func start() {
        let pre = c.selection.filter { drawing.entity($0) != nil }
        scope = pre.isEmpty ? nil : pre
        allowsSpaces = true
        ask(scope == nil ? "Enter text to find" : "Enter text to find in the selection", .text)
    }

    override func value(_ s: String) -> Bool {
        guard let q = query else {
            query = s
            matches = drawing.findText(s, in: scope)
            guard !matches.isEmpty else { c.message("No matches found for \"\(s)\"."); finish(); return true }
            c.selection = Set(matches)
            c.message("\(matches.count) object(s) found containing \"\(s)\".")
            ask("Enter replacement text or <select matches>", .text)
            return true
        }
        let ids = Set(matches)
        var n = 0
        c.perform("Replace Text") { n = $0.replaceText(q, with: s, in: ids) }
        c.message("\(n) replacement(s) made.")
        keepsSelection = true
        c.selection = ids
        finish()
        return true
    }

    override func enter() {
        if query != nil { keepsSelection = true }
        finish()
    }
}

// MARK: - ISOLATEOBJECTS / HIDEOBJECTS

/// View-only isolation: hidden objects stay in the drawing and are not saved as hidden.
final class IsolateCommand: SelectionCommand {
    private let isolate: Bool
    init(_ c: CommandController, name: String, isolate: Bool) { self.isolate = isolate; super.init(c, name: name) }

    override func afterSelection() {
        let sel = ids
        if isolate {
            c.hiddenIDs.formUnion(drawing.entities.map(\.id).filter { !sel.contains($0) })
            c.message("\(sel.count) object(s) isolated. Use UNISOLATEOBJECTS to show everything again.")
        } else {
            c.hiddenIDs.formUnion(sel)
            c.message("\(sel.count) object(s) hidden. Use UNISOLATEOBJECTS to show them again.")
        }
        finish()
    }
}
