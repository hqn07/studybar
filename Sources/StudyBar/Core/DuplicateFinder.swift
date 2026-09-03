import Foundation

/// Finds likely-duplicate assignments — the same real task imported from two sources (e.g. a
/// Canvas feed and the syllabus), which have different UIDs so the import dedup misses them.
/// A group is a set of assignments the user reviews; merging keeps one and deletes the rest
/// (undoable — nothing is removed without confirmation).
struct DupGroup: Identifiable {
    let id = UUID()
    var items: [Assignment]     // ≥2, likely the same assignment
    var reason: String
}

enum DuplicateFinder {
    // MARK: Deterministic (fast, safe)

    /// Group open assignments that share a course + due date and have similar titles.
    static func find(_ assignments: [Assignment]) -> [DupGroup] {
        let cal = Calendar.current
        var buckets: [String: [Assignment]] = [:]
        for a in assignments where a.status != .done {
            guard let due = a.due else { continue }   // undated can't be matched confidently
            let day = Int(cal.startOfDay(for: due).timeIntervalSince1970)
            buckets["\(a.courseID?.uuidString ?? "-")|\(day)", default: []].append(a)
        }
        var groups: [DupGroup] = []
        for bucket in buckets.values where bucket.count >= 2 {
            var used = Set<UUID>()
            for i in bucket.indices where !used.contains(bucket[i].id) {
                var cluster = [bucket[i]]
                for j in (i + 1)..<bucket.count where !used.contains(bucket[j].id) {
                    if similar(bucket[i].title, bucket[j].title) {
                        cluster.append(bucket[j]); used.insert(bucket[j].id)
                    }
                }
                if cluster.count >= 2 {
                    used.insert(bucket[i].id)
                    groups.append(DupGroup(items: cluster, reason: "Same due date · similar title"))
                }
            }
        }
        return groups
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        let na = normalize(a), nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        let ta = Set(na.split(separator: " ")), tb = Set(nb.split(separator: " "))
        let jac = Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
        return jac >= 0.6      // conservative — avoid false merges; AI deep-scan catches the rest
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Pick which assignment to keep when merging: prefer a synced/imported one (stable id),
    /// then one with a due date, then the longest title (most descriptive).
    static func keeper(_ items: [Assignment]) -> Assignment {
        items.max { a, b in
            (rank(a), a.title.count) < (rank(b), b.title.count)
        } ?? items[0]
    }
    private static func rank(_ a: Assignment) -> Int {
        (a.canvasID != nil ? 2 : 0) + (a.sourceUID != nil ? 1 : 0) + (a.due != nil ? 1 : 0)
    }
}
