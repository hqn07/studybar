import SwiftUI
import CoreServices

/// (29) Offline definitions via macOS Dictionary Services (DCSCopyTextDefinition).
enum DictionaryService {
    static func define(_ term: String) -> String? {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let range = CFRange(location: 0, length: (t as NSString).length)
        guard let result = DCSCopyTextDefinition(nil, t as CFString, range) else { return nil }
        return result.takeRetainedValue() as String
    }
}

struct DictionaryView: View {
    @State private var term = ""
    @State private var definition: String?
    @State private var searched = false
    @AppStorage("dictRecents") private var recentsRaw = ""

    private var recents: [String] { recentsRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        ModulePane(title: "Dictionary") {
            Button { defineClipboard() } label: { Image(systemName: "doc.on.clipboard") }
                .help("Define word on clipboard")
        } content: {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "character.book.closed").foregroundStyle(.secondary)
                    TextField("Look up a word…", text: $term, onCommit: lookup)
                        .textFieldStyle(.plain)
                    Button("Define", action: lookup).disabled(term.isEmpty)
                }.padding(10)
                if !recents.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(recents, id: \.self) { w in
                                Button { term = w; lookup() } label: {
                                    Text(w).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(.background.secondary, in: Capsule())
                                }.buttonStyle(.plain)
                            }
                            Button { recentsRaw = "" } label: { Image(systemName: "xmark.circle").font(.caption2) }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }.padding(.horizontal, 10).padding(.bottom, 6)
                    }
                }
                Divider()
                ScrollView {
                    if let def = definition, !def.isEmpty {
                        Text(def).font(.body).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    } else if searched {
                        VStack(spacing: 8) {
                            EmptyState(symbol: "questionmark.circle", title: "No definition",
                                       subtitle: "“\(term)” isn’t in the active dictionaries. Enable more in Dictionary.app.")
                            Button("Open Dictionary.app") { openInDictionary() }
                        }
                    } else {
                        EmptyState(symbol: "character.book.closed", title: "Dictionary & Thesaurus",
                                   subtitle: "Uses macOS’s built-in dictionaries. Works offline.")
                    }
                }
                if let def = definition, !def.isEmpty {
                    Divider()
                    HStack {
                        Button { copy(def) } label: { Label("Copy", systemImage: "doc.on.doc") }
                            .buttonStyle(.borderless).font(.caption)
                        Spacer()
                        Button { openInDictionary() } label: {
                            Label("Open in Dictionary.app", systemImage: "arrow.up.right.square")
                        }.buttonStyle(.borderless).font(.caption)
                    }.padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
    }

    private func lookup() {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        definition = DictionaryService.define(t)
        searched = true
        if definition != nil { addRecent(t) }
    }

    private func defineClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        let firstWord = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).first.map(String.init) ?? ""
        guard !firstWord.isEmpty else { return }
        term = firstWord
        lookup()
    }

    private func addRecent(_ t: String) {
        var list = recents.filter { $0.caseInsensitiveCompare(t) != .orderedSame }
        list.insert(t, at: 0)
        recentsRaw = list.prefix(15).joined(separator: "\n")
    }
    private func copy(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    }

    private func openInDictionary() {
        let t = term.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? term
        if let url = URL(string: "dict://\(t)") { NSWorkspace.shared.open(url) }
    }
}
