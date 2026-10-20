import Foundation
import CadCore

/// Difference between two drawings, re-appliable to a drawing that changed meanwhile
/// (the user may keep editing while a Claude proposal waits for approval).
struct AutomationPatch {
    struct SpaceDiff {
        var added: [Entity] = []
        var changed: [Entity] = []
        var removed: Set<EntityID> = []
        var isEmpty: Bool { added.isEmpty && changed.isEmpty && removed.isEmpty }
    }

    let base: Drawing
    let final: Drawing
    /// Keyed by layout name; "" = model space.
    var spaces: [String: SpaceDiff] = [:]
    var layersChanged = false
    var blocksChanged = false
    var settingsChanged = false
    var otherChanged = false

    init(base: Drawing, final: Drawing) {
        self.base = base
        self.final = final
        func diff(_ a: [Entity], _ b: [Entity]) -> SpaceDiff {
            var out = SpaceDiff()
            var old: [EntityID: Entity] = [:]
            old.reserveCapacity(a.count)
            for e in a { old[e.id] = e }
            var seen = Set<EntityID>()
            for e in b {
                seen.insert(e.id)
                if let o = old[e.id] { if o != e { out.changed.append(e) } } else { out.added.append(e) }
            }
            for e in a where !seen.contains(e.id) { out.removed.insert(e.id) }
            return out
        }
        if base.modelEntities != final.modelEntities {
            let d = diff(base.modelEntities, final.modelEntities)
            if !d.isEmpty { spaces[""] = d }
        }
        for l in final.layouts {
            let before = base.layouts.first { $0.name == l.name }?.entities ?? []
            if before != l.entities {
                let d = diff(before, l.entities)
                if !d.isEmpty { spaces[l.name] = d }
            }
        }
        layersChanged = base.layers != final.layers
        blocksChanged = base.blocks != final.blocks
        settingsChanged = base.settings != final.settings
        otherChanged = base.linetypes != final.linetypes || base.groups != final.groups
            || base.layouts.map { [$0.name, $0.paper.name] } != final.layouts.map { [$0.name, $0.paper.name] }
            || base.layouts.map(\.paper) != final.layouts.map(\.paper)
    }

    var isEmpty: Bool { spaces.isEmpty && !layersChanged && !blocksChanged && !settingsChanged && !otherChanged }

    var addedCount: Int { spaces.values.reduce(0) { $0 + $1.added.count } }
    var changedCount: Int { spaces.values.reduce(0) { $0 + $1.changed.count } }
    var removedCount: Int { spaces.values.reduce(0) { $0 + $1.removed.count } }

    /// Entities to highlight in the given space ("" = model).
    func previewEntities(space: String) -> [Entity] {
        guard let s = spaces[space] else { return [] }
        return s.added + s.changed
    }

    /// Human-readable list of non-entity changes.
    var tableChanges: [String] {
        var out: [String] = []
        if layersChanged {
            let newNames = final.layers.filter { l in base.layer(named: l.name) == nil }.map(\.name)
            let removed = base.layers.filter { l in final.layer(named: l.name) == nil }.map(\.name)
            let modified = final.layers.filter { l in base.layer(named: l.name).map { $0 != l } ?? false }.map(\.name)
            if !newNames.isEmpty { out.append("new layer\(newNames.count == 1 ? "" : "s") " + newNames.joined(separator: ", ")) }
            if !modified.isEmpty { out.append("changed layer\(modified.count == 1 ? "" : "s") " + modified.joined(separator: ", ")) }
            if !removed.isEmpty { out.append("removed layer\(removed.count == 1 ? "" : "s") " + removed.joined(separator: ", ")) }
        }
        if blocksChanged { out.append("block definitions changed") }
        if settingsChanged {
            if base.settings.currentLayer != final.settings.currentLayer { out.append("current layer → \(final.settings.currentLayer)") }
            var s = base.settings; s.currentLayer = final.settings.currentLayer
            if s != final.settings { out.append("drawing settings changed") }
        }
        if otherChanged { out.append("linetypes/groups/layouts changed") }
        return out
    }

    /// Applies the change to `d`. When `d` still equals the base, the result is exactly `final`.
    func apply(to d: inout Drawing) {
        let keepLayout = d.activeLayout
        if d == base {
            d = final
            d.activeLayout = keepLayout.flatMap { final.layoutIndex($0) != nil ? $0 : nil }
            return
        }
        func patch(_ es: inout [Entity], _ s: SpaceDiff) {
            if !s.removed.isEmpty { es.removeAll { s.removed.contains($0.id) } }
            if !s.changed.isEmpty {
                var byID: [EntityID: Entity] = [:]
                for e in s.changed { byID[e.id] = e }
                for i in es.indices { if let n = byID.removeValue(forKey: es[i].id) { es[i] = n } }
            }
            let existing = Set(es.map(\.id))
            es += s.added.filter { !existing.contains($0.id) }
        }
        if otherChanged {
            // Rare (layout/linetype edits via run_command): take the proposed tables wholesale.
            d.linetypes = final.linetypes
            d.groups = final.groups
            var layouts = final.layouts
            for i in layouts.indices {
                if let cur = d.layouts.first(where: { $0.name == layouts[i].name }) { layouts[i].entities = cur.entities }
            }
            d.layouts = layouts
        }
        if let s = spaces[""] { patch(&d.modelEntities, s) }
        for (name, s) in spaces where !name.isEmpty {
            if let i = d.layoutIndex(name) { patch(&d.layouts[i].entities, s) }
        }
        if layersChanged {
            for l in final.layers {
                let old = base.layer(named: l.name)
                if old == l { continue }
                if let i = d.layers.firstIndex(where: { $0.name.caseInsensitiveCompare(l.name) == .orderedSame }) { d.layers[i] = l } else { d.layers.append(l) }
            }
            for l in base.layers where final.layer(named: l.name) == nil { d.layers.removeAll { $0.name == l.name } }
        }
        if blocksChanged {
            for (k, b) in final.blocks where base.blocks[k] != b { d.blocks[k] = b }
            for k in base.blocks.keys where final.blocks[k] == nil { d.blocks[k] = nil }
        }
        if settingsChanged { d.settings = AutomationPatch.merge(base: base.settings, final: final.settings, current: d.settings) }
        // Make sure every referenced layer exists.
        for s in spaces.values { for e in s.added + s.changed { d.ensureLayer(e.layer) } }
        if let k = keepLayout, d.layoutIndex(k) == nil { d.activeLayout = nil } else { d.activeLayout = keepLayout }
    }

    /// Field-wise three-way merge: fields Claude changed win, other fields keep the user's values.
    static func merge<T: Codable>(base: T, final: T, current: T) -> T {
        let enc = JSONEncoder(), dec = JSONDecoder()
        guard let b = (try? enc.encode(base)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              let f = (try? enc.encode(final)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              var c = (try? enc.encode(current)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return final }
        for (k, v) in f where !((b[k] as AnyObject?)?.isEqual(v) ?? false) { c[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: c), let out = try? dec.decode(T.self, from: data) else { return final }
        return out
    }
}
