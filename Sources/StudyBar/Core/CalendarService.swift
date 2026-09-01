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

    /// Calendars we're allowed to add events to.
    var writableCalendars: [EKCalendar] {
        store.calendars(for: .event).filter { $0.allowsContentModifications }
            .sorted { $0.title < $1.title }
    }
    var defaultCalendar: EKCalendar? { store.defaultCalendarForNewEvents }

    /// Create a new event in the macOS Calendar. Returns false if not authorized
    /// or the save failed.
    @discardableResult
    func createEvent(title: String, start: Date, end: Date, allDay: Bool,
                     calendar: EKCalendar?, notes: String? = nil, days: Int) -> Bool {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return false }
        guard let target = calendar ?? store.defaultCalendarForNewEvents ?? writableCalendars.first else { return false }
        let ev = EKEvent(eventStore: store)
        ev.title = title
        ev.isAllDay = allDay
        ev.startDate = start
        ev.endDate = allDay ? start : max(end, start.addingTimeInterval(60))
        if let notes, !notes.isEmpty { ev.notes = notes }
        ev.calendar = target
        do { try store.save(ev, span: .thisEvent); load(days: days); return true }
        catch { return false }
    }

    /// Fetch + parse a subscribed iCal feed (Canvas / Google / school).
    func fetchFeed(_ raw: String) async -> [ICSEvent]? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("webcal://") { s = "https://" + s.dropFirst("webcal://".count) }
        guard let url = URL(string: s) else { return nil }
        do {
            let (data, _) = try await URLSession.sb.data(from: url)
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return ICSParser.parse(text)
        } catch { return nil }
    }
}
