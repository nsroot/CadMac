import AppKit
import CadCore

/// Drawable piece of an entity with the (insert-resolved) properties that style it.
struct ScenePart {
    var layer: String
    var color: CadColor
    var linetype: String
    var lineweight: Double
    var width: Double = 0
    var strokes: [Prim] = []
    /// Polygons filled together with the even-odd rule (one solid hatch or arrowheads).
    var fills: [[Vec2]] = []
    var texts: [TextGeom] = []
    var points: [Vec2] = []
}

/// Geometry of one drawing entity, computed once per entity change.
final class SceneItem {
    let entity: Entity
    let bbox: BBox
    /// World-space curves used for picking, snapping and highlight.
    let prims: [Prim]
    /// Regions where a click counts as a hit (text boxes, hatch interiors).
    let areas: [[Vec2]]
    let parts: [ScenePart]
    private(set) lazy var outline: CGPath = makeWorldPath(prims)

    init(_ e: Entity, in d: Drawing) {
        entity = e
        var parts: [ScenePart] = []
        var prims: [Prim] = []
        var areas: [[Vec2]] = []
        SceneItem.collect(e, d, depth: 0, parts: &parts, prims: &prims, areas: &areas)
        self.parts = parts
        self.prims = prims
        self.areas = areas
        var b = prims.reduce(BBox.empty) { $0.union($1.bbox) }
        for a in areas { b = b.union(BBox(points: a)) }
        for p in parts { for pt in p.points { b = b.union(BBox(corner: pt, pt)) } }
        bbox = b
    }

    private static func collect(_ e: Entity, _ d: Drawing, depth: Int, parts: inout [ScenePart], prims: inout [Prim], areas: inout [[Vec2]]) {
        var part = ScenePart(layer: e.layer, color: e.color, linetype: e.linetype, lineweight: e.lineweight)
        switch e.kind {
        case .insert:
            guard depth < 16 else { return }
            for child in d.expandInsert(e) { collect(child, d, depth: depth + 1, parts: &parts, prims: &prims, areas: &areas) }
            return
        case .point(let p):
            part.points = [p.position]
            prims.append(.seg(p.position, p.position))
        case .attdef(let a):
            let t = a.displayText
            part.texts = [t]
            let c = textCorners(t)
            areas.append(c)
            prims += zip(c, c.dropFirst() + [c[0]]).map { Prim.seg($0.0, $0.1) }
        case .text(let t):
            part.texts = [t]
            let c = textCorners(t)
            areas.append(c)
            prims += zip(c, c.dropFirst() + [c[0]]).map { Prim.seg($0.0, $0.1) }
        case .dimension(let dm):
            let g = dimensionGraphics(dm, style: d.settings.dimStyle)
            part.strokes = g.prims
            part.fills = g.arrows
            part.texts = [g.text]
            prims += g.prims
            areas.append(textCorners(g.text))
        case .hatch(let h):
            let loops = h.loops.map { loopPoints($0) }
            if h.pattern == .solid { part.fills = loops } else { part.strokes = hatchPatternLines(h) }
            areas += loops
            prims += h.loops.flatMap { d.prims(of: Entity(.polyline(PolylineGeom(vertices: $0, closed: true)))) }
        case .polyline(let p):
            part.width = p.width
            part.strokes = d.prims(of: e)
            prims += part.strokes
        default:
            part.strokes = d.prims(of: e)
            prims += part.strokes
        }
        parts.append(part)
    }
}

/// Builds a CGPath in world coordinates (y up) from primitives.
func makeWorldPath(_ prims: [Prim]) -> CGPath {
    let path = CGMutablePath()
    appendWorld(prims, to: path)
    return path
}

func appendWorld(_ prims: [Prim], to path: CGMutablePath) {
    var last: Vec2?
    for p in prims {
        let s = p.startPoint
        if last == nil || last!.distance(to: s) > 1e-9 { path.move(to: CGPoint(x: s.x, y: s.y)) }
        switch p {
        case let .seg(_, b):
            if b.isClose(to: s, tol: 1e-12) { path.addLine(to: CGPoint(x: s.x + 1e-9, y: s.y)) } else { path.addLine(to: CGPoint(x: b.x, y: b.y)) }
            last = b
        case let .arc(c, r, st, sw):
            path.addArc(center: CGPoint(x: c.x, y: c.y), radius: r, startAngle: st, endAngle: st + sw, clockwise: false)
            last = p.endPoint
        }
    }
}

/// Resolved stroke style shared by many entities.
struct StyleKey: Hashable {
    var color: CadColor
    var linetype: String
    var lineweight: Double
    var width: Double
}

/// Merged stroke geometry for one style within one spatial tile.
final class StrokeBatch {
    let style: StyleKey
    let path: CGPath
    let bbox: BBox
    /// Source primitives, used for decimated drawing when zoomed far out.
    let prims: [Prim]
    init(style: StyleKey, path: CGPath, bbox: BBox, prims: [Prim]) {
        self.style = style; self.path = path; self.bbox = bbox; self.prims = prims
    }
}

struct FillItem { var color: CadColor; var path: CGPath; var bbox: BBox }
struct TextItem { var color: CadColor; var text: TextGeom; var bbox: BBox }
struct PointItem { var color: CadColor; var point: Vec2 }

/// Immutable render/pick index for one drawing version. Safe to read from a render thread.
final class Scene {
    let version: Int
    let items: [SceneItem]
    let byID: [EntityID: SceneItem]
    let visible: [Bool]
    let strokes: [StrokeBatch]
    let fills: [FillItem]
    let texts: [TextItem]
    let points: [PointItem]
    let linetypes: [String: Linetype]
    let ltScale: Double
    let extents: BBox
    private let blocks: [String: BlockDef]
    private let dimStyle: DimStyle
    private let grid: SpatialGrid

    /// `hidden`: entities temporarily hidden from view (ISOLATEOBJECTS / HIDEOBJECTS).
    init(drawing d: Drawing, version: Int, previous: Scene?, hidden: Set<EntityID> = []) {
        self.version = version
        blocks = d.blocks
        dimStyle = d.settings.dimStyle
        ltScale = d.settings.ltScale
        let reuse = previous.map { $0.blocks == d.blocks && $0.dimStyle == d.settings.dimStyle } ?? false
        var items: [SceneItem] = []
        items.reserveCapacity(d.entities.count)
        for e in d.entities {
            if reuse, let old = previous?.byID[e.id], old.entity == e { items.append(old) } else { items.append(SceneItem(e, in: d)) }
        }
        self.items = items
        var byID: [EntityID: SceneItem] = [:]
        byID.reserveCapacity(items.count)
        for it in items { byID[it.entity.id] = it }
        self.byID = byID

        var layers: [String: Layer] = [:]
        for l in d.layers { layers[l.name.lowercased()] = l }
        var lts: [String: Linetype] = [:]
        for l in d.linetypes { lts[l.name.lowercased()] = l }
        linetypes = lts
        func layerVisible(_ n: String) -> Bool { layers[n.lowercased()]?.isVisible ?? true }
        visible = items.map { layerVisible($0.entity.layer) && !hidden.contains($0.entity.id) }

        var ext = BBox.empty
        for (i, it) in items.enumerated() where visible[i] { ext = ext.union(it.bbox) }
        extents = ext
        grid = SpatialGrid(items: items, extents: ext)

        // Group strokes by style and coarse tile so off-screen batches can be skipped.
        let tiles = 12.0
        let tileW = max(ext.width, 1e-9) / tiles, tileH = max(ext.height, 1e-9) / tiles
        struct BatchKey: Hashable { var style: StyleKey; var tx: Int; var ty: Int }
        // Core Graphics rasterizes very large single paths super-linearly, so batches are capped.
        let maxPrimsPerBatch = 1500
        var paths: [BatchKey: (CGMutablePath, BBox, [Prim])] = [:]
        var full: [StrokeBatch] = []
        var fills: [FillItem] = []
        var texts: [TextItem] = []
        var points: [PointItem] = []
        for (i, it) in items.enumerated() where visible[i] {
            for part in it.parts where layerVisible(part.layer) {
                var color = part.color
                if color == .byLayer || color == .byBlock { color = layers[part.layer.lowercased()]?.color ?? .aci(7) }
                var lt = part.linetype
                if lt.caseInsensitiveCompare("ByLayer") == .orderedSame || lt.caseInsensitiveCompare("ByBlock") == .orderedSame {
                    lt = layers[part.layer.lowercased()]?.linetype ?? "Continuous"
                }
                var lw = part.lineweight
                if lw < 0 { lw = layers[part.layer.lowercased()]?.lineweight ?? -1 }
                if lw < 0 { lw = 0.25 }
                if !part.strokes.isEmpty {
                    let style = StyleKey(color: color, linetype: lt.lowercased(), lineweight: lw, width: part.width)
                    let c = it.bbox.center
                    let key = BatchKey(style: style, tx: Int(((c.x - ext.min.x) / tileW).rounded(.down)), ty: Int(((c.y - ext.min.y) / tileH).rounded(.down)))
                    var start = 0
                    while start < part.strokes.count {
                        var entry = paths[key] ?? (CGMutablePath(), .empty, [])
                        let take = min(part.strokes.count - start, max(1, maxPrimsPerBatch - entry.2.count))
                        let slice = Array(part.strokes[start..<(start + take)])
                        appendWorld(slice, to: entry.0)
                        entry.1 = entry.1.union(slice.reduce(BBox.empty) { $0.union($1.bbox) })
                        entry.2 += slice
                        start += take
                        if entry.2.count >= maxPrimsPerBatch {
                            full.append(StrokeBatch(style: style, path: entry.0, bbox: entry.1, prims: entry.2))
                            paths[key] = nil
                        } else {
                            paths[key] = entry
                        }
                    }
                }
                if !part.fills.isEmpty {
                    let p = CGMutablePath()
                    for poly in part.fills where poly.count >= 3 {
                        p.addLines(between: poly.map { CGPoint(x: $0.x, y: $0.y) })
                        p.closeSubpath()
                    }
                    fills.append(FillItem(color: color, path: p, bbox: it.bbox))
                }
                for t in part.texts { texts.append(TextItem(color: color, text: t, bbox: BBox(points: textCorners(t)))) }
                for pt in part.points { points.append(PointItem(color: color, point: pt)) }
            }
        }
        strokes = full + paths.map { StrokeBatch(style: $0.key.style, path: $0.value.0, bbox: $0.value.1, prims: $0.value.2) }
        self.fills = fills
        self.texts = texts
        self.points = points
    }

    // MARK: Queries

    /// Indices of visible items whose bbox intersects `box`.
    func query(_ box: BBox) -> [Int] {
        grid.query(box).filter { visible[$0] && items[$0].bbox.intersects(box) }
    }

    func distance(from p: Vec2, to it: SceneItem) -> Double {
        for a in it.areas where pointInPolygon(p, a) { return 0 }
        var best = Double.infinity
        for pr in it.prims { best = min(best, pr.distance(to: p)) }
        return best
    }

    /// Topmost visible entity within `tol` of `p`.
    func pick(at p: Vec2, tolerance tol: Double) -> EntityID? {
        let box = BBox(corner: p, p).expanded(by: tol)
        var best: (Int, Double)?
        for i in query(box) {
            let d = distance(from: p, to: items[i])
            // Prefer later (drawn on top) items on ties.
            if d <= tol, best == nil || d < best!.1 || (d == best!.1 && i > best!.0) { best = (i, d) }
        }
        return best.map { items[$0.0].entity.id }
    }

    /// Window (inside) or crossing selection.
    func select(window box: BBox, crossing: Bool) -> [EntityID] {
        var out: [EntityID] = []
        for i in query(box) {
            let it = items[i]
            if box.contains(it.bbox) { out.append(it.entity.id); continue }
            guard crossing else { continue }
            if it.prims.contains(where: { $0.intersects(box: box) }) || it.areas.contains(where: { a in box.corners.contains { pointInPolygon($0, a) } }) {
                out.append(it.entity.id)
            }
        }
        return out
    }
}

/// Uniform grid over item bounding boxes for fast picking.
struct SpatialGrid {
    private var cells: [Int: [Int]] = [:]
    private var large: [Int] = []
    private let origin: Vec2
    private let cell: Double
    private let n: Int

    init(items: [SceneItem], extents: BBox) {
        n = 128
        origin = extents.isEmpty ? .zero : extents.min
        cell = extents.isEmpty ? 1 : max(max(extents.width, extents.height) / Double(n), 1e-9)
        for (i, it) in items.enumerated() where !it.bbox.isEmpty {
            let (x0, y0, x1, y1) = range(it.bbox)
            if (x1 - x0 + 1) * (y1 - y0 + 1) > 256 { large.append(i); continue }
            for x in x0...x1 { for y in y0...y1 { cells[x * 4096 + y, default: []].append(i) } }
        }
    }

    private func range(_ b: BBox) -> (Int, Int, Int, Int) {
        func c(_ v: Double, _ o: Double) -> Int { max(-1, min(n + 1, Int(((v - o) / cell).rounded(.down)))) }
        return (c(b.min.x, origin.x), c(b.min.y, origin.y), c(b.max.x, origin.x), c(b.max.y, origin.y))
    }

    func query(_ box: BBox) -> [Int] {
        let (x0, y0, x1, y1) = range(box)
        var out = large
        if (x1 - x0 + 1) * (y1 - y0 + 1) > 4096 {
            // Huge query: everything.
            var seen = Set(out)
            for v in cells.values { for i in v where seen.insert(i).inserted { out.append(i) } }
            return out
        }
        var seen = Set(out)
        for x in x0...x1 { for y in y0...y1 { if let v = cells[x * 4096 + y] { for i in v where seen.insert(i).inserted { out.append(i) } } } }
        return out
    }
}
