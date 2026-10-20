import Foundation

// MARK: - DRAWORDER

public enum DrawOrderPlacement: Equatable {
    /// Drawn last (on top of everything).
    case front
    /// Drawn first (beneath everything).
    case back
    /// Directly above the topmost of the reference objects.
    case above(Set<EntityID>)
    /// Directly beneath the bottommost of the reference objects.
    case under(Set<EntityID>)
}

/// Reorders `list` so the entities in `moving` are placed per `placement`, keeping the relative
/// order of both the moved and the remaining entities.
public func reorderEntities(_ list: [Entity], moving: Set<EntityID>, _ placement: DrawOrderPlacement) -> [Entity] {
    let moved = list.filter { moving.contains($0.id) }
    guard !moved.isEmpty else { return list }
    var rest = list.filter { !moving.contains($0.id) }
    switch placement {
    case .front: return rest + moved
    case .back: return moved + rest
    case .above(let refs):
        guard let i = rest.lastIndex(where: { refs.contains($0.id) }) else { return list }
        rest.insert(contentsOf: moved, at: i + 1)
        return rest
    case .under(let refs):
        guard let i = rest.firstIndex(where: { refs.contains($0.id) }) else { return list }
        rest.insert(contentsOf: moved, at: i)
        return rest
    }
}

public enum TextToFrontKind: String, CaseIterable {
    case text = "Text", dimensions = "Dimensions", all = "All"
}

extension Drawing {
    /// Reorders the active space.
    public mutating func drawOrder(_ ids: Set<EntityID>, _ placement: DrawOrderPlacement) {
        entities = reorderEntities(entities, moving: ids, placement)
    }

    /// Brings text (TEXT/MTEXT/attribute definitions) and/or dimensions to the front. Returns the count moved.
    @discardableResult
    public mutating func textToFront(_ kind: TextToFrontKind = .all) -> Int {
        let ids = Set(entities.filter { e in
            switch e.kind {
            case .text, .attdef: return kind != .dimensions
            case .dimension: return kind != .text
            default: return false
            }
        }.map(\.id))
        drawOrder(ids, .front)
        return ids.count
    }
}
