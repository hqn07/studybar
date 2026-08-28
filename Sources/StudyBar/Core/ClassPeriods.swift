import Foundation

/// UF-style class periods. Many schools schedule by numbered period rather than clock
/// time (period 3 = 9:35–10:25). The grid stays time-based (so any time works), but when
/// "class periods" are on, the editor lets you pick a start/end period and the gutter
/// labels each period — matching how students actually read their schedule.
enum ClassPeriods {
    struct Period: Identifiable, Hashable {
        let label: String        // "1"…"11", "E1"…"E3"
        let start: Int           // minutes from midnight
        let end: Int
        var id: String { label }
    }

    /// The standard University of Florida period grid (50-minute periods).
    static let uf: [Period] = [
        .init(label: "1",  start:  7 * 60 + 25, end:  8 * 60 + 15),
        .init(label: "2",  start:  8 * 60 + 30, end:  9 * 60 + 20),
        .init(label: "3",  start:  9 * 60 + 35, end: 10 * 60 + 25),
        .init(label: "4",  start: 10 * 60 + 40, end: 11 * 60 + 30),
        .init(label: "5",  start: 11 * 60 + 45, end: 12 * 60 + 35),
        .init(label: "6",  start: 12 * 60 + 50, end: 13 * 60 + 40),
        .init(label: "7",  start: 13 * 60 + 55, end: 14 * 60 + 45),
        .init(label: "8",  start: 15 * 60 +  0, end: 15 * 60 + 50),
        .init(label: "9",  start: 16 * 60 +  5, end: 16 * 60 + 55),
        .init(label: "10", start: 17 * 60 + 10, end: 18 * 60 +  0),
        .init(label: "11", start: 18 * 60 + 15, end: 19 * 60 +  5),
        .init(label: "E1", start: 19 * 60 + 20, end: 20 * 60 + 10),
        .init(label: "E2", start: 20 * 60 + 20, end: 21 * 60 + 10),
        .init(label: "E3", start: 21 * 60 + 20, end: 22 * 60 + 10),
    ]

    /// The period whose start best matches `m` (within 10 min), else nil.
    static func period(start m: Int) -> Period? { uf.first { abs($0.start - m) <= 10 } }
    static func periodEnding(_ m: Int) -> Period? { uf.first { abs($0.end - m) <= 10 } }

    /// A compact label for a class time span in period terms, e.g. "P3" or "P9–10".
    static func spanLabel(start: Int, end: Int) -> String? {
        guard let s = periodStartingAtOrAfter(start), let e = periodEndingAtOrBefore(end) else { return nil }
        return s.label == e.label ? "P\(s.label)" : "P\(s.label)–\(e.label)"
    }
    private static func periodStartingAtOrAfter(_ m: Int) -> Period? { period(start: m) }
    private static func periodEndingAtOrBefore(_ m: Int) -> Period? { periodEnding(m) }
}
