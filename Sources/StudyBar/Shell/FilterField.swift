import SwiftUI

/// The toolbar field while a list module is open: it filters that list as you type. A course
/// suggestion becomes a token (↩); ⌘↩ searches everywhere instead; ↩ with no suggestion hands
/// the keyboard to the list. In other modules the window shows the plain search field.
struct FilterField: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var win: WindowModel
    let courses: [Course]
    let placeholder: String
    @Binding var expanded: Bool

    @FocusState private var focused: Bool
    @State private var highlight: Int?
    /// Esc hides the suggestions until the text changes again.
    @State private var dismissed = false

    private var suggestions: [ListFilter.Suggestion] { ListFilter.suggestions(for: win.filter.text, courses: courses) }
    private var showsSuggestions: Bool { focused && !dismissed && !suggestions.isEmpty }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            if let t = win.filter.course { token(t) }
            TextField(placeholder, text: $win.filter.text)
                .textFieldStyle(.plain).font(.callout)
                .focused($focused)
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) { searchEverywhere(); return .handled }
                    if showsSuggestions, let i = highlight, suggestions.indices.contains(i) { take(suggestions[i]); return .handled }
                    win.listFocusRequest += 1
                    return .handled
                }
                .onKeyPress(.delete) {
                    guard win.filter.text.isEmpty, win.filter.course != nil else { return .ignored }
                    win.filter.course = nil
                    return .handled
                }
                // Not onKeyPress(.escape): a focused text field takes Escape as its own cancel.
                .onExitCommand {
                    if showsSuggestions { dismissed = true } else { win.filter.text = "" }
                }
            if !win.filter.text.isEmpty || win.filter.course != nil {
                Button { win.filter = ListFilter() } label: { Image(systemName: "xmark.circle.fill").accessibilityLabel("Clear filter") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.sbSurface, in: Capsule())
        .overlay(alignment: .topTrailing) {
            if showsSuggestions { suggestionList.offset(y: 30) }
        }
        .onChange(of: win.filter.text) { _, _ in
            dismissed = false
            // The first course is ready for ↩; with only "Search everywhere" left, ↩ goes to the list.
            highlight = suggestions.first.flatMap { if case .searchEverywhere = $0 { return nil } else { return 0 } }
        }
        .onChange(of: win.focusFilterRequest) { _, _ in focused = true }
        .onChange(of: focused || win.filter.course != nil) { _, v in expanded = v }
        .onAppear { expanded = focused || win.filter.course != nil }
    }

    private func move(_ d: Int) -> KeyPress.Result {
        guard showsSuggestions else { return .ignored }
        let n = suggestions.count
        highlight = ((highlight ?? (d > 0 ? -1 : n)) + d + n) % n
        return .handled
    }

    private func take(_ s: ListFilter.Suggestion) {
        switch s {
        case .course(let id): win.filter.course = .course(id); win.filter.text = ""
        case .noCourse: win.filter.course = .noCourse; win.filter.text = ""
        case .searchEverywhere: searchEverywhere()
        }
    }

    private func searchEverywhere() {
        let q = win.filter.text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        win.filter = ListFilter()
        state.globalSearch = q
    }

    @ViewBuilder private func token(_ t: ListFilter.CourseToken) -> some View {
        let course: Course? = { if case .course(let id) = t { return courses.first { $0.id == id } } else { return nil } }()
        HStack(spacing: 4) {
            if let course { Circle().fill(course.color).frame(width: 7, height: 7) }
            Text(course.map { $0.code.isEmpty ? $0.name : $0.code } ?? "No course").lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background((course?.color ?? .secondary).opacity(0.2), in: Capsule())
        .accessibilityLabel("Filtered to \(course?.name ?? "no course")")
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { i, s in
                Button { take(s) } label: { row(s, on: i == highlight) }.buttonStyle(.plain)
            }
        }
        .padding(DS.Space.xs)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }

    private func row(_ s: ListFilter.Suggestion, on: Bool) -> some View {
        HStack(spacing: DS.Space.m) {
            switch s {
            case .course(let id):
                let c = courses.first { $0.id == id }
                Circle().fill(c?.color ?? .secondary).frame(width: 8, height: 8)
                Text(c?.code ?? "").fontWeight(.semibold)
                Text(c?.name ?? "").foregroundStyle(.secondary).lineLimit(1)
            case .noCourse:
                Image(systemName: "circle.dashed").font(.caption).foregroundStyle(.secondary)
                Text("No course")
            case .searchEverywhere(let q):
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                Text("Search everywhere for “\(q)”").lineLimit(1)
                Spacer(minLength: DS.Space.s)
                Text("⌘↩").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if on, case .searchEverywhere = s {} else if on { Text("↩").font(.caption).foregroundStyle(.secondary) }
        }
        .font(.callout)
        .padding(.horizontal, DS.Space.m).padding(.vertical, 5)
        .background(on ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .contentShape(Rectangle())
    }
}
