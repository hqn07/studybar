import Foundation

struct ICSEvent: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var start: Date?
    var end: Date?
    var url: String
    var location: String
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
                    location: decode(cur["LOCATION"] ?? "")))
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
