import SwiftUI

/// What the toolbar field narrows the list you're on to: one course token and the typed text,
/// both must match. A list passes its own searchable fields; lists that rank fuzzily (Notes,
/// Snippets) use `matchesCourse` and their own ranking on `text`. Pure.
struct ListFilter: Equatable {
    /// `noCourse` rather than `none`: on an optional token `.none` would read as nil.
    enum CourseToken: Equatable { case course(UUID), noCourse }
    enum Suggestion: Equatable { case course(UUID), noCourse, searchEverywhere(String) }

    var text = ""
    var course: CourseToken? = nil

    var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
    var isActive: Bool { !trimmed.isEmpty || course != nil }

    func matchesCourse(_ courseID: UUID?) -> Bool {
        switch course {
        case nil: return true
        case .noCourse: return courseID == nil
        case .course(let id): return courseID == id
        }
    }

    func matches(courseID: UUID?, fields: [String]) -> Bool {
        guard matchesCourse(courseID) else { return false }
        let t = trimmed
        return t.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(t) }
    }

    /// Courses by code first, then by name, at most four; "No course" when the text starts it;
    /// Search everywhere always last. Nothing for empty text.
    static func suggestions(for text: String, courses: [Course]) -> [Suggestion] {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        let byCode = courses.filter { $0.code.localizedCaseInsensitiveContains(t) }
        let byName = courses.filter { c in !byCode.contains { $0.id == c.id } && c.name.localizedCaseInsensitiveContains(t) }
        var out: [Suggestion] = (byCode + byName).prefix(4).map { .course($0.id) }
        if t.count >= 2, "no course".hasPrefix(t.lowercased()) { out.append(.noCourse) }
        out.append(.searchEverywhere(text))
        return out
    }

    /// A token for a course that no longer exists would match nothing and strand the list empty.
    func pruned(courses: [Course]) -> ListFilter {
        guard case .course(let id) = course, !courses.contains(where: { $0.id == id }) else { return self }
        var f = self; f.course = nil; return f
    }
}

private struct ListFilterKey: EnvironmentKey { static let defaultValue = ListFilter() }
extension EnvironmentValues {
    /// The left pane's filter, from the toolbar field. Empty everywhere else.
    var listFilter: ListFilter {
        get { self[ListFilterKey.self] }
        set { self[ListFilterKey.self] = newValue }
    }
}

private struct ListFocusRequestKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    /// Changes when the window wants its left pane's list to take the keyboard.
    var listFocusRequest: Int {
        get { self[ListFocusRequestKey.self] }
        set { self[ListFocusRequestKey.self] = newValue }
    }
}

/// "3 of 58 notes · Clear · Esc" over a filtered list — the field is far from the list, so the
/// list says it's narrowed. Nothing when the filter is off.
struct FilterStatus: View {
    let shown: Int
    let total: Int
    let noun: String
    @Environment(\.listFilter) private var filter
    @Environment(\.workspace) private var workspace

    var body: some View {
        if filter.isActive {
            HStack(spacing: DS.Space.s) {
                Text("\(shown) of \(total) \(noun)")
                Spacer(minLength: DS.Space.s)
                Button("Clear · Esc") { workspace?.filter = ListFilter() }
                    .buttonStyle(.borderless)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
        }
    }
}
