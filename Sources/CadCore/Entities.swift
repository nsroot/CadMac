import Foundation

public typealias EntityID = UUID

// MARK: - Geometry payloads

public struct LineGeom: Hashable, Codable {
    public var start: Vec2
    public var end: Vec2
    public init(start: Vec2, end: Vec2) { self.start = start; self.end = end }
    public var length: Double { start.distance(to: end) }
    public var midpoint: Vec2 { (start + end) / 2 }
}

public struct CircleGeom: Hashable, Codable {
    public var center: Vec2
    public var radius: Double
    public init(center: Vec2, radius: Double) { self.center = center; self.radius = radius }
}

/// Arc running counter-clockwise from startAngle to endAngle (radians).
public struct ArcGeom: Hashable, Codable {
    public var center: Vec2
    public var radius: Double
    public var startAngle: Double
    public var endAngle: Double
    public init(center: Vec2, radius: Double, startAngle: Double, endAngle: Double) {
        self.center = center; self.radius = radius
        self.startAngle = normalizeAngle(startAngle); self.endAngle = normalizeAngle(endAngle)
    }
    public var sweep: Double { ccwSweep(from: startAngle, to: endAngle) }
    public var startPoint: Vec2 { center + .polar(radius, startAngle) }
    public var endPoint: Vec2 { center + .polar(radius, endAngle) }
    public var midPoint: Vec2 { center + .polar(radius, startAngle + sweep / 2) }
    public var length: Double { radius * sweep }

    /// Arc through three points, or nil when they are collinear.
    public static func through(_ p1: Vec2, _ p2: Vec2, _ p3: Vec2) -> ArcGeom? {
        guard let (c, r) = circleThrough(p1, p2, p3) else { return nil }
        let a1 = (p1 - c).angle, a2 = (p2 - c).angle, a3 = (p3 - c).angle
        // Choose direction so that p2 lies on the arc.
        if angleOnArc(a2, start: a1, end: a3) {
            return ArcGeom(center: c, radius: r, startAngle: a1, endAngle: a3)
        }
        return ArcGeom(center: c, radius: r, startAngle: a3, endAngle: a1)
    }
}

public func circleThrough(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> (Vec2, Double)? {
    let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
    guard abs(d) > 1e-12 else { return nil }
    let a2 = a.lengthSquared, b2 = b.lengthSquared, c2 = c.lengthSquared
    let ux = (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d
    let uy = (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d
    let center = Vec2(ux, uy)
    return (center, center.distance(to: a))
}

public struct PolyVertex: Hashable, Codable {
    public var point: Vec2
    /// tan(sweep/4) of the segment that starts at this vertex; 0 = straight. Positive = CCW.
    public var bulge: Double
    public init(_ point: Vec2, bulge: Double = 0) { self.point = point; self.bulge = bulge }
}

public struct PolylineGeom: Hashable, Codable {
    public var vertices: [PolyVertex]
    public var closed: Bool
    /// Constant width (DXF code 43); 0 = hairline.
    public var width: Double
    public init(vertices: [PolyVertex], closed: Bool = false, width: Double = 0) {
        self.vertices = vertices; self.closed = closed; self.width = width
    }
    public init(points: [Vec2], closed: Bool = false) {
        self.init(vertices: points.map { PolyVertex($0) }, closed: closed)
    }
    public var segmentCount: Int { vertices.count < 2 ? 0 : (closed ? vertices.count : vertices.count - 1) }
}

/// Ellipse; `majorAxis` is the vector from center to the end of the major axis.
/// Parameters run CCW from startParam to endParam (full ellipse: 0..2pi).
public struct EllipseGeom: Hashable, Codable {
    public var center: Vec2
    public var majorAxis: Vec2
    public var ratio: Double
    public var startParam: Double
    public var endParam: Double
    public init(center: Vec2, majorAxis: Vec2, ratio: Double, startParam: Double = 0, endParam: Double = 2 * .pi) {
        self.center = center; self.majorAxis = majorAxis; self.ratio = ratio
        self.startParam = startParam; self.endParam = endParam
    }
    public var isFull: Bool { abs(ccwSweep(from: startParam, to: endParam) - 2 * .pi) < 1e-9 }
    public var minorAxis: Vec2 { majorAxis.perp * ratio }
    public func point(at t: Double) -> Vec2 { center + majorAxis * cos(t) + minorAxis * sin(t) }
}

public enum TextHAlign: Int, Codable, CaseIterable { case left = 0, center = 1, right = 2 }
public enum TextVAlign: Int, Codable, CaseIterable { case baseline = 0, bottom = 1, middle = 2, top = 3 }

public struct TextGeom: Hashable, Codable {
    public var position: Vec2
    public var height: Double
    public var rotation: Double
    public var text: String
    public var hAlign: TextHAlign
    public var vAlign: TextVAlign
    /// True for MTEXT (multi-line, top-left anchored by default).
    public var isMultiline: Bool
    /// Wrap width for MTEXT; 0 = no wrapping.
    public var width: Double
    public var style: String
    public init(position: Vec2, height: Double, text: String, rotation: Double = 0,
                hAlign: TextHAlign = .left, vAlign: TextVAlign = .baseline,
                isMultiline: Bool = false, width: Double = 0, style: String = "Standard") {
        self.position = position; self.height = height; self.text = text; self.rotation = rotation
        self.hAlign = hAlign; self.vAlign = vAlign; self.isMultiline = isMultiline; self.width = width
        self.style = style
    }
    public var lines: [String] { text.components(separatedBy: "\n") }
}

public struct PointGeom: Hashable, Codable {
    public var position: Vec2
    public init(position: Vec2) { self.position = position }
}

public enum DimensionKind: String, Codable, CaseIterable {
    case linear      // horizontal or vertical, by `rotation`
    case aligned
    case radius
    case diameter
    case angular
}

/// Dimension definition. Meaning of points by kind:
/// - linear/aligned: p1, p2 = measured points; p3 = a point on the dimension line.
/// - radius/diameter: p1 = center, p2 = point on curve, p3 = text/leader point.
/// - angular: p1 = vertex, p2 / p4 = points on the two legs, p3 = arc location.
public struct DimensionGeom: Hashable, Codable {
    public var kind: DimensionKind
    public var p1: Vec2
    public var p2: Vec2
    public var p3: Vec2
    public var p4: Vec2
    /// For linear dims: angle of the dimension line (0 = horizontal, pi/2 = vertical).
    public var rotation: Double
    /// Override text; empty = measured value. "<>" inside is replaced by the measurement.
    public var textOverride: String
    public init(kind: DimensionKind, p1: Vec2, p2: Vec2, p3: Vec2, p4: Vec2 = .zero,
                rotation: Double = 0, textOverride: String = "") {
        self.kind = kind; self.p1 = p1; self.p2 = p2; self.p3 = p3; self.p4 = p4
        self.rotation = rotation; self.textOverride = textOverride
    }

    public var measurement: Double {
        switch kind {
        case .linear:
            let dir = Vec2.polar(1, rotation)
            return abs((p2 - p1).dot(dir))
        case .aligned: return p1.distance(to: p2)
        case .radius: return p1.distance(to: p2)
        case .diameter: return p1.distance(to: p2) * 2
        case .angular:
            let a1 = (p2 - p1).angle, a2 = (p4 - p1).angle
            var s = normalizeAngle(a2 - a1)
            if s > .pi { s = 2 * .pi - s }
            return degrees(s)
        }
    }
}

/// Attribute definition (ATTDEF) inside a block: a named text field filled per insert.
public struct AttDefGeom: Hashable, Codable {
    public var tag: String
    public var prompt: String
    public var defaultValue: String
    /// Placement, height, rotation, alignment and style; `text.text` mirrors `tag` for display.
    public var text: TextGeom
    public var isInvisible: Bool
    public var isConstant: Bool
    public var isPreset: Bool
    public init(tag: String, prompt: String = "", defaultValue: String = "", text: TextGeom,
                isInvisible: Bool = false, isConstant: Bool = false, isPreset: Bool = false) {
        self.tag = tag; self.prompt = prompt; self.defaultValue = defaultValue; self.text = text
        self.isInvisible = isInvisible; self.isConstant = isConstant; self.isPreset = isPreset
    }
}

/// Attribute value (ATTRIB) attached to a block reference, in world coordinates.
public struct AttribValue: Hashable, Codable {
    public var tag: String
    /// World placement and the value (`text.text`).
    public var text: TextGeom
    public var isInvisible: Bool
    /// Own layer/color (DXF ATTRIBs carry them); nil = the block reference's.
    public var layer: String?
    public var color: CadColor?
    public init(tag: String, text: TextGeom, isInvisible: Bool = false, layer: String? = nil, color: CadColor? = nil) {
        self.tag = tag; self.text = text; self.isInvisible = isInvisible; self.layer = layer; self.color = color
    }
    public var value: String { text.text }
}

public struct InsertGeom: Hashable, Codable {
    public var blockName: String
    public var position: Vec2
    public var scaleX: Double
    public var scaleY: Double
    public var rotation: Double
    /// Attribute values, transformed with the insert.
    public var attributes: [AttribValue]
    public init(blockName: String, position: Vec2, scaleX: Double = 1, scaleY: Double = 1, rotation: Double = 0,
                attributes: [AttribValue] = []) {
        self.blockName = blockName; self.position = position
        self.scaleX = scaleX; self.scaleY = scaleY; self.rotation = rotation
        self.attributes = attributes
    }
    /// Maps block-definition coordinates (relative to `basePoint`) into world coordinates.
    public func transform(basePoint: Vec2) -> Transform2D {
        Transform2D.translation(-basePoint)
            .then(.scale(sx: scaleX, sy: scaleY))
            .then(.rotation(rotation))
            .then(.translation(position))
    }
}

public enum HatchPatternKind: String, Codable { case solid, lines, cross }

public struct HatchGeom: Hashable, Codable {
    /// Closed boundary loops.
    public var loops: [[PolyVertex]]
    public var pattern: HatchPatternKind
    public var patternName: String
    public var angle: Double
    public var spacing: Double
    public init(loops: [[PolyVertex]], pattern: HatchPatternKind = .solid, patternName: String = "SOLID",
                angle: Double = 0, spacing: Double = 1) {
        self.loops = loops; self.pattern = pattern; self.patternName = patternName
        self.angle = angle; self.spacing = spacing
    }
}

/// Spline stored by its fit/control points; rendered as a Catmull-Rom (fit) or B-spline (control).
public struct SplineGeom: Hashable, Codable {
    public var controlPoints: [Vec2]
    public var fitPoints: [Vec2]
    public var degree: Int
    public var knots: [Double]
    public var closed: Bool
    public init(controlPoints: [Vec2] = [], fitPoints: [Vec2] = [], degree: Int = 3, knots: [Double] = [], closed: Bool = false) {
        self.controlPoints = controlPoints; self.fitPoints = fitPoints; self.degree = degree
        self.knots = knots; self.closed = closed
    }
}

/// Paper-space window onto model space.
public struct ViewportGeom: Hashable, Codable {
    /// Center, width and height of the viewport frame in paper units.
    public var center: Vec2
    public var width: Double
    public var height: Double
    /// Model-space point shown at the viewport center.
    public var viewCenter: Vec2
    /// Model-space height visible in the viewport.
    public var viewHeight: Double
    public var isOn: Bool
    public var isLocked: Bool
    /// Layers frozen only in this viewport (VPLAYER).
    public var frozenLayers: [String]

    public init(center: Vec2, width: Double, height: Double, viewCenter: Vec2, viewHeight: Double,
                isOn: Bool = true, isLocked: Bool = false, frozenLayers: [String] = []) {
        self.center = center; self.width = width; self.height = height
        self.viewCenter = viewCenter; self.viewHeight = viewHeight
        self.isOn = isOn; self.isLocked = isLocked; self.frozenLayers = frozenLayers
    }

    /// Paper units per model unit (e.g. 0.01 for 1:100 when both are mm).
    public var scale: Double {
        get { viewHeight > 0 ? height / viewHeight : 1 }
        set { if newValue > 0 { viewHeight = height / newValue } }
    }

    public var frame: BBox { BBox(min: center - Vec2(width / 2, height / 2), max: center + Vec2(width / 2, height / 2)) }

    /// Maps model coordinates to paper coordinates.
    public var modelToPaper: Transform2D {
        Transform2D.translation(-viewCenter).then(.scale(scale)).then(.translation(center))
    }

    /// Centers and zooms the view so `box` fits.
    public mutating func fit(_ box: BBox) {
        guard !box.isEmpty else { return }
        viewCenter = box.center
        let w = max(box.width, 1e-9), h = max(box.height, 1e-9)
        let s = min(width / w, height / h) * 0.95
        viewHeight = height / s
    }
}

// MARK: - Entity

public enum EntityKind: Hashable, Codable {
    case line(LineGeom)
    case circle(CircleGeom)
    case arc(ArcGeom)
    case polyline(PolylineGeom)
    case ellipse(EllipseGeom)
    case text(TextGeom)
    case point(PointGeom)
    case dimension(DimensionGeom)
    case insert(InsertGeom)
    case hatch(HatchGeom)
    case spline(SplineGeom)
    case viewport(ViewportGeom)
    case attdef(AttDefGeom)

    public var typeName: String {
        switch self {
        case .line: return "Line"
        case .circle: return "Circle"
        case .arc: return "Arc"
        case .polyline: return "Polyline"
        case .ellipse: return "Ellipse"
        case .text(let t): return t.isMultiline ? "MText" : "Text"
        case .point: return "Point"
        case .dimension: return "Dimension"
        case .insert: return "Block Reference"
        case .hatch: return "Hatch"
        case .spline: return "Spline"
        case .viewport: return "Viewport"
        case .attdef: return "Attribute Definition"
        }
    }
}

public struct Entity: Hashable, Codable, Identifiable {
    public var id: EntityID
    public var layer: String
    public var color: CadColor
    /// "ByLayer", "Continuous", "DASHED", ...
    public var linetype: String
    /// Lineweight in mm; negative = ByLayer.
    public var lineweight: Double
    public var kind: EntityKind

    public init(_ kind: EntityKind, layer: String = "0", color: CadColor = .byLayer,
                linetype: String = "ByLayer", lineweight: Double = -1, id: EntityID = UUID()) {
        self.id = id; self.kind = kind; self.layer = layer; self.color = color
        self.linetype = linetype; self.lineweight = lineweight
    }

    /// Copy with a fresh ID and the same properties.
    public func duplicate(kind newKind: EntityKind? = nil) -> Entity {
        var e = self
        e.id = UUID()
        if let k = newKind { e.kind = k }
        return e
    }
}
