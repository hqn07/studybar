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

    // MARK: AI deep-scan (semantic, opt-in)

    /// One call: number the assignments, ask the model to group duplicates by index. Handles
    /// reworded duplicates the deterministic pass misses. `provider` nil → nil.
    static func aiScan(_ assignments: [Assignment], provider: AIProvider?) async -> [DupGroup]? {
        guard let provider else { return nil }
        let open = assignments.filter { $0.status != .done }
        guard open.count >= 2 else { return [] }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let numbered = open.enumerated().map { i, a in
            "\(i). \(a.title.isEmpty ? "Untitled" : a.title) [\(a.due.map { df.string(from: $0) } ?? "no date")]"
        }.joined(separator: "\n")
        let sys = """
        You find DUPLICATE assignments — the same real task listed more than once (e.g. imported \
        from two sources under slightly different names). Group ONLY items that are clearly the \
        same task. Reply with ONLY a JSON array of groups, each group an array of the item numbers: \
        [[0,5],[2,9]]. Do not list items that have no duplicate. Be conservative — when unsure, \
        don't group.
        """
        let user = "Assignments:\n\(numbered)"
        let msgs = [AIMessage(role: .user, text: user)]
        let out: String
        do {
            if let ollama = provider as? OllamaProvider {
                out = try await ollama.completePlainOnce(system: sys, messages: msgs)
            } else {
                out = try await provider.completePlain(system: sys, messages: msgs)
            }
        } catch {
            Diagnostics.error(.ai, "Duplicate scan failed: \(error.localizedDescription)")
            return nil
        }
        guard let s = out.firstIndex(of: "["), let e = out.lastIndex(of: "]"), s < e,
              let data = String(out[s...e]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[Int]] else {
            Diagnostics.warn(.ai, "Duplicate scan: unparseable reply (\(out.count) chars)")
            return nil
        }
        var groups: [DupGroup] = []
        let cal = Calendar.current
        for g in arr {
            let items = g.compactMap { open.indices.contains($0) ? open[$0] : nil }
            guard items.count >= 2 else { continue }
            // Sanity filter: real duplicates share a due date. Weak models sometimes group
            // unrelated items (e.g. "Homework 1" with "Quiz 3"); reject groups spanning days.
            let days = Set(items.compactMap { $0.due.map { cal.startOfDay(for: $0) } })
            guard days.count <= 1 else { continue }
            groups.append(DupGroup(items: items, reason: "AI: same assignment"))
        }
        return groups
    }
}
