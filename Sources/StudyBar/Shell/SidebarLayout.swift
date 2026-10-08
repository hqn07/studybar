import Foundation

/// One run of sidebar rows, with the label above it if it earns one.
struct SidebarSection: Equatable {
    var title: String?
    var ids: [String]
}

/// Which sidebar rows go together and which groups get a header. Pure, so the self-test can
/// pin it. A header over one or two rows is noise ("ASSIGNMENTS › Assignments"), and a short
/// list needs no headers at all — so they appear only on a group of three or more, and only
/// once more than eight modules are showing.
enum SidebarLayout {
    /// - Parameters:
    ///   - visible: the shown modules, in display order. Settings is dropped: it is pinned to
    ///     the bottom of the sidebar, outside the list.
    ///   - favorites: starred module ids, in their order; they head the list.
    ///   - flat: "Most used" / "Custom" order — one list, no groups.
    static func sections(visible: [ModuleInfo], favorites: [String], flat: Bool) -> [SidebarSection] {
        let shown = visible.filter { $0.id != "settings" }
        let favs = favorites.filter { id in shown.contains { $0.id == id } }
        var out: [SidebarSection] = favs.isEmpty ? [] : [SidebarSection(title: "Favorites", ids: favs)]
        let rest = shown.filter { !favs.contains($0.id) }
        guard !rest.isEmpty else { return out }
        if flat { return out + [SidebarSection(title: nil, ids: rest.map(\.id))] }

        var groups: [(ModuleCategory, [String])] = []
        for m in rest {
            if let i = groups.firstIndex(where: { $0.0 == m.category }) { groups[i].1.append(m.id) }
            else { groups.append((m.category, [m.id])) }
        }
        for (i, (cat, ids)) in groups.enumerated() {
            let titled = rest.count > 8 && ids.count >= 3 && (i > 0 || !favs.isEmpty)
            out.append(SidebarSection(title: titled ? cat.rawValue : nil, ids: ids))
        }
        return out
    }
}
