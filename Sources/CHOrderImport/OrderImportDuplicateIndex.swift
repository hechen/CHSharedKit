import Foundation

/// Indexed duplicate checks against the source keys the host app already persisted.
///
/// Persisted keys are `sourceKey:unitIndex` (see `OrderLineDraft.sourceKey(forUnit:)`).
/// The index strips that suffix so a line counts as imported once any unit exists.
public struct OrderImportDuplicateIndex: Sendable, Equatable {
    private var sources: Set<String> = []

    public init() {}

    public init(importedSourceKeys: some Sequence<String>) {
        for key in importedSourceKeys {
            sources.insert(Self.lineKey(fromPersisted: key))
        }
    }

    public var isEmpty: Bool { sources.isEmpty }

    public func contains(_ draft: OrderLineDraft) -> Bool {
        guard let key = draft.sourceKey else { return false }
        return sources.contains(key)
    }

    public func contains(lineSourceKey key: String) -> Bool {
        sources.contains(key)
    }

    public mutating func insert(_ draft: OrderLineDraft) {
        if let key = draft.sourceKey { sources.insert(key) }
    }

    /// `abc:3` → `abc`; a key without a numeric unit suffix is returned unchanged.
    public static func lineKey(fromPersisted key: String) -> String {
        guard let separator = key.lastIndex(of: ":") else { return key }
        let suffix = key[key.index(after: separator)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return key }
        return String(key[..<separator])
    }
}
