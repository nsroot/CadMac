import AppKit
import CadCore

/// A drawing change proposed by Claude (via cadmac-mcp), waiting for the user's Apply/Reject.
@MainActor
final class ClaudeProposal {
    enum Outcome { case applied, rejected(String) }

    let summary: String
    let patch: AutomationPatch
    weak var window: CadWindowController?
    let completion: (Outcome) -> Void
    fileprivate var finished = false

    init(summary: String, patch: AutomationPatch, window: CadWindowController, completion: @escaping (Outcome) -> Void) {
        self.summary = summary
        self.patch = patch
        self.window = window
        self.completion = completion
    }

    var countsText: String {
        var parts: [String] = []
        if patch.addedCount > 0 { parts.append("+\(patch.addedCount) added") }
        if patch.changedCount > 0 { parts.append("~\(patch.changedCount) changed") }
        if patch.removedCount > 0 { parts.append("−\(patch.removedCount) removed") }
        parts += patch.tableChanges
        return parts.isEmpty ? "No visible changes" : parts.joined(separator: "  ·  ")
    }
}

/// Queues Claude proposals and shows them one at a time: purple preview on the canvas plus a
/// small floating panel with Apply (⏎) / Reject (Esc). Unanswered proposals expire after 10 minutes.
@MainActor
final class ClaudeApproval {
    static let shared = ClaudeApproval()

    /// Testing only: CADMAC_AUTOMATION_AUTOAPPROVE=1 applies every proposal without asking.
    static let autoApprove = ProcessInfo.processInfo.environment["CADMAC_AUTOMATION_AUTOAPPROVE"] == "1"
    /// 10 minutes (CADMAC_AUTOMATION_TIMEOUT overrides, in seconds; for testing).
    static let timeout: TimeInterval = Double(ProcessInfo.processInfo.environment["CADMAC_AUTOMATION_TIMEOUT"] ?? "") ?? 600

    private var queue: [ClaudeProposal] = []
    private var current: ClaudeProposal?
    private var panel: NSPanel?
    private var timer: Timer?
    private var queueLabel: NSTextField?
    private var closeObserver: NSObjectProtocol?

    func submit(_ p: ClaudeProposal) {
        if ClaudeApproval.autoApprove {
            finish(p, apply: true)
            return
        }
        queue.append(p)
        if current == nil { showNext() } else { updateQueueLabel() }
    }

    private func showNext() {
        while current == nil, !queue.isEmpty {
            let p = queue.removeFirst()
            guard let wc = p.window, wc.window.map({ $0.isVisible || $0.isMiniaturized }) == true else {
                finish(p, apply: false, reason: "The drawing window was closed.")
                continue
            }
            current = p
            show(p, in: wc)
        }
    }

    private func show(_ p: ClaudeProposal, in wc: CadWindowController) {
        let space = wc.controller.drawing.activeLayout ?? ""
        let preview = p.patch.previewEntities(space: space)
        wc.canvas.externalPreview = preview
        NSApp.activate()
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.requestUserAttention(.informationalRequest)

        // Bring off-screen proposals into view.
        let box = previewBox(p, wc)
        if let box, !box.isEmpty, !wc.canvas.vt.visibleBox.contains(box) {
            wc.canvas.zoom(.window(wc.canvas.vt.visibleBox.union(box).expanded(by: max(box.width, box.height, 1) * 0.08)))
        }

        let panel = makePanel(p, previewAvailable: box != nil)
        self.panel = panel
        if let parent = wc.window {
            let f = parent.frame
            let size = panel.frame.size
            let top = parent.contentLayoutRect.maxY + f.minY - 12
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: top - size.height))
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        if let path = ProcessInfo.processInfo.environment["CADMAC_AUTOMATION_PANEL_SNAPSHOT"] {
            // Testing aid: PNG of the approval panel.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak panel] in
                MainActor.assumeIsolated {
                    guard let v = panel?.contentView?.superview ?? panel?.contentView,
                          let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: wc.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.decide(apply: false, reason: "The drawing window was closed.") }
        }
        wc.controller.message("Claude wants to: \(p.summary) (\(p.countsText)) — Apply (⏎) or Reject (Esc) in the panel")

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: ClaudeApproval.timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.decide(apply: false, reason: "No answer from the user in time; the change was discarded.") }
        }
    }

    private func previewBox(_ p: ClaudeProposal, _ wc: CadWindowController) -> BBox? {
        let d = wc.controller.drawing
        let es = p.patch.previewEntities(space: d.activeLayout ?? "")
        guard !es.isEmpty else { return nil }
        let b = es.reduce(BBox.empty) { $0.union(d.bbox(of: $1)) }
        return b.isEmpty ? nil : b
    }

    private func makePanel(_ p: ClaudeProposal, previewAvailable: Bool) -> NSPanel {
        let width: CGFloat = 460
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
                             styleMask: [.titled, .utilityWindow, .hudWindow, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.title = "Claude"
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onCancel = { [weak self] in self?.decide(apply: false) }

        let title = NSTextField(wrappingLabelWithString: "Claude wants to: \(p.summary)")
        title.font = .boldSystemFont(ofSize: 13)
        title.preferredMaxLayoutWidth = width - 32
        let counts = NSTextField(wrappingLabelWithString: p.countsText)
        counts.font = .systemFont(ofSize: 12)
        counts.textColor = .secondaryLabelColor
        counts.preferredMaxLayoutWidth = width - 32
        var hintText = previewAvailable ? "New/changed objects are highlighted in purple." : "Nothing to highlight on the canvas."
        if p.patch.removedCount > 0 { hintText += " Objects to be removed are not highlighted." }
        let hint = NSTextField(wrappingLabelWithString: hintText)
        hint.preferredMaxLayoutWidth = width - 32
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        let queueLabel = NSTextField(labelWithString: "")
        queueLabel.font = .systemFont(ofSize: 11)
        queueLabel.textColor = .systemOrange
        self.queueLabel = queueLabel

        let apply = NSButton(title: "Apply", target: self, action: #selector(applyAction(_:)))
        apply.keyEquivalent = "\r"
        apply.bezelColor = .controlAccentColor
        let reject = NSButton(title: "Reject", target: self, action: #selector(rejectAction(_:)))
        reject.keyEquivalent = "\u{1b}"
        let zoom = NSButton(title: "Zoom to Preview", target: self, action: #selector(zoomAction(_:)))
        zoom.isEnabled = previewAvailable
        let buttons = NSStackView(views: [zoom, queueLabel, NSView(), reject, apply])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [title, counts, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            content.widthAnchor.constraint(equalToConstant: width),
        ])
        panel.contentView = content
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: width, height: max(100, stack.fittingSize.height)))
        panel.defaultButtonCell = apply.cell as? NSButtonCell
        updateQueueLabel()
        return panel
    }

    private func updateQueueLabel() {
        queueLabel?.stringValue = queue.isEmpty ? "" : "\(queue.count) more waiting"
    }

    @objc private func applyAction(_ sender: Any?) { decide(apply: true) }
    @objc private func rejectAction(_ sender: Any?) { decide(apply: false) }
    @objc private func zoomAction(_ sender: Any?) {
        guard let p = current, let wc = p.window, let b = previewBox(p, wc) else { return }
        wc.canvas.zoom(.window(b.expanded(by: max(b.width, b.height, 1) * 0.1)))
    }

    private func decide(apply: Bool, reason: String? = nil) {
        guard let p = current else { return }
        timer?.invalidate()
        timer = nil
        if let o = closeObserver { NotificationCenter.default.removeObserver(o); closeObserver = nil }
        if let wc = p.window {
            wc.canvas.externalPreview = []
            if let panel { wc.window?.removeChildWindow(panel) }
        }
        panel?.orderOut(nil)
        panel = nil
        queueLabel = nil
        current = nil
        finish(p, apply: apply, reason: reason)
        if let wc = p.window, queue.isEmpty { wc.window?.makeFirstResponder(wc.canvas) }
        showNext()
    }

    private func finish(_ p: ClaudeProposal, apply: Bool, reason: String? = nil) {
        guard !p.finished else { return }
        p.finished = true
        guard apply, let wc = p.window else {
            p.window?.controller.message("Claude: \(p.summary) — rejected")
            p.completion(.rejected(reason ?? "The user rejected the change; the drawing was not modified."))
            return
        }
        let patch = p.patch
        wc.controller.perform("Claude: \(p.summary)") { patch.apply(to: &$0) }
        wc.controller.message("Claude: \(p.summary) — applied")
        p.completion(.applied)
    }
}

/// Panel that can become key (for ⏎ / Esc) and maps Esc to `onCancel`.
private final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
