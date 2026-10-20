import AppKit
import CadCore

/// Shows the cached drawing image; between re-renders it is drawn shifted/scaled to follow pan & zoom.
final class SceneImageView: NSView {
    var image: CGImage?
    /// Maps image view-space to current view-space.
    var imageTransform = CGAffineTransform.identity
    var background: CGColor = .black
    override var isFlipped: Bool { false }
    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(background)
        ctx.fill(bounds)
        guard let img = image else { return }
        ctx.saveGState()
        ctx.concatenate(imageTransform)
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(img.width) / (window?.backingScaleFactor ?? 2), height: CGFloat(img.height) / (window?.backingScaleFactor ?? 2)))
        ctx.restoreGState()
    }
}

/// Transparent layer for cursor, highlights, previews; redrawn on every mouse move.
final class OverlayView: NSView {
    var drawer: ((CGContext) -> Void)?
    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawer?(ctx)
    }
}

private let renderQueue = DispatchQueue(label: "cadmac.render", qos: .userInteractive)

@MainActor
final class CanvasView: NSView {
    var controller: CommandController!
    var vt = ViewTransform() { didSet { viewChanged(oldValue) } }
    var style = RenderStyle()

    /// Called with the snapped cursor position for the status bar.
    var onCursorMove: ((Vec2) -> Void)?
    /// Forwards a typed key to the command line. Returns true if consumed.
    var onTypeKey: ((NSEvent) -> Bool)?
    /// Double-click on an entity (e.g. edit text).
    var onDoubleClickEntity: ((EntityID) -> Void)?
    /// Command line hidden: show prompt + typed text next to the cursor (Dynamic Input).
    var dynamicInput = false { didSet { refreshOverlay() } }
    var dynamicText = "" { didSet { refreshOverlay() } }
    var dynamicPrompt = "Command:" { didSet { if dynamicInput { refreshOverlay() } } }
    var onToggleCommandLine: (() -> Void)?
    /// Recent command-line messages shown briefly while the command line is hidden.
    private var toasts: [(text: String, time: Date)] = []
    private var toastTimer: Timer?

    func toast(_ text: String) {
        toasts.append((text, Date()))
        if toasts.count > 6 { toasts.removeFirst(toasts.count - 6) }
        refreshOverlay()
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                let before = self.toasts.count
                self.toasts.removeAll { Date().timeIntervalSince($0.time) > 6 }
                if self.toasts.count != before { self.refreshOverlay() }
                if self.toasts.isEmpty { t.invalidate() }
            }
        }
    }

    // MARK: Dynamic Input fields (length/angle or X/Y)

    /// Typed values for the two fields; active once the user types a number during point input.
    private(set) var diText = ["", ""]
    private(set) var diIndex = 0
    var diActive: Bool { !diText[0].isEmpty || !diText[1].isEmpty || diIndex != 0 }

    /// Whether Dynamic Input fields apply right now.
    var diApplies: Bool { controller.dynInputOn && controller.inputKind == .point && controller.gripDrag == nil }

    func diType(_ s: String) { diText[diIndex] += s; refreshOverlay() }
    func diTab() { diIndex = (diIndex + 1) % 2; refreshOverlay() }
    func diBackspace() {
        if !diText[diIndex].isEmpty { diText[diIndex].removeLast() } else if diIndex == 1 { diIndex = 0 }
        refreshOverlay()
    }
    func diCancel() { diText = ["", ""]; diIndex = 0; refreshOverlay() }

    /// Converts the fields into command-line input ("@len<ang", "len", "x,y"); empty fields use live values.
    func diSubmission() -> String {
        defer { diCancel() }
        let world = snapResult?.point ?? controller.cursor
        if let base = controller.active?.basePoint {
            let v = world - base
            if diText[1].isEmpty && !diText[0].isEmpty { return diText[0] }  // direct distance along the cursor
            let len = diText[0].isEmpty ? fmt(v.length, precision: 6) : diText[0]
            let ang = diText[1].isEmpty ? fmt(degrees(normalizeAngle(v.angle)), precision: 6) : diText[1]
            return "@\(len)<\(ang)"
        }
        let x = diText[0].isEmpty ? fmt(world.x, precision: 6) : diText[0]
        let y = diText[1].isEmpty ? fmt(world.y, precision: 6) : diText[1]
        return "\(x),\(y)"
    }

    /// Text typed so far, for falling back to normal command input.
    var diRawText: String { diIndex == 0 ? diText[0] : diText[0] + "," + diText[1] }

    /// Entities proposed by an external tool (Claude via MCP), drawn as a highlighted preview.
    var externalPreview: [Entity] = [] { didSet { refreshOverlay() } }

    /// Block Editor base point, drawn as a marker.
    var basePointMarker: Vec2? { didSet { refreshOverlay() } }

    private let sceneView = SceneImageView()
    private lazy var metalView: MetalCanvasView? = {
        guard let p = MetalPipeline.shared else { return nil }
        return MetalCanvasView(frame: bounds, pipeline: p)
    }()
    private let overlay = OverlayView()
    /// View transform the current scene image was rendered with.
    private var imageVT: ViewTransform?
    private var renderInFlight = false
    private var renderPending = false
    private var renderTimer: Timer?

    private var cursorPoint: CGPoint?
    private var snapResult: CommandController.SnapResult?
    private var hover: EntityID?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    /// First corner of a click-click selection window (world).
    private var pendingWindowCorner: Vec2?
    private var panLast: CGPoint?
    private var previousViews: [ViewTransform] = []
    private var trackingArea: NSTrackingArea?

    private static let blankCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: img, hotSpot: .zero)
    }()

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        if let mv = metalView {
            mv.frame = bounds
            mv.autoresizingMask = [.width, .height]
            addSubview(mv)
        }
        for v in [sceneView, overlay] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            v.wantsLayer = true
            addSubview(v)
        }
        overlay.drawer = { [weak self] ctx in self?.drawOverlay(ctx) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Redraws only the cursor/highlight layer.
    func refreshOverlay() { overlay.needsDisplay = true }

    // MARK: Lifecycle

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(t)
        trackingArea = t
    }

    override func cursorUpdate(with event: NSEvent) { CanvasView.blankCursor.set() }
    override func mouseEntered(with event: NSEvent) { CanvasView.blankCursor.set() }
    override func mouseExited(with event: NSEvent) {
        cursorPoint = nil
        NSCursor.arrow.set()
        refreshOverlay()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        vt.size = newSize
        metalView?.setFrameSize(newSize)
    }

    /// The drawing changed: re-render right away.
    func invalidateCache() {
        style.showLineweights = controller.lineweightOn
        metalView?.style = style
        sceneView.background = style.background
        requestRender(delay: 0)
        refreshOverlay()
    }

    private func viewChanged(_ old: ViewTransform) {
        controller?.viewScale = vt.scale
        if let mv = metalView, let c = controller, !c.drawing.isPaperSpace {
            mv.vt = vt
            refreshOverlay()
            return
        }
        applyImageTransform()
        // Resizes need a fresh image immediately; pan/zoom re-render once motion pauses.
        requestRender(delay: old.size != vt.size ? 0 : 0.07)
        refreshOverlay()
    }

    private func applyImageTransform() {
        guard let i = imageVT else { return }
        let k = vt.scale / i.scale
        let tx = (i.center.x - vt.center.x) * vt.scale + vt.size.width / 2 - i.size.width / 2 * k
        let ty = (i.center.y - vt.center.y) * vt.scale + vt.size.height / 2 - i.size.height / 2 * k
        sceneView.imageTransform = CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: tx, ty: ty)
        sceneView.needsDisplay = true
    }

    private func requestRender(delay: TimeInterval) {
        renderTimer?.invalidate()
        if delay <= 0 { startRender(); return }
        renderTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.startRender() }
        }
    }

    private func startRender() {
        guard let controller, bounds.width > 1, bounds.height > 1 else { return }
        let d = controller.drawing
        let scene = controller.scene

        if let mv = metalView, !d.isPaperSpace, let pipeline = MetalPipeline.shared {
            sceneView.isHidden = true
            mv.isHidden = false
            mv.style = style
            mv.vt = vt
            let geo = MetalGeometryBuffer.build(from: scene, drawing: d, style: style, pipeline: pipeline)
            mv.geometryBuffer = geo
            mv.needsDisplay = true
            refreshOverlay()
            return
        }

        sceneView.isHidden = false
        metalView?.isHidden = true
        if renderInFlight { renderPending = true; return }
        let paper = PaperRenderData.make(controller)
        let job = RenderJob(scene: scene, drawing: d, vt: vt, style: style,
                            grid: controller.gridOn && paper == nil ? d.settings.gridSpacing : nil,
                            scaleFactor: window?.backingScaleFactor ?? 2, paper: paper)
        // Small drawings render synchronously (no flicker); big ones on a background queue.
        let workload = scene.items.count + (paper?.viewports.reduce(0) { $0 + $1.1.items.count } ?? 0)
        if workload < 4000 {
            finishRender(job.run(), vt: job.vt)
            return
        }
        renderInFlight = true
        renderQueue.async {
            let img = job.run()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.renderInFlight = false
                    self.finishRender(img, vt: job.vt)
                    if self.renderPending { self.renderPending = false; self.startRender() }
                }
            }
        }
    }

    private func finishRender(_ img: CGImage?, vt rendered: ViewTransform) {
        sceneView.image = img
        sceneView.background = controller.drawing.isPaperSpace ? PaperRenderData.surround : style.background
        imageVT = rendered
        applyImageTransform()
    }

    // MARK: View operations

    func pushView() {
        previousViews.append(vt)
        if previousViews.count > 50 { previousViews.removeFirst() }
    }

    func zoom(_ op: ZoomOperation) {
        switch op {
        case .extents:
            pushView()
            var box = controller.scene.extents
            if let paper = controller.drawing.activeLayoutDef?.paper {
                box = box.union(BBox(min: .zero, max: Vec2(paper.width, paper.height)))
            }
            if box.isEmpty { box = BBox(corner: controller.drawing.settings.limitsMin, controller.drawing.settings.limitsMax) }
            vt.zoomToFit(box)
        case .window(let b):
            pushView()
            vt.zoomToFit(b, margin: 0)
        case .scale(let f):
            pushView()
            vt.scale *= f
        case .center(let p, let s):
            pushView()
            vt.center = p
            if let s { vt.scale = s }
        case .previous:
            if let v = previousViews.popLast() { vt.center = v.center; vt.scale = v.scale }
        }
        requestRender(delay: 0)
    }

    // MARK: Overlay

    private func drawUCSIcon(_ ctx: CGContext) {
        let o = CGPoint(x: 24, y: 24)
        ctx.setLineWidth(2)
        ctx.setStrokeColor(CGColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 0.9))
        ctx.move(to: o); ctx.addLine(to: CGPoint(x: o.x + 36, y: o.y)); ctx.strokePath()
        ctx.setStrokeColor(CGColor(red: 0.3, green: 0.85, blue: 0.3, alpha: 0.9))
        ctx.move(to: o); ctx.addLine(to: CGPoint(x: o.x, y: o.y + 36)); ctx.strokePath()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.lightGray]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("X" as NSString).draw(at: CGPoint(x: o.x + 38, y: o.y - 6), withAttributes: attrs)
        ("Y" as NSString).draw(at: CGPoint(x: o.x - 4, y: o.y + 38), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    private let selectionColor = CGColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 1)
    private let gripColor = CGColor(red: 0.1, green: 0.45, blue: 1.0, alpha: 1)
    private let hotGripColor = CGColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1)
    private let snapColor = CGColor(red: 1.0, green: 0.85, blue: 0.1, alpha: 1)

    /// Strokes cached item outlines (optionally through a transform) in one pass.
    private func strokeItems(_ r: Renderer, _ ids: some Sequence<EntityID>, color: CGColor, width: CGFloat, dashed: Bool, transform: Transform2D? = nil) {
        let scene = controller.scene
        let extra = transform.map { CGAffineTransform(a: $0.a, b: $0.b, c: $0.c, d: $0.d, tx: $0.tx, ty: $0.ty) } ?? .identity
        var any = false
        for id in ids {
            guard let it = scene.byID[id] else { continue }
            r.addWorldPath(it.outline, extra: extra)
            any = true
        }
        guard any else { return }
        let ctx = r.ctx
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: dashed ? [6, 4] : [])
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    private func drawOverlay(_ ctx: CGContext) {
        guard let controller else { return }
        let d = controller.drawing
        var r = Renderer(drawing: d, vt: vt, ctx: ctx)
        r.style = style
        if d.isPaperSpace { r.style.darkBackground = false }

        // When Metal renders the geometry beneath, draw grid and text in the overlay pass
        if let mv = metalView, !mv.isHidden {
            if controller.gridOn {
                RenderJob.drawGrid(ctx, spacing: d.settings.gridSpacing, vt: vt, style: style)
            }
            let vis = vt.visibleBox
            for t in controller.scene.texts where t.bbox.intersects(vis) {
                r.drawText(t.text, color: r.cgColor(t.color))
            }
        }

        drawUCSIcon(ctx)
        if let a = controller.activeViewportOverride {
            let f = a.geom.frame
            ctx.setStrokeColor(CGColor(red: 0.2, green: 0.55, blue: 1, alpha: 1))
            ctx.setLineWidth(3)
            ctx.stroke(CGRect(origin: vt.toView(f.min), size: CGSize(width: f.width * vt.scale, height: f.height * vt.scale)))
        }
        if let bp = basePointMarker {
            let p = vt.toView(bp)
            ctx.setStrokeColor(CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 1))
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
            ctx.move(to: CGPoint(x: p.x - 12, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + 12, y: p.y))
            ctx.move(to: CGPoint(x: p.x, y: p.y - 12)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + 12))
            ctx.strokePath()
            drawTooltip(ctx, at: CGPoint(x: p.x - 6, y: p.y - 30), text: Loc.t("Base point"), accent: true)
        }

        // Hover highlight.
        if let h = hover, !controller.selection.contains(h) {
            strokeItems(r, [h], color: r.style.darkBackground ? CGColor(gray: 1, alpha: 0.9) : CGColor(gray: 0, alpha: 0.9), width: 2.5, dashed: false)
        }
        // Selection.
        strokeItems(r, controller.selection, color: selectionColor, width: 2, dashed: true)

        // Grips (idle only, like AutoCAD).
        if controller.active == nil && controller.selection.count <= 100 {
            for id in controller.selection {
                guard let e = controller.scene.byID[id]?.entity, d.isEditable(e) else { continue }
                for (i, g) in d.grips(of: e).enumerated() {
                    let p = vt.toView(g)
                    let hot = controller.gripDrag.map { $0.entity == e.id && $0.index == i } ?? false
                    ctx.setFillColor(hot ? hotGripColor : gripColor)
                    ctx.fill(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
                    ctx.setLineWidth(1)
                    ctx.stroke(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                }
            }
        }

        // Command preview / rubber band.
        if let cp = cursorPoint {
            let world = snapResult?.point ?? vt.toWorld(cp)
            if let (ids, t) = controller.active?.previewTransform(world) {
                strokeItems(r, ids, color: CGColor(gray: 0.85, alpha: 0.9), width: 1, dashed: false, transform: t)
            }
            let ghosts = controller.previewEntities(at: world)
            for e in ghosts { r.draw(e, override: CGColor(gray: 0.85, alpha: 0.9), dashed: false) }
            if let base = controller.active?.basePoint ?? controller.gripDrag?.base, controller.inputKind == .point || controller.gripDrag != nil {
                ctx.setStrokeColor(CGColor(gray: 0.7, alpha: 0.6))
                ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [3, 3])
                ctx.move(to: vt.toView(base)); ctx.addLine(to: vt.toView(world)); ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
                if let ang = snapResult?.polarAngle { drawPolarTrack(ctx, base: base, angle: ang) }
                if diApplies {
                    let v = world - base
                    drawDIFields(ctx, at: vt.toView(world), live: [d.settings.formatLength(v.length, precision: 4), fmt(degrees(normalizeAngle(v.angle)), precision: 2) + "°"])
                } else { drawTooltip(ctx, at: vt.toView(world), text: "\(d.settings.formatLength(base.distance(to: world), precision: 4)) < \(fmt(degrees(normalizeAngle((world - base).angle)), precision: 1))°") }
            } else if diApplies, controller.active?.basePoint == nil {
                drawDIFields(ctx, at: vt.toView(world), live: [fmt(world.x, precision: 4), fmt(world.y, precision: 4)])
            }
            // Object snap tracking.
            for t in controller.trackPoints {
                let p = vt.toView(t)
                ctx.setStrokeColor(CGColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 1))
                ctx.setLineWidth(1.5)
                ctx.move(to: CGPoint(x: p.x - 4, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + 4, y: p.y))
                ctx.move(to: CGPoint(x: p.x, y: p.y - 4)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + 4))
                ctx.strokePath()
            }
            if let tracks = snapResult?.tracks, !tracks.isEmpty {
                ctx.setStrokeColor(CGColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 0.8))
                ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [2, 4])
                let wp = vt.toView(world)
                for t in tracks {
                    let tp = vt.toView(t)
                    // Extend the alignment line across the view through the acquired point.
                    if abs(tp.x - wp.x) < 0.5 {
                        ctx.move(to: CGPoint(x: tp.x, y: 0)); ctx.addLine(to: CGPoint(x: tp.x, y: bounds.height))
                    } else {
                        ctx.move(to: CGPoint(x: 0, y: tp.y)); ctx.addLine(to: CGPoint(x: bounds.width, y: tp.y))
                    }
                }
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
                drawTooltip(ctx, at: wp, text: Loc.t(tracks.count > 1 ? "Intersection of tracks" : "Track"), accent: true)
            }
        }

        // Proposed changes awaiting approval.
        for e in externalPreview { r.draw(e, override: CGColor(red: 0.85, green: 0.45, blue: 1, alpha: 0.95), extraWidth: 1) }

        // Selection window.
        if let a = dragStart, let b = dragCurrent { drawSelectionWindow(ctx, a, b) }
        if let a = pendingWindowCorner, let cp = cursorPoint { drawSelectionWindow(ctx, vt.toView(a), cp) }

        // Snap marker.
        if let s = snapResult?.snap { drawSnapMarker(ctx, s) }

        // Crosshair.
        if let cp = cursorPoint { drawCrosshair(ctx, at: snapResult?.snap != nil ? vt.toView(snapResult!.point) : cp) }

        if dynamicInput { drawDynamicInput(ctx) }
        if !toasts.isEmpty { drawToasts(ctx) }
    }

    /// Prompt and typed text in a box near the cursor (or bottom-left when the cursor is outside).
    private func drawDynamicInput(_ ctx: CGContext) {
        let idle = controller.active == nil
        guard !idle || !dynamicText.isEmpty else { return }
        var lines: [(String, NSColor, NSFont)] = []
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        lines.append((dynamicPrompt, NSColor(calibratedRed: 0.6, green: 0.82, blue: 1, alpha: 1), NSFont.systemFont(ofSize: 11, weight: .semibold)))
        lines.append(((dynamicText.isEmpty ? "" : dynamicText) + "▏", .white, mono))
        if idle, !dynamicText.isEmpty, let s = CommandRegistry.suggestions(for: dynamicText, limit: 3).first {
            lines.append(("\(s.name) — \(Loc.summary(s.name, s.summary))   ⇥", NSColor(white: 0.7, alpha: 1), NSFont.systemFont(ofSize: 10.5)))
        }
        let strings = lines.map { NSAttributedString(string: $0.0, attributes: [.font: $0.2, .foregroundColor: $0.1]) }
        let w = min(520, (strings.map { $0.size().width }.max() ?? 0) + 16)
        let lineH: CGFloat = 16
        let h = CGFloat(strings.count) * lineH + 8
        var origin = cursorPoint.map { CGPoint(x: $0.x + 22, y: $0.y - 26 - h) } ?? CGPoint(x: 14, y: 14)
        origin.x = min(max(4, origin.x), bounds.width - w - 4)
        origin.y = min(max(4, origin.y), bounds.height - h - 4)
        let rect = CGRect(origin: origin, size: CGSize(width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.12, green: 0.14, blue: 0.17, alpha: 0.94))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(red: 0.35, green: 0.6, blue: 1, alpha: 0.8))
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.strokePath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, a) in strings.enumerated() {
            a.draw(with: CGRect(x: rect.minX + 8, y: rect.maxY - 4 - CGFloat(i + 1) * lineH, width: w - 16, height: lineH),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Recent messages stacked at the bottom-left, fading out.
    private func drawToasts(_ ctx: CGContext) {
        let now = Date()
        var y: CGFloat = 70
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for t in toasts.reversed() {
            let age = now.timeIntervalSince(t.time)
            let alpha = CGFloat(max(0, min(1, (6 - age) / 1.5)))
            guard alpha > 0 else { continue }
            let s = NSAttributedString(string: t.text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: NSColor(white: 0.95, alpha: alpha),
            ])
            let w = min(bounds.width - 120, s.size().width + 18)
            let rect = CGRect(x: 80, y: y, width: w, height: 22)
            ctx.setFillColor(CGColor(red: 0.12, green: 0.14, blue: 0.17, alpha: 0.88 * alpha))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
            s.draw(with: rect.insetBy(dx: 9, dy: 4), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += 26
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Two input boxes next to the cursor; the active one is highlighted, typed values replace live ones.
    private func drawDIFields(_ ctx: CGContext, at p: CGPoint, live: [String]) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        var x = p.x + 16
        let y = p.y + 14
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for i in 0..<2 {
            let typed = !diText[i].isEmpty
            let active = diActive && diIndex == i
            let text = typed ? diText[i] + (active ? "▏" : "") : live[i]
            let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: typed ? NSColor.white : NSColor(white: 0.75, alpha: 1)])
            let w = max(54, s.size().width + 12)
            let r = CGRect(x: x, y: y, width: w, height: 18)
            ctx.setFillColor(active ? CGColor(red: 0.16, green: 0.36, blue: 0.7, alpha: 0.95) : CGColor(red: 0.18, green: 0.21, blue: 0.25, alpha: 0.92))
            ctx.fill(r)
            ctx.setStrokeColor(active ? CGColor(red: 0.5, green: 0.75, blue: 1, alpha: 1) : CGColor(gray: 0.5, alpha: 0.8))
            ctx.setLineWidth(1)
            ctx.stroke(r)
            s.draw(at: CGPoint(x: r.minX + 6, y: r.minY + 2))
            x += w + 4
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSelectionWindow(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint) {
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        let crossing = b.x < a.x
        ctx.setFillColor(crossing ? CGColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 0.15) : CGColor(red: 0.2, green: 0.4, blue: 1, alpha: 0.15))
        ctx.fill(rect)
        ctx.setStrokeColor(crossing ? CGColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 0.9) : CGColor(red: 0.4, green: 0.6, blue: 1, alpha: 0.9))
        ctx.setLineWidth(1)
        if crossing { ctx.setLineDash(phase: 0, lengths: [5, 3]) }
        ctx.stroke(rect)
        ctx.setLineDash(phase: 0, lengths: [])
    }

    private func drawPolarTrack(_ ctx: CGContext, base: Vec2, angle: Double) {
        let a = vt.toView(base)
        let far = vt.toView(base + Vec2.polar(1e6 / vt.scale, angle))
        ctx.setStrokeColor(CGColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 0.6))
        ctx.setLineDash(phase: 0, lengths: [2, 4])
        ctx.move(to: a); ctx.addLine(to: far); ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    private func drawCrosshair(_ ctx: CGContext, at p: CGPoint) {
        let color = style.darkBackground && !controller.drawing.isPaperSpace ? CGColor(gray: 1, alpha: 0.9) : CGColor(gray: 0, alpha: 0.9)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1)
        let len: CGFloat = 4000
        let x = p.x.rounded() + 0.5, y = p.y.rounded() + 0.5
        let box: CGFloat = 5
        let showBox = controller.inputKind != .point && controller.gripDrag == nil
        let gap: CGFloat = showBox ? box : 0
        ctx.move(to: CGPoint(x: x - len, y: y)); ctx.addLine(to: CGPoint(x: x - gap, y: y))
        ctx.move(to: CGPoint(x: x + gap, y: y)); ctx.addLine(to: CGPoint(x: x + len, y: y))
        ctx.move(to: CGPoint(x: x, y: y - len)); ctx.addLine(to: CGPoint(x: x, y: y - gap))
        ctx.move(to: CGPoint(x: x, y: y + gap)); ctx.addLine(to: CGPoint(x: x, y: y + len))
        ctx.strokePath()
        if showBox { ctx.stroke(CGRect(x: x - box, y: y - box, width: box * 2, height: box * 2)) }
    }

    private func drawSnapMarker(_ ctx: CGContext, _ s: SnapPoint) {
        let p = vt.toView(s.point)
        let r: CGFloat = 6
        ctx.setStrokeColor(snapColor)
        ctx.setLineWidth(2)
        switch s.kind {
        case .endpoint:
            ctx.stroke(CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        case .midpoint:
            ctx.addLines(between: [CGPoint(x: p.x - r, y: p.y - r), CGPoint(x: p.x + r, y: p.y - r), CGPoint(x: p.x, y: p.y + r)])
            ctx.closePath(); ctx.strokePath()
        case .center:
            ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        case .quadrant:
            ctx.addLines(between: [CGPoint(x: p.x, y: p.y - r), CGPoint(x: p.x + r, y: p.y), CGPoint(x: p.x, y: p.y + r), CGPoint(x: p.x - r, y: p.y)])
            ctx.closePath(); ctx.strokePath()
        case .intersection:
            ctx.move(to: CGPoint(x: p.x - r, y: p.y - r)); ctx.addLine(to: CGPoint(x: p.x + r, y: p.y + r))
            ctx.move(to: CGPoint(x: p.x - r, y: p.y + r)); ctx.addLine(to: CGPoint(x: p.x + r, y: p.y - r))
            ctx.strokePath()
        case .perpendicular:
            ctx.move(to: CGPoint(x: p.x - r, y: p.y + r)); ctx.addLine(to: CGPoint(x: p.x - r, y: p.y - r)); ctx.addLine(to: CGPoint(x: p.x + r, y: p.y - r))
            ctx.move(to: CGPoint(x: p.x - r, y: p.y)); ctx.addLine(to: CGPoint(x: p.x, y: p.y)); ctx.addLine(to: CGPoint(x: p.x, y: p.y - r))
            ctx.strokePath()
        case .tangent:
            ctx.strokeEllipse(in: CGRect(x: p.x - r * 0.8, y: p.y - r * 0.8, width: 1.6 * r, height: 1.6 * r))
            ctx.move(to: CGPoint(x: p.x - r, y: p.y + r)); ctx.addLine(to: CGPoint(x: p.x + r, y: p.y + r)); ctx.strokePath()
        case .nearest:
            ctx.addLines(between: [CGPoint(x: p.x - r, y: p.y + r), CGPoint(x: p.x + r, y: p.y + r), CGPoint(x: p.x - r, y: p.y - r), CGPoint(x: p.x + r, y: p.y - r)])
            ctx.closePath(); ctx.strokePath()
        case .node:
            ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            ctx.move(to: CGPoint(x: p.x - r * 0.7, y: p.y - r * 0.7)); ctx.addLine(to: CGPoint(x: p.x + r * 0.7, y: p.y + r * 0.7))
            ctx.move(to: CGPoint(x: p.x - r * 0.7, y: p.y + r * 0.7)); ctx.addLine(to: CGPoint(x: p.x + r * 0.7, y: p.y - r * 0.7))
            ctx.strokePath()
        case .insertion:
            ctx.stroke(CGRect(x: p.x - r, y: p.y, width: r, height: r))
            ctx.stroke(CGRect(x: p.x, y: p.y - r, width: r, height: r))
        }
        drawTooltip(ctx, at: CGPoint(x: p.x + 4, y: p.y - 26), text: Loc.t(s.kind.label), accent: true)
    }

    private func drawTooltip(_ ctx: CGContext, at p: CGPoint, text: String, accent: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: accent ? NSColor.black : NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let rect = CGRect(x: p.x + 14, y: p.y + 10, width: size.width + 10, height: size.height + 4)
        ctx.setFillColor(accent ? CGColor(red: 1, green: 0.9, blue: 0.4, alpha: 0.95) : CGColor(red: 0.2, green: 0.25, blue: 0.3, alpha: 0.92))
        ctx.fill(rect)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        s.draw(at: CGPoint(x: rect.minX + 5, y: rect.minY + 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Mouse

    private func updateCursor(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursorPoint = p
        let raw = vt.toWorld(p)
        controller.cursor = raw
        let res = controller.resolve(raw)
        snapResult = res
        let kind = controller.inputKind
        if kind == nil || kind == .selection || kind == .entity {
            hover = dragStart == nil ? controller.pickEntity(at: raw) : nil
        } else {
            hover = nil
        }
        onCursorMove?(res.point)
        refreshOverlay()
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        updateCursor(event)
        let p = convert(event.locationInWindow, from: nil)
        let world = vt.toWorld(p)
        let snapped = snapResult?.point ?? world

        if event.clickCount == 2, controller.active == nil, controller.drawing.isPaperSpace {
            if let vp = viewport(at: world) {
                if controller.activeViewportOverride?.id != vp { exitViewport(); enterViewport(vp) }
            } else if controller.activeViewportOverride != nil {
                exitViewport()
            } else if let id = controller.pickEntity(at: world) {
                onDoubleClickEntity?(id)
            }
            return
        }
        if controller.activeViewportOverride != nil { return }
        if event.clickCount == 2, controller.active == nil, let id = controller.pickEntity(at: world) {
            onDoubleClickEntity?(id)
            return
        }
        if controller.gripDrag != nil {
            controller.finishGrip(at: snapped)
            invalidateCache()
            return
        }
        switch controller.inputKind {
        case .point?:
            controller.canvasPoint(snapped)
        case .entity?:
            if let id = controller.pickEntity(at: world) { controller.canvasEntity(id, at: world) }
        case .text?:
            break
        case nil, .selection?:
            if controller.active == nil, let g = controller.grip(at: 6, near: world) {
                controller.beginGrip(g)
                refreshOverlay()
                return
            }
            if let a = pendingWindowCorner {
                pendingWindowCorner = nil
                finishWindow(a, world)
                return
            }
            if let id = controller.pickEntity(at: world) {
                controller.toggleSelect(id, remove: event.modifierFlags.contains(.shift))
            } else {
                dragStart = p
                dragCurrent = nil
            }
        }
        refreshOverlay()
    }

    override func mouseDragged(with event: NSEvent) {
        updateCursor(event)
        if dragStart != nil {
            dragCurrent = convert(event.locationInWindow, from: nil)
            refreshOverlay()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let a = dragStart else { return }
        let b = convert(event.locationInWindow, from: nil)
        dragStart = nil
        dragCurrent = nil
        if hypot(b.x - a.x, b.y - a.y) > 4 {
            finishWindow(vt.toWorld(a), vt.toWorld(b), remove: event.modifierFlags.contains(.shift))
        } else {
            // Click on empty space: start a click-click window.
            pendingWindowCorner = vt.toWorld(a)
        }
        refreshOverlay()
    }

    private func finishWindow(_ a: Vec2, _ b: Vec2, remove: Bool = false) {
        let crossing = b.x < a.x
        controller.select(window: BBox(corner: a, b), crossing: crossing, remove: remove)
        refreshOverlay()
    }

    override func rightMouseDown(with event: NSEvent) {
        if controller.gripDrag != nil { controller.cancelGrip(); refreshOverlay(); return }
        if controller.active != nil {
            controller.enter()
            refreshOverlay()
            return
        }
        let menu = NSMenu()
        func add(_ title: String, _ cmd: String) {
            let item = NSMenuItem(title: title, action: #selector(contextCommand(_:)), keyEquivalent: "")
            item.representedObject = cmd
            item.target = self
            menu.addItem(item)
        }
        if let last = controller.lastCommandName { add("Repeat \(last)", last); menu.addItem(.separator()) }
        if !controller.selection.isEmpty {
            for (t, c) in [("Erase", "ERASE"), ("Move", "MOVE"), ("Copy Selection", "COPY"), ("Scale", "SCALE"), ("Rotate", "ROTATE"),
                           ("Mirror", "MIRROR"), ("Offset", "OFFSET"), ("Explode", "EXPLODE"), ("Join", "JOIN"), ("Array", "ARRAY"),
                           ("Make Block", "BLOCK")] { add(t, c) }
            menu.addItem(.separator())
            let d = controller.drawing
            if controller.selection.count == 1, let id = controller.selection.first, case .insert = d.entity(id)?.kind {
                add("Edit Block…", "BEDIT")
            }
            add("Copy to Clipboard", "COPYCLIP")
            add("List", "LIST")
            add("Deselect All", "__DESELECT")
        } else {
            add("Paste", "PASTECLIP")
            add("Select All", "SELECTALL")
            add("Zoom Extents", "__ZOOMEXT")
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func contextCommand(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? String else { return }
        switch cmd {
        case "__DESELECT": controller.selection.removeAll()
        case "__ZOOMEXT": zoom(.extents)
        default: controller.run(cmd)
        }
        refreshOverlay()
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.clickCount == 2 { zoom(.extents); return }
        panLast = convert(event.locationInWindow, from: nil)
    }

    override func otherMouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let last = panLast {
            if controller.activeViewportOverride != nil { viewportPan(p.x - last.x, p.y - last.y) } else {
                vt.center -= Vec2((p.x - last.x) / vt.scale, (p.y - last.y) / vt.scale)
            }
        }
        panLast = p
        updateCursor(event)
    }

    override func otherMouseUp(with event: NSEvent) { panLast = nil }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let inViewport = controller.activeViewportOverride != nil
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            // Trackpad: two-finger scroll pans.
            if inViewport { viewportPan(event.scrollingDeltaX, -event.scrollingDeltaY) } else {
                vt.center -= Vec2(-event.scrollingDeltaX / vt.scale, event.scrollingDeltaY / vt.scale)
            }
        } else {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 50 : event.scrollingDeltaY
            guard dy != 0 else { return }
            if inViewport { viewportZoom(pow(1.2, dy), at: p) } else { vt.zoom(by: pow(1.2, dy), at: p) }
        }
        updateCursor(event)
    }

    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if controller.activeViewportOverride != nil { viewportZoom(1 + event.magnification, at: p); return }
        vt.zoom(by: 1 + event.magnification, at: p)
    }

    // MARK: Viewport (model space through a paper viewport)

    /// Topmost viewport whose frame contains the paper point.
    private func viewport(at p: Vec2) -> EntityID? {
        let sc = controller.scene
        for (i, it) in sc.items.enumerated().reversed() where sc.visible[i] {
            if case .viewport(let v) = it.entity.kind, v.frame.contains(p) { return it.entity.id }
        }
        return nil
    }

    func enterViewport(_ id: EntityID) {
        guard case .viewport(let v) = controller.drawing.entity(id)?.kind else { return }
        if v.isLocked {
            controller.message("Viewport is locked. Unlock it in Properties (Locked = No) to pan or zoom its view.")
            return
        }
        controller.activeViewportOverride = .init(id: id, geom: v)
        controller.message("Viewport active (scale \(formatViewportScale(v.scale))): scroll to pan, pinch / wheel to zoom. Esc or double-click outside to finish.")
        requestRender(delay: 0)
        refreshOverlay()
    }

    /// Leaves viewport mode, committing the new view as one undo step.
    func exitViewport() {
        guard let a = controller.activeViewportOverride else { return }
        controller.activeViewportOverride = nil
        if var e = controller.drawing.entity(a.id), case .viewport(let old) = e.kind, old != a.geom {
            e.kind = .viewport(a.geom)
            controller.perform("Viewport View") { $0.replace(e) }
            controller.message("Viewport scale \(formatViewportScale(a.geom.scale)).")
        } else {
            requestRender(delay: 0)
        }
        refreshOverlay()
    }

    private func viewportPan(_ dx: CGFloat, _ dy: CGFloat) {
        guard var a = controller.activeViewportOverride else { return }
        a.geom.viewCenter -= Vec2(dx, dy) / (vt.scale * a.geom.scale)
        controller.activeViewportOverride = a
        requestRender(delay: 0)
    }

    private func viewportZoom(_ factor: Double, at viewPoint: CGPoint) {
        guard var a = controller.activeViewportOverride, factor > 0 else { return }
        let pp = vt.toWorld(viewPoint)
        let anchor = a.geom.viewCenter + (pp - a.geom.center) / a.geom.scale
        a.geom.scale *= factor
        a.geom.viewCenter = anchor - (pp - a.geom.center) / a.geom.scale
        controller.activeViewportOverride = a
        requestRender(delay: 0)
    }

    override func smartMagnify(with event: NSEvent) { zoom(.extents) }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), event.keyCode == 25 { // ⌃9 like AutoCAD
            onToggleCommandLine?()
            return
        }
        if diActive {
            switch event.keyCode {
            case 51: diBackspace(); return
            case 53: diCancel(); return
            default: break
            }
        }
        if dynamicInput, !dynamicText.isEmpty {
            switch event.keyCode {
            case 51: dynamicText.removeLast(); return
            case 53: dynamicText = ""; return
            default: break
            }
        }
        switch event.keyCode {
        case 53: // Escape
            escape()
        case 51, 117: // Delete
            if controller.active == nil { controller.eraseSelection(); invalidateCache() }
        default:
            if onTypeKey?(event) != true { super.keyDown(with: event) }
        }
    }

    func escape() {
        if controller.activeViewportOverride != nil { exitViewport(); return }
        if controller.gripDrag != nil { controller.cancelGrip() }
        pendingWindowCorner = nil
        dragStart = nil
        controller.cancel()
        refreshOverlay()
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) { controller.run("COPYCLIP") }
    @objc func cut(_ sender: Any?) { controller.run("CUTCLIP") }
    @objc func paste(_ sender: Any?) { controller.run("PASTECLIP") }
    @objc override func selectAll(_ sender: Any?) { controller.selectAll() }
    @objc func delete(_ sender: Any?) { controller.eraseSelection() }
}

/// Off-main-thread render of the scene into a bitmap.
/// What a layout tab needs to render: its sheet and the model scenes seen through each viewport.
struct PaperRenderData {
    let paper: PaperSetup
    let viewports: [(ViewportGeom, Scene)]

    static let surround = CGColor(red: 0.3, green: 0.32, blue: 0.35, alpha: 1)

    @MainActor
    static func make(_ c: CommandController) -> PaperRenderData? {
        let d = c.drawing
        guard let layout = d.activeLayoutDef else { return nil }
        var vps: [(ViewportGeom, Scene)] = []
        let sc = c.scene
        for (i, it) in sc.items.enumerated() where sc.visible[i] {
            if case .viewport(let v) = it.entity.kind, v.isOn {
                vps.append((c.activeViewportOverride?.id == it.entity.id ? c.activeViewportOverride!.geom : v, c.modelScene(frozen: v.frozenLayers)))
            }
        }
        return PaperRenderData(paper: layout.paper, viewports: vps)
    }

    /// Draws the sheet, the model through each viewport, then the paper-space scene.
    func draw(_ ctx: CGContext, vt: ViewTransform, paperScene: Scene, drawing: Drawing, background: Bool) {
        let paperRect = CGRect(origin: vt.toView(.zero), size: CGSize(width: paper.width * vt.scale, height: paper.height * vt.scale))
        if background {
            ctx.setFillColor(PaperRenderData.surround)
            ctx.fill(CGRect(origin: .zero, size: vt.size))
            ctx.setShadow(offset: CGSize(width: 4, height: -4), blur: 8, color: CGColor(gray: 0, alpha: 0.5))
        }
        ctx.setFillColor(.white)
        ctx.fill(paperRect)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        if background {
            // Printable area.
            let pb = paper.printableBox
            ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(CGRect(origin: vt.toView(pb.min), size: CGSize(width: pb.width * vt.scale, height: pb.height * vt.scale)))
            ctx.setLineDash(phase: 0, lengths: [])
        }
        var style = RenderStyle()
        style.darkBackground = false
        for (vp, ms) in viewports {
            let f = vp.frame
            ctx.saveGState()
            ctx.clip(to: CGRect(origin: vt.toView(f.min), size: CGSize(width: f.width * vt.scale, height: f.height * vt.scale)))
            var mvt = vt
            mvt.scale = vt.scale * vp.scale
            mvt.center = vp.viewCenter + (vt.center - vp.center) / vp.scale
            var r = Renderer(drawing: drawing, vt: mvt, ctx: ctx)
            r.style = style
            r.drawScene(ms)
            ctx.restoreGState()
        }
        var r = Renderer(drawing: drawing, vt: vt, ctx: ctx)
        r.style = style
        r.drawScene(paperScene)
    }
}

struct RenderJob: @unchecked Sendable {
    let scene: Scene
    let drawing: Drawing
    let vt: ViewTransform
    let style: RenderStyle
    let grid: Double?
    let scaleFactor: CGFloat
    var paper: PaperRenderData? = nil

    func run() -> CGImage? {
        let w = Int(vt.size.width * scaleFactor), h = Int(vt.size.height * scaleFactor)
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scaleFactor, y: scaleFactor)
        if let paper {
            paper.draw(ctx, vt: vt, paperScene: scene, drawing: drawing, background: true)
            return ctx.makeImage()
        }
        ctx.setFillColor(style.background)
        ctx.fill(CGRect(origin: .zero, size: vt.size))
        if let g = grid { RenderJob.drawGrid(ctx, spacing: g, vt: vt, style: style) }
        var r = Renderer(drawing: drawing, vt: vt, ctx: ctx)
        r.style = style
        r.drawScene(scene)
        return ctx.makeImage()
    }

    static func drawGrid(_ ctx: CGContext, spacing: Double, vt: ViewTransform, style: RenderStyle) {
        var s = spacing
        guard s > 0 else { return }
        var steps = 0
        while s * vt.scale < 10 && steps < 40 { s *= 5; steps += 1 }
        while s * vt.scale > 200 && steps < 80 { s /= 5; steps += 1 }
        let box = vt.visibleBox
        let size = vt.size
        let minor = style.darkBackground ? CGColor(gray: 1, alpha: 0.05) : CGColor(gray: 0, alpha: 0.06)
        let major = style.darkBackground ? CGColor(gray: 1, alpha: 0.12) : CGColor(gray: 0, alpha: 0.14)
        ctx.setLineWidth(1)
        for pass in 0..<2 {
            ctx.setStrokeColor(pass == 0 ? minor : major)
            let step = pass == 0 ? s : s * 5
            var x = (box.min.x / step).rounded(.down) * step
            while x <= box.max.x {
                let vx = vt.toView(Vec2(x, 0)).x.rounded() + 0.5
                ctx.move(to: CGPoint(x: vx, y: 0)); ctx.addLine(to: CGPoint(x: vx, y: size.height))
                x += step
            }
            var y = (box.min.y / step).rounded(.down) * step
            while y <= box.max.y {
                let vy = vt.toView(Vec2(0, y)).y.rounded() + 0.5
                ctx.move(to: CGPoint(x: 0, y: vy)); ctx.addLine(to: CGPoint(x: size.width, y: vy))
                y += step
            }
            ctx.strokePath()
        }
        let o = vt.toView(.zero)
        ctx.setStrokeColor(CGColor(red: 0.8, green: 0.3, blue: 0.3, alpha: 0.35))
        ctx.move(to: CGPoint(x: 0, y: o.y)); ctx.addLine(to: CGPoint(x: size.width, y: o.y)); ctx.strokePath()
        ctx.setStrokeColor(CGColor(red: 0.3, green: 0.8, blue: 0.3, alpha: 0.35))
        ctx.move(to: CGPoint(x: o.x, y: 0)); ctx.addLine(to: CGPoint(x: o.x, y: size.height)); ctx.strokePath()
    }
}
