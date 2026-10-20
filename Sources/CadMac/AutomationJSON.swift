import Foundation
import CadCore

/// JSON <-> model conversion for the Claude automation tools (plain `[String: Any]` values).
enum AutomationJSON {
    struct InputError: Error, CustomStringConvertible {
        let description: String
        init(_ s: String) { description = s }
    }

    static let maxEntitiesPerCall = 20_000

    // MARK: Output helpers

    /// Number for JSON output, rounded to 6 decimals (decimal, so it prints without float noise).
    static func num(_ v: Double) -> NSNumber {
        guard v.isFinite else { return 0 }
        return NSDecimalNumber(string: fmt(v, precision: 6))
    }
    static func pt(_ p: Vec2) -> [NSNumber] { [num(p.x), num(p.y)] }
    static func box(_ b: BBox) -> [NSNumber]? { b.isEmpty ? nil : [num(b.min.x), num(b.min.y), num(b.max.x), num(b.max.y)] }
    static func deg(_ r: Double) -> NSNumber { num(degrees(r)) }

    static func color(_ c: CadColor) -> Any {
        switch c {
        case .byLayer: return "ByLayer"
        case .byBlock: return "ByBlock"
        case .aci(let i): return i
        case .rgb(let c): return String(format: "#%02x%02x%02x", c.r, c.g, c.b)
        }
    }

    static func string(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return "\(obj)" }
        return s
    }

    static func polylineLength(_ verts: [PolyVertex], closed: Bool) -> Double {
        guard verts.count >= 2 else { return 0 }
        let n = closed ? verts.count : verts.count - 1
        var total = 0.0
        for i in 0..<n {
            total += bulgeSegment(verts[i].point, verts[(i + 1) % verts.count].point, bulge: verts[i].bulge).length
        }
        return total
    }

    /// Area-weighted centroid of a closed loop (tessellated).
    static func centroid(_ loop: [PolyVertex]) -> Vec2 {
        let pts = loopPoints(loop, closed: true)
        guard pts.count >= 3 else { return pts.first ?? .zero }
        var a = 0.0, cx = 0.0, cy = 0.0
        for i in pts.indices {
            let p = pts[i], q = pts[(i + 1) % pts.count]
            let c = p.cross(q)
            a += c; cx += (p.x + q.x) * c; cy += (p.y + q.y) * c
        }
        if abs(a) < 1e-15 { return BBox(points: pts).center }
        return Vec2(cx / (3 * a), cy / (3 * a))
    }

    private static let maxListedVertices = 100

    /// Compact JSON description of an entity for Claude.
    static func describe(_ e: Entity, in d: Drawing) -> [String: Any] {
        var o: [String: Any] = ["id": e.id.uuidString, "type": e.kind.typeName, "layer": e.layer, "color": color(e.color)]
        if e.linetype.caseInsensitiveCompare("ByLayer") != .orderedSame { o["linetype"] = e.linetype }
        switch e.kind {
        case .line(let l):
            o["start"] = pt(l.start); o["end"] = pt(l.end)
            o["length"] = num(l.length); o["angle"] = num(normalizeAngle((l.end - l.start).angle) * 180 / .pi)
        case .circle(let c):
            o["center"] = pt(c.center); o["radius"] = num(c.radius)
        case .arc(let a):
            o["center"] = pt(a.center); o["radius"] = num(a.radius)
            o["start_angle"] = deg(a.startAngle); o["end_angle"] = deg(a.endAngle)
            o["start_point"] = pt(a.startPoint); o["end_point"] = pt(a.endPoint); o["length"] = num(a.length)
        case .polyline(let p):
            o["closed"] = p.closed
            o["vertex_count"] = p.vertices.count
            o["vertices"] = p.vertices.prefix(maxListedVertices).map { pt($0.point) }
            if p.vertices.count > maxListedVertices { o["vertices_truncated"] = true }
            if p.vertices.contains(where: { abs($0.bulge) > 1e-12 }) { o["bulges"] = p.vertices.prefix(maxListedVertices).map { num($0.bulge) } }
            if p.width > 0 { o["width"] = num(p.width) }
            o["length"] = num(polylineLength(p.vertices, closed: p.closed))
            if p.closed, p.vertices.count >= 2 { o["area"] = num(abs(polygonArea(p.vertices))) }
        case .ellipse(let el):
            o["center"] = pt(el.center); o["major_axis"] = pt(el.majorAxis); o["ratio"] = num(el.ratio)
            if !el.isFull { o["start_param"] = deg(el.startParam); o["end_param"] = deg(el.endParam) }
        case .text(let t):
            o["text"] = t.text.count > 2000 ? String(t.text.prefix(2000)) + "…" : t.text
            o["position"] = pt(t.position); o["height"] = num(t.height)
            if abs(t.rotation) > 1e-12 { o["rotation"] = deg(t.rotation) }
            o["align"] = "\(t.hAlign)"; o["valign"] = "\(t.vAlign)"
            if t.isMultiline && t.width > 0 { o["width"] = num(t.width) }
        case .point(let p):
            o["position"] = pt(p.position)
        case .dimension(let dm):
            o["kind"] = dm.kind.rawValue
            o["p1"] = pt(dm.p1); o["p2"] = pt(dm.p2); o["p3"] = pt(dm.p3)
            if dm.kind == .angular { o["p4"] = pt(dm.p4) }
            o["measurement"] = num(dm.measurement)
            o["text"] = dm.textOverride.isEmpty ? d.settings.dimStyle.format(dm.measurement, kind: dm.kind)
                                                : dm.textOverride.replacingOccurrences(of: "<>", with: d.settings.dimStyle.format(dm.measurement, kind: dm.kind))
        case .insert(let i):
            o["block"] = i.blockName; o["position"] = pt(i.position)
            if i.scaleX != 1 || i.scaleY != 1 { o["scale"] = [num(i.scaleX), num(i.scaleY)] }
            if abs(i.rotation) > 1e-12 { o["rotation"] = deg(i.rotation) }
            if !i.attributes.isEmpty {
                var attrs: [String: String] = [:]
                for a in i.attributes { attrs[a.tag] = a.value }
                o["attributes"] = attrs
            }
        case .hatch(let h):
            o["pattern"] = h.patternName
            o["loop_count"] = h.loops.count
            if let first = h.loops.first { o["outline"] = first.prefix(maxListedVertices).map { pt($0.point) } }
        case .spline(let s):
            o["closed"] = s.closed; o["degree"] = s.degree
            if !s.fitPoints.isEmpty { o["fit_points"] = s.fitPoints.prefix(maxListedVertices).map(pt) }
            else { o["control_points"] = s.controlPoints.prefix(maxListedVertices).map(pt) }
        case .viewport(let v):
            o["center"] = pt(v.center); o["width"] = num(v.width); o["height"] = num(v.height)
            o["view_center"] = pt(v.viewCenter); o["scale"] = num(v.scale)
        case .attdef(let a):
            o["tag"] = a.tag; o["prompt"] = a.prompt; o["default"] = a.defaultValue; o["position"] = pt(a.text.position)
        }
        if let b = box(d.bbox(of: e)) { o["bbox"] = b }
        return o
    }

    /// Normalized type key used for filtering ("Block Reference" -> "insert").
    static func typeKey(_ k: EntityKind) -> String {
        switch k {
        case .line: return "line"
        case .circle: return "circle"
        case .arc: return "arc"
        case .polyline: return "polyline"
        case .ellipse: return "ellipse"
        case .text(let t): return t.isMultiline ? "mtext" : "text"
        case .point: return "point"
        case .dimension: return "dimension"
        case .insert: return "insert"
        case .hatch: return "hatch"
        case .spline: return "spline"
        case .viewport: return "viewport"
        case .attdef: return "attdef"
        }
    }

    static func normalizeTypeFilter(_ s: String) -> String {
        let t = s.lowercased().filter { $0.isLetter }
        switch t {
        case "lwpolyline", "pline", "polylines": return "polyline"
        case "blockreference", "block", "blockref", "inserts": return "insert"
        case "dim", "dimensions": return "dimension"
        case "attributedefinition": return "attdef"
        case "lines": return "line"
        case "circles": return "circle"
        case "arcs": return "arc"
        case "texts", "dtext": return "text"
        default: return t
        }
    }

    // MARK: Input parsing

    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue.isFinite ? n.doubleValue : nil }
        if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite { return d }
        return nil
    }

    static func point(_ v: Any?) -> Vec2? {
        if let a = v as? [Any], a.count >= 2, let x = double(a[0]), let y = double(a[1]) { return Vec2(x, y) }
        if let o = v as? [String: Any], let x = double(o["x"]), let y = double(o["y"]) { return Vec2(x, y) }
        if let s = v as? String {
            let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2, let x = Double(parts[0]), let y = Double(parts[1]), x.isFinite, y.isFinite { return Vec2(x, y) }
        }
        return nil
    }

    static func requirePoint(_ o: [String: Any], _ key: String, _ ctx: String) throws -> Vec2 {
        guard let p = point(o[key]) else { throw InputError("\(ctx): '\(key)' must be a point [x, y]") }
        return p
    }

    static func requireDouble(_ o: [String: Any], _ key: String, _ ctx: String) throws -> Double {
        guard let v = double(o[key]) else { throw InputError("\(ctx): '\(key)' must be a number") }
        return v
    }

    static func bbox(_ v: Any?) -> BBox? {
        if let a = v as? [Any], a.count == 4, let x1 = double(a[0]), let y1 = double(a[1]), let x2 = double(a[2]), let y2 = double(a[3]) {
            return BBox(corner: Vec2(x1, y1), Vec2(x2, y2))
        }
        if let o = v as? [String: Any], let a = point(o["min"]), let b = point(o["max"]) { return BBox(corner: a, b) }
        return nil
    }

    static func parseColor(_ v: Any?) throws -> CadColor? {
        guard let v, !(v is NSNull) else { return nil }
        if let n = double(v), !(v is String) {
            let i = Int(n)
            switch i {
            case 0: return .byBlock
            case 256: return .byLayer
            case 1...255: return .aci(i)
            default: throw InputError("color index must be 0...256")
            }
        }
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces).lowercased() else { throw InputError("invalid color") }
        if s.hasPrefix("#"), s.count == 7, let packed = Int(s.dropFirst(), radix: 16) { return .rgb(RGB(packed: packed)) }
        if let i = Int(s) { return try parseColor(NSNumber(value: i)) }
        let names: [String: CadColor] = ["bylayer": .byLayer, "byblock": .byBlock, "red": .aci(1), "yellow": .aci(2), "green": .aci(3),
                                         "cyan": .aci(4), "blue": .aci(5), "magenta": .aci(6), "white": .aci(7), "black": .aci(7),
                                         "gray": .aci(8), "grey": .aci(8), "lightgray": .aci(9), "lightgrey": .aci(9)]
        if let c = names[s.replacingOccurrences(of: " ", with: "")] { return c }
        throw InputError("invalid color \"\(s)\" (use an ACI index 1-255, \"#rrggbb\", ByLayer or a basic color name)")
    }

    /// Layer color must be a concrete color.
    static func parseLayerColor(_ v: Any?) throws -> CadColor? {
        guard let c = try parseColor(v) else { return nil }
        switch c {
        case .byLayer, .byBlock: throw InputError("a layer color must be an ACI index or #rrggbb")
        default: return c
        }
    }

    static func validLayerName(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.count <= 255 && !t.contains(where: { "<>/\\\":;?*|=`".contains($0) || $0.isNewline })
    }

    /// Builds an entity from Claude's simple JSON schema. `d` supplies defaults (current layer, text height).
    static func entity(from o: [String: Any], index: Int, in d: Drawing) throws -> Entity {
        guard let rawType = o["type"] as? String else { throw InputError("entities[\(index)]: missing 'type'") }
        let type = rawType.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        let ctx = "entities[\(index)] (\(type))"
        let st = d.settings
        let kind: EntityKind
        switch type {
        case "line":
            kind = .line(LineGeom(start: try requirePoint(o, "start", ctx), end: try requirePoint(o, "end", ctx)))
        case "polyline", "pline", "lwpolyline":
            guard let arr = o["points"] as? [Any] ?? o["vertices"] as? [Any] else { throw InputError("\(ctx): 'points' must be an array of [x, y]") }
            let pts = try arr.enumerated().map { i, v -> Vec2 in
                guard let p = point(v) else { throw InputError("\(ctx): points[\(i)] is not [x, y]") }
                return p
            }
            guard pts.count >= 2 else { throw InputError("\(ctx): needs at least 2 points") }
            guard pts.count <= 100_000 else { throw InputError("\(ctx): too many points") }
            let bulges = (o["bulges"] as? [Any])?.map { double($0) ?? 0 } ?? []
            let verts = pts.enumerated().map { i, p in PolyVertex(p, bulge: i < bulges.count ? bulges[i] : 0) }
            kind = .polyline(PolylineGeom(vertices: verts, closed: o["closed"] as? Bool ?? false, width: max(0, double(o["width"]) ?? 0)))
        case "rectangle", "rect", "rectang":
            let a: Vec2, b: Vec2
            if let c1 = point(o["corner1"]), let c2 = point(o["corner2"]) { a = c1; b = c2 }
            else if let c1 = point(o["origin"] ?? o["corner"]), let w = double(o["width"]), let h = double(o["height"]) { a = c1; b = c1 + Vec2(w, h) }
            else { throw InputError("\(ctx): needs 'corner1' and 'corner2' (or 'origin', 'width', 'height')") }
            guard abs(a.x - b.x) > geomEps, abs(a.y - b.y) > geomEps else { throw InputError("\(ctx): zero-size rectangle") }
            kind = .polyline(PolylineGeom(points: [a, Vec2(b.x, a.y), b, Vec2(a.x, b.y)], closed: true))
        case "circle":
            let r = try requireDouble(o, "radius", ctx)
            guard r > 0 else { throw InputError("\(ctx): radius must be > 0") }
            kind = .circle(CircleGeom(center: try requirePoint(o, "center", ctx), radius: r))
        case "arc":
            let r = try requireDouble(o, "radius", ctx)
            guard r > 0 else { throw InputError("\(ctx): radius must be > 0") }
            kind = .arc(ArcGeom(center: try requirePoint(o, "center", ctx), radius: r,
                                startAngle: radians(try requireDouble(o, "start_angle", ctx)), endAngle: radians(try requireDouble(o, "end_angle", ctx))))
        case "text", "mtext":
            guard let text = o["text"] as? String ?? (o["content"] as? String), !text.isEmpty else { throw InputError("\(ctx): 'text' is required") }
            guard text.count <= 100_000 else { throw InputError("\(ctx): text too long") }
            let h = double(o["height"]) ?? st.textHeight
            guard h > 0 else { throw InputError("\(ctx): height must be > 0") }
            let multi = type == "mtext"
            let hAlign: TextHAlign = ["center": .center, "middle": .center, "right": .right][(o["align"] as? String ?? "").lowercased()] ?? .left
            let vDefault: TextVAlign = multi ? .top : .baseline
            let vAlign: TextVAlign = ["baseline": .baseline, "bottom": .bottom, "middle": .middle, "center": .middle, "top": .top][(o["valign"] as? String ?? "").lowercased()] ?? vDefault
            kind = .text(TextGeom(position: try requirePoint(o, "position", ctx), height: h,
                                  text: multi ? text : text.replacingOccurrences(of: "\n", with: " "),
                                  rotation: radians(double(o["rotation"]) ?? 0), hAlign: hAlign, vAlign: vAlign,
                                  isMultiline: multi, width: multi ? max(0, double(o["width"]) ?? 0) : 0, style: st.textStyle))
        case "point":
            kind = .point(PointGeom(position: try requirePoint(o, "position", ctx)))
        case "dimension_linear", "dimension_aligned", "dimlinear", "dimaligned":
            let p1 = try requirePoint(o, "p1", ctx), p2 = try requirePoint(o, "p2", ctx)
            guard let p3 = point(o["dim_line_point"] ?? o["p3"]) else { throw InputError("\(ctx): 'dim_line_point' must be a point [x, y]") }
            if type.hasSuffix("aligned") {
                kind = .dimension(DimensionGeom(kind: .aligned, p1: p1, p2: p2, p3: p3))
            } else {
                let dir = (o["direction"] as? String ?? "auto").lowercased()
                var rot: Double
                switch dir {
                case "horizontal", "h": rot = 0
                case "vertical", "v": rot = .pi / 2
                default:
                    let lo = Vec2(min(p1.x, p2.x), min(p1.y, p2.y)), hi = Vec2(max(p1.x, p2.x), max(p1.y, p2.y))
                    if p3.y > hi.y || p3.y < lo.y { rot = 0 }
                    else if p3.x > hi.x || p3.x < lo.x { rot = .pi / 2 }
                    else { rot = abs(p2.x - p1.x) >= abs(p2.y - p1.y) ? 0 : .pi / 2 }
                }
                if let r = double(o["rotation"]) { rot = radians(r) }
                kind = .dimension(DimensionGeom(kind: .linear, p1: p1, p2: p2, p3: p3, rotation: rot))
            }
        case "hatch_solid", "hatch", "solid":
            var loop: [PolyVertex]
            if let arr = o["points"] as? [Any] {
                let pts = try arr.enumerated().map { i, v -> Vec2 in
                    guard let p = point(v) else { throw InputError("\(ctx): points[\(i)] is not [x, y]") }
                    return p
                }
                guard pts.count >= 3 else { throw InputError("\(ctx): needs at least 3 boundary points") }
                loop = pts.map { PolyVertex($0) }
            } else if let bp = point(o["boundary_point"]) {
                guard let l = d.boundary(around: bp, using: nil) else { throw InputError("\(ctx): no closed boundary found around \(bp)") }
                loop = l
            } else {
                throw InputError("\(ctx): needs 'points' or 'boundary_point'")
            }
            if loop.count > 1, loop.first!.point.isClose(to: loop.last!.point) { loop.removeLast() }
            kind = .hatch(HatchGeom(loops: [loop], pattern: .solid, patternName: "SOLID"))
        default:
            throw InputError("\(ctx): unknown type '\(rawType)'. Use line, polyline, rectangle, circle, arc, text, mtext, point, dimension_linear, dimension_aligned or hatch_solid")
        }
        var layer = st.currentLayer
        if let l = o["layer"] as? String {
            guard validLayerName(l) else { throw InputError("\(ctx): invalid layer name '\(l)'") }
            layer = d.layer(named: l)?.name ?? l.trimmingCharacters(in: .whitespaces)
        }
        let color = try parseColor(o["color"]) ?? st.currentColor
        var e = Entity(kind, layer: layer, color: color, linetype: st.currentLinetype, lineweight: st.currentLineweight)
        if let lt = o["linetype"] as? String { e.linetype = lt }
        return e
    }
}
