import AppKit
import CadCore

/// AutoCAD-style command window: scrolling history above a prompt + input field.
@MainActor
final class CommandLineView: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let promptLabel = NSTextField(labelWithString: "Command:")
    private let suggestionLabel = NSTextField(labelWithString: "")
    private let historyView = NSTextView()
    private let historyScroll = NSScrollView()
    private var recall: [String] = []
    private var recallIndex = 0

    var onSubmit: ((String) -> Void)?
    var onEscape: (() -> Void)?
    var onDeleteWhenEmpty: (() -> Void)?
    /// Whether a space should be inserted literally (TEXT input) instead of submitting.
    var spaceIsLiteral: (() -> Bool)?

    private let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.22, alpha: 1).cgColor

        historyView.isEditable = false
        historyView.isSelectable = true
        historyView.drawsBackground = false
        historyView.font = mono
        historyView.textColor = NSColor(white: 0.75, alpha: 1)
        historyView.textContainerInset = NSSize(width: 6, height: 4)
        historyView.isVerticallyResizable = true
        historyView.autoresizingMask = [.width]
        historyScroll.documentView = historyView
        historyScroll.hasVerticalScroller = true
        historyScroll.drawsBackground = false
        historyScroll.borderType = .noBorder

        promptLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        promptLabel.textColor = NSColor(calibratedRed: 0.55, green: 0.8, blue: 1, alpha: 1)
        promptLabel.lineBreakMode = .byTruncatingHead
        promptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        field.font = mono
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .white
        field.delegate = self
        field.placeholderString = "Type a command"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        suggestionLabel.font = NSFont.systemFont(ofSize: 11)
        suggestionLabel.textColor = NSColor(white: 0.6, alpha: 1)
        suggestionLabel.lineBreakMode = .byTruncatingTail
        suggestionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let icon = NSTextField(labelWithString: "›")
        icon.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        icon.textColor = NSColor(calibratedRed: 0.55, green: 0.8, blue: 1, alpha: 1)

        let inputRow = NSStackView(views: [icon, promptLabel, field])
        inputRow.orientation = .horizontal
        inputRow.spacing = 6
        inputRow.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        inputRow.wantsLayer = true
        inputRow.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.135, blue: 0.16, alpha: 1).cgColor

        for v in [historyScroll, suggestionLabel, inputRow] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            historyScroll.topAnchor.constraint(equalTo: topAnchor),
            historyScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            historyScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            historyScroll.bottomAnchor.constraint(equalTo: suggestionLabel.topAnchor),
            suggestionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            suggestionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            suggestionLabel.bottomAnchor.constraint(equalTo: inputRow.topAnchor, constant: -2),
            suggestionLabel.heightAnchor.constraint(equalToConstant: 15),
            inputRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            inputRow.bottomAnchor.constraint(equalTo: bottomAnchor),
            inputRow.heightAnchor.constraint(equalToConstant: 26),
            promptLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.75),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPrompt(_ p: String) {
        promptLabel.stringValue = p
    }

    func echo(_ s: String) {
        let storage = historyView.textStorage!
        let attrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor(white: 0.78, alpha: 1)]
        storage.append(NSAttributedString(string: (storage.length > 0 ? "\n" : "") + s, attributes: attrs))
        // Keep the history bounded.
        if storage.length > 200_000 { storage.deleteCharacters(in: NSRange(location: 0, length: 50_000)) }
        historyView.scrollToEndOfDocument(nil)
    }

    /// Inserts typed text from the canvas and focuses the field.
    func type(_ chars: String) {
        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
            editor.insertText(chars)
        } else {
            field.stringValue += chars
        }
        updateSuggestions()
    }

    func submitCurrent() {
        let text = field.stringValue
        field.stringValue = ""
        suggestionLabel.stringValue = ""
        if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            recall.append(text)
            if recall.count > 100 { recall.removeFirst() }
        }
        recallIndex = recall.count
        onSubmit?(text)
    }

    private func updateSuggestions() {
        let t = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, spaceIsLiteral?() != true, !t.contains(","), Double(t) == nil else {
            suggestionLabel.stringValue = ""
            return
        }
        let s = CommandRegistry.suggestions(for: t)
        suggestionLabel.stringValue = s.map { info in
            info.aliases.isEmpty ? info.name : "\(info.name) (\(info.aliases[0]))"
        }.joined(separator: "   ·   ") + (s.isEmpty ? "" : "      ⇥ " + Loc.t("Tab to complete"))
        if let first = s.first { suggestionLabel.toolTip = Loc.summary(first.name, first.summary) }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        let s = field.stringValue
        if s.hasSuffix(" "), spaceIsLiteral?() != true {
            field.stringValue = String(s.dropLast())
            submitCurrent()
            return
        }
        updateSuggestions()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            submitCurrent()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            field.stringValue = ""
            suggestionLabel.stringValue = ""
            onEscape?()
            return true
        case #selector(NSResponder.insertTab(_:)):
            if let first = CommandRegistry.suggestions(for: field.stringValue.trimmingCharacters(in: .whitespaces)).first {
                field.stringValue = first.name
                textView.selectedRange = NSRange(location: first.name.count, length: 0)
                updateSuggestions()
            }
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard !recall.isEmpty else { return true }
            recallIndex = max(0, recallIndex - 1)
            field.stringValue = recall[recallIndex]
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard !recall.isEmpty else { return true }
            recallIndex = min(recall.count, recallIndex + 1)
            field.stringValue = recallIndex < recall.count ? recall[recallIndex] : ""
            return true
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
            if field.stringValue.isEmpty { onDeleteWhenEmpty?(); return true }
            return false
        default:
            return false
        }
    }
}

/// Bottom status bar: coordinates and drafting-aid toggles.
@MainActor
final class StatusBarView: NSView {
    private let coords = NSTextField(labelWithString: "0.0000, 0.0000")
    private var buttons: [String: NSButton] = [:]
    var onToggle: ((String) -> Void)?
    private let layerLabel = NSTextField(labelWithString: "")

    static let toggles = ["GRID", "SNAP", "ORTHO", "POLAR", "OSNAP", "OTRACK", "DYN", "LWT"]
    static let tips = [
        "GRID": "Grid display (F7)", "SNAP": "Snap mode (F9)", "ORTHO": "Ortho mode (F8)",
        "POLAR": "Polar tracking (F10)", "OSNAP": "Object snap (F3) — right-click for settings", "LWT": "Show lineweights",
        "OTRACK": "Object snap tracking (F11): pause on a snap point to acquire it, then align with it",
        "DYN": "Dynamic Input (F12): type length/angle or X/Y in boxes at the cursor; Tab switches fields",
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.2, green: 0.22, blue: 0.25, alpha: 1).cgColor
        coords.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        coords.textColor = NSColor(white: 0.85, alpha: 1)
        coords.alignment = .left
        coords.widthAnchor.constraint(equalToConstant: 230).isActive = true
        layerLabel.font = NSFont.systemFont(ofSize: 11)
        layerLabel.textColor = NSColor(white: 0.7, alpha: 1)

        var views: [NSView] = [coords]
        for t in StatusBarView.toggles {
            let b = NSButton(title: t, target: self, action: #selector(toggle(_:)))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .recessed
            b.controlSize = .small
            b.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            b.toolTip = StatusBarView.tips[t]
            b.identifier = NSUserInterfaceItemIdentifier(t)
            buttons[t] = b
            views.append(b)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        views += [spacer, layerLabel]
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle(_ sender: NSButton) {
        onToggle?(sender.identifier?.rawValue ?? "")
    }

    func setCoords(_ p: Vec2, precision: Int, unit: String = "") {
        let u = unit.isEmpty ? "" : " \(unit)"
        coords.stringValue = "\(String(format: "%.\(precision)f", p.x)), \(String(format: "%.\(precision)f", p.y))\(u)"
    }

    func setStates(_ states: [String: Bool]) {
        for (k, v) in states { buttons[k]?.state = v ? .on : .off }
    }

    func setInfo(_ s: String) { layerLabel.stringValue = s }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let b = buttons["OSNAP"], b.frame.insetBy(dx: -4, dy: -4).contains(convert(p, to: b.superview)) {
            onToggle?("OSNAPSETTINGS")
        }
    }
}
