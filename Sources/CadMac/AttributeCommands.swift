import AppKit
import CadCore

/// Block attribute commands (ATTDEF, ATTEDIT). Registered via `CommandRegistry`.
@MainActor
enum AttributeCommands {
    static let all: [CommandInfo] = [
        CommandInfo(name: "ATTDEF", aliases: ["ATT", "DDATTDEF"], summary: "Creates an attribute definition for a block") {
            AttDefCommand($0, name: "ATTDEF")
        },
        CommandInfo(name: "ATTEDIT", aliases: ["ATE", "EATTEDIT", "DDATTE"], summary: "Edits the attribute values of a block reference") {
            AttEditCommand($0, name: "ATTEDIT")
        },
    ]
}

// MARK: - ATTDEF

/// Command-line ATTDEF: modes, tag, prompt, default, insertion point, height, rotation.
final class AttDefCommand: CadCommand {
    private enum Stage { case tag, prompt, value, point, height, rotation }
    private var stage = Stage.tag
    private var invisible = false, constant = false, preset = false
    private var tag = "", promptText = "", defaultValue = ""
    private var position: Vec2?
    private var height = 2.5

    override func start() {
        height = drawing.settings.textHeight
        askTag()
    }

    private func yn(_ b: Bool) -> String { b ? "Y" : "N" }

    private func askTag() {
        stage = .tag
        allowsSpaces = false
        c.message("Current attribute modes: Invisible=\(yn(invisible)) Constant=\(yn(constant)) Preset=\(yn(preset))")
        ask("Enter attribute tag name", .text, keywords: ["Invisible", "Constant", "Preset"])
    }

    private func askPrompt() {
        stage = .prompt
        allowsSpaces = true
        ask("Enter attribute prompt <\(tag)>", .text)
    }

    private func askValue() {
        stage = .value
        allowsSpaces = true
        ask(constant ? "Enter attribute value" : "Enter default attribute value", .text)
    }

    private func askPoint() {
        stage = .point
        allowsSpaces = false
        ask("Specify start point")
    }

    private func askRotation() {
        stage = .rotation
        // No base point: a typed number is an angle, not a direct distance.
        ask("Specify rotation angle of text <0>", .point)
    }

    override func keyword(_ k: String) {
        guard stage == .tag else { return }
        switch k {
        case "Invisible": invisible.toggle()
        case "Constant": constant.toggle()
        case "Preset": preset.toggle()
        default: break
        }
        askTag()
    }

    override func value(_ s: String) -> Bool {
        switch stage {
        case .tag:
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.contains(" ") else { return false }
            tag = t.uppercased()
            if constant { askValue() } else { askPrompt() }
            return true
        case .prompt:
            promptText = s
            askValue()
            return true
        case .value:
            defaultValue = s
            askPoint()
            return true
        case .height:
            guard let v = Double(s.replacingOccurrences(of: ",", with: ".")), v > 0 else { return false }
            height = v
            askRotation()
            return true
        case .rotation:
            guard let v = Double(s.replacingOccurrences(of: ",", with: ".")) else { return false }
            create(rotation: radians(v))
            return true
        case .point:
            return false
        }
    }

    override func enter() {
        switch stage {
        case .tag, .point: finish()
        case .prompt: promptText = tag; askValue()
        case .value: defaultValue = ""; askPoint()
        case .height: askRotation()
        case .rotation: create(rotation: 0)
        }
    }

    override func point(_ p: Vec2) {
        switch stage {
        case .point:
            position = p
            stage = .height
            ask("Specify text height <\(fmt(height))>", base: p)
        case .height:
            guard let pos = position else { return }
            let h = pos.distance(to: p)
            if h > 1e-9 { height = h }
            askRotation()
        case .rotation:
            guard let pos = position else { return }
            create(rotation: p.isClose(to: pos, tol: 1e-12) ? 0 : (p - pos).angle)
        default:
            break
        }
    }

    private func create(rotation: Double) {
        guard let pos = position else { finish(); return }
        let text = TextGeom(position: pos, height: height, text: tag, rotation: normalizeAngle(rotation),
                            style: drawing.settings.textStyle)
        let def = AttDefGeom(tag: tag, prompt: constant ? "" : promptText, defaultValue: defaultValue, text: text,
                             isInvisible: invisible, isConstant: constant, isPreset: preset)
        let e = make(.attdef(def))
        let h = height
        c.perform("Attribute Definition") { d in
            d.add(e)
            d.settings.textHeight = h
        }
        c.message("Attribute definition \(tag) created. Include it in a block with BLOCK.")
        finish()
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        guard !tag.isEmpty else { return [] }
        switch stage {
        case .point:
            return [make(.attdef(AttDefGeom(tag: tag, text: TextGeom(position: cursor, height: height, text: tag))))]
        case .rotation:
            guard let pos = position else { return [] }
            let r = cursor.isClose(to: pos, tol: 1e-12) ? 0 : (cursor - pos).angle
            return [make(.attdef(AttDefGeom(tag: tag, text: TextGeom(position: pos, height: height, text: tag, rotation: r))))]
        default:
            return []
        }
    }
}

// MARK: - ATTEDIT

/// Edits the attribute values of one block reference in a sheet (one undo step).
final class AttEditCommand: CadCommand {
    override func start() {
        let pre = c.selection.compactMap { drawing.entity($0) }.filter { if case .insert = $0.kind { return true }; return false }
        if pre.count == 1 {
            edit(pre[0].id)
        } else {
            c.selection.removeAll()
            ask("Select block reference", .entity)
        }
    }

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        guard let e = drawing.entity(id), case .insert = e.kind else {
            c.message("Object is not a block reference")
            return
        }
        edit(id)
    }

    private func edit(_ id: EntityID) {
        guard let e = drawing.entity(id), case .insert(var ins) = e.kind else { finish(); return }
        let block = drawing.blocks[ins.blockName]
        // A reference without values (e.g. inserted before ATTDEFs existed) gets its definitions' defaults.
        if ins.attributes.isEmpty, let b = block { ins.attributes = ins.makeAttributes(block: b) }
        guard !ins.attributes.isEmpty else {
            c.message("Block \"\(ins.blockName)\" has no editable attributes")
            finish()
            return
        }
        guard drawing.isEditable(e) else {
            c.message("Object is on a locked layer")
            finish()
            return
        }
        let labels = ins.attributes.map { a -> String in
            if let p = block?.attributeDefinition(tag: a.tag)?.prompt, !p.isEmpty { return p }
            return a.tag
        }
        let initial = ins.attributes.map(\.value)
        let controller = c
        let edited = ins.attributes
        finish()
        AttributeEditorSheet.run(title: "Edit Attributes", info: "Block: \(ins.blockName)", labels: labels, values: initial) { values in
            guard let values, var cur = controller.drawing.entity(id), case .insert(var g) = cur.kind,
                  values != initial || g.attributes.count != edited.count else { return }
            var atts = g.attributes.count == edited.count ? g.attributes : edited
            for i in atts.indices where i < values.count { atts[i].text.text = values[i] }
            g.attributes = atts
            cur.kind = .insert(g)
            controller.perform("Edit Attributes") { $0.replace(cur) }
            controller.message("\(atts.count) attribute(s) updated")
        }
    }
}

/// Form sheet with one labelled text field per attribute.
@MainActor
enum AttributeEditorSheet {
    static func run(title: String, info: String, labels: [String], values: [String], completion: @escaping ([String]?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        var fields: [NSTextField] = []
        var rows: [[NSView]] = []
        for (label, value) in zip(labels, values) {
            let l = NSTextField(labelWithString: label + ":")
            l.alignment = .right
            l.lineBreakMode = .byTruncatingTail
            let f = NSTextField(string: value)
            f.lineBreakMode = .byClipping
            f.usesSingleLineMode = !value.contains("\n")
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
            fields.append(f)
            rows.append([l, f])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        let size = grid.fittingSize
        let width = max(420, size.width)
        let height = min(size.height, 420)
        if size.height > height {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width + 20, height: height))
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            let doc = AttributeFormDocumentView(frame: NSRect(x: 0, y: 0, width: width, height: size.height))
            doc.addSubview(grid)
            NSLayoutConstraint.activate([
                grid.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
                grid.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
                grid.topAnchor.constraint(equalTo: doc.topAnchor),
            ])
            scroll.documentView = doc
            alert.accessoryView = scroll
        } else {
            let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: size.height))
            box.addSubview(grid)
            NSLayoutConstraint.activate([
                grid.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                grid.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                grid.topAnchor.constraint(equalTo: box.topAnchor),
            ])
            alert.accessoryView = box
        }
        for (a, b) in zip(fields, fields.dropFirst()) { a.nextKeyView = b }
        if let first = fields.first { alert.window.initialFirstResponder = first }

        let finish: (NSApplication.ModalResponse) -> Void = { resp in
            completion(resp == .alertFirstButtonReturn ? fields.map(\.stringValue) : nil)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
            if let first = fields.first { DispatchQueue.main.async { alert.window.makeFirstResponder(first) } }
        } else {
            finish(alert.runModal())
        }
    }
}

/// Top-down document view for the scrolling attribute form.
private final class AttributeFormDocumentView: NSView {
    override var isFlipped: Bool { true }
}
