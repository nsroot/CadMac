import Foundation

// MARK: - QSELECT filtering (pure logic)

/// Property a quick-select filter can test.
public enum QSelectProperty: String, CaseIterable, Codable {
    case layer = "Layer"
    case color = "Color"
    case linetype = "Linetype"
    case lineweight = "Lineweight"
    case textContents = "Contents"
    case blockName = "Name"
    case radius = "Radius"
    case length = "Length"
    case area = "Area"

    /// True when values are compared numerically.
    public var isNumeric: Bool {
        switch self {
        case .lineweight, .radius, .length, .area: return true
        default: return false
        }
    }

    /// Operators that make sense for this property.
    public var operators: [QSelectOperator] {
        isNumeric ? [.equals, .notEqual, .greater, .less, .selectAll]
                  : [.equals, .notEqual, .contains, .wildcard, .selectAll]
    }
}

public enum QSelectOperator: String, CaseIterable, Codable {
    case equals = "= Equals"
    case notEqual = "≠ Not Equal"
    case greater = "> Greater than"
    case less = "< Less than"
    case contains = "Contains"
    case wildcard = "* Wildcard Match"
    case selectAll = "Select All"
}

public enum QSelectMode: String, CaseIterable, Codable {
    /// New selection = matching objects.
    case replace = "Replace selection"
    /// Current selection plus matching objects.
    case append = "Append to selection"
    /// Objects (of the apply-to set) that do NOT match.
    case exclude = "Exclude matches"
}

public struct QSelectCriteria: Equatable {
    /// `EntityKind.typeName`, or nil for "Multiple" (any type).
    public var objectType: String?
    public var property: QSelectProperty
    public var op: QSelectOperator
    public var value: String
    public init(objectType: String? = nil, property: QSelectProperty, op: QSelectOperator, value: String = "") {
        self.objectType = objectType; self.property = property; self.op = op; self.value = value
    }
}

/// A property value: textual or numeric.
public enum QSelectValue: Equatable {
    case text(String)
    case number(Double)
}

/// AutoCAD-style wildcard match (case-insensitive): `*` any run, `?` one char, `#` digit,
/// `@` letter, `.` non-alphanumeric, `` ` `` escapes, `,` separates alternatives, leading `~` negates.
public func wildcardMatch(_ pattern: String, _ text: String) -> Bool {
    var alternatives: [String] = []
    var cur = ""
    var escaped = false
    for ch in pattern {
        if escaped { cur.append("`"); cur.append(ch); escaped = false; continue }
        if ch == "`" { escaped = true; continue }
        if ch == "," { alternatives.append(cur); cur = ""; continue }
        cur.append(ch)
    }
    if escaped { cur.append("`") }
    alternatives.append(cur)
    let t = Array(text.lowercased())
    for alt in alternatives {
        var p = alt
        var negate = false
        if p.hasPrefix("~") { negate = true; p.removeFirst() }
        let m = matchWildcard(Array(p.lowercased()), t)
        if m != negate { return true }
    }
    return false
}

private enum WildToken { case star, any, digit, alpha, nonAlnum, lit(Character) }

private func matchWildcard(_ p: [Character], _ t: [Character]) -> Bool {
    var toks: [WildToken] = []
    var i = 0
    while i < p.count {
        let ch = p[i]
        switch ch {
        case "`":
            if i + 1 < p.count { toks.append(.lit(p[i + 1])); i += 1 } else { toks.append(.lit("`")) }
        case "*": toks.append(.star)
        case "?": toks.append(.any)
        case "#": toks.append(.digit)
        case "@": toks.append(.alpha)
        case ".": toks.append(.nonAlnum)
        default: toks.append(.lit(ch))
        }
        i += 1
    }
    func one(_ tk: WildToken, _ c: Character) -> Bool {
        switch tk {
        case .star, .any: return true
        case .digit: return c.isNumber
        case .alpha: return c.isLetter
        case .nonAlnum: return !(c.isLetter || c.isNumber)
        case .lit(let l): return l == c
        }
    }
    // Iterative glob match with backtracking on the last star.
    var ti = 0, pi = 0, starP = -1, starT = 0
    while ti < t.count {
        if pi < toks.count, case .star = toks[pi] {
            starP = pi; starT = ti; pi += 1
        } else if pi < toks.count, one(toks[pi], t[ti]) {
            pi += 1; ti += 1
        } else if starP >= 0 {
            pi = starP + 1; starT += 1; ti = starT
        } else {
            return false
        }
    }
    while pi < toks.count, case .star = toks[pi] { pi += 1 }
    return pi == toks.count
}

/// Parses a lineweight string ("ByLayer", "ByBlock", "Default", "0.25", "0.25 mm").
public func parseLineweight(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces).lowercased()
    switch t {
    case "bylayer": return -1
    case "byblock": return -2
    case "default": return -3
    default:
        let n = t.replacingOccurrences(of: "mm", with: "").trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        return Double(n)
    }
}

/// Display string of a lineweight value (matches the Properties panel).
public func lineweightName(_ v: Double) -> String {
    switch v {
    case -1: return "ByLayer"
    case -2: return "ByBlock"
    case ..<0: return "Default"
    default: return String(format: "%.2f mm", v)
    }
}

/// Parses a color name ("ByLayer", "Red", "1", "Color 30", "255,0,0").
public func parseColor(_ s: String) -> CadColor? {
    let t = s.trimmingCharacters(in: .whitespaces)
    let l = t.lowercased()
    if l == "bylayer" { return .byLayer }
    if l == "byblock" { return .byBlock }
    let names = ["red": 1, "yellow": 2, "green": 3, "cyan": 4, "blue": 5, "magenta": 6, "white": 7, "black": 7]
    if let i = names[l] { return .aci(i) }
    var num = l
    if num.hasPrefix("color ") { num.removeFirst(6) }
    if let i = Int(num.trimmingCharacters(in: .whitespaces)), (0...256).contains(i) { return .aci(i) }
    let parts = l.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    if parts.count == 3, let r = UInt8(parts[0]), let g = UInt8(parts[1]), let b = UInt8(parts[2]) {
        return .rgb(RGB(r, g, b))
    }
    return nil
}

extension Drawing {
    /// Object type names present in the active space, sorted.
    public func qselectTypes() -> [String] {
        Array(Set(entities.map(\.kind.typeName))).sorted()
    }

    /// Properties available for an object type (nil = "Multiple": general properties only).
    public static func qselectProperties(forType type: String?) -> [QSelectProperty] {
        let general: [QSelectProperty] = [.layer, .color, .linetype, .lineweight]
        switch type {
        case "Line": return general + [.length]
        case "Circle": return general + [.radius, .length, .area]
        case "Arc": return general + [.radius, .length]
        case "Polyline": return general + [.length, .area]
        case "Ellipse", "Hatch": return general + [.area]
        case "Spline": return general + [.length, .area]
        case "Text", "MText": return general + [.textContents]
        case "Block Reference": return general + [.blockName]
        default: return general
        }
    }

    /// Value of `prop` for `e`, or nil when the object has no such property.
    public func qselectValue(_ e: Entity, _ prop: QSelectProperty) -> QSelectValue? {
        switch prop {
        case .layer: return .text(e.layer)
        case .color: return .text(e.color.displayName)
        case .linetype: return .text(e.linetype)
        case .lineweight: return .number(e.lineweight < 0 && e.lineweight != -1 && e.lineweight != -2 ? -3 : e.lineweight)
        case .textContents:
            if case .text(let t) = e.kind { return .text(t.text) }
            return nil
        case .blockName:
            if case .insert(let i) = e.kind { return .text(i.blockName) }
            return nil
        case .radius:
            switch e.kind {
            case .circle(let c): return .number(c.radius)
            case .arc(let a): return .number(a.radius)
            default: return nil
            }
        case .length:
            switch e.kind {
            case .line, .arc, .polyline, .spline: return curvePath(of: e).map { .number($0.length) }
            case .circle(let c): return .number(2 * .pi * c.radius)
            default: return nil
            }
        case .area:
            switch e.kind {
            case .circle(let c): return .number(.pi * c.radius * c.radius)
            case .polyline(let p):
                guard p.closed, p.vertices.count >= 2 else { return nil }
                return .number(abs(polygonArea(p.vertices)))
            case .ellipse, .hatch, .spline:
                return area(of: e.id).map { .number($0) }
            default: return nil
            }
        }
    }

    /// Suggested values for the value field (existing layers, colors, ...).
    public func qselectValueChoices(_ prop: QSelectProperty, type: String? = nil) -> [String] {
        let es = entities.filter { type == nil || $0.kind.typeName == type }
        switch prop {
        case .layer: return layers.map(\.name)
        case .color:
            var seen: [String] = ["ByLayer", "ByBlock", "Red", "Yellow", "Green", "Cyan", "Blue", "Magenta", "White"]
            for e in es where !seen.contains(e.color.displayName) { seen.append(e.color.displayName) }
            return seen
        case .linetype:
            var seen: [String] = ["ByLayer", "ByBlock"] + linetypes.map(\.name)
            for e in es where !seen.contains(where: { $0.caseInsensitiveCompare(e.linetype) == .orderedSame }) { seen.append(e.linetype) }
            return seen
        case .lineweight:
            return Array(Set(es.map { lineweightName($0.lineweight) })).sorted()
        case .blockName:
            var names = Set(blocks.keys.filter { !$0.hasPrefix("*") })
            for e in es { if case .insert(let i) = e.kind { names.insert(i.blockName) } }
            return names.sorted()
        default: return []
        }
    }

    /// True when `e` satisfies the criteria.
    public func qselectMatches(_ e: Entity, _ cr: QSelectCriteria) -> Bool {
        if let t = cr.objectType, e.kind.typeName != t { return false }
        if cr.op == .selectAll { return true }
        guard let v = qselectValue(e, cr.property) else { return false }
        switch v {
        case .text(let s):
            if cr.property == .color, cr.op == .equals || cr.op == .notEqual, let want = parseColor(cr.value) {
                let eq = e.color == want
                return cr.op == .equals ? eq : !eq
            }
            let eq = s.caseInsensitiveCompare(cr.value.trimmingCharacters(in: .whitespaces)) == .orderedSame
            switch cr.op {
            case .equals: return eq
            case .notEqual: return !eq
            case .contains: return cr.value.isEmpty || s.range(of: cr.value, options: .caseInsensitive) != nil
            case .wildcard: return wildcardMatch(cr.value, s)
            case .greater: return s.localizedStandardCompare(cr.value) == .orderedDescending
            case .less: return s.localizedStandardCompare(cr.value) == .orderedAscending
            case .selectAll: return true
            }
        case .number(let x):
            let want: Double?
            if cr.property == .lineweight { want = parseLineweight(cr.value) } else {
                want = Double(cr.value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
            }
            guard let w = want else { return false }
            let tol = 1e-6 * max(1, abs(w))
            switch cr.op {
            case .equals: return abs(x - w) <= tol
            case .notEqual: return abs(x - w) > tol
            case .greater: return x > w + tol
            case .less: return x < w - tol
            case .contains, .wildcard: return wildcardMatch(cr.value, fmt(x))
            case .selectAll: return true
            }
        }
    }

    /// Computes the new selection.
    /// - Parameters:
    ///   - applyTo: candidate objects (nil = whole active space).
    ///   - current: the current selection (used by `.append`).
    public func quickSelect(_ cr: QSelectCriteria, mode: QSelectMode = .replace,
                            applyTo: Set<EntityID>? = nil, current: Set<EntityID> = []) -> Set<EntityID> {
        var candidates = entities
        if let a = applyTo { candidates = candidates.filter { a.contains($0.id) } }
        candidates = candidates.filter { isEditable($0) }
        switch mode {
        case .replace:
            return Set(candidates.filter { qselectMatches($0, cr) }.map(\.id))
        case .append:
            return current.union(candidates.filter { qselectMatches($0, cr) }.map(\.id))
        case .exclude:
            return Set(candidates.filter { !qselectMatches($0, cr) }.map(\.id))
        }
    }
}
