import Foundation

/// What ⌘K remembers: the items opened (a note, deck, book…) and the commands run, newest
/// first. Entries are `ItemRef.recentKey` or `"cmd:<title>"`; one that points at something
/// deleted is dropped when the palette shows it.
enum PaletteRecents {
    static let key = "paletteRecents"
    static let limit = 8

    /// `entry` at the front, its older copy removed, at most `limit` kept. Pure.
    static func adding(_ entry: String, to list: [String]) -> [String] {
        Array(([entry] + list.filter { $0 != entry }).prefix(limit))
    }

    static var current: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func record(_ entry: String) {
        UserDefaults.standard.set(adding(entry, to: current), forKey: key)
    }
}

/// The empty palette, top to bottom: the selected item's actions, five recents, the modules,
/// then everything else. Pure.
enum PaletteSections {
    static func emptyQuery(selection: [CommandPalette.Action], recents: [CommandPalette.Action],
                           goTo: [CommandPalette.Action], others: [CommandPalette.Action]) -> [CommandPalette.Action] {
        selection + recents.prefix(5) + goTo + others
    }
}
