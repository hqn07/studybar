import Foundation

struct ICSEvent: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var start: Date?
    var end: Date?
    var url: String
    var location: String
    var uid: String = ""     // RFC 5545 UID — stable per source item, used to dedup imports
    var rrule: String = ""   // raw RRULE (e.g. FREQ=WEEKLY;BYDAY=MO,WE,FR) — for class import
}

/// Minimal iCalendar (RFC 5545) parser — enough for Canvas / Google / school feeds.
enum ICSParser {
    static func parse(_ text: String) -> [ICSEvent] {
        let unfolded = unfold(text)
        var events: [ICSEvent] = []
        var cur: [String: String] = [:]
        var inEvent = false
        for line in unfolded.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l == "BEGIN:VEVENT" { inEvent = true; cur = [:]; continue }
            if l == "END:VEVENT" {
                inEvent = false
                events.append(ICSEvent(
                    title: decode(cur["SUMMARY"] ?? "Untitled"),
                    start: date(cur["DTSTART"]),
                    end: date(cur["DTEND"]),
                    url: cur["URL"] ?? "",
                    location: decode(cur["LOCATION"] ?? ""),
                    uid: cur["UID"] ?? "",
                    rrule: cur["RRULE"] ?? ""))
                continue
            }
            guard inEvent, let colon = l.firstIndex(of: ":") else { continue }
            let keyPart = String(l[l.startIndex..<colon])          // may have ;params
            let value = String(l[l.index(after: colon)...])
            let key = keyPart.split(separator: ";").first.map(String.init) ?? keyPart
            cur[key] = value
        }
        return events.sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    private static func unfold(_ text: String) -> String {
        // Continuation lines begin with space or tab; join to previous line.
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
         .replacingOccurrences(of: "\\,", with: ",")
         .replacingOccurrences(of: "\\;", with: ";")
         .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static let fmts: [String] = [
        "yyyyMMdd'T'HHmmss'Z'", "yyyyMMdd'T'HHmmss", "yyyyMMdd"
    ]
    private static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for f in fmts {
            df.dateFormat = f
            df.timeZone = f.hasSuffix("'Z'") ? TimeZone(identifier: "UTC") : TimeZone.current
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}

// MARK: - Export

/// Open assignments with a due date, as a calendar file Calendar (or Google, or Outlook) can
/// take in. A deadline at the end of a day is an all-day event on its due day — a 23:59 block
/// is noise on a calendar — any other time is a moment; each has a reminder the day before.
/// UIDs are the assignments' own, so importing again updates rather than duplicates.
enum ICSExport {
    static func calendar(_ assignments: [Assignment], courses: [Course], now: Date = .now, cal: Calendar = .current) -> String {
        let since = cal.startOfDay(for: now)
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//StudyBar//Deadlines//EN", "CALSCALE:GREGORIAN",
                     "X-WR-CALNAME:StudyBar deadlines"]
        let utc = DateFormatter(), day = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX"); utc.timeZone = TimeZone(identifier: "UTC"); utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        day.locale = Locale(identifier: "en_US_POSIX"); day.timeZone = cal.timeZone; day.dateFormat = "yyyyMMdd"
        for a in assignments where a.isOpen {
            guard let due = a.due, due >= since else { continue }
            let course = courses.first { $0.id == a.courseID }.map { $0.code.isEmpty ? $0.name : $0.code }
            let t = cal.dateComponents([.hour, .minute], from: due)
            let endOfDay = (t.hour == 23 && (t.minute ?? 0) >= 55) || (t.hour == 0 && t.minute == 0)
            lines += ["BEGIN:VEVENT", "UID:\(a.id.uuidString)@studybar", "DTSTAMP:\(utc.string(from: now))",
                      "SUMMARY:" + escape([course, a.title].compactMap { $0 }.joined(separator: ": "))]
            if endOfDay {
                let d = t.hour == 0 ? cal.date(byAdding: .day, value: -1, to: due) ?? due : due   // midnight is the day before's end
                lines += ["DTSTART;VALUE=DATE:\(day.string(from: d))",
                          "DTEND;VALUE=DATE:\(day.string(from: cal.date(byAdding: .day, value: 1, to: d) ?? d))"]
            } else {
                lines += ["DTSTART:\(utc.string(from: due))", "DTEND:\(utc.string(from: due))"]
            }
            if !a.notes.isEmpty { lines.append("DESCRIPTION:" + escape(a.notes)) }
            if !a.link.isEmpty { lines.append("URL:" + a.link) }
            lines += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:" + escape("Due tomorrow: \(a.title)"),
                      "TRIGGER:-P1D", "END:VALARM", "END:VEVENT"]
        }
        lines.append("END:VCALENDAR")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 5545 text: backslash, semicolon, comma and line breaks escaped.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Lines longer than 75 bytes continue on the next line after a space, as the format asks.
    private static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var out = "", count = 0
        for ch in line {
            let n = String(ch).utf8.count
            if count + n > 75 { out += "\r\n "; count = 1 }
            out.append(ch); count += n
        }
        return out
    }
}
