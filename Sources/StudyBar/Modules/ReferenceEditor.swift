import SwiftUI

struct ReferenceEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Reference
    @State private var authorsText: String

    init(reference: Reference) {
        _draft = State(initialValue: reference)
        _authorsText = State(initialValue: reference.authors.joined(separator: "\n"))
    }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Reference") {
                Button("Delete", role: .destructive) {
                    state.data.references.removeAll { $0.id == draft.id }; dismiss()
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Type", selection: $draft.type) {
                        ForEach(RefType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)

                    labeled("Title") { TextField("", text: $draft.title, axis: .vertical) }
                    labeled("Authors (one per line, “Last, First”)") {
                        TextEditor(text: $authorsText).frame(height: 60)
                            .font(.callout).scrollContentBackground(.hidden)
                            .background(Color.sbSurface, in: RoundedRectangle(cornerRadius: 6))
                    }
                    HStack {
                        labeled("Year") { TextField("", text: $draft.year) }
                        labeled(containerLabel) { TextField("", text: $draft.container) }
                    }
                    if draft.type == .article {
                        HStack {
                            labeled("Volume") { TextField("", text: $draft.volume) }
                            labeled("Issue") { TextField("", text: $draft.issue) }
                            labeled("Pages") { TextField("", text: $draft.pages) }
                        }
                        labeled("DOI") { TextField("", text: $draft.doi) }
                    }
                    if draft.type == .website {
                        labeled("URL") { TextField("", text: $draft.url) }
                    }
                    HStack {
                        Text("Course").font(.caption).foregroundStyle(.secondary)
                        CoursePicker(courseID: $draft.courseID)
                    }
                    preview
                }.padding(14)
            }
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .toolbar(.hidden, for: .windowToolbar)
    }

    private var containerLabel: String {
        switch draft.type { case .article: return "Journal"; case .book: return "Publisher"; case .website: return "Site" }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PREVIEW").font(.caption2.bold()).foregroundStyle(.secondary)
            ForEach(CiteStyle.allCases) { s in
                if s != .bibtex {
                    HStack(alignment: .top) {
                        Text(s.rawValue).font(.caption2.bold()).foregroundStyle(.tint).frame(width: 56, alignment: .leading)
                        Text(CitationFormatter.format(previewRef, style: s).replacingOccurrences(of: "*", with: ""))
                            .font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private var previewRef: Reference {
        var r = draft
        r.authors = parseAuthors()
        return r
    }

    @ViewBuilder private func labeled<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            c().textFieldStyle(.roundedBorder)
        }
    }

    private func parseAuthors() -> [String] {
        authorsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func save() {
        draft.authors = parseAuthors()
        if draft.title.trimmingCharacters(in: .whitespaces).isEmpty {
            state.data.references.removeAll { $0.id == draft.id }
        } else if let i = state.data.references.firstIndex(where: { $0.id == draft.id }) {
            state.data.references[i] = draft
        } else {
            state.data.references.append(draft)
        }
        dismiss()
    }
}
