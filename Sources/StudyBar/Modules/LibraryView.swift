import SwiftUI

/// Which shelf of the unified Library is showing. Persisted so it survives module switches.
enum LibraryTab: String, CaseIterable, Identifiable {
    case links, readlater, files, feeds
    var id: String { rawValue }
    var title: String {
        switch self {
        case .links: "Links"
        case .readlater: "Read later"
        case .files: "Files"
        case .feeds: "Feeds"
        }
    }
    var symbol: String {
        switch self {
        case .links: "link"
        case .readlater: "books.vertical"
        case .files: "folder"
        case .feeds: "dot.radiowaves.left.and.right"
        }
    }
}

/// The unified **Library** module — Links · Read later · Files · Feeds, folded from four
/// separate modules (Quick Links, Reading List, Files, News). Each face keeps its own view
/// and toolbar; this wrapper just picks which to show. (Same pattern as Schedule's Week/Plan.)
struct LibraryView: View {
    @AppStorage("libraryTab") private var tabRaw = LibraryTab.links.rawValue
    var body: some View {
        switch LibraryTab(rawValue: tabRaw) ?? .links {
        case .links:    LinksView()
        case .readlater: ReadingListView()
        case .files:    FilesView()
        case .feeds:    RSSView()
        }
    }
}

/// Segmented Links · Read later · Files · Feeds control for any Library face's toolbar.
struct LibraryTabPicker: View {
    @AppStorage("libraryTab") private var tabRaw = LibraryTab.links.rawValue
    var body: some View {
        Picker("", selection: $tabRaw) {
            ForEach(LibraryTab.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
        }
        .pickerStyle(.segmented).labelStyle(.iconOnly).frame(width: 158).fixedSize()
        .help("Links · Read later · Files · Feeds")
    }
}
