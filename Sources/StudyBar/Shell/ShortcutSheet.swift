import SwiftUI

/// ⌘/ — what the keyboard can do here.
///
/// The app ships fifty-odd key equivalents and, before this, exactly none of them were
/// discoverable from the keyboard: they lived in tooltips, in a Settings tab nobody opens, or
/// nowhere at all. A student who never finds ⇧⌘A types every question with the mouse.
struct ShortcutSheet: View {
    @Binding var isPresented: Bool

    struct Group: Identifiable {
        let id = UUID()
        let title: String
        let items: [(String, String)]
    }

    static let groups: [Group] = [
        .init(title: "Anywhere", items: [
            ("⌘K", "Open anything — a note, an assignment, a module, or a sum"),
            ("⌃⌥N", "Capture a note without leaving the app you're in"),
            ("⌃⌥T", "Capture a task the same way"),
            ("⌘\\", "Collapse or expand the sidebar"),
            ("⌘Z", "Undo the last change"),
            ("⌘/", "This list"),
        ]),
        .init(title: "Window", items: [
            ("⌘O", "Open the workspace window from the popover"),
            ("⌘M", "Minimize"),
            ("⌘W", "Close the window (the app stays in the menu bar)"),
            ("⌃⌘F", "Full screen"),
        ]),
        .init(title: "Notes", items: [
            ("⌘N", "New note"),
            ("⇧⌘L", "Hide the note list — just this note"),
            ("⇧⌘F", "Focus mode — hide everything but the writing"),
            ("⌘E", "Switch between reading and editing"),
            ("⌘F", "Find inside this note"),
        ]),
        .init(title: "Ask this note", items: [
            ("⇧⌘A", "Ask about the note you're reading"),
            ("⌘↩", "Insert the answer under its question"),
            ("Esc", "Put the panel away (the thread is kept)"),
        ]),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { isPresented = false }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Keyboard", systemImage: "command").font(.headline)
                    Spacer()
                    Button { isPresented = false } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Self.groups) { group in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(group.title.uppercased())
                                    .font(.caption2.weight(.bold)).tracking(0.6)
                                    .foregroundStyle(.secondary)
                                ForEach(group.items, id: \.0) { key, what in
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(key)
                                            .font(.callout.monospaced())
                                            .frame(width: 54, alignment: .leading)
                                            .foregroundStyle(.tint)
                                        Text(what).font(.callout)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .frame(width: 460, height: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
            .shadow(radius: 24)
        }
        .onExitCommand { isPresented = false }
    }
}
