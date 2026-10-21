import AppKit
import CadCore

/// Identifies a window that edits a block definition of a parent drawing.
struct BlockEditInfo {
    let name: String
    let basePoint: Vec2
    weak var parent: CadWindowController?
}

@MainActor
final class CadWindowController: NSWindowController, NSWindowDelegate, CommandControllerDelegate, NSMenuItemValidation, NSToolbarDelegate {
    let controller: CommandController
    let canvas = CanvasView()
    let commandLine = CommandLineView()
    let statusBar = StatusBarView()
    let palette = ToolPaletteView()
    let properties = PropertiesPanel()
    let layersPanel = LayersPanel()
    let layoutTabs = LayoutTabBar()
    /// Remembered view per tab ("" = Model).
    private var spaceViews: [String: (Vec2, Double)] = [:]
    private var switchingSpace = false
    private var commandLineHeight: NSLayoutConstraint!
    /// Command window shown at the bottom; when hidden, input moves next to the cursor.
    private(set) var commandLineVisible = true
    private let mainSplit = NSSplitView()
    /// Right inspector: tabbed Layers / Properties.
    private let rightPanel = NSView()
    private let inspectorTabs = NSSegmentedControl(labels: ["Layers", "Properties"], trackingMode: .selectOne, target: nil, action: nil)
    private let inspectorContent = NSTabView()
    private var didInitialZoom = false
    /// Non-nil when this window is a Block Editor.
    let blockEdit: BlockEditInfo?
    /// Statistics of the DWG read that opened this document, nil for DXF and new drawings.
    let importReport: NativeDWGReader.Report?
    /// The import notice is shown once per window.
    private var didAnnounceImport = false
    private var blockDirty = false
    /// Block Editor windows opened from this drawing.
    private var blockEditors: [CadWindowController] = []

    init(history: DrawingHistory, blockEdit: BlockEditInfo? = nil, importReport: NativeDWGReader.Report? = nil) {
        controller = CommandController(history: history)
        self.blockEdit = blockEdit
        self.importReport = importReport
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 880),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 800, height: 500)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = false
        window.tabbingMode = .preferred
        super.init(window: window)
        window.delegate = self
        buildLayout()
        buildToolbar()
        wire()
        applyPreferences()
        window.center()
        if let b = blockEdit {
            window.title = "\(b.name) — Block Editor"
            window.tabbingIdentifier = "CadMacBlockEditor"
            canvas.basePointMarker = b.basePoint
            canvas.style.darkBackground = true
        } else {
            window.setFrameAutosaveName("CadMacMainWindow")
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin

        let center = NSView()
        commandLineHeight = commandLine.heightAnchor.constraint(equalToConstant: 118)
        let banner = makeBlockEditorBanner()
        for v in [banner, canvas, layoutTabs, commandLine, statusBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            center.addSubview(v)
        }
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: center.topAnchor),
            banner.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            banner.heightAnchor.constraint(equalToConstant: blockEdit == nil ? 0 : 34),
            canvas.topAnchor.constraint(equalTo: banner.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: layoutTabs.topAnchor),
            layoutTabs.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            layoutTabs.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            layoutTabs.bottomAnchor.constraint(equalTo: commandLine.topAnchor),
            layoutTabs.heightAnchor.constraint(equalToConstant: blockEdit == nil ? 24 : 0),
            commandLine.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            commandLine.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            commandLineHeight,
            commandLine.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: center.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
        ])

        buildInspector()
        mainSplit.addArrangedSubview(palette)
        mainSplit.addArrangedSubview(center)
        mainSplit.addArrangedSubview(rightPanel)
        mainSplit.setHoldingPriority(.init(260), forSubviewAt: 0)
        mainSplit.setHoldingPriority(.init(200), forSubviewAt: 1)
        mainSplit.setHoldingPriority(.init(260), forSubviewAt: 2)
        palette.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        rightPanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(mainSplit)
        NSLayoutConstraint.activate([
            mainSplit.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            mainSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        DispatchQueue.main.async { [self] in
            mainSplit.setPosition(156, ofDividerAt: 0)
            mainSplit.setPosition(mainSplit.bounds.width - 330, ofDividerAt: 1)
            let defaults = UserDefaults.standard
            setPanel(left: true, visible: defaults.object(forKey: "ShowToolSets") as? Bool ?? true)
            setPanel(left: false, visible: defaults.object(forKey: "ShowInspector") as? Bool ?? true)
            setCommandLine(visible: defaults.object(forKey: "ShowCommandLine") as? Bool ?? true, announce: false)
        }
    }

    private func makeBlockEditorBanner() -> NSView {
        let bar = NSView()
        guard let b = blockEdit else { bar.isHidden = true; return bar }
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(calibratedRed: 0.85, green: 0.5, blue: 0.1, alpha: 1).cgColor
        let label = NSTextField(labelWithString: "BLOCK EDITOR  ·  \(b.name)")
        label.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        label.textColor = .black
        let hint = NSTextField(labelWithString: "Edits apply to every reference of this block when saved. The yellow marker is the base point.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = NSColor(white: 0.1, alpha: 1)
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let save = NSButton(title: "Save Block", target: self, action: #selector(saveBlockAction(_:)))
        let close = NSButton(title: "Close Block Editor", target: self, action: #selector(closeBlockAction(_:)))
        for btn in [save, close] { btn.bezelStyle = .rounded; btn.controlSize = .small }
        save.keyEquivalent = ""
        let stack = NSStackView(views: [label, hint, NSView(), save, close])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor), stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        return bar
    }

    // MARK: Block Editor

    /// Opens `name` in a Block Editor tab (or focuses an existing one).
    func openBlockEditor(_ name: String) {
        if let existing = blockEditors.first(where: { $0.blockEdit?.name == name }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let block = controller.drawing.blocks[name] else {
            controller.message("Block \"\(name)\" has no definition in this drawing (it may not have been converted from the DWG).")
            return
        }
        controller.cancel()
        var d = controller.drawing.modelView
        d.layouts = []
        d.entities = block.entities
        // A block cannot contain itself.
        d.blocks[name] = nil
        let editor = CadWindowController(history: DrawingHistory(d), blockEdit: BlockEditInfo(name: name, basePoint: block.basePoint, parent: self))
        blockEditors.append(editor)
        if let w = window, let ew = editor.window {
            ew.setFrame(w.frame, display: false)
            w.addTabbedWindow(ew, ordered: .above)
        }
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
        controller.message("Opened block \"\(name)\" in the Block Editor.")
    }

    /// Writes the edited entities back into the parent drawing's block definition.
    func saveBlockEdit() {
        guard let b = blockEdit, let parent = b.parent else { return }
        let child = controller.drawing
        parent.controller.perform("Edit Block \(b.name)") { pd in
            pd.blocks[b.name] = BlockDef(name: b.name, basePoint: b.basePoint, entities: child.entities)
            for l in child.layers where pd.layer(named: l.name) == nil { pd.layers.append(l) }
            for (k, def) in child.blocks where pd.blocks[k] == nil && k != b.name { pd.blocks[k] = def }
        }
        let refs = parent.controller.drawing.entities.filter { if case .insert(let i) = $0.kind { return i.blockName == b.name } else { return false } }.count
        parent.controller.message("Block \"\(b.name)\" updated (\(refs) reference(s) in the drawing).")
        controller.message("Block \"\(b.name)\" saved.")
        blockDirty = false
        window?.isDocumentEdited = false
    }

    @objc func saveBlockAction(_ sender: Any?) { saveBlockEdit() }
    @objc func closeBlockAction(_ sender: Any?) { window?.performClose(sender) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let b = blockEdit, blockDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to block \"\(b.name)\"?"
        alert.informativeText = "If you don't save, your changes to the block definition will be lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        alert.beginSheetModal(for: sender) { [weak self] resp in
            guard let self else { return }
            switch resp {
            case .alertFirstButtonReturn: self.saveBlockEdit(); sender.close()
            case .alertThirdButtonReturn: self.blockDirty = false; sender.close()
            default: break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let b = blockEdit, let parent = b.parent else { return }
        parent.blockEditors.removeAll { $0 === self }
        parent.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Layouts

    /// Sheet data for plotting the active layout (nil on the Model tab).
    private func paperPlot() -> PaperPlot? {
        guard let data = PaperRenderData.make(controller) else { return nil }
        return PaperPlot(data: data, scene: controller.scene)
    }

    /// Switches between Model (nil) and a layout tab, remembering each tab's view.
    func switchSpace(_ name: String?) {
        let d = controller.drawing
        let target = name.flatMap { d.layoutIndex($0) }.map { d.layouts[$0].name }
        guard target != d.activeLayout || (name != nil && target == nil) else {
            layoutTabs.reload(layouts: d.layouts, active: d.activeLayout)
            return
        }
        canvas.exitViewport()
        controller.cancel()
        spaceViews[d.activeLayout ?? ""] = (canvas.vt.center, canvas.vt.scale)
        switchingSpace = true
        controller.history.setActiveLayout(target)
        switchingSpace = false
        if let v = spaceViews[target ?? ""] {
            canvas.vt.center = v.0
            canvas.vt.scale = v.1
        } else {
            canvas.zoom(.extents)
        }
        canvas.invalidateCache()
        window?.makeFirstResponder(canvas)
        controller.message(target.map { "Switched to layout \"\($0)\". Double-click inside a viewport to pan/zoom its view." } ?? "Switched to Model space.")
    }

    func layoutAction(_ action: LayoutAction) {
        let d = controller.drawing
        switch action {
        case .set(let name):
            if let name, d.layoutIndex(name) == nil, name.caseInsensitiveCompare("Model") != .orderedSame {
                controller.message("Layout \"\(name)\" not found.")
                return
            }
            switchSpace(name.flatMap { $0.caseInsensitiveCompare("Model") == .orderedSame ? nil : $0 })
        case .new(let requested):
            var name = requested ?? ""
            if name.isEmpty {
                var i = d.layouts.count + 1
                while d.layoutIndex("Layout\(i)") != nil { i += 1 }
                name = "Layout\(i)"
            }
            guard d.layoutIndex(name) == nil, name.caseInsensitiveCompare("Model") != .orderedSame else {
                controller.message("Layout \"\(name)\" already exists.")
                return
            }
            let order = (d.layouts.map(\.tabOrder).max() ?? 0) + 1
            let model = controller.modelScene.extents
            controller.perform("New Layout") { $0.layouts.append(Layout.withDefaultViewport(name: name, tabOrder: order, showing: model)) }
            switchSpace(name)
        case .rename(let old, let new):
            let n = new.trimmingCharacters(in: .whitespaces)
            guard let i = d.layoutIndex(old), !n.isEmpty, n.caseInsensitiveCompare("Model") != .orderedSame,
                  d.layoutIndex(n) == nil || d.layoutIndex(n) == i else {
                controller.message("Invalid or duplicate layout name.")
                return
            }
            let wasActive = d.activeLayout == d.layouts[i].name
            controller.perform("Rename Layout") { dd in
                dd.layouts[i].name = n
                if wasActive { dd.activeLayout = n }
            }
            if let v = spaceViews.removeValue(forKey: old) { spaceViews[n] = v }
        case .delete(let name):
            guard let i = d.layoutIndex(name) else { return }
            guard d.layouts.count > 1 else { controller.message("A drawing must keep at least one layout."); return }
            if d.activeLayout == d.layouts[i].name { switchSpace(nil) }
            controller.perform("Delete Layout") { $0.layouts.remove(at: i) }
            controller.message("Layout \"\(name)\" deleted.")
        case .list:
            controller.message("Layouts: " + d.layouts.sorted { $0.tabOrder < $1.tabOrder }.map { "\($0.name) (\($0.paper.name))" }.joined(separator: ", "))
        case .pageSetup:
            if let n = d.activeLayout { showPageSetup(n) } else { controller.message("Page setup applies to layouts. Switch to a layout tab first.") }
        }
    }

    private func moveLayout(_ name: String, by dir: Int) {
        let sorted = controller.drawing.layouts.sorted { $0.tabOrder < $1.tabOrder }.map(\.name)
        guard let i = sorted.firstIndex(of: name), sorted.indices.contains(i + dir) else { return }
        var order = sorted
        order.swapAt(i, i + dir)
        controller.perform("Move Layout") { d in
            for k in d.layouts.indices { d.layouts[k].tabOrder = (order.firstIndex(of: d.layouts[k].name) ?? k) + 1 }
        }
    }

    private func promptRenameLayout(_ name: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Layout"
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.layoutAction(.rename(name, field.stringValue)) }
        }
    }

    private func showPageSetup(_ name: String) {
        guard let window, let i = controller.drawing.layoutIndex(name) else { return }
        let current = controller.drawing.layouts[i].paper
        let alert = NSAlert()
        alert.messageText = "Page Setup — \(name)"
        alert.informativeText = "Paper size for this layout. Existing objects keep their position."
        let sizes = NSPopUpButton(frame: .zero, pullsDown: false)
        for (n, w, h) in PaperSetup.standardSizes { sizes.addItem(withTitle: "\(n)  (\(fmt(w)) × \(fmt(h)) mm)") }
        let landscape = current.width >= current.height
        let cw = min(current.width, current.height), ch = max(current.width, current.height)
        if let k = PaperSetup.standardSizes.firstIndex(where: { abs($0.1 - cw) < 1 && abs($0.2 - ch) < 1 }) { sizes.selectItem(at: k) }
        let orient = NSSegmentedControl(labels: ["Portrait", "Landscape"], trackingMode: .selectOne, target: nil, action: nil)
        orient.selectedSegment = landscape ? 1 : 0
        let stack = NSStackView(views: [sizes, orient])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        alert.accessoryView = stack
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            let (n, w, h) = PaperSetup.standardSizes[sizes.indexOfSelectedItem]
            let land = orient.selectedSegment == 1
            let paper = PaperSetup(name: "\(n) (\(fmt(land ? h : w)) x \(fmt(land ? w : h)) MM)", width: land ? h : w, height: land ? w : h,
                                   margins: current.margins)
            self.controller.perform("Page Setup") { d in if let k = d.layoutIndex(name) { d.layouts[k].paper = paper } }
            if self.controller.drawing.activeLayout == name { self.canvas.zoom(.extents) }
        }
    }

    private func buildInspector() {
        rightPanel.wantsLayer = true
        rightPanel.layer?.backgroundColor = PanelStyle.background.cgColor
        inspectorTabs.selectedSegment = 0
        inspectorTabs.segmentStyle = .automatic
        inspectorTabs.controlSize = .small
        inspectorTabs.target = self
        inspectorTabs.action = #selector(inspectorTabChanged(_:))
        inspectorContent.tabViewType = .noTabsNoBorder
        inspectorContent.drawsBackground = false
        for (label, view) in [("Layers", layersPanel as NSView), ("Properties", properties as NSView)] {
            let item = NSTabViewItem(identifier: label)
            item.label = label
            item.view = view
            inspectorContent.addTabViewItem(item)
        }
        for v in [inspectorTabs, inspectorContent] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            rightPanel.addSubview(v)
        }
        NSLayoutConstraint.activate([
            inspectorTabs.topAnchor.constraint(equalTo: rightPanel.topAnchor, constant: 8),
            inspectorTabs.centerXAnchor.constraint(equalTo: rightPanel.centerXAnchor),
            inspectorContent.topAnchor.constraint(equalTo: inspectorTabs.bottomAnchor, constant: 6),
            inspectorContent.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            inspectorContent.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor),
            inspectorContent.bottomAnchor.constraint(equalTo: rightPanel.bottomAnchor),
        ])
    }

    @objc private func inspectorTabChanged(_ sender: NSSegmentedControl) {
        inspectorContent.selectTabViewItem(at: sender.selectedSegment)
    }

    private func selectInspectorTab(_ index: Int) {
        inspectorTabs.selectedSegment = index
        inspectorContent.selectTabViewItem(at: index)
    }

    // MARK: Collapsible side panels

    private func setPanel(left: Bool, visible: Bool) {
        let view: NSView = left ? palette : rightPanel
        guard view.isHidden == visible else { return }
        view.isHidden = !visible
        mainSplit.adjustSubviews()
        if visible && !left { mainSplit.setPosition(mainSplit.bounds.width - 330, ofDividerAt: mainSplit.arrangedSubviews.firstIndex(of: rightPanel)! - 1) }
        if visible && left { mainSplit.setPosition(156, ofDividerAt: 0) }
        UserDefaults.standard.set(visible, forKey: left ? "ShowToolSets" : "ShowInspector")
        canvas.invalidateCache()
    }

    @objc func toggleToolSets(_ sender: Any?) { setPanel(left: true, visible: palette.isHidden) }
    @objc func toggleCommandLine(_ sender: Any?) { setCommandLine(visible: !commandLineVisible) }

    /// Shows or hides the command window. Hidden: typing goes to an input box at the cursor
    /// and messages appear briefly over the drawing.
    func setCommandLine(visible: Bool, announce: Bool = true) {
        guard visible != commandLineVisible else { return }
        commandLineVisible = visible
        if !visible {
            // Carry over anything typed so far.
            canvas.dynamicText = commandLine.field.stringValue
            commandLine.field.stringValue = ""
        } else if !canvas.dynamicText.isEmpty {
            commandLine.field.stringValue = canvas.dynamicText
            canvas.dynamicText = ""
        }
        commandLine.isHidden = !visible
        commandLineHeight.constant = visible ? 118 : 0
        canvas.dynamicInput = !visible
        UserDefaults.standard.set(visible, forKey: "ShowCommandLine")
        window?.makeFirstResponder(canvas)
        if !visible && announce { canvas.toast("Command line hidden — type anywhere; input appears at the cursor. ⌥⌘3 or ⌃9 shows it again.") }
    }

    /// Submits typed text the same way from the command line and the cursor input box.
    private func submitCommandText(_ text: String) {
        let wasTextInput = controller.active?.allowsSpaces == true
        controller.submit(text)
        // Return focus to the canvas unless still entering text.
        if commandLineVisible && !(wasTextInput && controller.active?.allowsSpaces == true) {
            window?.makeFirstResponder(canvas)
        }
        canvas.refreshOverlay()
    }
    @objc func toggleInspector(_ sender: Any?) { setPanel(left: false, visible: rightPanel.isHidden) }

    // MARK: Toolbar

    private static let leftToggleID = NSToolbarItem.Identifier("ToggleToolSets")
    private static let rightToggleID = NSToolbarItem.Identifier("ToggleInspector")
    private static let commandToggleID = NSToolbarItem.Identifier("ToggleCommandLine")

    private func buildToolbar() {
        let tb = NSToolbar(identifier: "CadMacToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        window?.toolbar = tb
        window?.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [CadWindowController.leftToggleID, .flexibleSpace, CadWindowController.commandToggleID, CadWindowController.rightToggleID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id == CadWindowController.commandToggleID {
            item.label = "Command Line"
            item.toolTip = "Show/Hide Command Line (⌥⌘3 or ⌃9)"
            item.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: item.label)
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleCommandLine(_:))
            item.label = Loc.t(item.label)
            item.toolTip = item.toolTip.map(Loc.t)
            return item
        }
        let left = id == CadWindowController.leftToggleID
        item.label = left ? "Tool Sets" : "Inspector"
        item.toolTip = left ? "Show/Hide Tool Sets (⌥⌘1)" : "Show/Hide Layers & Properties (⌥⌘2)"
        item.image = NSImage(systemSymbolName: left ? "sidebar.left" : "sidebar.right", accessibilityDescription: item.label)
        item.isBordered = true
        item.target = self
        item.action = left ? #selector(toggleToolSets(_:)) : #selector(toggleInspector(_:))
        item.label = Loc.t(item.label)
        item.toolTip = item.toolTip.map(Loc.t)
        return item
    }

    private func wire() {
        canvas.controller = controller
        controller.delegate = self
        properties.controller = controller
        layersPanel.controller = controller

        controller.history.onChange = { [weak self] in self?.drawingChanged() }
        controller.onSelectionChange = { [weak self] in self?.properties.reload() }
        controller.onModesChange = { [weak self] in self?.refreshStatus() }

        canvas.onCursorMove = { [weak self] p in
            guard let self else { return }
            let st = self.controller.drawing.settings
            self.statusBar.setCoords(p, precision: st.unitPrecision, unit: st.insUnits.suffix)
        }
        canvas.onTypeKey = { [weak self] e in
            guard let self, let chars = e.characters, !chars.isEmpty else { return false }
            if e.modifierFlags.contains(.command) { return false }
            if let handled = self.handleDIKey(e, chars) { return handled }
            if !self.commandLineVisible { return self.handleDynamicKey(e, chars) }
            switch e.keyCode {
            case 36, 76: // Return / Enter
                self.commandLine.submitCurrent(); return true
            case 49: // Space = Enter unless typing text
                if self.controller.active?.allowsSpaces == true && !self.commandLine.field.stringValue.isEmpty {
                    self.commandLine.type(" "); return true
                }
                self.commandLine.submitCurrent(); return true
            case 123, 124, 125, 126:
                return false
            default:
                guard chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else { return false }
                self.commandLine.type(chars)
                return true
            }
        }
        canvas.onDoubleClickEntity = { [weak self] id in self?.editEntity(id) }

        commandLine.onSubmit = { [weak self] text in self?.submitCommandText(text) }
        canvas.onToggleCommandLine = { [weak self] in self?.toggleCommandLine(nil) }
        commandLine.onEscape = { [weak self] in
            self?.canvas.escape()
            self?.window?.makeFirstResponder(self?.canvas)
        }
        commandLine.onDeleteWhenEmpty = { [weak self] in
            guard let self, self.controller.active == nil else { return }
            self.controller.eraseSelection()
        }
        commandLine.spaceIsLiteral = { [weak self] in self?.controller.active?.allowsSpaces == true }

        palette.onCommand = { [weak self] cmd in
            self?.controller.run(cmd)
            self?.window?.makeFirstResponder(self?.canvas)
        }
        statusBar.onToggle = { [weak self] name in self?.toggleMode(name) }
        layoutTabs.isHidden = blockEdit != nil
        layoutTabs.onSelect = { [weak self] name in self?.switchSpace(name) }
        layoutTabs.onNew = { [weak self] in self?.layoutAction(.new(nil)) }
        layoutTabs.onRename = { [weak self] name in self?.promptRenameLayout(name) }
        layoutTabs.onDelete = { [weak self] name in self?.layoutAction(.delete(name)) }
        layoutTabs.onPageSetup = { [weak self] name in self?.showPageSetup(name) }
        layoutTabs.onMove = { [weak self] name, dir in self?.moveLayout(name, by: dir) }
        layoutTabs.reload(layouts: controller.drawing.layouts, active: controller.drawing.activeLayout)

        commandLine.echo(Loc.isTurkish ? "CadMac — macOS için 2B çizim. Bir komut yazın (ör. L, C, REC, TR) veya yardım için F1."
                                      : "CadMac — native 2D drafting for macOS. Type a command (e.g. L, C, REC, TR) or HELP.")
        if let v = window?.contentView { Loc.localize(v) }
        promptDidChange("Command:")
        refreshStatus()
        properties.reload()
        layersPanel.reload()
    }

    override func windowDidLoad() {
        super.windowDidLoad()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if !didInitialZoom {
            didInitialZoom = true
            DispatchQueue.main.async { [self] in
                canvas.zoom(.extents)
                window?.makeFirstResponder(canvas)
            }
        }
    }

    /// Says what a DWG read brought in, and what it could not carry — instead of leaving the
    /// user to discover missing objects later. Called once, after the window is on screen.
    func announceImport() {
        guard let r = importReport, !didAnnounceImport else { return }
        didAnnounceImport = true
        controller.message(String(format: Loc.t("%1$@ DWG · %2$@ objects · %3$@ entities"),
                                  r.formatName, r.objectCount.formatted(), r.modelEntityCount.formatted()))
        if !r.misaligned.isEmpty {
            // Bytes the reader could not line up. Usually harmless, so it goes to the command line only.
            let parts = r.misaligned.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                .prefix(4).map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            controller.message(Loc.t("Parts of the file CadMac read imperfectly") + ": " + parts)
        }
        guard !r.dropped.isEmpty else { return }
        var lines = [Loc.t("Objects left out") + ": " + r.topDropped.map { "\($0.name) ×\($0.count)" }.joined(separator: ", ")]
        if r.dropped.count > r.topDropped.count {
            lines.append(Loc.t("more types") + ": \(r.dropped.count - r.topDropped.count)")
        }
        if r.unresolvedHandles > 0 { lines.append(Loc.t("Broken references") + ": \(r.unresolvedHandles.formatted())") }
        let alert = NSAlert()
        alert.messageText = Loc.t("Some objects were not imported")
        alert.informativeText = lines.joined(separator: "\n") + "\n\n"
            + Loc.t("CadMac has no model for them, so saving will not write them back. Keep the original file.")
        alert.addButton(withTitle: Loc.t("OK"))
        if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
    }

    // MARK: State refresh

    private func drawingChanged() {
        let scene = controller.scene
        controller.selection = controller.selection.filter { scene.byID[$0] != nil }
        canvas.invalidateCache()
        properties.reload()
        layersPanel.reload()
        refreshStatus()
        layoutTabs.reload(layouts: controller.drawing.layouts, active: controller.drawing.activeLayout)
        Loc.localize(properties)
        Loc.localize(layersPanel)
        if switchingSpace { return }
        if blockEdit != nil {
            blockDirty = true
            window?.isDocumentEdited = true
        } else {
            (document as? CadDocument)?.updateChangeCount(.changeDone)
        }
    }

    func refreshStatus() {
        statusBar.setStates([
            "GRID": controller.gridOn, "SNAP": controller.snapOn, "ORTHO": controller.orthoOn,
            "POLAR": controller.polarOn, "OSNAP": controller.osnapOn, "OTRACK": controller.otrackOn,
            "DYN": controller.dynInputOn, "LWT": controller.lineweightOn,
        ])
        let st = controller.drawing.settings
        let space = controller.drawing.activeLayout.map { "Layout: \($0) (\(Loc.t("paper, mm")))" } ?? "Model"
        statusBar.setInfo("\(space)   ·   \(Loc.t("Units")): \(Loc.t(st.insUnits.displayName))   ·   \(Loc.t("Layer")): \(st.currentLayer)   ")
    }

    func toggleMode(_ name: String) {
        switch name {
        case "GRID": controller.gridOn.toggle()
        case "SNAP": controller.snapOn.toggle()
        case "ORTHO": controller.orthoOn.toggle(); if controller.orthoOn { controller.polarOn = false }
        case "POLAR": controller.polarOn.toggle(); if controller.polarOn { controller.orthoOn = false }
        case "OSNAP": controller.osnapOn.toggle()
        case "OTRACK": controller.otrackOn.toggle()
        case "DYN": controller.dynInputOn.toggle(); canvas.diCancel()
        case "LWT": controller.lineweightOn.toggle()
        case "OSNAPSETTINGS": runModal(.osnapSettings)
        default: break
        }
        refreshStatus()
        window?.makeFirstResponder(canvas)
    }

    // MARK: CommandControllerDelegate

    func commandLineEcho(_ text: String) {
        commandLine.echo(text)
        if !commandLineVisible, !text.hasPrefix("Command: ") { canvas.toast(text) }
    }

    /// Dynamic Input fields: numbers go into the length/angle (X/Y) boxes at the cursor.
    /// Returns nil when the key isn't for the fields.
    private func handleDIKey(_ e: NSEvent, _ chars: String) -> Bool? {
        guard canvas.diApplies else { return nil }
        let cmdLineText = commandLineVisible ? commandLine.field.stringValue : canvas.dynamicText
        guard cmdLineText.isEmpty else { return nil }
        let isNumeric = chars.allSatisfy { "0123456789.-".contains($0) }
        switch e.keyCode {
        case 36, 76, 49:
            guard canvas.diActive else { return nil }
            submitCommandText(canvas.diSubmission())
            return true
        case 48:
            canvas.diTab()
            return true
        default:
            if isNumeric {
                canvas.diType(chars)
                return true
            }
            if canvas.diActive {
                // Anything else (",", "@", "<", letters): continue as normal command-line input.
                let carried = canvas.diRawText
                canvas.diCancel()
                if commandLineVisible { commandLine.type(carried + chars) } else { canvas.dynamicText = carried + chars }
                return true
            }
            return nil
        }
    }

    /// Keyboard input while the command line is hidden (cursor input box).
    private func handleDynamicKey(_ e: NSEvent, _ chars: String) -> Bool {
        switch e.keyCode {
        case 36, 76:
            let t = canvas.dynamicText
            canvas.dynamicText = ""
            submitCommandText(t)
            return true
        case 49:
            if controller.active?.allowsSpaces == true && !canvas.dynamicText.isEmpty {
                canvas.dynamicText += " "
            } else {
                let t = canvas.dynamicText
                canvas.dynamicText = ""
                submitCommandText(t)
            }
            return true
        case 48: // Tab completes a command name
            if let first = CommandRegistry.suggestions(for: canvas.dynamicText).first { canvas.dynamicText = first.name }
            return true
        case 123, 124, 125, 126:
            return false
        default:
            guard chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else { return false }
            canvas.dynamicText += chars
            return true
        }
    }

    func promptDidChange(_ prompt: String) {
        let prompt = Loc.t(prompt)
        commandLine.setPrompt(prompt)
        canvas.dynamicPrompt = prompt
    }

    func needsRedraw(drawingChanged: Bool) {
        if drawingChanged { canvas.invalidateCache() } else { canvas.refreshOverlay() }
    }

    func zoom(_ op: ZoomOperation) { canvas.zoom(op) }

    func layout(_ action: LayoutAction) { layoutAction(action) }

    func setCommandLineVisible(_ visible: Bool?) { setCommandLine(visible: visible ?? !commandLineVisible) }

    func blockEditor(_ action: BlockEditorAction) {
        switch action {
        case .open(let name): openBlockEditor(name)
        case .save:
            if blockEdit == nil { controller.message("BSAVE is only available in the Block Editor.") } else { saveBlockEdit() }
        case .close:
            if blockEdit == nil { controller.message("BCLOSE is only available in the Block Editor.") } else { window?.performClose(nil) }
        }
    }

    func showPanel(_ panel: String) {
        setPanel(left: false, visible: true)
        selectInspectorTab(panel == "layers" ? 0 : 1)
    }

    func runModal(_ request: ModalRequest) {
        guard let window else { return }
        switch request {
        case .mtext(let initial, let completion):
            TextEditorSheet.run(on: window, title: "Multiline Text", initial: initial, completion: completion)
        case .print:
            PrintSupport.print(drawing: controller.drawing, window: window, paper: paperPlot())
        case .exportPDF:
            PrintSupport.exportPDF(drawing: controller.drawing, window: window, suggestedName: document?.displayName ?? "Drawing", paper: paperPlot())
        case .osnapSettings:
            showOsnapSettings()
        case .textFont:
            chooseTextFont(nil)
        case .chat:
            ClaudeChatWindow.shared.toggle()
        case .publish:
            Publisher.run(self)
        }
    }

    private func showOsnapSettings() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Object Snap Modes"
        alert.informativeText = "Select the snap points to use while picking points."
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        var boxes: [(SnapKind, NSButton)] = []
        for k in SnapKind.allCases {
            let b = NSButton(checkboxWithTitle: k.label, target: nil, action: nil)
            b.state = controller.osnapModes.contains(k) ? .on : .off
            boxes.append((k, b))
            stack.addArrangedSubview(b)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 220, height: CGFloat(boxes.count) * 22)
        alert.accessoryView = stack
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self else { return }
            self.controller.osnapModes = Set(boxes.filter { $0.1.state == .on }.map(\.0))
            self.controller.osnapOn = true
            self.refreshStatus()
        }
    }

    // MARK: Preferences

    /// The background color saved in Preferences, or nil to use the dark/light default.
    static func savedBackground() -> CGColor? {
        guard let data = UserDefaults.standard.data(forKey: "CanvasBackgroundColor"),
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
        else { return nil }
        return color.usingColorSpace(.deviceRGB)?.cgColor
    }

    /// Applies the saved background color and default text font to this window.
    func applyPreferences() {
        canvas.style.customBackground = Self.savedBackground()
        if let fam = UserDefaults.standard.string(forKey: "DefaultTextFont"), !fam.isEmpty {
            Renderer.defaultFontFamily = fam
        }
        canvas.invalidateCache()
    }

    @objc func showSettings(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = Loc.t("Preferences")
        alert.informativeText = Loc.t("Canvas background and default text font.")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let well = NSColorWell()
        if let c = Self.savedBackground(), let ns = NSColor(cgColor: c) { well.color = ns }
        else { well.color = NSColor(calibratedRed: 0.13, green: 0.157, blue: 0.188, alpha: 1) }
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 64).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let popup = NSPopUpButton()
        let families = NSFontManager.shared.availableFontFamilies.sorted()
        popup.addItems(withTitles: families)
        let current = UserDefaults.standard.string(forKey: "DefaultTextFont") ?? Renderer.defaultFontFamily
        if families.contains(current) { popup.selectItem(withTitle: current) }

        stack.addArrangedSubview(NSTextField(labelWithString: Loc.t("Background color")))
        stack.addArrangedSubview(well)
        stack.addArrangedSubview(NSTextField(labelWithString: Loc.t("Default text font")))
        stack.addArrangedSubview(popup)

        let keyField = NSSecureTextField()
        keyField.stringValue = ChatPrefs.apiKey
        keyField.placeholderString = "sk-ant-…"
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let modelPopup = NSPopUpButton()
        let models = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"]
        modelPopup.addItems(withTitles: models)
        if models.contains(ChatPrefs.model) { modelPopup.selectItem(withTitle: ChatPrefs.model) }
        stack.addArrangedSubview(NSTextField(labelWithString: Loc.t("Anthropic API key (for Claude Chat)")))
        stack.addArrangedSubview(keyField)
        stack.addArrangedSubview(NSTextField(labelWithString: Loc.t("Claude model")))
        stack.addArrangedSubview(modelPopup)
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 260)
        alert.accessoryView = stack
        alert.addButton(withTitle: Loc.t("OK"))
        alert.addButton(withTitle: Loc.t("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self else { return }
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: well.color, requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: "CanvasBackgroundColor")
            }
            if let fam = popup.titleOfSelectedItem { UserDefaults.standard.set(fam, forKey: "DefaultTextFont") }
            ChatPrefs.apiKey = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let m = modelPopup.titleOfSelectedItem { ChatPrefs.model = m }
            self.applyPreferences()
        }
    }

    /// Picks the font used for new text (TEXT/MTEXT) in this drawing, from installed macOS fonts.
    @objc func chooseTextFont(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = Loc.t("Text font")
        alert.informativeText = Loc.t("Font for text you add next (installed macOS fonts).")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        let families = NSFontManager.shared.availableFontFamilies.sorted()
        popup.addItems(withTitles: families)
        let cur = controller.drawing.settings.textFont
        if families.contains(cur) { popup.selectItem(withTitle: cur) }
        else if families.contains(Renderer.defaultFontFamily) { popup.selectItem(withTitle: Renderer.defaultFontFamily) }
        alert.accessoryView = popup
        alert.addButton(withTitle: Loc.t("OK"))
        alert.addButton(withTitle: Loc.t("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self, let fam = popup.titleOfSelectedItem else { return }
            self.controller.perform("Text font") { $0.settings.textFont = fam }
        }
    }

    /// Double-click editing: text opens the editor, others select and show properties.
    private func editEntity(_ id: EntityID) {
        guard let window, let e = controller.drawing.entity(id) else { return }
        switch e.kind {
        case .text(let t):
            TextEditorSheet.run(on: window, title: t.isMultiline ? "Edit Multiline Text" : "Edit Text", initial: t.text, multiline: t.isMultiline) { [weak self] s in
                guard let self, let s, !s.isEmpty, var cur = self.controller.drawing.entity(id), case .text(var g) = cur.kind else { return }
                g.text = s
                cur.kind = .text(g)
                self.controller.perform("Edit Text") { $0.replace(cur) }
            }
        case .dimension:
            controller.selection = [id]
            showPanel("properties")
        case .insert(let ins):
            // Like AutoCAD: blocks with attributes open the attribute editor, others the Block Editor.
            if !ins.attributes.isEmpty, CommandRegistry.lookup("ATTEDIT") != nil {
                controller.selection = [id]
                controller.run("ATTEDIT")
            } else {
                openBlockEditor(ins.blockName)
            }
        default:
            controller.selection = [id]
        }
    }

    // MARK: Menu actions (responder chain)

    @objc func runCommand(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        controller.run(name)
        window?.makeFirstResponder(canvas)
    }

    @objc func cadUndo(_ sender: Any?) { controller.cancel(); controller.undo() }
    @objc func cadRedo(_ sender: Any?) { controller.redo() }
    @objc func zoomExtents(_ sender: Any?) { canvas.zoom(.extents) }
    @objc func zoomIn(_ sender: Any?) { canvas.vt.zoom(by: 1.5, at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)) }
    @objc func zoomOut(_ sender: Any?) { canvas.vt.zoom(by: 1 / 1.5, at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)) }
    @objc func toggleOsnap(_ sender: Any?) { toggleMode("OSNAP") }
    @objc func toggleGrid(_ sender: Any?) { toggleMode("GRID") }
    @objc func toggleOrtho(_ sender: Any?) { toggleMode("ORTHO") }
    @objc func toggleSnap(_ sender: Any?) { toggleMode("SNAP") }
    @objc func togglePolar(_ sender: Any?) { toggleMode("POLAR") }
    @objc func toggleOtrack(_ sender: Any?) { toggleMode("OTRACK") }
    @objc func toggleDyn(_ sender: Any?) { toggleMode("DYN") }
    @objc func toggleBackground(_ sender: Any?) {
        canvas.style.darkBackground.toggle()
        canvas.invalidateCache()
    }
    @objc func printDrawing(_ sender: Any?) { runModal(.print) }
    @objc func exportPDF(_ sender: Any?) { runModal(.exportPDF) }
    @objc func publishLayouts(_ sender: Any?) { runModal(.publish) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(cadUndo(_:)):
            item.title = Loc.t(controller.history.undoName.map { "Undo \($0)" } ?? "Undo")
            return controller.history.canUndo
        case #selector(cadRedo(_:)):
            item.title = Loc.t(controller.history.redoName.map { "Redo \($0)" } ?? "Redo")
            return controller.history.canRedo
        case #selector(toggleGrid(_:)): item.state = controller.gridOn ? .on : .off
        case #selector(toggleOrtho(_:)): item.state = controller.orthoOn ? .on : .off
        case #selector(toggleOsnap(_:)): item.state = controller.osnapOn ? .on : .off
        case #selector(toggleSnap(_:)): item.state = controller.snapOn ? .on : .off
        case #selector(togglePolar(_:)): item.state = controller.polarOn ? .on : .off
        case #selector(toggleOtrack(_:)): item.state = controller.otrackOn ? .on : .off
        case #selector(toggleDyn(_:)): item.state = controller.dynInputOn ? .on : .off
        case #selector(toggleBackground(_:)): item.state = canvas.style.darkBackground ? .on : .off
        case #selector(toggleToolSets(_:)): item.title = Loc.t(palette.isHidden ? "Show Tool Sets" : "Hide Tool Sets")
        case #selector(toggleInspector(_:)): item.title = Loc.t(rightPanel.isHidden ? "Show Inspector" : "Hide Inspector")
        case #selector(toggleCommandLine(_:)):
            if !item.isHidden { item.title = Loc.t(commandLineVisible ? "Hide Command Line" : "Show Command Line") }
        default: break
        }
        return true
    }
}

// MARK: - Text editor sheet

@MainActor
enum TextEditorSheet {
    static func run(on window: NSWindow, title: String, initial: String, multiline: Bool = true, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: multiline ? 180 : 24))
        let tv = NSTextView(frame: scroll.bounds)
        tv.string = initial
        tv.font = NSFont.systemFont(ofSize: 14)
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        scroll.hasVerticalScroller = multiline
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = tv
        alert.beginSheetModal(for: window) { resp in
            var s = tv.string
            if !multiline { s = s.replacingOccurrences(of: "\n", with: " ") }
            completion(resp == .alertFirstButtonReturn ? s : nil)
        }
        DispatchQueue.main.async { alert.window.makeFirstResponder(tv) }
    }
}

// MARK: - Printing / PDF

/// A layout sheet ready to plot at 1:1 paper size.
struct PaperPlot {
    let data: PaperRenderData
    let scene: Scene
    /// Page size in points.
    var pageSize: NSSize { NSSize(width: data.paper.width * 72 / 25.4, height: data.paper.height * 72 / 25.4) }
}

/// Renders drawing extents (Model) or a layout sheet (true size) onto a white page.
final class PlotView: NSView {
    let drawing: Drawing
    let paper: PaperPlot?
    init(drawing: Drawing, size: NSSize, paper: PaperPlot? = nil) {
        self.drawing = drawing
        self.paper = paper
        super.init(frame: NSRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(.white)
        ctx.fill(bounds)
        var vt = ViewTransform()
        vt.size = bounds.size
        if let paper {
            // Fit the sheet to the page (1:1 when the page matches the paper size).
            vt.scale = min(bounds.width / paper.data.paper.width, bounds.height / paper.data.paper.height)
            vt.center = Vec2(paper.data.paper.width / 2, paper.data.paper.height / 2)
            paper.data.draw(ctx, vt: vt, paperScene: paper.scene, drawing: drawing, background: false)
            return
        }
        var box = drawing.extents()
        if box.isEmpty { box = BBox(corner: drawing.settings.limitsMin, drawing.settings.limitsMax) }
        vt.zoomToFit(box, margin: 0.04)
        let hidden = Set(drawing.layers.filter { !$0.isPlottable }.map(\.name))
        let ents = drawing.entities.filter { !hidden.contains($0.layer) }
        MainActor.assumeIsolated {
            var r = Renderer(drawing: drawing, vt: vt, ctx: ctx)
            r.style = RenderStyle(darkBackground: false, showLineweights: true, monochrome: false)
            r.drawAll(ents)
        }
    }
}

@MainActor
enum PrintSupport {
    static func print(drawing: Drawing, window: NSWindow, paper: PaperPlot? = nil) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.orientation = .landscape
        if let paper {
            info.paperSize = paper.pageSize
            info.orientation = paper.pageSize.width >= paper.pageSize.height ? .landscape : .portrait
        }
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        let size = info.imageablePageBounds.size
        let view = PlotView(drawing: drawing, size: size, paper: paper)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    static func exportPDF(drawing: Drawing, window: NSWindow, suggestedName: String, paper: PaperPlot? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (suggestedName as NSString).deletingPathExtension + ".pdf"
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            // Layout: its paper size; Model: A3 landscape (points).
            var media = CGRect(origin: .zero, size: paper?.pageSize ?? CGSize(width: 1190.55, height: 841.89))
            guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else { return }
            ctx.beginPDFPage(nil)
            let view = PlotView(drawing: drawing, size: media.size, paper: paper)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            view.draw(media)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
            ctx.closePDF()
        }
    }
}
