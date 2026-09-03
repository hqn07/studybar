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

    // MARK: - Paste a schedule → AI extraction

    /// Extract weekly `ClassSession`s from free-form pasted text (a copied timetable, a
    /// registrar "detailed schedule", an email). The model does the parsing — local qwen is
    /// reliable for this kind of structured extraction — and returns a strict JSON array we
    /// map to draft classes for the same review sheet the .ics path uses. Returns [] on any
    /// failure (no engine, empty paste, unparseable reply) so the caller can show a message.
    static func fromPasted(_ text: String, provider: AIProvider?) async -> [ClassSession] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return [] }
        guard let provider else { Diagnostics.warn(.ai, "Paste import: no AI provider"); return [] }

        let sys = """
        You extract a student's WEEKLY class schedule from pasted text. Reply with ONLY a JSON array, \
        one object per class:
        [{"title":"MAC 2311 Lecture","days":"MWF","start":"09:35","end":"10:25","room":"LIT 109","online":false,"link":""}]
        Rules:
        - One object per distinct class. A class meeting several days (e.g. Mon/Wed/Fri) is ONE object; \
        put all its days in "days".
        - days uses these letters, no separators: U=Sunday M=Monday T=Tuesday W=Wednesday R=Thursday \
        F=Friday S=Saturday. Example Tue+Thu = "TR".
        - start and end are 24-hour "HH:MM".
        - title: the course code and/or name, plus the section type if given (Lecture, Lab, Discussion).
        - online: true only if it clearly says online/remote/Zoom; put any meeting URL in "link".
        - If a class has no listed meeting time, omit start/end and set "online": true.
        Use only what the text states. No prose outside the JSON array.
        """
        let user = "SCHEDULE:\n" + String(trimmed.prefix(12000))
        Diagnostics.info(.ai, "Paste import: sending \(user.count) chars…")
        let msgs = [AIMessage(role: .user, text: user)]
        let out: String
        do {
            if let ollama = provider as? OllamaProvider {
                out = try await ollama.completePlainOnce(system: sys, messages: msgs)
            } else {
                out = try await provider.completePlain(system: sys, messages: msgs)
            }
        } catch {
            Diagnostics.error(.ai, "Paste import failed: \(error.localizedDescription)")
            return []
        }
        let classes = parsePasted(out)
        Diagnostics.log(.ai, classes.isEmpty ? .warn : .info,
                        "Paste import: got \(out.count) chars, parsed \(classes.count) class(es)")
        return classes
    }

    /// Parse the JSON array the paste extractor returns into draft classes.
    static func parsePasted(_ raw: String) -> [ClassSession] {
        guard let s = raw.firstIndex(of: "["), let e = raw.lastIndex(of: "]"), s < e,
              let data = String(raw[s...e]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out: [ClassSession] = []
        for o in arr {
            let title = (o["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let days = parseDayLetters((o["days"] as? String) ?? "")
            let online = (o["online"] as? Bool) ?? false
            let link = (o["link"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let room = (o["room"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let start = parseTime(o["start"])
            let end = parseTime(o["end"])
            // Skip empty rows the model sometimes pads with.
            if title.isEmpty && days.isEmpty && start == nil { continue }
            var c = ClassSession(courseID: nil)
            c.title = title.isEmpty ? "Class" : title
            c.days = days
            c.weekday = days.first ?? 2
            if let start {
                c.startMinutes = start; c.endMinutes = max(start + 5, end ?? (start + 50))
            } else if !online && !days.isEmpty {
                // Has meeting days but the time didn't parse — flag it (‑1) rather than fabricate a
                // 9 a.m. block; the review sheet shows "time not detected" and add() fills a default.
                c.startMinutes = -1; c.endMinutes = -1
            }
            c.room = room
            if !link.isEmpty { c.link = link }
            if online || (days.isEmpty && start == nil) { c.online = true }
            out.append(c)
        }
        return out.sorted { ($0.weekdays.first ?? 0, $0.startMinutes) < ($1.weekdays.first ?? 0, $1.startMinutes) }
    }

    /// "MWF" / "TR" / "MoWeFr" / "Tu,Th" → sorted weekday ints (1=Sun … 7=Sat). Prefers the
    /// single-letter convention (U M T W R F S); falls back to two-letter day names only when the
    /// stripped string cleanly divides into valid two-letter tokens (so "MW" stays Mon+Wed, while
    /// "TuTh" reads as Tue+Thu).
    static func parseDayLetters(_ s: String) -> [Int] {
        let upper = s.uppercased().filter { $0.isLetter }
        let two: [String: Int] = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
        let chars = Array(upper)
        if chars.count >= 2, chars.count % 2 == 0 {
            var chunks: [String] = [], ok = true
            var i = 0
            while i < chars.count { chunks.append(String(chars[i...i+1])); i += 2 }
            var found = Set<Int>()
            for c in chunks { if let wd = two[c] { found.insert(wd) } else { ok = false; break } }
            if ok && !found.isEmpty { return found.sorted() }
        }
        let single: [Character: Int] = ["U": 1, "M": 2, "T": 3, "W": 4, "R": 5, "F": 6, "S": 7]
        var found = Set<Int>()
        for ch in chars where single[ch] != nil { found.insert(single[ch]!) }
        return found.sorted()
    }

    /// Parse a time value (JSON string "HH:MM"/"H:MM AM" or a number of minutes) → minutes of day.
    static func parseTime(_ v: Any?) -> Int? {
        if let n = v as? Int, n >= 0, n < 24 * 60 { return n }
        guard var str = (v as? String)?.trimmingCharacters(in: .whitespaces), !str.isEmpty else { return nil }
        var pm = false, am = false
        let low = str.lowercased()
        if low.hasSuffix("pm") { pm = true; str = String(str.dropLast(2)) }
        else if low.hasSuffix("am") { am = true; str = String(str.dropLast(2)) }
        str = str.trimmingCharacters(in: .whitespaces)
        let parts = str.split(separator: ":")
        guard let h = Int(parts.first ?? "") else { return nil }
        let m = parts.count > 1 ? (Int(parts[1].prefix(2)) ?? 0) : 0
        var hour = h
        if pm && hour < 12 { hour += 12 }
        if am && hour == 12 { hour = 0 }
        guard (0..<24).contains(hour), (0..<60).contains(m) else { return nil }
        return hour * 60 + m
    }
}
