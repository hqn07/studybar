import Foundation
import Combine

enum OrderMode: String, CaseIterable, Identifiable {
    case category = "Category", mostUsed = "Most used", custom = "Custom"
    var id: String { rawValue }
}

/// User control over which modules appear, which are pinned, and their order.
@MainActor
final class ModulePrefs: ObservableObject {
    @Published var hidden: Set<String> { didSet { save("hiddenModules", Array(hidden)) } }
    @Published var favorites: [String] { didSet { save("favoriteModules", favorites) } }
    @Published var order: OrderMode { didSet { UserDefaults.standard.set(order.rawValue, forKey: "moduleOrder") } }
    @Published var custom: [String] { didSet { save("customOrder", custom) } }
    @Published var categoryOrder: [String] { didSet { save("categoryOrder", categoryOrder) } }
    @Published private var usage: [String: Int] {
        didSet { UserDefaults.standard.set(usage, forKey: "moduleUsage") }
    }

    /// Modules that can never be hidden (needed to reach settings / home).
    static let locked: Set<String> = ["today", "settings"]

    init() {
        hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenModules") ?? [])
        favorites = UserDefaults.standard.stringArray(forKey: "favoriteModules") ?? []
        order = OrderMode(rawValue: UserDefaults.standard.string(forKey: "moduleOrder") ?? "") ?? .category
        custom = UserDefaults.standard.stringArray(forKey: "customOrder") ?? []
        categoryOrder = UserDefaults.standard.stringArray(forKey: "categoryOrder") ?? []
        usage = (UserDefaults.standard.dictionary(forKey: "moduleUsage") as? [String: Int]) ?? [:]
        reconcileCustom()
        reconcileCategories()
    }

    func isVisible(_ id: String) -> Bool { !hidden.contains(id) || Self.locked.contains(id) }
    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }
    func uses(_ id: String) -> Int { usage[id] ?? 0 }

    func toggleHidden(_ id: String) {
        guard !Self.locked.contains(id) else { return }
        if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) }
    }
    func toggleFavorite(_ id: String) {
        if let i = favorites.firstIndex(of: id) { favorites.remove(at: i) } else { favorites.append(id) }
    }
    func recordUse(_ id: String) { usage[id, default: 0] += 1 }

    /// Keep `custom` in sync with the registry (append new, drop removed). Assign only if changed.
    func reconcileCustom() {
        let merged = completeCustom()
        if merged != custom { custom = merged }
    }
    /// Pure: custom order with any missing modules appended — no mutation.
    private func completeCustom() -> [String] {
        let all = ModuleRegistry.all.map(\.id)
        return custom.filter { all.contains($0) } + all.filter { !custom.contains($0) }
    }

    /// The order to show modules in a flat list (Most-used / Custom). Pure — safe to call during render.
    func orderedIDs() -> [String] {
        let all = ModuleRegistry.all.map(\.id)
        switch order {
        case .category: return all
        case .mostUsed:
            return all.enumerated().sorted { a, b in
                let ua = uses(a.element), ub = uses(b.element)
                return ua != ub ? ua > ub : a.offset < b.offset
            }.map(\.element)
        case .custom:
            return completeCustom()
        }
    }

    func move(_ id: String, up: Bool) {
        var arr = completeCustom()
        guard let i = arr.firstIndex(of: id) else { return }
        let j = up ? i - 1 : i + 1
        guard arr.indices.contains(j) else { return }
        arr.swapAt(i, j)
        custom = arr
    }

    // MARK: Categories

    func reconcileCategories() {
        let merged = completeCategories()
        if merged != categoryOrder { categoryOrder = merged }
    }
    private func completeCategories() -> [String] {
        let all = ModuleCategory.allCases.map(\.rawValue)
        return categoryOrder.filter { all.contains($0) } + all.filter { !categoryOrder.contains($0) }
    }
    /// Pure — safe to call during render.
    func orderedCategories() -> [ModuleCategory] {
        completeCategories().compactMap { ModuleCategory(rawValue: $0) }
    }
    func moveCategory(_ raw: String, up: Bool) {
        var arr = completeCategories()
        guard let i = arr.firstIndex(of: raw) else { return }
        let j = up ? i - 1 : i + 1
        guard arr.indices.contains(j) else { return }
        arr.swapAt(i, j)
        categoryOrder = arr
    }

    private func save(_ key: String, _ v: [String]) { UserDefaults.standard.set(v, forKey: key) }
}
