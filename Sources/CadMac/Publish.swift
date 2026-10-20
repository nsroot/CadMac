import AppKit
import CadCore

/// PUBLISH: every layout of the drawing into one multi-page PDF, each page at its paper size.
@MainActor
enum Publisher {
    struct Page: @unchecked Sendable {
        let name: String
        let data: PaperRenderData
        let scene: Scene
    }

    /// Prepares render data for each layout (scenes are immutable and safe to render off the main thread).
    static func pages(_ c: CommandController) -> [Page] {
        let d = c.drawing
        return d.layouts.sorted { $0.tabOrder < $1.tabOrder }.map { layout in
            var paperDrawing = d
            paperDrawing.activeLayout = layout.name
            let scene = Scene(drawing: paperDrawing, version: -1, previous: nil)
            var vps: [(ViewportGeom, Scene)] = []
            for (i, it) in scene.items.enumerated() where scene.visible[i] {
                if case .viewport(let v) = it.entity.kind, v.isOn { vps.append((v, c.modelScene(frozen: v.frozenLayers))) }
            }
            return Page(name: layout.name, data: PaperRenderData(paper: layout.paper, viewports: vps), scene: scene)
        }
    }

    static func run(_ wc: CadWindowController) {
        guard let window = wc.window else { return }
        let c = wc.controller
        let drawing = c.drawing
        guard !drawing.layouts.isEmpty else { c.message("This drawing has no layouts to publish."); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = ((wc.document?.displayName ?? "Drawing") as NSString).deletingPathExtension + " - Layouts.pdf"
        panel.message = "Publish \(drawing.layouts.count) layout(s) to a multi-page PDF"
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            let pages = Publisher.pages(c)
            publish(pages, drawing: drawing, to: url, window: window, controller: c)
        }
    }

    private static func publish(_ pages: [Page], drawing: Drawing, to url: URL, window: NSWindow, controller c: CommandController) {
        // Progress sheet.
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        let label = NSTextField(labelWithString: "Publishing…")
        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(pages.count)
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 320).isActive = true
        sheet.contentView = stack
        window.beginSheet(sheet)

        DispatchQueue.global(qos: .userInitiated).async {
            var ok = false
            if let ctx = CGContext(url as CFURL, mediaBox: nil, nil) {
                for (i, page) in pages.enumerated() {
                    DispatchQueue.main.async { label.stringValue = "Publishing \(page.name) (\(i + 1)/\(pages.count))…"; bar.doubleValue = Double(i) }
                    let size = CGSize(width: page.data.paper.width * 72 / 25.4, height: page.data.paper.height * 72 / 25.4)
                    var box = CGRect(origin: .zero, size: size)
                    let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
                    ctx.beginPDFPage(info)
                    var vt = ViewTransform()
                    vt.size = size
                    vt.scale = 72 / 25.4
                    vt.center = Vec2(page.data.paper.width / 2, page.data.paper.height / 2)
                    page.data.draw(ctx, vt: vt, paperScene: page.scene, drawing: drawing, background: false)
                    ctx.endPDFPage()
                }
                ctx.closePDF()
                ok = true
            }
            DispatchQueue.main.async {
                window.endSheet(sheet)
                if ok {
                    c.message("Published \(pages.count) layout(s) to \(url.lastPathComponent).")
                    NSWorkspace.shared.open(url)
                } else {
                    c.message("Could not write \(url.path).")
                }
            }
        }
    }
}
