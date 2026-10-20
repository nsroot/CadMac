import AppKit

/// Simple vector icons for tool buttons (template images, 20×20 pt).
@MainActor
enum ToolIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ name: String) -> NSImage {
        if let i = cache[name] { return i }
        let img = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            draw(name)
            return true
        }
        img.isTemplate = true
        cache[name] = img
        return img
    }

    private static func path(_ pts: [(CGFloat, CGFloat)], close: Bool = false, width: CGFloat = 1.5) {
        let p = NSBezierPath()
        p.lineWidth = width
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        for (i, q) in pts.enumerated() {
            if i == 0 { p.move(to: NSPoint(x: q.0, y: q.1)) } else { p.line(to: NSPoint(x: q.0, y: q.1)) }
        }
        if close { p.close() }
        p.stroke()
    }

    private static func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat = 1.6) {
        NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).fill()
    }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, width: CGFloat = 1.5) {
        let p = NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        p.lineWidth = width
        p.stroke()
    }

    private static func arc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ a0: CGFloat, _ a1: CGFloat, width: CGFloat = 1.5) {
        let p = NSBezierPath()
        p.appendArc(withCenter: NSPoint(x: x, y: y), radius: r, startAngle: a0, endAngle: a1)
        p.lineWidth = width
        p.lineCapStyle = .round
        p.stroke()
    }

    private static func dashed(_ pts: [(CGFloat, CGFloat)]) {
        let p = NSBezierPath()
        p.lineWidth = 1
        p.setLineDash([2, 2], count: 2, phase: 0)
        for (i, q) in pts.enumerated() {
            if i == 0 { p.move(to: NSPoint(x: q.0, y: q.1)) } else { p.line(to: NSPoint(x: q.0, y: q.1)) }
        }
        p.stroke()
    }

    private static func text(_ s: String, size: CGFloat = 12, at p: NSPoint = NSPoint(x: 3, y: 2)) {
        (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: NSColor.black])
    }

    private static func arrowHead(_ x: CGFloat, _ y: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
        let l = hypot(dx, dy), ux = dx / l, uy = dy / l
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x, y: y))
        p.line(to: NSPoint(x: x - ux * 4 - uy * 2, y: y - uy * 4 + ux * 2))
        p.line(to: NSPoint(x: x - ux * 4 + uy * 2, y: y - uy * 4 - ux * 2))
        p.close()
        p.fill()
    }

    private static func draw(_ name: String) {
        switch name {
        case "LINE": path([(3, 4), (17, 16)]); dot(3, 4); dot(17, 16)
        case "PLINE": path([(2, 4), (7, 14), (12, 6), (18, 15)]); dot(2, 4); dot(18, 15)
        case "CIRCLE": circle(10, 10, 7); dot(10, 10, 1.2)
        case "ARC": arc(10, 5, 8, 20, 160); dot(17.5, 7.7); dot(2.5, 7.7)
        case "RECTANG": path([(3, 5), (17, 5), (17, 15), (3, 15)], close: true)
        case "POLYGON":
            path((0..<6).map { i -> (CGFloat, CGFloat) in let a = CGFloat(i) * .pi / 3; return (10 + 7.5 * cos(a), 10 + 7.5 * sin(a)) }, close: true)
        case "ELLIPSE":
            let p = NSBezierPath(ovalIn: NSRect(x: 2, y: 5, width: 16, height: 10)); p.lineWidth = 1.5; p.stroke()
        case "SPLINE":
            let p = NSBezierPath(); p.lineWidth = 1.5
            p.move(to: NSPoint(x: 2, y: 6)); p.curve(to: NSPoint(x: 18, y: 14), controlPoint1: NSPoint(x: 8, y: 22), controlPoint2: NSPoint(x: 12, y: -2)); p.stroke()
        case "HATCH":
            path([(3, 3), (17, 3), (17, 17), (3, 17)], close: true, width: 1.2)
            for k in stride(from: -10, through: 10, by: 4) {
                let k = CGFloat(k)
                path([(max(3, 3 + k), max(3, 3 - k)), (min(17, 17 + k), min(17, 17 - k))], width: 0.9)
            }
        case "POINT": dot(10, 10, 2); path([(5, 10), (15, 10)], width: 1); path([(10, 5), (10, 15)], width: 1)
        case "TEXT": text("A", size: 15, at: NSPoint(x: 4, y: 1))
        case "MTEXT": text("A", size: 11, at: NSPoint(x: 2, y: 6)); path([(11, 14), (18, 14)], width: 1); path([(11, 10), (18, 10)], width: 1); path([(3, 4), (18, 4)], width: 1)
        case "MOVE":
            path([(10, 2), (10, 18)]); path([(2, 10), (18, 10)])
            arrowHead(10, 18, 0, 1); arrowHead(10, 2, 0, -1); arrowHead(18, 10, 1, 0); arrowHead(2, 10, -1, 0)
        case "COPY": path([(2, 2), (11, 2), (11, 11), (2, 11)], close: true); path([(8, 8), (18, 8), (18, 18), (8, 18)], close: true)
        case "ROTATE": arc(10, 10, 7, 30, 330); arrowHead(16.1, 13.5, -0.5, 0.9); dot(10, 10, 1.2)
        case "SCALE": path([(2, 2), (9, 2), (9, 9), (2, 9)], close: true); path([(2, 2), (18, 2), (18, 18), (2, 18)], close: true, width: 1); path([(9, 9), (16, 16)]); arrowHead(16, 16, 1, 1)
        case "MIRROR": dashed([(10, 1), (10, 19)]); path([(2, 4), (7, 4), (7, 15)], close: true); path([(18, 4), (13, 4), (13, 15)], close: true)
        case "STRETCH": path([(2, 4), (9, 4), (9, 14), (2, 14)]); dashed([(9, 4), (16, 4), (16, 14), (9, 14)]); path([(11, 9), (18, 9)]); arrowHead(18, 9, 1, 0)
        case "OFFSET": arc(18, 2, 10, 90, 180); arc(18, 2, 15, 90, 180, width: 1.2)
        case "TRIM": path([(6, 2), (6, 18)]); path([(14, 2), (14, 18)]); path([(2, 10), (6, 10)]); dashed([(6, 10), (14, 10)]); path([(14, 10), (18, 10)])
        case "EXTEND": path([(16, 2), (16, 18)], width: 2); path([(2, 10), (9, 10)]); dashed([(9, 10), (16, 10)]); arrowHead(15, 10, 1, 0)
        case "FILLET": path([(3, 18), (3, 9)]); arc(11, 9, 8, 180, 270); path([(11, 1), (18, 1)])
        case "CHAMFER": path([(3, 18), (3, 8), (9, 2), (18, 2)])
        case "ARRAY": for x in [4, 10, 16] { for y in [4, 10, 16] { let r = NSRect(x: CGFloat(x) - 2, y: CGFloat(y) - 2, width: 4, height: 4); NSBezierPath(rect: r).fill() } }
        case "ERASE": path([(4, 4), (16, 16)], width: 2); path([(4, 16), (16, 4)], width: 2)
        case "EXPLODE": for a in stride(from: 0.0, to: 360, by: 45) { let r = a * .pi / 180; path([(10 + 3 * cos(r), 10 + 3 * sin(r)), (10 + 8 * cos(r), 10 + 8 * sin(r))]) }
        case "BREAK": path([(2, 10), (8, 10)]); path([(12, 10), (18, 10)]); path([(9, 6), (11, 14)], width: 1)
        case "JOIN": path([(2, 10), (9, 10)]); path([(11, 10), (18, 10)]); dot(10, 10, 2)
        case "DIMLINEAR": path([(3, 4), (3, 16)], width: 1); path([(17, 4), (17, 16)], width: 1); path([(3, 12), (17, 12)], width: 1.2); arrowHead(3, 12, -1, 0); arrowHead(17, 12, 1, 0)
        case "DIMALIGNED": path([(3, 3), (15, 15)], width: 1.2); arrowHead(3, 3, -1, -1); arrowHead(15, 15, 1, 1); path([(6, 1), (1, 6)], width: 1); path([(18, 13), (13, 18)], width: 1)
        case "DIMRADIUS": circle(10, 10, 7, width: 1); path([(10, 10), (15, 15)]); arrowHead(15, 15, 1, 1); text("R", size: 8, at: NSPoint(x: 3, y: 2))
        case "DIMDIAMETER": circle(10, 10, 7, width: 1); path([(5, 5), (15, 15)]); arrowHead(15, 15, 1, 1); arrowHead(5, 5, -1, -1)
        case "DIMANGULAR": path([(3, 3), (18, 3)]); path([(3, 3), (14, 16)]); arc(3, 3, 11, 0, 49, width: 1.2)
        case "QLEADER": path([(3, 3), (10, 12), (17, 12)]); arrowHead(3, 3, -1, -1.3); path([(11, 16), (18, 16)], width: 1)
        case "BLOCK": path([(3, 5), (12, 5), (12, 14), (3, 14)], close: true); circle(13, 12, 5)
        case "BEDIT": path([(3, 3), (11, 3), (11, 11), (3, 11)], close: true); path([(9, 9), (17, 17)], width: 2.5); path([(8, 8), (9, 10), (10, 9)], close: true, width: 1)
        case "INSERT": path([(3, 3), (11, 3), (11, 11), (3, 11)], close: true); path([(17, 17), (11, 11)]); arrowHead(11, 11, -1, -1)
        case "DIST": path([(2, 10), (18, 10)]); arrowHead(2, 10, -1, 0); arrowHead(18, 10, 1, 0); path([(2, 6), (2, 14)], width: 1); path([(18, 6), (18, 14)], width: 1)
        case "AREA": path([(3, 3), (17, 5), (15, 17), (5, 14)], close: true); dot(3, 3); dot(17, 5); dot(15, 17); dot(5, 14)
        case "LAYER": path([(10, 2), (18, 6), (10, 10), (2, 6)], close: true); path([(2, 10), (10, 14), (18, 10)]); path([(2, 14), (10, 18), (18, 14)])
        case "MATCHPROP": path([(4, 2), (4, 10), (16, 10), (16, 16), (4, 16), (4, 10)]); path([(8, 2), (8, 8)], width: 3)
        default: circle(10, 10, 6)
        }
    }
}

/// Left "Tool Sets" palette with grouped icon buttons.
@MainActor
final class ToolPaletteView: NSView {
    var onCommand: ((String) -> Void)?

    static let groups: [(String, [(String, String)])] = [
        ("Draw", [("LINE", "Line (L)"), ("PLINE", "Polyline (PL)"), ("CIRCLE", "Circle (C)"), ("ARC", "Arc (A)"),
                  ("RECTANG", "Rectangle (REC)"), ("POLYGON", "Polygon (POL)"), ("ELLIPSE", "Ellipse (EL)"), ("SPLINE", "Spline (SPL)"),
                  ("HATCH", "Hatch (H)"), ("POINT", "Point (PO)"), ("TEXT", "Single-line Text (DT)"), ("MTEXT", "Multiline Text (T)")]),
        ("Modify", [("MOVE", "Move (M)"), ("COPY", "Copy (CO)"), ("ROTATE", "Rotate (RO)"), ("SCALE", "Scale (SC)"),
                    ("MIRROR", "Mirror (MI)"), ("STRETCH", "Stretch (S)"), ("OFFSET", "Offset (O)"), ("TRIM", "Trim (TR)"),
                    ("EXTEND", "Extend (EX)"), ("FILLET", "Fillet (F)"), ("CHAMFER", "Chamfer (CHA)"), ("ARRAY", "Array (AR)"),
                    ("BREAK", "Break (BR)"), ("JOIN", "Join (J)"), ("EXPLODE", "Explode (X)"), ("ERASE", "Erase (E)")]),
        ("Annotation", [("DIMLINEAR", "Linear Dimension (DLI)"), ("DIMALIGNED", "Aligned Dimension (DAL)"), ("DIMRADIUS", "Radius Dimension (DRA)"),
                        ("DIMDIAMETER", "Diameter Dimension (DDI)"), ("DIMANGULAR", "Angular Dimension (DAN)"), ("QLEADER", "Leader (LE)")]),
        ("Block & Tools", [("BLOCK", "Create Block (B)"), ("INSERT", "Insert Block (I)"), ("BEDIT", "Block Editor (BE)"), ("MATCHPROP", "Match Properties (MA)"),
                           ("DIST", "Measure Distance (DI)"), ("AREA", "Area (AA)"), ("LAYER", "Layer Properties (LA)")]),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.2, green: 0.22, blue: 0.25, alpha: 1).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        for (title, tools) in ToolPaletteView.groups {
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = NSFont.systemFont(ofSize: 10, weight: .bold)
            label.textColor = NSColor(white: 0.6, alpha: 1)
            stack.addArrangedSubview(label)
            let grid = NSGridView()
            grid.rowSpacing = 2
            grid.columnSpacing = 2
            var row: [NSView] = []
            for (cmd, tip) in tools {
                let b = NSButton(image: ToolIcons.icon(cmd), target: self, action: #selector(click(_:)))
                b.bezelStyle = .regularSquare
                b.isBordered = false
                b.imageScaling = .scaleNone
                b.contentTintColor = NSColor(white: 0.9, alpha: 1)
                b.toolTip = tip
                b.identifier = NSUserInterfaceItemIdentifier(cmd)
                b.wantsLayer = true
                b.layer?.cornerRadius = 4
                b.widthAnchor.constraint(equalToConstant: 32).isActive = true
                b.heightAnchor.constraint(equalToConstant: 30).isActive = true
                row.append(b)
                if row.count == 4 { grid.addRow(with: row); row = [] }
            }
            if !row.isEmpty { grid.addRow(with: row) }
            stack.addArrangedSubview(grid)
            stack.setCustomSpacing(12, after: grid)
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let flipped = FlippedView()
        flipped.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: flipped.topAnchor),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])
        flipped.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = flipped
        flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func click(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onCommand?(id) }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
