import AppKit
import CadCore

// MARK: - LINE

final class LineCommand: CadCommand {
    private var first: Vec2?
    private var current: Vec2?
    private var created: [EntityID] = []
    private var starts: [Vec2] = []

    override func start() { ask("Specify first point") }

    override func point(_ p: Vec2) {
        guard let cur = current else {
            first = p; current = p
            ask("Specify next point", keywords: ["Undo"], base: p)
            return
        }
        guard !cur.isClose(to: p) else { return }
        let e = make(.line(LineGeom(start: cur, end: p)))
        c.perform("Line") { $0.add(e) }
        created.append(e.id)
        starts.append(cur)
        current = p
        ask("Specify next point", keywords: created.count >= 2 ? ["Close", "Undo"] : ["Undo"], base: p)
    }

    override func keyword(_ k: String) {
        switch k {
        case "Close":
            if let f = first { point(f) }
            finish()
        case "Undo":
            guard let id = created.popLast(), let s = starts.popLast() else { return }
            c.perform("Undo segment") { $0.remove(ids: [id]) }
            current = s
            c.lastPoint = s
            ask("Specify next point", keywords: created.count >= 2 ? ["Close", "Undo"] : ["Undo"], base: s)
        default: break
        }
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        guard let cur = current else { return [] }
        return [make(.line(LineGeom(start: cur, end: cursor)))]
    }
}

// MARK: - XLINE / RAY (finite stand-ins)

final class ConstructionLineCommand: CadCommand {
    private var origin: Vec2?
    private let isRay: Bool
    init(_ c: CommandController, name: String, ray: Bool) { isRay = ray; super.init(c, name: name) }

    override func start() { ask(isRay ? "Specify start point" : "Specify a point") }

    private func geometry(_ through: Vec2) -> LineGeom? {
        guard let o = origin, !o.isClose(to: through) else { return nil }
        let dir = (through - o).normalized
        let ext = max(1e5, drawing.extents().width * 100, drawing.extents().height * 100)
        return LineGeom(start: isRay ? o : o - dir * ext, end: o + dir * ext)
    }

    override func point(_ p: Vec2) {
        guard origin != nil else {
            origin = p
            ask("Specify through point", base: p)
            return
        }
        if let g = geometry(p) {
            let e = make(.line(g))
            c.perform(name) { $0.add(e) }
        }
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        geometry(cursor).map { [make(.line($0))] } ?? []
    }
}

// MARK: - PLINE

final class PolylineCommand: CadCommand {
    private var verts: [PolyVertex] = []
    private var arcMode = false
    private var width = 0.0

    override func start() { ask("Specify start point") }

    private var keywordsNow: [String] {
        var k = arcMode ? ["Line"] : ["Arc"]
        if verts.count >= 2 { k.append("Close") }
        k += ["Width", "Undo"]
        return k
    }

    private func promptNext() {
        ask(arcMode ? "Specify endpoint of arc" : "Specify next point", keywords: keywordsNow, base: verts.last?.point)
    }

    /// Tangent direction at the end of the current polyline.
    private var endTangent: Vec2? {
        guard verts.count >= 2 else { return nil }
        let a = verts[verts.count - 2], b = verts[verts.count - 1]
        let prim = bulgeSegment(a.point, b.point, bulge: a.bulge)
        switch prim {
        case .seg(let p, let q): return (q - p).normalized
        case let .arc(c, _, _, _):
            let r = (b.point - c).normalized
            return a.bulge > 0 ? r.perp : -r.perp
        }
    }

    /// Bulge for a tangent arc from the last vertex to `p`.
    private func tangentBulge(to p: Vec2) -> Double {
        guard let last = verts.last else { return 0 }
        let dir = endTangent ?? Vec2(1, 0)
        let chord = p - last.point
        guard chord.length > 1e-12 else { return 0 }
        let ang = atan2(dir.cross(chord), dir.dot(chord))
        return tan(ang / 2)  // sweep = 2*ang → bulge = tan(sweep/4)
    }

    private func appendPoint(_ p: Vec2) {
        if let last = verts.last, last.point.isClose(to: p) { return }
        if arcMode, !verts.isEmpty { verts[verts.count - 1].bulge = tangentBulge(to: p) }
        verts.append(PolyVertex(p))
    }

    override func point(_ p: Vec2) {
        appendPoint(p)
        promptNext()
    }

    override func keyword(_ k: String) {
        switch k {
        case "Arc": arcMode = true; promptNext()
        case "Line": arcMode = false; promptNext()
        case "Close":
            if arcMode, let f = verts.first { verts[verts.count - 1].bulge = tangentBulge(to: f.point) }
            commit(closed: true)
        case "Width":
            ask("Specify width <\(fmt(width))>", .text)
        case "Undo":
            if !verts.isEmpty { verts.removeLast() }
            if !verts.isEmpty { verts[verts.count - 1].bulge = 0; c.lastPoint = verts.last!.point }
            if verts.isEmpty { ask("Specify start point") } else { promptNext() }
        default: break
        }
    }

    override func value(_ s: String) -> Bool {
        guard input == .text, let w = Double(s), w >= 0 else { return false }
        width = w
        promptNext()
        return true
    }

    override func enter() {
        if input == .text { promptNext(); return }
        commit(closed: false)
    }

    private func commit(closed: Bool) {
        if verts.count >= 2 {
            let e = make(.polyline(PolylineGeom(vertices: verts, closed: closed, width: width)))
            c.perform("Polyline") { $0.add(e) }
        }
        finish()
    }

    override func cancelled() {
        // AutoCAD keeps what was drawn when a polyline is cancelled.
        if verts.count >= 2 {
            let e = make(.polyline(PolylineGeom(vertices: verts, width: width)))
            c.perform("Polyline") { $0.add(e) }
        }
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        guard !verts.isEmpty else { return [] }
        var v = verts
        if arcMode { v[v.count - 1].bulge = tangentBulge(to: cursor) }
        v.append(PolyVertex(cursor))
        return [make(.polyline(PolylineGeom(vertices: v, width: width)))]
    }
}

// MARK: - RECTANG

final class RectangleCommand: CadCommand {
    private var corner: Vec2?
    override func start() { ask("Specify first corner point") }

    private func rect(_ a: Vec2, _ b: Vec2) -> EntityKind {
        .polyline(PolylineGeom(points: [a, Vec2(b.x, a.y), b, Vec2(a.x, b.y)], closed: true))
    }

    override func point(_ p: Vec2) {
        guard let a = corner else {
            corner = p
            ask("Specify other corner point", base: p)
            return
        }
        guard abs(a.x - p.x) > 1e-9, abs(a.y - p.y) > 1e-9 else { c.message("Rectangle has zero size"); return }
        let e = make(rect(a, p))
        c.perform("Rectangle") { $0.add(e) }
        finish()
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        corner.map { [make(rect($0, cursor))] } ?? []
    }
}

// MARK: - CIRCLE

final class CircleCommand: CadCommand {
    private enum Mode { case center, twoPoint, threePoint }
    private var mode = Mode.center
    private var pts: [Vec2] = []
    private var diameter = false

    override func start() { ask("Specify center point for circle", keywords: ["3P", "2P"]) }

    override func keyword(_ k: String) {
        switch k {
        case "3P": mode = .threePoint; pts = []; ask("Specify first point on circle")
        case "2P": mode = .twoPoint; pts = []; ask("Specify first end point of circle's diameter")
        case "Diameter": diameter = true; ask("Specify diameter of circle", base: pts.first)
        default: break
        }
    }

    private func circle(for p: Vec2) -> CircleGeom? {
        switch mode {
        case .center:
            guard let c0 = pts.first else { return nil }
            let r = c0.distance(to: p) / (diameter ? 2 : 1)
            return r > 1e-12 ? CircleGeom(center: c0, radius: r) : nil
        case .twoPoint:
            guard let a = pts.first else { return nil }
            return CircleGeom(center: (a + p) / 2, radius: a.distance(to: p) / 2)
        case .threePoint:
            guard pts.count == 2, let (cc, r) = circleThrough(pts[0], pts[1], p) else { return nil }
            return CircleGeom(center: cc, radius: r)
        }
    }

    private func create(_ g: CircleGeom) {
        let e = make(.circle(g))
        c.perform("Circle") { $0.add(e) }
        finish()
    }

    override func point(_ p: Vec2) {
        switch mode {
        case .center where pts.isEmpty:
            pts = [p]
            ask("Specify radius of circle", keywords: ["Diameter"], base: p)
        case .threePoint where pts.count < 2:
            pts.append(p)
            ask(pts.count == 1 ? "Specify second point on circle" : "Specify third point on circle", base: p)
        case .twoPoint where pts.isEmpty:
            pts = [p]
            ask("Specify second end point of circle's diameter", base: p)
        default:
            if let g = circle(for: p) { create(g) }
        }
    }

    override func value(_ s: String) -> Bool {
        guard mode == .center, let c0 = pts.first, let v = Double(s), v > 0 else { return false }
        create(CircleGeom(center: c0, radius: diameter ? v / 2 : v))
        return true
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        guard let g = circle(for: cursor) else { return [] }
        var out = [make(.circle(g))]
        if mode == .center, let c0 = pts.first { out.append(make(.line(LineGeom(start: c0, end: cursor)))) }
        return out
    }
}

// MARK: - ARC

final class ArcCommand: CadCommand {
    private var pts: [Vec2] = []
    private var centerMode = false
    private var center: Vec2?

    override func start() { ask("Specify start point of arc", keywords: ["Center"]) }

    override func keyword(_ k: String) {
        if k == "Center" { centerMode = true; ask("Specify center point of arc") }
    }

    private func arc(_ p: Vec2) -> ArcGeom? {
        if centerMode {
            guard let cc = center, let s = pts.first else { return nil }
            return ArcGeom(center: cc, radius: cc.distance(to: s), startAngle: (s - cc).angle, endAngle: (p - cc).angle)
        }
        guard pts.count == 2 else { return nil }
        return ArcGeom.through(pts[0], pts[1], p)
    }

    override func point(_ p: Vec2) {
        if centerMode {
            if center == nil { center = p; ask("Specify start point of arc", base: p); return }
            if pts.isEmpty { pts = [p]; ask("Specify end point of arc (hold direction CCW)", base: center); return }
        } else if pts.count < 2 {
            pts.append(p)
            ask(pts.count == 1 ? "Specify second point of arc" : "Specify end point of arc", base: p)
            return
        }
        if let a = arc(p) {
            let e = make(.arc(a))
            c.perform("Arc") { $0.add(e) }
            finish()
        }
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        if let a = arc(cursor) { return [make(.arc(a))] }
        if pts.count == 1, !centerMode { return [make(.line(LineGeom(start: pts[0], end: cursor)))] }
        return []
    }
}

// MARK: - ELLIPSE

final class EllipseCommand: CadCommand {
    private var a1: Vec2?
    private var a2: Vec2?
    private var centerMode = false

    override func start() { ask("Specify axis endpoint of ellipse", keywords: ["Center"]) }

    override func keyword(_ k: String) {
        if k == "Center" { centerMode = true; ask("Specify center of ellipse") }
    }

    private func geom(_ p: Vec2) -> EllipseGeom? {
        guard let a1, let a2 else { return nil }
        let center = centerMode ? a1 : (a1 + a2) / 2
        let major = a2 - center
        guard major.length > 1e-12 else { return nil }
        // Distance from p to the major axis line is the other semi-axis.
        let minor = abs((p - center).cross(major.normalized))
        guard minor > 1e-12 else { return nil }
        if minor > major.length {
            return EllipseGeom(center: center, majorAxis: major.perp.normalized * minor, ratio: major.length / minor)
        }
        return EllipseGeom(center: center, majorAxis: major, ratio: minor / major.length)
    }

    override func point(_ p: Vec2) {
        if a1 == nil { a1 = p; ask(centerMode ? "Specify endpoint of axis" : "Specify other endpoint of axis", base: p); return }
        if a2 == nil { a2 = p; ask("Specify distance to other axis", base: centerMode ? a1 : (a1! + p) / 2); return }
        if let g = geom(p) { create(g) }
    }

    override func value(_ s: String) -> Bool {
        guard let a1, let a2, let d = Double(s), d > 0 else { return false }
        let center = centerMode ? a1 : (a1 + a2) / 2
        let probe = center + (a2 - center).normalized.perp * d
        guard let g = geom(probe) else { return false }
        create(g)
        return true
    }

    private func create(_ g: EllipseGeom) {
        let e = make(.ellipse(g))
        c.perform("Ellipse") { $0.add(e) }
        finish()
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        if let g = geom(cursor) { return [make(.ellipse(g))] }
        if let a1 { return [make(.line(LineGeom(start: a1, end: cursor)))] }
        return []
    }
}

// MARK: - POLYGON

final class PolygonCommand: CadCommand {
    static var lastSides = 4
    private var sides = PolygonCommand.lastSides
    private var center: Vec2?
    private var inscribed = true
    private var edgeMode = false
    private var edgeStart: Vec2?

    override func start() { ask("Enter number of sides <\(sides)>", .text) }

    override func value(_ s: String) -> Bool {
        if input == .text {
            guard let n = Int(s), (3...1024).contains(n) else { return false }
            sides = n; PolygonCommand.lastSides = n
            ask("Specify center of polygon", keywords: ["Edge"])
            return true
        }
        guard let r = Double(s), r > 0, let cc = center else { return false }
        create(points(center: cc, through: cc + Vec2(r, 0)))
        return true
    }

    override func enter() {
        if input == .text { ask("Specify center of polygon", keywords: ["Edge"]) } else { finish() }
    }

    override func keyword(_ k: String) {
        switch k {
        case "Edge": edgeMode = true; ask("Specify first endpoint of edge")
        case "Inscribed in circle": inscribed = true; ask("Specify radius of circle", base: center)
        case "Circumscribed about circle": inscribed = false; ask("Specify radius of circle", base: center)
        default: break
        }
    }

    private func points(center cc: Vec2, through p: Vec2) -> [Vec2] {
        let n = Double(sides)
        var r = cc.distance(to: p)
        var a0 = (p - cc).angle
        if !inscribed { r /= cos(.pi / n); a0 += .pi / n }
        return (0..<sides).map { cc + .polar(r, a0 + 2 * .pi * Double($0) / n) }
    }

    private func edgePoints(_ a: Vec2, _ b: Vec2) -> [Vec2] {
        var pts = [a, b]
        let ext = 2 * .pi / Double(sides)
        for _ in 2..<sides {
            let p = pts[pts.count - 1], q = pts[pts.count - 2]
            pts.append(p + (p - q).rotated(by: ext))
        }
        return pts
    }

    private func create(_ pts: [Vec2]) {
        let e = make(.polyline(PolylineGeom(points: pts, closed: true)))
        c.perform("Polygon") { $0.add(e) }
        finish()
    }

    override func point(_ p: Vec2) {
        if edgeMode {
            if let a = edgeStart { create(edgePoints(a, p)) } else { edgeStart = p; ask("Specify second endpoint of edge", base: p) }
            return
        }
        if let cc = center { create(points(center: cc, through: p)); return }
        center = p
        ask("Specify radius of circle", keywords: ["Inscribed in circle", "Circumscribed about circle"], base: p)
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        if edgeMode, let a = edgeStart { return [make(.polyline(PolylineGeom(points: edgePoints(a, cursor), closed: true)))] }
        guard let cc = center, cc.distance(to: cursor) > 1e-12 else { return [] }
        return [make(.polyline(PolylineGeom(points: points(center: cc, through: cursor), closed: true)))]
    }
}

// MARK: - POINT

final class PointCommand: CadCommand {
    override func start() { ask("Specify a point") }
    override func point(_ p: Vec2) {
        let e = make(.point(PointGeom(position: p)))
        c.perform("Point") { $0.add(e) }
        ask("Specify a point")
    }
}

// MARK: - DONUT

final class DonutCommand: CadCommand {
    static var inner = 5.0, outer = 10.0
    override func start() { ask("Specify inside diameter of donut <\(fmt(DonutCommand.inner))>", .text) }
    private var stage = 0

    override func value(_ s: String) -> Bool {
        guard let v = Double(s), v >= 0 else { return false }
        if stage == 0 { DonutCommand.inner = v } else { DonutCommand.outer = max(v, DonutCommand.inner + 1e-9) }
        advance()
        return true
    }
    override func enter() {
        if input == .text { advance() } else { finish() }
    }
    private func advance() {
        stage += 1
        if stage == 1 { ask("Specify outside diameter of donut <\(fmt(DonutCommand.outer))>", .text) } else { ask("Specify center of donut") }
    }
    private func geom(_ p: Vec2) -> PolylineGeom {
        let r = (DonutCommand.inner + DonutCommand.outer) / 4
        let w = (DonutCommand.outer - DonutCommand.inner) / 2
        return PolylineGeom(vertices: [PolyVertex(p - Vec2(r, 0), bulge: 1), PolyVertex(p + Vec2(r, 0), bulge: 1)], closed: true, width: w)
    }
    override func point(_ p: Vec2) {
        let e = make(.polyline(geom(p)))
        c.perform("Donut") { $0.add(e) }
    }
    override func preview(_ cursor: Vec2) -> [Entity] { input == .point ? [make(.polyline(geom(cursor)))] : [] }
}

// MARK: - SPLINE

final class SplineCommand: CadCommand {
    private var pts: [Vec2] = []
    override func start() { ask("Specify first point") }

    override func point(_ p: Vec2) {
        pts.append(p)
        ask(pts.count == 1 ? "Enter next point" : "Enter next point", keywords: pts.count >= 3 ? ["Close", "Undo"] : ["Undo"], base: p)
    }

    override func keyword(_ k: String) {
        switch k {
        case "Close": commit(closed: true)
        case "Undo":
            if !pts.isEmpty { pts.removeLast() }
            if pts.isEmpty { ask("Specify first point") } else { ask("Enter next point", keywords: ["Undo"], base: pts.last) }
        default: break
        }
    }

    override func enter() { commit(closed: false) }

    private func commit(closed: Bool) {
        if pts.count >= 2 {
            let e = make(.spline(SplineGeom(fitPoints: pts, closed: closed)))
            c.perform("Spline") { $0.add(e) }
        }
        finish()
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        guard !pts.isEmpty else { return [] }
        return [make(.spline(SplineGeom(fitPoints: pts + [cursor])))]
    }
}

// MARK: - REVCLOUD

final class RevcloudCommand: CadCommand {
    static var arcLength = 15.0
    private var corner: Vec2?

    override func start() {
        ask("Specify first corner point (rectangular cloud)", keywords: ["Arc length", "Object"])
    }

    override func keyword(_ k: String) {
        switch k {
        case "Arc length": ask("Specify arc length <\(fmt(RevcloudCommand.arcLength))>", .text)
        case "Object": ask("Select object", .entity)
        default: break
        }
    }

    override func value(_ s: String) -> Bool {
        guard let v = Double(s), v > 0 else { return false }
        RevcloudCommand.arcLength = v
        start()
        return true
    }

    /// Closed cloud polyline around the given boundary points.
    private func cloud(_ boundary: [Vec2]) -> PolylineGeom {
        var verts: [PolyVertex] = []
        let n = boundary.count
        for i in 0..<n {
            let a = boundary[i], b = boundary[(i + 1) % n]
            let count = max(1, Int((a.distance(to: b) / RevcloudCommand.arcLength).rounded()))
            for k in 0..<count {
                verts.append(PolyVertex(a.lerp(to: b, Double(k) / Double(count)), bulge: -0.5))
            }
        }
        // Bulge sign makes arcs bulge outward for CCW boundaries.
        let area = zip(boundary, boundary.dropFirst() + [boundary[0]]).reduce(0.0) { $0 + $1.0.cross($1.1) }
        if area < 0 { verts = verts.map { PolyVertex($0.point, bulge: 0.5) } }
        return PolylineGeom(vertices: verts, closed: true)
    }

    override func entityPicked(_ id: EntityID, at p: Vec2) {
        guard let e = drawing.entity(id) else { return }
        let pts: [Vec2]
        if case .polyline(let pl) = e.kind {
            pts = loopPoints(pl.vertices, maxAngleStep: .pi / 8)
        } else {
            pts = drawing.prims(of: e).flatMap { Array($0.tessellate(maxAngleStep: .pi / 8).dropLast()) }
        }
        guard pts.count >= 3 else { c.message("Object must be closed"); return }
        let cl = cloud(pts)
        var replaced = e
        replaced.kind = .polyline(cl)
        c.perform("Revcloud") { $0.replace(replaced) }
        finish()
    }

    override func point(_ p: Vec2) {
        guard let a = corner else { corner = p; ask("Specify opposite corner", base: p); return }
        let pts = [a, Vec2(p.x, a.y), p, Vec2(a.x, p.y)]
        let e = make(.polyline(cloud(pts)))
        c.perform("Revcloud") { $0.add(e) }
        finish()
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        guard let a = corner, abs(a.x - cursor.x) > 1e-9, abs(a.y - cursor.y) > 1e-9 else { return [] }
        return [make(.polyline(cloud([a, Vec2(cursor.x, a.y), cursor, Vec2(a.x, cursor.y)])))]
    }
}

// MARK: - HATCH

final class HatchCommand: CadCommand {
    static var pattern: HatchPatternKind = .lines
    static var patternName = "ANSI31"
    static var spacing = 3.175
    static var angle = 0.0

    private var created = 0

    override func start() { promptPick() }

    private func promptPick() {
        ask("Pick internal point", keywords: ["Select objects", "Pattern", "sCale", "Angle"])
    }

    override func keyword(_ k: String) {
        switch k {
        case "Select objects": ask("Select closed objects", .selection)
        case "Pattern": ask("Enter pattern name [SOLID/ANSI31/ANSI37] <\(HatchCommand.patternName)>", .text)
        case "sCale": ask("Specify spacing <\(fmt(HatchCommand.spacing))>", .text)
        case "Angle": ask("Specify angle <\(fmt(degrees(HatchCommand.angle)))>", .text)
        default: break
        }
    }

    private var lastAsked: String { prompt }

    override func value(_ s: String) -> Bool {
        if prompt.hasPrefix("Enter pattern") {
            switch s.uppercased() {
            case "SOLID": HatchCommand.pattern = .solid
            case "ANSI31", "LINE", "LINES": HatchCommand.pattern = .lines
            case "ANSI37", "NET", "CROSS": HatchCommand.pattern = .cross
            default: return false
            }
            HatchCommand.patternName = s.uppercased()
        } else if prompt.hasPrefix("Specify spacing") {
            guard let v = Double(s), v > 0 else { return false }
            HatchCommand.spacing = v
        } else if prompt.hasPrefix("Specify angle") {
            guard let v = Double(s) else { return false }
            HatchCommand.angle = radians(v)
        } else {
            return false
        }
        promptPick()
        return true
    }

    override func enter() {
        if input == .text { promptPick(); return }
        finish()
    }

    private func create(_ loops: [[PolyVertex]]) {
        var h = HatchGeom(loops: loops, pattern: HatchCommand.pattern, patternName: HatchCommand.patternName,
                          angle: HatchCommand.angle + (HatchCommand.pattern == .lines ? .pi / 4 : 0), spacing: HatchCommand.spacing)
        if h.pattern == .solid { h.patternName = "SOLID" }
        let e = make(.hatch(h))
        c.perform("Hatch") { $0.add(e) }
        created += 1
    }

    override func point(_ p: Vec2) {
        guard let loop = drawing.boundary(around: p, using: nil) else {
            c.message("Valid hatch boundary not found.")
            return
        }
        create([loop])
        promptPick()
    }

    override func selectionDone(_ ids: Set<EntityID>) {
        var loops: [[PolyVertex]] = []
        for id in ids {
            guard let e = drawing.entity(id) else { continue }
            switch e.kind {
            case .polyline(let p) where p.closed: loops.append(p.vertices)
            case .circle(let ci):
                loops.append([PolyVertex(ci.center - Vec2(ci.radius, 0), bulge: 1), PolyVertex(ci.center + Vec2(ci.radius, 0), bulge: 1)])
            case .ellipse(let el) where el.isFull:
                loops.append(ellipsePoints(el, segments: 72).dropLast().map { PolyVertex($0) })
            case .spline(let s) where s.closed:
                loops.append(splinePoints(s).dropLast().map { PolyVertex($0) })
            default: break
            }
        }
        if loops.isEmpty { c.message("No closed objects selected") } else { create(loops) }
        c.selection.removeAll()
        promptPick()
    }
}

// MARK: - TEXT

final class TextCommand: CadCommand {
    private var position: Vec2?
    private var height: Double = 2.5
    private var rotation = 0.0
    private var lineIndex = 0
    private var hAlign = TextHAlign.left
    private var vAlign = TextVAlign.baseline

    override func start() {
        height = drawing.settings.textHeight
        ask("Specify start point of text", keywords: ["Justify"])
    }

    override func keyword(_ k: String) {
        switch k {
        case "Justify": ask("Enter justification [Left/Center/Right/Middle/TL/TC/TR/ML/MC/MR/BL/BC/BR]", .text)
        default: break
        }
    }

    override func point(_ p: Vec2) {
        if position == nil {
            position = p
            ask("Specify height <\(fmt(height))>", base: p)
        } else if prompt.hasPrefix("Specify height") {
            height = max(1e-6, position!.distance(to: p))
            c.perform("Text height") { $0.settings.textHeight = height }
            ask("Specify rotation angle of text <\(fmt(degrees(rotation)))>", base: position)
        } else if prompt.hasPrefix("Specify rotation") {
            rotation = (p - position!).angle
            askText()
        }
    }

    private func askText() {
        allowsSpaces = true
        ask("Enter text", .text)
    }

    override func value(_ s: String) -> Bool {
        if prompt.hasPrefix("Enter justification") {
            let map: [String: (TextHAlign, TextVAlign)] = [
                "L": (.left, .baseline), "LEFT": (.left, .baseline), "C": (.center, .baseline), "CENTER": (.center, .baseline),
                "R": (.right, .baseline), "RIGHT": (.right, .baseline), "M": (.center, .middle), "MIDDLE": (.center, .middle),
                "TL": (.left, .top), "TC": (.center, .top), "TR": (.right, .top),
                "ML": (.left, .middle), "MC": (.center, .middle), "MR": (.right, .middle),
                "BL": (.left, .bottom), "BC": (.center, .bottom), "BR": (.right, .bottom),
            ]
            guard let j = map[s.uppercased()] else { return false }
            (hAlign, vAlign) = j
            ask("Specify start point of text")
            return true
        }
        if prompt.hasPrefix("Specify height") {
            guard let v = Double(s), v > 0 else { return false }
            height = v
            c.perform("Text height") { $0.settings.textHeight = v }
            ask("Specify rotation angle of text <\(fmt(degrees(rotation)))>", base: position)
            return true
        }
        if prompt.hasPrefix("Specify rotation") {
            guard let v = Double(s) else { return false }
            rotation = radians(v)
            askText()
            return true
        }
        if input == .text, let pos = position {
            // Each line is its own TEXT entity, stacked downward.
            let offset = Vec2(0, -height * textLineSpacing * Double(lineIndex)).rotated(by: rotation)
            let e = make(.text(TextGeom(position: pos + offset, height: height, text: s, rotation: rotation, hAlign: hAlign, vAlign: vAlign, style: drawing.settings.textStyle, font: drawing.settings.textFont)))
            c.perform("Text") { $0.add(e) }
            lineIndex += 1
            askText()
            return true
        }
        return false
    }

    override func enter() {
        if prompt.hasPrefix("Specify height") { ask("Specify rotation angle of text <\(fmt(degrees(rotation)))>", base: position); return }
        if prompt.hasPrefix("Specify rotation") { askText(); return }
        finish()
    }
}

// MARK: - MTEXT

final class MTextCommand: CadCommand {
    private var corner: Vec2?

    override func start() { ask("Specify first corner") }

    override func point(_ p: Vec2) {
        guard let a = corner else {
            corner = p
            ask("Specify opposite corner", base: p)
            return
        }
        let topLeft = Vec2(min(a.x, p.x), max(a.y, p.y))
        let width = abs(p.x - a.x)
        let height = drawing.settings.textHeight
        let st = drawing.settings.textStyle
        let ft = drawing.settings.textFont
        ask("Enter text in the editor", .text)
        c.delegate?.runModal(.mtext(initial: "") { [weak self] text in
            guard let self else { return }
            if let text, !text.isEmpty {
                let e = self.make(.text(TextGeom(position: topLeft, height: height, text: text, hAlign: .left, vAlign: .top,
                                                 isMultiline: true, width: width, style: st, font: ft)))
                self.c.perform("MText") { $0.add(e) }
            }
            self.finish()
        })
    }

    override func preview(_ cursor: Vec2) -> [Entity] {
        guard let a = corner else { return [] }
        return [make(.polyline(PolylineGeom(points: [a, Vec2(cursor.x, a.y), cursor, Vec2(a.x, cursor.y)], closed: true)))]
    }
}
