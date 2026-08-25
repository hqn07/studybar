import Foundation

/// FSRS-4.5 spaced-repetition scheduler (Difficulty · Stability · Retrievability).
/// A modern, retention-optimizing replacement for SM-2 — same 4-grade UI
/// (Again/Hard/Good/Easy) via `SM2.Grade`, mapped to FSRS ratings 1…4.
///
/// Reference: open-spaced-repetition FSRS-4.5. Default (untrained) parameters.
enum FSRS {
    typealias Grade = SM2.Grade

    /// 17 default parameters w[0]…w[16].
    static let w: [Double] = [
        0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2298, 0.8975, 0.031,
        1.6474, 0.1367, 1.0461, 2.1072, 0.0793, 0.3246, 1.587, 0.2272, 2.8755
    ]
    static let decay = -0.5
    static let factor = 19.0 / 81.0        // R = 0.9 exactly when t == S
    static let requestRetention = 0.9

    /// Again/Hard/Good/Easy → FSRS rating 1/2/3/4.
    private static func rating(_ g: Grade) -> Int {
        switch g { case .again: 1; case .hard: 2; case .good: 3; case .easy: 4 }
    }

    // MARK: - Public API (mirrors SM2)

    static func apply(_ card: Flashcard, grade g: Grade) -> Flashcard {
        var c = card
        let G = rating(g)
        let now = Date()
        c.reviews += 1

        if c.stability <= 0 && c.reps == 0 {
            // Brand-new card: seed from initial D/S and schedule.
            c.difficulty = clampD(initDifficulty(G))
            c.stability = max(0.1, initStability(G))
            if g == .again { c.lapses += 1 } else { c.reps += 1 }
            return schedule(&c, g, now)
        }
        if c.stability <= 0 {
            // Legacy SM-2 card: seed FSRS state from its existing interval, then review.
            c.stability = Double(max(1, c.interval))
            c.difficulty = clampD(initDifficulty(3))
        }

        let t = c.lastReview.map { max(0, now.timeIntervalSince($0) / 86_400) } ?? Double(max(1, c.interval))
        let r = retrievability(t: t, s: c.stability)
        c.difficulty = clampD(nextDifficulty(c.difficulty, G))

        if g == .again {
            c.stability = min(c.stability, stabilityForget(d: c.difficulty, s: c.stability, r: r))
            c.lapses += 1
            c.reps = 0
        } else {
            c.stability = stabilityRecall(d: c.difficulty, s: c.stability, r: r, G: G)
            c.reps += 1
        }
        return schedule(&c, g, now)
    }

    /// Short label for the interval a grade would produce (shown on grade buttons).
    static func intervalPreview(_ card: Flashcard, grade: Grade) -> String {
        if grade == .again { return "10m" }
        let n = apply(card, grade: grade).interval
        if n >= 365 { return "\(n / 365)y" }
        if n >= 30 { return "\(n / 30)mo" }
        return "\(max(1, n))d"
    }

    // MARK: - Scheduling

    private static func schedule(_ c: inout Flashcard, _ g: Grade, _ now: Date) -> Flashcard {
        c.stability = max(0.1, c.stability)
        c.interval = max(1, min(36_500, Int(nextInterval(c.stability).rounded())))
        c.lastReview = now
        // "Again" returns within the session (10 min); everything else by interval.
        c.due = g == .again
            ? (Calendar.current.date(byAdding: .minute, value: 10, to: now) ?? now)
            : (Calendar.current.date(byAdding: .day, value: c.interval, to: now) ?? now)
        return c
    }

    // MARK: - FSRS-4.5 formulas

    private static func initStability(_ G: Int) -> Double { w[G - 1] }
    private static func initDifficulty(_ G: Int) -> Double { w[4] - Double(G - 3) * w[5] }

    private static func nextDifficulty(_ d: Double, _ G: Int) -> Double {
        let delta = -w[6] * Double(G - 3)
        let dp = d + delta
        return w[7] * initDifficulty(4) + (1 - w[7]) * dp     // mean reversion toward D0(Easy)
    }

    private static func retrievability(t: Double, s: Double) -> Double {
        pow(1 + factor * t / s, decay)
    }
    private static func nextInterval(_ s: Double) -> Double {
        (s / factor) * (pow(requestRetention, 1 / decay) - 1)
    }

    private static func stabilityRecall(d: Double, s: Double, r: Double, G: Int) -> Double {
        let hard = G == 2 ? w[15] : 1.0
        let easy = G == 4 ? w[16] : 1.0
        return s * (1 + exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp((1 - r) * w[10]) - 1) * hard * easy)
    }
    private static func stabilityForget(d: Double, s: Double, r: Double) -> Double {
        w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp((1 - r) * w[14])
    }

    private static func clampD(_ d: Double) -> Double { min(10, max(1, d)) }
}
