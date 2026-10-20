import AppKit
import CadCore

// MARK: - Shared helpers

@MainActor
enum PanelStyle {
    static let background = NSColor(calibratedRed: 0.2, green: 0.22, blue: 0.25, alpha: 1)
    static let header = NSColor(white: 0.6, alpha: 1)
    static let text = NSColor(white: 0.88, alpha: 1)

    static func headerLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s.uppercased())
        l.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        l.textColor = header
        return l
    }

    static func nsColor(_ c: CadColor) -> NSColor {
        let rgb = c.rgb(darkBackground: true)
        return NSColor(calibratedRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }

    static func swatch(_ c: CadColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            nsColor(c).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).fill()
            NSColor(white: 0.5, alpha: 1).setStroke()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
            return true
        }
        return img
    }

    static let standardColors: [CadColor] = [.aci(1), .aci(2), .aci(3), .aci(4), .aci(5), .aci(6), .aci(7), .aci(8), .aci(9),
                                             .aci(30), .aci(40), .aci(140), .aci(200), .aci(250)]
    static let lineweights: [Double] = [0, 0.05, 0.09, 0.13, 0.15, 0.18, 0.2, 0.25, 0.3, 0.35, 0.4, 0.5, 0.53, 0.6, 0.7, 0.8, 0.9, 1.0, 1.2, 1.4, 2.0]

    static func lineweightTitle(_ v: Double) -> String {
        switch v {
        case -1: return "ByLayer"
        case -2: return "ByBlock"
        case ..<0: return "Default"
        default: return String(format: "%.2f mm", v)
        }
    }
}

/// Popup listing colors; tag-encoded so it can represent ByLayer/ByBlock/ACI.
@MainActor
func makeColorPopup(selected: CadColor?, includeByLayer: Bool, target: AnyObject, action: Selector) -> NSPopUpButton {
    let p = NSPopUpButton(frame: .zero, pullsDown: false)
    p.controlSize = .small
    p.font = NSFont.systemFont(ofSize: 11)
    var colors: [CadColor] = includeByLayer ? [.byLayer, .byBlock] : []
    colors += PanelStyle.standardColors
    if let s = selected, !colors.contains(s) { colors.append(s) }
    for c in colors {
        let item = NSMenuItem(title: c.displayName, action: nil, keyEquivalent: "")
        if case .aci = c { item.image = PanelStyle.swatch(c) }
        if case .rgb = c { item.image = PanelStyle.swatch(c) }
        item.representedObject = c
        p.menu?.addItem(item)
    }
    p.menu?.addItem(.separator())
    let custom = NSMenuItem(title: "Select Color…", action: nil, keyEquivalent: "")
    custom.representedObject = "custom"
    p.menu?.addItem(custom)
    if selected == nil {
        p.insertItem(withTitle: "*VARIES*", at: 0)
        p.selectItem(at: 0)
    } else if let s = selected, let i = colors.firstIndex(of: s) {
        p.selectItem(at: i)
    }
    p.target = target
    p.action = action
    return p
}

/// Shows the system color panel and reports the chosen color once.
@MainActor
final class ColorPicker: NSObject {
    static let shared = ColorPicker()
    private var completion: ((CadColor) -> Void)?

    func pick(_ completion: @escaping (CadColor) -> Void) {
        self.completion = completion
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.isContinuous = false
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func changed(_ sender: NSColorPanel) {
        guard let c = sender.color.usingColorSpace(.sRGB) else { return }
        let rgb = RGB(UInt8(c.redComponent * 255), UInt8(c.greenComponent * 255), UInt8(c.blueComponent * 255))
        completion?(.rgb(rgb))
    }
}

// MARK: - Properties inspector

@MainActor
final class PropertiesPanel: NSView {
    weak var controller: CommandController?
    private let stack = NSStackView()
    private var fieldSetters: [NSTextField: (String) -> Void] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = PanelStyle.background.cgColor
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        let flipped = FlippedView()
        flipped.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = flipped
        flipped.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: flipped.topAnchor), stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor), stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var selectedEntities: [Entity] {
        guard let c = controller else { return [] }
        return c.drawing.entities.filter { c.selection.contains($0.id) }
    }

    func reload() {
        guard let c = controller else { return }
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        fieldSetters.removeAll()
        let d = c.drawing
        let sel = selectedEntities

        let title: String
        if sel.isEmpty { title = "No selection" }
        else if sel.count == 1 { title = sel[0].kind.typeName }
        else {
            let types = Set(sel.map { $0.kind.typeName })
            title = types.count == 1 ? "\(types.first!) (\(sel.count))" : "All (\(sel.count))"
        }
        let t = NSTextField(labelWithString: title)
        t.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        t.textColor = PanelStyle.text
        stack.addArrangedSubview(t)
        stack.addArrangedSubview(PanelStyle.headerLabel("General"))

        // Layer
        let layerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        layerPopup.controlSize = .small
        layerPopup.font = NSFont.systemFont(ofSize: 11)
        for l in d.layers {
            layerPopup.addItem(withTitle: l.name)
            layerPopup.lastItem?.image = PanelStyle.swatch(l.color)
        }
        let layers = Set(sel.map(\.layer))
        if sel.isEmpty { layerPopup.selectItem(withTitle: d.settings.currentLayer) }
        else if layers.count == 1 { layerPopup.selectItem(withTitle: layers.first!) }
        else { layerPopup.insertItem(withTitle: "*VARIES*", at: 0); layerPopup.selectItem(at: 0) }
        layerPopup.target = self
        layerPopup.action = #selector(layerChanged(_:))
        addRow("Layer", layerPopup)

        // Color
        let colors = Set(sel.map(\.color))
        let currentColor: CadColor? = sel.isEmpty ? d.settings.currentColor : (colors.count == 1 ? colors.first : nil)
        addRow("Color", makeColorPopup(selected: currentColor, includeByLayer: true, target: self, action: #selector(colorChanged(_:))))

        // Linetype
        let ltPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        ltPopup.controlSize = .small
        ltPopup.font = NSFont.systemFont(ofSize: 11)
        ltPopup.addItems(withTitles: ["ByLayer", "ByBlock"] + d.linetypes.map(\.name))
        let lts = Set(sel.map(\.linetype))
        if sel.isEmpty { ltPopup.selectItem(withTitle: d.settings.currentLinetype) }
        else if lts.count == 1 { ltPopup.selectItem(withTitle: lts.first!) }
        else { ltPopup.insertItem(withTitle: "*VARIES*", at: 0); ltPopup.selectItem(at: 0) }
        ltPopup.target = self
        ltPopup.action = #selector(linetypeChanged(_:))
        addRow("Linetype", ltPopup)

        // Lineweight
        let lwPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        lwPopup.controlSize = .small
        lwPopup.font = NSFont.systemFont(ofSize: 11)
        for v in [-1.0, -2.0, -3.0] + PanelStyle.lineweights {
            lwPopup.addItem(withTitle: PanelStyle.lineweightTitle(v))
            lwPopup.lastItem?.representedObject = v
        }
        let lws = Set(sel.map(\.lineweight))
        let lwSel = sel.isEmpty ? d.settings.currentLineweight : (lws.count == 1 ? lws.first! : nil)
        if let v = lwSel { lwPopup.selectItem(withTitle: PanelStyle.lineweightTitle(v)) }
        else { lwPopup.insertItem(withTitle: "*VARIES*", at: 0); lwPopup.selectItem(at: 0) }
        lwPopup.target = self
        lwPopup.action = #selector(lineweightChanged(_:))
        addRow("Lineweight", lwPopup)

        if sel.isEmpty {
            stack.addArrangedSubview(PanelStyle.headerLabel("Drawing"))
            let unitsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            unitsPopup.controlSize = .small
            unitsPopup.font = NSFont.systemFont(ofSize: 11)
            for u in [DrawingUnit.millimeters, .centimeters, .meters, .inches, .feet, .unitless] {
                unitsPopup.addItem(withTitle: u == .unitless ? u.displayName : "\(u.displayName) (\(u.suffix))")
                unitsPopup.lastItem?.representedObject = u.rawValue
                if u == d.settings.insUnits { unitsPopup.select(unitsPopup.lastItem) }
            }
            unitsPopup.target = self
            unitsPopup.action = #selector(unitsChanged(_:))
            unitsPopup.toolTip = "Real-world size of one drawing unit. Changing it does not scale geometry."
            addRow("Units", unitsPopup)
            addField("Text height", fmt(d.settings.textHeight)) { [weak self] s in
                guard let v = Double(s), v > 0 else { return }
                self?.controller?.perform("Text height") { $0.settings.textHeight = v }
            }
            addField("Dim scale", fmt(d.settings.dimStyle.scale)) { [weak self] s in
                guard let v = Double(s), v > 0 else { return }
                self?.controller?.perform("Dim scale") { $0.settings.dimStyle.scale = v }
            }
            addField("LT scale", fmt(d.settings.ltScale)) { [weak self] s in
                guard let v = Double(s), v > 0 else { return }
                self?.controller?.perform("LT scale") { $0.settings.ltScale = v }
            }
            addField("Grid spacing", fmt(d.settings.gridSpacing)) { [weak self] s in
                guard let v = Double(s), v > 0 else { return }
                self?.controller?.perform("Grid spacing") { $0.settings.gridSpacing = v; $0.settings.snapSpacing = v }
            }
            let n = d.entities.count
            let info = NSTextField(labelWithString: "\(n) objects · \(d.layers.count) layers · \(d.blocks.count) blocks")
            info.font = NSFont.systemFont(ofSize: 10)
            info.textColor = PanelStyle.header
            stack.addArrangedSubview(info)
        } else if sel.count == 1 {
            addGeometry(sel[0])
        }
        Loc.localize(self)
    }

    private func addRow(_ label: String, _ control: NSView) {
        let l = NSTextField(labelWithString: label)
        l.font = NSFont.systemFont(ofSize: 11)
        l.textColor = PanelStyle.text
        l.widthAnchor.constraint(equalToConstant: 80).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [l, control])
        row.orientation = .horizontal
        row.spacing = 6
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
    }

    private func addField(_ label: String, _ value: String, editable: Bool = true, _ setter: @escaping (String) -> Void) {
        let f = NSTextField(string: value)
        f.controlSize = .small
        f.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        f.isEditable = editable
        f.target = self
        f.action = #selector(fieldCommitted(_:))
        fieldSetters[f] = setter
        addRow(label, f)
    }

    private func addInfo(_ label: String, _ value: String) {
        addField(label, value, editable: false) { _ in }
    }

    @objc private func fieldCommitted(_ sender: NSTextField) {
        fieldSetters[sender]?(sender.stringValue)
    }

    /// Edits the single selected entity.
    private func edit(_ e: Entity, _ name: String, _ body: @escaping (inout EntityKind, String) -> Bool) -> (String) -> Void {
        { [weak self] s in
            guard let c = self?.controller, var cur = c.drawing.entity(e.id) else { return }
            var k = cur.kind
            guard body(&k, s) else { NSSound.beep(); self?.reload(); return }
            cur.kind = k
            c.perform(name) { $0.replace(cur) }
        }
    }

    private func num(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }

    private func addGeometry(_ e: Entity) {
        let d = controller!.drawing
        let u = d.settings.insUnits.suffix
        stack.addArrangedSubview(PanelStyle.headerLabel(u.isEmpty ? "Geometry" : "Geometry (\(u))"))
        let st = d.settings
        func len(_ v: Double) -> String { st.formatLength(v) }
        func area(_ v: Double) -> String { st.formatArea(abs(v)) }
        func xy(_ label: String, _ p: Vec2, _ set: @escaping (inout EntityKind, Vec2) -> Void) {
            addField("\(label) X", fmt(p.x), edit(e, "Edit \(label)") { k, s in guard let v = self.num(s) else { return false }; set(&k, Vec2(v, p.y)); return true })
            addField("\(label) Y", fmt(p.y), edit(e, "Edit \(label)") { k, s in guard let v = self.num(s) else { return false }; set(&k, Vec2(p.x, v)); return true })
        }
        switch e.kind {
        case .line(let l):
            xy("Start", l.start) { k, v in if case .line(var g) = k { g.start = v; k = .line(g) } }
            xy("End", l.end) { k, v in if case .line(var g) = k { g.end = v; k = .line(g) } }
            addInfo("Length", len(l.length))
            addInfo("Angle", fmt(degrees(normalizeAngle((l.end - l.start).angle))) + "°")
        case .circle(let ci):
            xy("Center", ci.center) { k, v in if case .circle(var g) = k { g.center = v; k = .circle(g) } }
            addField("Radius", fmt(ci.radius), edit(e, "Edit Radius") { k, s in
                guard let v = self.num(s), v > 0, case .circle(var g) = k else { return false }; g.radius = v; k = .circle(g); return true })
            addField("Diameter", fmt(ci.radius * 2), edit(e, "Edit Diameter") { k, s in
                guard let v = self.num(s), v > 0, case .circle(var g) = k else { return false }; g.radius = v / 2; k = .circle(g); return true })
            addInfo("Circumference", len(2 * .pi * ci.radius))
            addInfo("Area", area(.pi * ci.radius * ci.radius))
        case .arc(let a):
            xy("Center", a.center) { k, v in if case .arc(var g) = k { g.center = v; k = .arc(g) } }
            addField("Radius", fmt(a.radius), edit(e, "Edit Radius") { k, s in
                guard let v = self.num(s), v > 0, case .arc(var g) = k else { return false }; g.radius = v; k = .arc(g); return true })
            addField("Start angle", fmt(degrees(a.startAngle)), edit(e, "Edit Arc") { k, s in
                guard let v = self.num(s), case .arc(let g) = k else { return false }
                k = .arc(ArcGeom(center: g.center, radius: g.radius, startAngle: radians(v), endAngle: g.endAngle)); return true })
            addField("End angle", fmt(degrees(a.endAngle)), edit(e, "Edit Arc") { k, s in
                guard let v = self.num(s), case .arc(let g) = k else { return false }
                k = .arc(ArcGeom(center: g.center, radius: g.radius, startAngle: g.startAngle, endAngle: radians(v))); return true })
            addInfo("Arc length", len(a.length))
        case .polyline(let p):
            addInfo("Vertices", "\(p.vertices.count)")
            addField("Closed", p.closed ? "Yes" : "No", edit(e, "Edit Polyline") { k, s in
                guard case .polyline(var g) = k else { return false }
                g.closed = s.lowercased().hasPrefix("y") || s == "1"; k = .polyline(g); return true })
            addField("Global width", fmt(p.width), edit(e, "Edit Polyline") { k, s in
                guard let v = self.num(s), v >= 0, case .polyline(var g) = k else { return false }; g.width = v; k = .polyline(g); return true })
            if let a = d.area(of: e.id) { addInfo("Area", area(a)) }
            if let l = d.perimeter(of: e.id) { addInfo("Length", len(l)) }
        case .text(let t):
            addField("Contents", t.text.replacingOccurrences(of: "\n", with: "\\P"), edit(e, "Edit Text") { k, s in
                guard case .text(var g) = k else { return false }; g.text = s.replacingOccurrences(of: "\\P", with: "\n"); k = .text(g); return true })
            addField("Height", fmt(t.height), edit(e, "Edit Text") { k, s in
                guard let v = self.num(s), v > 0, case .text(var g) = k else { return false }; g.height = v; k = .text(g); return true })
            addField("Rotation", fmt(degrees(t.rotation)), edit(e, "Edit Text") { k, s in
                guard let v = self.num(s), case .text(var g) = k else { return false }; g.rotation = radians(v); k = .text(g); return true })
            xy("Position", t.position) { k, v in if case .text(var g) = k { g.position = v; k = .text(g) } }
        case .point(let p):
            xy("Position", p.position) { k, v in k = .point(PointGeom(position: v)) }
        case .ellipse(let el):
            xy("Center", el.center) { k, v in if case .ellipse(var g) = k { g.center = v; k = .ellipse(g) } }
            addInfo("Major radius", len(el.majorAxis.length))
            addField("Radius ratio", fmt(el.ratio), edit(e, "Edit Ellipse") { k, s in
                guard let v = self.num(s), v > 0, v <= 1, case .ellipse(var g) = k else { return false }; g.ratio = v; k = .ellipse(g); return true })
        case .dimension(let dm):
            addInfo("Measurement", dm.kind == .angular ? fmt(dm.measurement) + "°" : len(dm.measurement))
            addField("Text override", dm.textOverride, edit(e, "Edit Dimension") { k, s in
                guard case .dimension(var g) = k else { return false }; g.textOverride = s; k = .dimension(g); return true })
        case .insert(let i):
            addInfo("Block", i.blockName)
            for (idx, a) in i.attributes.enumerated() {
                addField(a.tag, a.value, edit(e, "Edit Attribute") { k, s in
                    guard case .insert(var g) = k, idx < g.attributes.count else { return false }
                    g.attributes[idx].text.text = s; k = .insert(g); return true })
            }
            xy("Position", i.position) { k, v in if case .insert(var g) = k { g.position = v; k = .insert(g) } }
            addField("Scale X", fmt(i.scaleX), edit(e, "Edit Block") { k, s in
                guard let v = self.num(s), v != 0, case .insert(var g) = k else { return false }; g.scaleX = v; k = .insert(g); return true })
            addField("Scale Y", fmt(i.scaleY), edit(e, "Edit Block") { k, s in
                guard let v = self.num(s), v != 0, case .insert(var g) = k else { return false }; g.scaleY = v; k = .insert(g); return true })
            addField("Rotation", fmt(degrees(i.rotation)), edit(e, "Edit Block") { k, s in
                guard let v = self.num(s), case .insert(var g) = k else { return false }; g.rotation = radians(v); k = .insert(g); return true })
        case .hatch(let h):
            addInfo("Pattern", h.patternName)
            if h.pattern != .solid {
                addField("Spacing", fmt(h.spacing), edit(e, "Edit Hatch") { k, s in
                    guard let v = self.num(s), v > 0, case .hatch(var g) = k else { return false }; g.spacing = v; k = .hatch(g); return true })
                addField("Angle", fmt(degrees(h.angle)), edit(e, "Edit Hatch") { k, s in
                    guard let v = self.num(s), case .hatch(var g) = k else { return false }; g.angle = radians(v); k = .hatch(g); return true })
            }
            if let a = d.area(of: e.id) { addInfo("Area", area(a)) }
        case .spline(let s):
            addInfo("Points", "\(max(s.fitPoints.count, s.controlPoints.count))")
            addInfo("Closed", s.closed ? "Yes" : "No")
        case .attdef(let a):
            addField("Tag", a.tag, edit(e, "Edit Attribute Definition") { k, s in
                guard case .attdef(var g) = k, !s.isEmpty, !s.contains(" ") else { return false }; g.tag = s.uppercased(); k = .attdef(g); return true })
            addField("Prompt", a.prompt, edit(e, "Edit Attribute Definition") { k, s in
                guard case .attdef(var g) = k else { return false }; g.prompt = s; k = .attdef(g); return true })
            addField("Default", a.defaultValue, edit(e, "Edit Attribute Definition") { k, s in
                guard case .attdef(var g) = k else { return false }; g.defaultValue = s; k = .attdef(g); return true })
            addField("Height", fmt(a.text.height), edit(e, "Edit Attribute Definition") { k, s in
                guard let v = self.num(s), v > 0, case .attdef(var g) = k else { return false }; g.text.height = v; k = .attdef(g); return true })
        case .viewport(let v):
            addField("Scale", formatViewportScale(v.scale), edit(e, "Viewport Scale") { k, s in
                guard let sc = parseViewportScale(s), case .viewport(var g) = k else { return false }; g.scale = sc; k = .viewport(g); return true })
            addField("Width", fmt(v.width), edit(e, "Viewport Size") { k, s in
                guard let w = self.num(s), w > 0, case .viewport(var g) = k else { return false }
                let sc = g.scale; g.width = w; g.scale = sc; k = .viewport(g); return true })
            addField("Height", fmt(v.height), edit(e, "Viewport Size") { k, s in
                guard let h = self.num(s), h > 0, case .viewport(var g) = k else { return false }
                let sc = g.scale; g.height = h; g.scale = sc; k = .viewport(g); return true })
            xy("Center", v.center) { k, p in if case .viewport(var g) = k { g.center = p; k = .viewport(g) } }
            xy("View center", v.viewCenter) { k, p in if case .viewport(var g) = k { g.viewCenter = p; k = .viewport(g) } }
            addField("Locked", v.isLocked ? "Yes" : "No", edit(e, "Viewport Lock") { k, s in
                guard case .viewport(var g) = k else { return false }
                g.isLocked = s.lowercased().hasPrefix("y") || s == "1"; k = .viewport(g); return true })
            addField("On", v.isOn ? "Yes" : "No", edit(e, "Viewport On") { k, s in
                guard case .viewport(var g) = k else { return false }
                g.isOn = s.lowercased().hasPrefix("y") || s == "1"; k = .viewport(g); return true })
            if !v.frozenLayers.isEmpty { addInfo("Frozen layers", v.frozenLayers.joined(separator: ", ")) }
        }
    }

    // MARK: Actions

    private func applyToSelectionOrCurrent(_ name: String, entity: @escaping (inout Entity) -> Void, current: @escaping (inout DrawingSettings) -> Void) {
        guard let c = controller else { return }
        let ids = c.selection
        if ids.isEmpty {
            c.perform(name) { current(&$0.settings) }
        } else {
            c.perform(name) { $0.update(ids: ids, entity) }
        }
    }

    @objc private func unitsChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? Int, let u = DrawingUnit(rawValue: raw) else { return }
        controller?.perform("Units") { $0.settings.insUnits = u }
    }

    @objc private func layerChanged(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem, name != "*VARIES*" else { return }
        applyToSelectionOrCurrent("Change Layer", entity: { $0.layer = name }, current: { $0.currentLayer = name })
    }

    @objc private func colorChanged(_ sender: NSPopUpButton) {
        let obj = sender.selectedItem?.representedObject
        if obj as? String == "custom" {
            ColorPicker.shared.pick { [weak self] c in
                self?.applyToSelectionOrCurrent("Change Color", entity: { $0.color = c }, current: { $0.currentColor = c })
            }
            return
        }
        guard let c = obj as? CadColor else { return }
        applyToSelectionOrCurrent("Change Color", entity: { $0.color = c }, current: { $0.currentColor = c })
    }

    @objc private func linetypeChanged(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem, name != "*VARIES*" else { return }
        applyToSelectionOrCurrent("Change Linetype", entity: { $0.linetype = name }, current: { $0.currentLinetype = name })
    }

    @objc private func lineweightChanged(_ sender: NSPopUpButton) {
        guard let v = sender.selectedItem?.representedObject as? Double else { return }
        applyToSelectionOrCurrent("Change Lineweight", entity: { $0.lineweight = v }, current: { $0.currentLineweight = v })
    }
}

// MARK: - Layers panel

@MainActor
final class LayersPanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    weak var controller: CommandController?
    private let table = NSTableView()

    private enum Col: String, CaseIterable {
        case current = "✓", name = "Name", on = "On", freeze = "Freeze", lock = "Lock", color = "Color", linetype = "Linetype", lineweight = "Lineweight"
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = PanelStyle.background.cgColor

        for c in Col.allCases {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.rawValue))
            col.title = c.rawValue
            switch c {
            case .current: col.width = 18
            case .name: col.width = 110
            case .on, .freeze, .lock: col.width = 40
            case .color: col.width = 80
            case .linetype: col.width = 90
            case .lineweight: col.width = 80
            }
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.style = .plain
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.doubleAction = #selector(doubleClicked)
        table.target = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let add = NSButton(title: "New", target: self, action: #selector(newLayer))
        let del = NSButton(title: "Delete", target: self, action: #selector(deleteLayer))
        let cur = NSButton(title: "Set Current", target: self, action: #selector(setCurrent))
        for b in [add, del, cur] { b.controlSize = .small; b.bezelStyle = .rounded; b.font = NSFont.systemFont(ofSize: 11) }
        let title = PanelStyle.headerLabel("Layers")
        let bar = NSStackView(views: [title, NSView(), add, del, cur])
        bar.orientation = .horizontal
        bar.spacing = 4
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 4, right: 8)

        for v in [bar, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor), bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var layers: [Layer] { controller?.drawing.layers ?? [] }

    func reload() {
        let sel = table.selectedRow
        table.reloadData()
        if sel >= 0 && sel < table.numberOfRows { table.selectRowIndexes([sel], byExtendingSelection: false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { layers.count }

    private func modify(_ row: Int, _ name: String, _ body: @escaping (inout Layer) -> Void) {
        guard row >= 0, row < layers.count else { return }
        let lname = layers[row].name
        controller?.perform(name) { d in
            if let i = d.layers.firstIndex(where: { $0.name == lname }) { body(&d.layers[i]) }
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let col = Col(rawValue: id), row < layers.count else { return nil }
        let l = layers[row]
        let isCurrent = controller?.drawing.settings.currentLayer == l.name
        func check(_ on: Bool, _ sel: Selector) -> NSView {
            let b = NSButton(checkboxWithTitle: "", target: self, action: sel)
            b.state = on ? .on : .off
            b.tag = row
            return b
        }
        switch col {
        case .current:
            let t = NSTextField(labelWithString: isCurrent ? "✓" : "")
            t.textColor = .systemGreen
            return t
        case .name:
            let t = NSTextField(string: l.name)
            t.isBordered = false
            t.drawsBackground = false
            t.textColor = PanelStyle.text
            t.font = NSFont.systemFont(ofSize: 12, weight: isCurrent ? .semibold : .regular)
            t.isEditable = l.name != "0" && l.name != "Defpoints"
            t.delegate = self
            t.tag = row
            return t
        case .on: return check(l.isOn, #selector(toggleOn(_:)))
        case .freeze: return check(l.isFrozen, #selector(toggleFreeze(_:)))
        case .lock: return check(l.isLocked, #selector(toggleLock(_:)))
        case .color:
            let p = makeColorPopup(selected: l.color, includeByLayer: false, target: self, action: #selector(colorChanged(_:)))
            p.tag = row
            p.isBordered = false
            return p
        case .linetype:
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            p.controlSize = .small
            p.isBordered = false
            p.font = NSFont.systemFont(ofSize: 11)
            p.addItems(withTitles: controller?.drawing.linetypes.map(\.name) ?? [])
            p.selectItem(withTitle: l.linetype)
            p.tag = row
            p.target = self
            p.action = #selector(linetypeChanged(_:))
            return p
        case .lineweight:
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            p.controlSize = .small
            p.isBordered = false
            p.font = NSFont.systemFont(ofSize: 11)
            for v in [-3.0] + PanelStyle.lineweights {
                p.addItem(withTitle: PanelStyle.lineweightTitle(v))
                p.lastItem?.representedObject = v
            }
            p.selectItem(withTitle: PanelStyle.lineweightTitle(l.lineweight < 0 ? -3 : l.lineweight))
            p.tag = row
            p.target = self
            p.action = #selector(lineweightChanged(_:))
            return p
        }
    }

    @objc private func toggleOn(_ s: NSButton) { modify(s.tag, "Layer On/Off") { $0.isOn = s.state == .on } }
    @objc private func toggleFreeze(_ s: NSButton) {
        if layers[s.tag].name == controller?.drawing.settings.currentLayer { NSSound.beep(); reload(); return }
        modify(s.tag, "Layer Freeze") { $0.isFrozen = s.state == .on }
    }
    @objc private func toggleLock(_ s: NSButton) { modify(s.tag, "Layer Lock") { $0.isLocked = s.state == .on } }
    @objc private func colorChanged(_ s: NSPopUpButton) {
        let row = s.tag
        if s.selectedItem?.representedObject as? String == "custom" {
            ColorPicker.shared.pick { [weak self] c in self?.modify(row, "Layer Color") { $0.color = c } }
            return
        }
        guard let c = s.selectedItem?.representedObject as? CadColor else { return }
        modify(row, "Layer Color") { $0.color = c }
    }
    @objc private func linetypeChanged(_ s: NSPopUpButton) {
        guard let n = s.titleOfSelectedItem else { return }
        modify(s.tag, "Layer Linetype") { $0.linetype = n }
    }
    @objc private func lineweightChanged(_ s: NSPopUpButton) {
        guard let v = s.selectedItem?.representedObject as? Double else { return }
        modify(s.tag, "Layer Lineweight") { $0.lineweight = v < 0 ? -1 : v }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, f.tag < layers.count else { return }
        let old = layers[f.tag].name
        let new = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old else { f.stringValue = old; return }
        if controller?.drawing.layer(named: new) != nil { NSSound.beep(); f.stringValue = old; return }
        controller?.perform("Rename Layer") { $0.renameLayer(old, to: new) }
    }

    @objc private func newLayer() {
        guard let c = controller else { return }
        var i = 1
        while c.drawing.layer(named: "Layer\(i)") != nil { i += 1 }
        let name = "Layer\(i)"
        let colors: [Int] = [1, 2, 3, 4, 5, 6, 30, 140, 200]
        c.perform("New Layer") { $0.layers.append(Layer(name: name, color: .aci(colors[(i - 1) % colors.count]))) }
        table.selectRowIndexes([layers.count - 1], byExtendingSelection: false)
    }

    @objc private func deleteLayer() {
        guard let c = controller, table.selectedRow >= 0, table.selectedRow < layers.count else { return }
        let name = layers[table.selectedRow].name
        if name == "0" || name == "Defpoints" || name == c.drawing.settings.currentLayer {
            c.message("Cannot delete layer \"\(name)\" (layer 0, Defpoints and the current layer cannot be deleted).")
            NSSound.beep(); return
        }
        if c.drawing.entities.contains(where: { $0.layer == name }) || c.drawing.blocks.values.contains(where: { $0.entities.contains { $0.layer == name } }) {
            c.message("Cannot delete layer \"\(name)\": it contains objects.")
            NSSound.beep(); return
        }
        c.perform("Delete Layer") { $0.layers.removeAll { $0.name == name } }
    }

    @objc private func setCurrent() {
        guard let c = controller, table.selectedRow >= 0, table.selectedRow < layers.count else { return }
        let l = layers[table.selectedRow]
        c.perform("Set Current Layer") { d in
            d.settings.currentLayer = l.name
            if let i = d.layers.firstIndex(where: { $0.name == l.name }) { d.layers[i].isFrozen = false; d.layers[i].isOn = true }
        }
    }

    @objc private func doubleClicked() {
        if table.clickedColumn >= 0, table.tableColumns[table.clickedColumn].identifier.rawValue == Col.name.rawValue { return }
        setCurrent()
    }
}
