import Foundation

// MARK: - GROUP / UNGROUP / GROUPEDIT

public enum GroupError: Error, LocalizedError, Equatable {
    case invalidName(String)
    case duplicateName(String)
    case notFound(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .invalidName(let n): return "Invalid group name \"\(n)\"."
        case .duplicateName(let n): return "A group named \"\(n)\" already exists."
        case .notFound(let n): return "Group \"\(n)\" not found."
        case .empty: return "No objects selected."
        }
    }
}

extension Drawing {
    public func groupIndex(named n: String) -> Int? {
        groups.firstIndex { $0.name.caseInsensitiveCompare(n) == .orderedSame }
    }

    /// Names of groups containing any of `ids`.
    public func groupNames(containing ids: Set<EntityID>) -> [String] {
        groups.filter { $0.members.contains(where: ids.contains) }.map(\.name)
    }

    /// Next free anonymous group name ("*A1", "*A2", ...).
    public func nextAnonymousGroupName() -> String {
        var n = 1
        while groupIndex(named: "*A\(n)") != nil { n += 1 }
        return "*A\(n)"
    }

    /// Validates a user-supplied group name (no leading "*", no control characters, ≤ 255 chars).
    public static func isValidGroupName(_ n: String) -> Bool {
        let t = n.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 255, !t.hasPrefix("*") else { return false }
        let bad = CharacterSet(charactersIn: "<>/\\\":;?,|=`").union(.controlCharacters)
        return t.unicodeScalars.allSatisfy { !bad.contains($0) }
    }

    /// Creates a group; nil/empty name makes an unnamed group. Members keep drawing order. Returns the name.
    @discardableResult
    public mutating func createGroup(name: String?, description: String = "", members: Set<EntityID>) throws -> String {
        let ordered = entities.filter { members.contains($0.id) }.map(\.id)
        guard !ordered.isEmpty else { throw GroupError.empty }
        var n = name?.trimmingCharacters(in: .whitespaces) ?? ""
        if n.isEmpty {
            n = nextAnonymousGroupName()
        } else {
            guard Drawing.isValidGroupName(n) else { throw GroupError.invalidName(n) }
            guard groupIndex(named: n) == nil else { throw GroupError.duplicateName(n) }
        }
        groups.append(EntityGroup(name: n, description: description, members: ordered))
        return n
    }

    /// Removes every group containing any of `ids`; returns removed names.
    @discardableResult
    public mutating func ungroup(containing ids: Set<EntityID>) -> [String] {
        let names = groupNames(containing: ids)
        groups.removeAll { names.contains($0.name) }
        return names
    }

    public mutating func deleteGroup(named n: String) throws {
        guard let i = groupIndex(named: n) else { throw GroupError.notFound(n) }
        groups.remove(at: i)
    }

    /// Adds objects to a group; returns how many were new.
    @discardableResult
    public mutating func addToGroup(_ n: String, _ ids: Set<EntityID>) throws -> Int {
        guard let i = groupIndex(named: n) else { throw GroupError.notFound(n) }
        let existing = Set(groups[i].members)
        let new = entities.filter { ids.contains($0.id) && !existing.contains($0.id) }.map(\.id)
        groups[i].members += new
        return new.count
    }

    /// Removes objects from a group (the group is deleted when it becomes empty). Returns how many were removed.
    @discardableResult
    public mutating func removeFromGroup(_ n: String, _ ids: Set<EntityID>) throws -> Int {
        guard let i = groupIndex(named: n) else { throw GroupError.notFound(n) }
        let before = groups[i].members.count
        groups[i].members.removeAll { ids.contains($0) }
        let removed = before - groups[i].members.count
        if groups[i].members.isEmpty { groups.remove(at: i) }
        return removed
    }

    public mutating func renameGroup(_ old: String, to new: String) throws {
        guard let i = groupIndex(named: old) else { throw GroupError.notFound(old) }
        let n = new.trimmingCharacters(in: .whitespaces)
        guard Drawing.isValidGroupName(n) else { throw GroupError.invalidName(n) }
        if let j = groupIndex(named: n), j != i { throw GroupError.duplicateName(n) }
        groups[i].name = n
    }

    /// Toggles group selection (PICKSTYLE): if any group is selectable all become unselectable, else all selectable.
    /// Returns the new state.
    @discardableResult
    public mutating func toggleGroupSelection() -> Bool {
        let on = !groups.contains { $0.isSelectable }
        for i in groups.indices { groups[i].isSelectable = on }
        return on
    }
}
