import Foundation

/// Turn a university/registrar iCalendar export into draft weekly `ClassSession`s. Events that
/// recur weekly (an RRULE with BYDAY) — or the same titled event repeated on several weekdays —
/// are grouped into one class spanning those days, matching how StudyBar models a class.
enum ClassImport {
    static func fromICS(_ text: String) -> [ClassSession] {
        let cal = Calendar.current
        let events = ICSParser.parse(text).filter { $0.start != nil }
        struct Key: Hashable { let title: String; let s: Int; let e: Int; let room: String }
        var groups: [Key: (days: Set<Int>, url: String)] = [:]
        for ev in events {
            guard let st = ev.start else { continue }
            let s = minutesOfDay(st, cal)
            let e = ev.end.map { minutesOfDay($0, cal) } ?? (s + 50)
            var days = Set(weekdays(fromRRULE: ev.rrule))
            if days.isEmpty { days = [cal.component(.weekday, from: st)] }
            let key = Key(title: ev.title.trimmingCharacters(in: .whitespacesAndNewlines), s: s, e: e, room: ev.location)
            groups[key, default: (Set<Int>(), ev.url)].days.formUnion(days)
            if (groups[key]?.url ?? "").isEmpty, !ev.url.isEmpty { groups[key]?.url = ev.url }
        }
        return groups.map { key, val -> ClassSession in
            var c = ClassSession(courseID: nil)
            c.title = key.title.isEmpty ? "Class" : key.title
            c.days = val.days.sorted()
            c.weekday = c.days?.first ?? 2
            c.startMinutes = key.s
            c.endMinutes = max(key.s + 5, key.e)
            c.room = key.room
            if isMeetingLink(val.url) { c.link = val.url; c.online = true }
            return c
        }
        .sorted { ($0.weekdays.first ?? 0, $0.startMinutes) < ($1.weekdays.first ?? 0, $1.startMinutes) }
    }

    private static func minutesOfDay(_ d: Date, _ cal: Calendar) -> Int {
        let c = cal.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// FREQ=WEEKLY;BYDAY=MO,WE,FR → [2,4,6]. Handles nth-day codes like 1MO by taking the day part.
    private static func weekdays(fromRRULE rrule: String) -> [Int] {
        guard rrule.uppercased().contains("WEEKLY") else { return [] }
        let map = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
        guard let byday = rrule.split(separator: ";").first(where: { $0.uppercased().hasPrefix("BYDAY=") }),
              let codes = byday.split(separator: "=").last?.split(separator: ",").map(String.init) else { return [] }
        return codes.compactMap { map[String($0.suffix(2)).uppercased()] }.sorted()
    }

    private static func isMeetingLink(_ s: String) -> Bool {
        let l = s.lowercased()
        return ["zoom", "meet.google", "teams.microsoft", "webex", "bbcollab"].contains { l.contains($0) }
    }
}
