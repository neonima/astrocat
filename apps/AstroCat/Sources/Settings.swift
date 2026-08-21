import Foundation

/// A file that has to keep meaning the same thing after the app that wrote it
/// has been replaced.
///
/// Swift's synthesised `Codable` throws on a missing key even when the property
/// has a default, so adding one field makes every file written before it
/// unreadable — and the `try?` around the decode turns that into a release that
/// silently starts everyone over. `Settings.decode` merges the file over a
/// default instance instead, so a new field takes its default and every other
/// edit survives untouched. `migrate` is only for what a default cannot
/// express: a value spelled differently, or one that now means something else.
///
/// A migration must be safe to run twice. `Settings.encode` keeps the keys it
/// found in the file and does not understand, so running an older build against
/// a newer file writes back what it knows and leaves the rest — but it stamps
/// its own version, and the newer build then steps those keys forward again.
/// `Settings.respell` is idempotent because it matches on the old spelling;
/// anything hand-written has to be too.
protocol Migratable: Codable {
    init()
    /// One entry per format change, oldest first. A file at version *n* has
    /// had the first *n - 1* applied, so upgrading runs the rest in order —
    /// v1 to v4 is entries 1, 2 and 3, each knowing only about its own change.
    ///
    /// A list rather than a switch on a separately declared version, because
    /// the version is then `count + 1` rather than a second thing to remember:
    /// a migration cannot be added without the file version moving, and the
    /// version cannot move without a migration to justify it.
    static var migrations: [(inout [String: Any]) -> Void] { get }
}

extension Migratable {
    static var migrations: [(inout [String: Any]) -> Void] { [] }
    static var version: Int { migrations.count + 1 }
}

enum Settings {
    static let versionKey = "version"

    /// `existing` is whatever is already at the destination. Keys in it that
    /// this build does not produce are kept, so running an old build against a
    /// file a newer one wrote costs nothing permanently — the settings it does
    /// not know about are still there when the newer build comes back.
    static func encode<T: Migratable>(_ value: T, carrying existing: Data? = nil) -> Data? {
        guard var object = fields(of: value) else { return nil }
        if let existing, let previous = (try? JSONSerialization.jsonObject(with: existing))
            as? [String: Any]
        {
            object = merged(previous, under: object)
        }
        object[versionKey] = T.version
        return try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    }

    static func decode<T: Migratable>(_ type: T.Type, from data: Data) -> T? {
        guard var stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let defaults = fields(of: T())
        else { return nil }

        // Every step between the file's version and this build's, in order. A
        // file from a newer build is read as far as this one understands it
        // rather than migrated backwards.
        let from = max(stored[versionKey] as? Int ?? 1, 1)
        if from <= T.migrations.count {
            for step in T.migrations[(from - 1)...] { step(&stored) }
        }

        var object = merged(defaults, under: stored)
        var repaired: Set<String> = []
        while true {
            guard let json = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            do {
                return try JSONDecoder().decode(type, from: json)
            } catch let error as DecodingError {
                // One field whose type changed under it would otherwise take
                // the whole file with it. Put its default back and decode
                // again; the rest of the edits are still good.
                let path = keyPath(error)
                guard !path.isEmpty, repaired.insert(path.joined(separator: ".")).inserted,
                    restore(path, in: &object, from: defaults)
                else { return nil }
            } catch {
                return nil
            }
        }
    }

    /// Rewrites one string value in place, for a migration that changes how a
    /// value is spelled rather than what it means.
    static func respell(_ object: inout [String: Any], _ key: String, _ table: [String: String]) {
        if let old = object[key] as? String, let new = table[old] { object[key] = new }
    }

    private static func fields<T: Encodable>(of value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Recursive, because a field added to a nested struct is exactly as fatal
    /// as one added to the top level.
    private static func merged(_ defaults: [String: Any], under stored: [String: Any])
        -> [String: Any]
    {
        var out = defaults
        for (key, value) in stored {
            if let nested = value as? [String: Any], let base = defaults[key] as? [String: Any] {
                out[key] = merged(base, under: nested)
            } else {
                out[key] = value
            }
        }
        return out
    }

    /// String keys down to the failure, stopping at the first array index: a
    /// bad element is repaired by replacing the array that holds it.
    private static func keyPath(_ error: DecodingError) -> [String] {
        let context: DecodingError.Context
        switch error {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c),
            .dataCorrupted(let c):
            context = c
        @unknown default:
            return []
        }
        return context.codingPath.prefix { $0.intValue == nil }.map(\.stringValue)
    }

    private static func restore(
        _ path: [String], in object: inout [String: Any], from defaults: [String: Any]
    ) -> Bool {
        guard let key = path.first, let fallback = defaults[key] else { return false }
        if path.count == 1 {
            object[key] = fallback
            return true
        }
        guard var nested = object[key] as? [String: Any], let base = fallback as? [String: Any],
            restore(Array(path.dropFirst()), in: &nested, from: base)
        else { return false }
        object[key] = nested
        return true
    }
}
