import Foundation

/// Two phones can each hold a copy of the same row (one backup imported on both) before iCloud
/// brings them together. Which copy goes has to be the same on every phone, or each deletes the
/// other's and neither is left: the lowest tag stays. A row without a tag yet is left alone; its
/// tag is on its way from the phone that made it.
public enum SyncDedupe {
    public static func extras<T>(_ rows: [T], key: (T) -> String, tag: (T) -> UUID?) -> [T] {
        var groups: [String: [(row: T, tag: String)]] = [:]
        for row in rows {
            guard let t = tag(row) else { continue }
            groups[key(row), default: []].append((row, t.uuidString))
        }
        return groups.values.flatMap { group in
            group.sorted { $0.tag < $1.tag }.dropFirst().map(\.row)
        }
    }
}
