import Foundation

extension BlockDef {
    /// Attribute definitions of the block, in definition order.
    public var attributeDefinitions: [AttDefGeom] {
        entities.compactMap { if case .attdef(let a) = $0.kind { return a } else { return nil } }
    }

    /// Definitions that get a per-insert value (everything but constant attributes).
    public var variableAttributeDefinitions: [AttDefGeom] {
        attributeDefinitions.filter { !$0.isConstant }
    }

    /// Definition for a tag (case-insensitive).
    public func attributeDefinition(tag: String) -> AttDefGeom? {
        attributeDefinitions.first { $0.tag.caseInsensitiveCompare(tag) == .orderedSame }
    }
}

extension InsertGeom {
    /// Attribute value for `def`, placed in world space with this insert's transform.
    public func attribute(from def: AttDefGeom, basePoint: Vec2, value: String) -> AttribValue {
        var t = def.text
        t.text = value
        if case .text(let w) = EntityKind.text(t).transformed(by: transform(basePoint: basePoint)) { t = w }
        return AttribValue(tag: def.tag, text: t, isInvisible: def.isInvisible)
    }

    /// Attribute values for every non-constant definition of `block`; `values` maps tags
    /// (uppercased) to values, missing tags get the definition's default.
    public func makeAttributes(block: BlockDef, values: [String: String] = [:]) -> [AttribValue] {
        block.variableAttributeDefinitions.map { def in
            attribute(from: def, basePoint: block.basePoint, value: values[def.tag.uppercased()] ?? def.defaultValue)
        }
    }
}
