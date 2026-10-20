import Foundation

// MARK: - COUNT

extension Drawing {
    /// Block references per block name in the active space (optionally only `ids`), sorted by name.
    public func blockCounts(in ids: Set<EntityID>? = nil) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for e in entities where ids?.contains(e.id) ?? true {
            if case .insert(let i) = e.kind { counts[i.blockName, default: 0] += 1 }
        }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// IDs of block references named `name` (case-insensitive) in the active space.
    public func blockReferences(named name: String) -> [EntityID] {
        entities.filter {
            if case .insert(let i) = $0.kind { return i.blockName.caseInsensitiveCompare(name) == .orderedSame }
            return false
        }.map(\.id)
    }
}

// MARK: - FIND / REPLACE

public struct FindOptions: Equatable {
    public var matchCase = false
    public var wholeWords = false
    public var includeText = true
    public var includeAttributes = true
    public var includeDimensions = true
    public init(matchCase: Bool = false, wholeWords: Bool = false) {
        self.matchCase = matchCase; self.wholeWords = wholeWords
    }
}

/// Ranges of `query` in `s` honoring the options.
func findRanges(_ query: String, in s: String, _ o: FindOptions) -> [Range<String.Index>] {
    guard !query.isEmpty else { return [] }
    var out: [Range<String.Index>] = []
    var start = s.startIndex
    let opts: String.CompareOptions = o.matchCase ? [] : [.caseInsensitive]
    while start < s.endIndex, let r = s.range(of: query, options: opts, range: start..<s.endIndex) {
        var ok = true
        if o.wholeWords {
            func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
            if r.lowerBound > s.startIndex, isWord(s[s.index(before: r.lowerBound)]) { ok = false }
            if r.upperBound < s.endIndex, isWord(s[r.upperBound]) { ok = false }
        }
        if ok { out.append(r) }
        start = r.upperBound > r.lowerBound ? r.upperBound : s.index(after: r.lowerBound)
    }
    return out
}

func replacing(_ query: String, with rep: String, in s: String, _ o: FindOptions) -> (String, Int) {
    let rs = findRanges(query, in: s, o)
    guard !rs.isEmpty else { return (s, 0) }
    var out = s
    for r in rs.reversed() { out.replaceSubrange(r, with: rep) }
    return (out, rs.count)
}

extension Drawing {
    /// Searchable strings of an entity: (text, editable slot).
    private func searchableStrings(_ e: Entity, _ o: FindOptions) -> [String] {
        switch e.kind {
        case .text(let t) where o.includeText: return [t.text]
        case .attdef(let a) where o.includeText: return [a.defaultValue]
        case .insert(let i) where o.includeAttributes: return i.attributes.map(\.value)
        case .dimension(let d) where o.includeDimensions: return d.textOverride.isEmpty ? [] : [d.textOverride]
        default: return []
        }
    }

    /// Objects in the active space (optionally only `ids`) whose text contains `query`.
    public func findText(_ query: String, options: FindOptions = FindOptions(), in ids: Set<EntityID>? = nil) -> [EntityID] {
        guard !query.isEmpty else { return [] }
        return entities.filter { e in
            (ids?.contains(e.id) ?? true) && searchableStrings(e, options).contains { !findRanges(query, in: $0, options).isEmpty }
        }.map(\.id)
    }

    /// Replaces `query` by `replacement` in matching objects. Returns the number of replacements.
    @discardableResult
    public mutating func replaceText(_ query: String, with replacement: String, options: FindOptions = FindOptions(),
                                     in ids: Set<EntityID>? = nil) -> Int {
        guard !query.isEmpty else { return 0 }
        var total = 0
        for i in entities.indices where ids?.contains(entities[i].id) ?? true {
            guard isEditable(entities[i]) else { continue }
            switch entities[i].kind {
            case .text(var t) where options.includeText:
                let (s, n) = replacing(query, with: replacement, in: t.text, options)
                if n > 0 { t.text = s; entities[i].kind = .text(t); total += n }
            case .attdef(var a) where options.includeText:
                let (s, n) = replacing(query, with: replacement, in: a.defaultValue, options)
                if n > 0 { a.defaultValue = s; entities[i].kind = .attdef(a); total += n }
            case .insert(var ins) where options.includeAttributes:
                var n = 0
                for k in ins.attributes.indices {
                    let (s, c) = replacing(query, with: replacement, in: ins.attributes[k].text.text, options)
                    if c > 0 { ins.attributes[k].text.text = s; n += c }
                }
                if n > 0 { entities[i].kind = .insert(ins); total += n }
            case .dimension(var d) where options.includeDimensions && !d.textOverride.isEmpty:
                let (s, n) = replacing(query, with: replacement, in: d.textOverride, options)
                if n > 0 { d.textOverride = s; entities[i].kind = .dimension(d); total += n }
            default: break
            }
        }
        return total
    }
}
