import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Indexes notes + open assignments into system Spotlight so they surface in a
/// system-wide search and open StudyBar via the continue-activity handler.
@MainActor
enum SpotlightIndexer {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "spotlightIndex") as? Bool ?? true }

    private static var lastReindex: Date = .distantPast

    /// Rebuild the whole index (launch / manual).
    static func reindex(_ data: AppData) {
        guard enabled else { return }
        lastReindex = .now
        var items: [CSSearchableItem] = []

        for n in data.notes {
            let attr = CSSearchableItemAttributeSet(contentType: .text)
            attr.title = n.title.isEmpty ? String(n.body.prefix(40)) : n.title
            attr.contentDescription = String(n.body.prefix(200))
            attr.keywords = n.tags
            items.append(CSSearchableItem(uniqueIdentifier: "note:\(n.id.uuidString)",
                                          domainIdentifier: "studybar.note", attributeSet: attr))
        }
        for a in data.assignments where a.status != .done {
            let attr = CSSearchableItemAttributeSet(contentType: .text)
            attr.title = a.title
            attr.contentDescription = a.notes.isEmpty ? (a.due.map { "Due \($0.dayMonth)" } ?? "Assignment") : a.notes
            items.append(CSSearchableItem(uniqueIdentifier: "assignment:\(a.id.uuidString)",
                                          domainIdentifier: "studybar.assignment", attributeSet: attr))
        }

        let index = CSSearchableIndex.default()
        index.deleteAllSearchableItems { _ in
            index.indexSearchableItems(items) { _ in }
        }
    }

    /// Reindex at most once per 30s (called from the debounced save).
    static func reindexThrottled(_ data: AppData) {
        guard enabled, Date().timeIntervalSince(lastReindex) > 30 else { return }
        reindex(data)
    }

    static func clear() { CSSearchableIndex.default().deleteAllSearchableItems { _ in } }

    /// Open the module for a Spotlight result identifier ("note:uuid" / "assignment:uuid").
    static func open(_ identifier: String) {
        let parts = identifier.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let s = AppState.current else { return }
        switch parts[0] {
        case "note":       s.selectedModuleID = "notes"
        case "assignment": s.selectedModuleID = "assignments"
        default:           break
        }
        s.globalSearch = ""
        WindowOpener.open?("main")
    }
}
