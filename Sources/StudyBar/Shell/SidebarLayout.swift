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

    /// The modules ⌘1–⌘9 open: the sidebar's rows top to bottom — favorites first, Settings
    /// (pinned below the list) left out — at most nine. Pure.
    static func shortcutOrder(visible: [ModuleInfo], favorites: [String], flat: Bool) -> [String] {
        Array(sections(visible: visible, favorites: favorites, flat: flat).flatMap(\.ids).prefix(9))
    }

    /// The shown modules in display order: by group in category order, or the flat order.
    @MainActor static func visible(prefs: ModulePrefs) -> [ModuleInfo] {
        let ids = prefs.order == .category
            ? prefs.orderedCategories().flatMap { cat in ModuleRegistry.all.filter { $0.category == cat }.map(\.id) }
            : prefs.orderedIDs()
        return ids.compactMap { ModuleRegistry.info($0) }.filter { prefs.isVisible($0.id) }
    }

    @MainActor static func shortcutOrder(prefs: ModulePrefs) -> [String] {
        shortcutOrder(visible: visible(prefs: prefs), favorites: prefs.favorites, flat: prefs.order != .category)
    }
}
