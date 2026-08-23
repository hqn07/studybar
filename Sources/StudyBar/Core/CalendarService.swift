import Foundation
import EventKit
import SwiftUI

/// (10) Reads macOS Calendar via EventKit (read-only), with per-calendar filtering.
@MainActor
final class CalendarService: ObservableObject {
    @Published var events: [EKEvent] = []
    @Published var calendars: [EKCalendar] = []
    @Published var authorized = false
    @Published var denied = false
    @Published var disabled: Set<String> {           // calendarIdentifiers the user hid
        didSet { UserDefaults.standard.set(Array(disabled), forKey: "calDisabled") }
    }

    private let store = EKEventStore()

    init() {
        disabled = Set(UserDefaults.standard.stringArray(forKey: "calDisabled") ?? [])
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func requestAndLoad(days: Int) {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.authorized = granted
                self.denied = !granted
                if granted { self.load(days: days) }
            }
        }
    }

    func load(days: Int) {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        authorized = true
        calendars = store.calendars(for: .event).sorted { $0.title < $1.title }
        let active = calendars.filter { !disabled.contains($0.calendarIdentifier) }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: active)
        events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    func toggle(_ cal: EKCalendar, days: Int) {
        let id = cal.calendarIdentifier
        if disabled.contains(id) { disabled.remove(id) } else { disabled.insert(id) }
        load(days: days)
    }

    /// Fetch + parse a subscribed iCal feed (Canvas / Google / school).
    func fetchFeed(_ raw: String) async -> [ICSEvent]? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("webcal://") { s = "https://" + s.dropFirst("webcal://".count) }
        guard let url = URL(string: s) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return ICSParser.parse(text)
        } catch { return nil }
    }
}
