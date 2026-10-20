import AppKit
import CadCore

/// AutoCAD-style "Model | Layout1 | Layout2 | +" tabs under the drawing area.
@MainActor
final class LayoutTabBar: NSView {
    var onSelect: ((String?) -> Void)?
    var onNew: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var onPageSetup: ((String) -> Void)?
    var onMove: ((String, Int) -> Void)?

    private let stack = NSStackView()
    /// Lists every layout; essential when tabs overflow (drawings with dozens of sheets).
    private let allMenu = NSPopUpButton(frame: .zero, pullsDown: true)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.15, green: 0.17, blue: 0.2, alpha: 1).cgColor
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 0, right: 6)
        allMenu.bezelStyle = .recessed
        allMenu.controlSize = .small
        allMenu.toolTip = "All layouts"
        allMenu.translatesAutoresizingMaskIntoConstraints = false
        addSubview(allMenu)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            allMenu.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            allMenu.centerYAnchor.constraint(equalTo: centerYAnchor),
            allMenu.widthAnchor.constraint(equalToConstant: 34),
            scroll.leadingAnchor.constraint(equalTo: allMenu.trailingAnchor, constant: 2), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload(layouts: [Layout], active: String?) {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        stack.addArrangedSubview(tab(title: "Model", name: nil, selected: active == nil))
        for l in layouts.sorted(by: { $0.tabOrder < $1.tabOrder }) {
            stack.addArrangedSubview(tab(title: l.name, name: l.name, selected: active?.caseInsensitiveCompare(l.name) == .orderedSame))
        }
        allMenu.removeAllItems()
        allMenu.addItem(withTitle: "▾")
        for (title, name) in [("Model", nil as String?)] + layouts.sorted(by: { $0.tabOrder < $1.tabOrder }).map({ ($0.name, Optional($0.name)) }) {
            let i = NSMenuItem(title: title, action: #selector(menuSelect(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = name
            i.state = (active?.caseInsensitiveCompare(title) == .orderedSame || (name == nil && active == nil)) ? .on : .off
            allMenu.menu?.addItem(i)
        }
        let plus = NSButton(title: "+", target: self, action: #selector(newLayout))
        plus.bezelStyle = .recessed
        plus.controlSize = .small
        plus.toolTip = "New layout"
        stack.addArrangedSubview(plus)
        for v in stack.arrangedSubviews { if let m = v.menu { Loc.localize(m) } }
        Loc.localize(self)
    }

    private func tab(title: String, name: String?, selected: Bool) -> NSView {
        let b = TabButton(title: title, target: self, action: #selector(tabClicked(_:)))
        b.layoutName = name
        b.bezelStyle = .recessed
        b.setButtonType(.pushOnPushOff)
        b.state = selected ? .on : .off
        b.controlSize = .small
        b.font = NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
        b.toolTip = name == nil ? "Model space" : "Layout (paper space) — right-click for options"
        if let name {
            let m = NSMenu()
            func item(_ t: String, _ sel: Selector, _ tag: Int = 0) {
                let i = m.addItem(withTitle: t, action: sel, keyEquivalent: "")
                i.target = self
                i.representedObject = name
                i.tag = tag
            }
            item("Rename…", #selector(renameItem(_:)))
            item("Page Setup…", #selector(pageSetupItem(_:)))
            m.addItem(.separator())
            item("Move Left", #selector(moveItem(_:)), -1)
            item("Move Right", #selector(moveItem(_:)), 1)
            m.addItem(.separator())
            item("Delete Layout", #selector(deleteItem(_:)))
            m.addItem(.separator())
            let n = m.addItem(withTitle: "New Layout", action: #selector(newLayout), keyEquivalent: "")
            n.target = self
            b.menu = m
        }
        b.onDoubleClick = { [weak self] in if let name { self?.onRename?(name) } }
        return b
    }

    @objc private func tabClicked(_ sender: TabButton) { onSelect?(sender.layoutName) }
    @objc private func menuSelect(_ sender: NSMenuItem) { onSelect?(sender.representedObject as? String) }
    @objc private func newLayout() { onNew?() }
    @objc private func renameItem(_ s: NSMenuItem) { if let n = s.representedObject as? String { onRename?(n) } }
    @objc private func deleteItem(_ s: NSMenuItem) { if let n = s.representedObject as? String { onDelete?(n) } }
    @objc private func pageSetupItem(_ s: NSMenuItem) { if let n = s.representedObject as? String { onPageSetup?(n) } }
    @objc private func moveItem(_ s: NSMenuItem) { if let n = s.representedObject as? String { onMove?(n, s.tag) } }
}

final class TabButton: NSButton {
    var layoutName: String?
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        super.mouseDown(with: event)
    }
}
