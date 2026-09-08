import Foundation

/// (P2) Voice activity detection for the Whisper chunker.
///
/// What it replaces: a single absolute threshold (`rms > 0.035`) that decided whether the mic
/// was hearing anything. Being absolute, it was wrong in both directions — a quiet lecturer or
/// a far mic never crossed it, so every chunk was cut at the minimum length mid-word; a noisy
/// room never fell below it, so no pause was ever detected and every chunk ran to the hard cap,
/// which is the lag. And nothing tracked whether a chunk contained *any* speech, so a long
/// silence was still cut into chunks and sent to Whisper, which hallucinates on silence
/// ("Thank you.", "you") — text that is not empty, so it landed in the transcript.
///
/// This is a stateful detector instead: it learns the room's noise floor, and calls speech by
/// how far a frame rises *above that floor*, with separate onset/offset thresholds and a
/// hangover so a gap between words doesn't end an utterance.
///
/// Deliberately dependency-free. `EnergyVAD` is a pure state machine over frame levels in
/// dBFS, so `--vad-selftest` drives it with synthetic audio, and swapping in libfvad or a
/// Core ML Silero later means conforming to `VoiceActivityDetector` and re-running that suite.
protocol VoiceActivityDetector {
    /// One frame of audio, as its level in dBFS. Returns whether speech is currently active.
    mutating func push(dB: Float) -> Bool
    mutating func reset()
}

struct EnergyVAD: VoiceActivityDetector {
    /// Speech starts when a frame rises this far above the learned floor…
    var onsetOverFloorDB: Float = 9
    /// …and ends when it falls back to within this much of it. The gap between the two is the
    /// hysteresis that stops a wavering level from chattering between states.
    var offsetOverFloorDB: Float = 4.5
    /// Frames of grace before speech is declared over (~21ms each at 1024 frames / 48kHz), so
    /// the gap between two words doesn't split an utterance.
    var hangoverFrames: Int = 14
    /// However quiet the room, nothing below this is ever speech. Without it, the floor in a
    /// silent room sits near the noise of the ADC and normal dither would clear onset.
    var absoluteFloorDB: Float = -52
    /// The floor can't be tracked below this — digital silence is -infinity dB.
    var floorClampDB: Float = -80

    private(set) var floor: Float = -60
    private(set) var active = false
    private var hang = 0
    private var started = false

    mutating func push(dB: Float) -> Bool {
        let level = max(dB, floorClampDB)
        if !started { floor = level; started = true }

        // Track the quiet baseline: drop toward a new low quickly, creep back up slowly. Frozen
        // while speech is active — otherwise a sustained talker drags the floor up behind them
        // and the detector goes deaf mid-sentence.
        if !active {
            if level < floor { floor += (level - floor) * 0.25 }
            else { floor = min(floor + 0.08, level) }
            floor = max(floor, floorClampDB)
        }

        let over = level - floor
        if active {
            if over < offsetOverFloorDB {
                hang -= 1
                if hang <= 0 { active = false }
            } else {
                hang = hangoverFrames
            }
        } else if over > onsetOverFloorDB && level > absoluteFloorDB {
            active = true
            hang = hangoverFrames
        }
        return active
    }

    mutating func reset() {
        floor = -60; active = false; hang = 0; started = false
    }

    /// Frame level in dBFS from raw samples. Separated so the detector itself stays testable
    /// without synthesising PCM.
    static func dBFS(rms: Float) -> Float { 20 * log10(max(rms, 1e-8)) }
}

/// Thread-safe wrapper the audio tap feeds from its own thread while the chunk timer reads it
/// on the main actor. The old code hopped to the main actor with a `Task` for *every* buffer
/// (~47 a second); this keeps the hot path to a lock and some arithmetic.
final class VoiceActivityTracker: @unchecked Sendable {
    struct Snapshot {
        /// Speech right now (including hangover).
        let isSpeech: Bool
        /// When speech was last active — the anchor for "has it been quiet long enough to cut?"
        let lastSpeechAt: Date
        /// Whether the *current chunk* has contained any speech at all. The gate that stops
        /// silence being sent to Whisper.
        let chunkHadSpeech: Bool
        /// Fraction of the current chunk's frames that were speech — for diagnostics.
        let speechRatio: Double
        let floorDB: Float
    }

    private let lock = NSLock()
    private var vad = EnergyVAD()
    private var lastSpeechAt = Date.distantPast
    private var chunkHadSpeech = false
    private var frames = 0
    private var speechFrames = 0

    /// Called from the audio tap, once per buffer.
    func consume(rms: Float) {
        let dB = EnergyVAD.dBFS(rms: rms)
        lock.lock()
        let speech = vad.push(dB: dB)
        frames += 1
        if speech {
            speechFrames += 1
            chunkHadSpeech = true
            lastSpeechAt = Date()
        }
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(isSpeech: vad.active,
                        lastSpeechAt: lastSpeechAt,
                        chunkHadSpeech: chunkHadSpeech,
                        speechRatio: frames > 0 ? Double(speechFrames) / Double(frames) : 0,
                        floorDB: vad.floor)
    }

    /// New chunk: clear the per-chunk gate and counters, but keep the learned noise floor —
    /// the room hasn't changed just because a chunk boundary went past.
    func beginChunk() {
        lock.lock(); chunkHadSpeech = false; frames = 0; speechFrames = 0; lock.unlock()
    }

    /// New recording: forget the room too.
    func resetAll() {
        lock.lock()
        vad.reset(); lastSpeechAt = .distantPast; chunkHadSpeech = false; frames = 0; speechFrames = 0
        lock.unlock()
    }
}

// MARK: - Headless self-test (StudyBar --vad-selftest)

/// Drives the detector with synthetic frame levels. Every case here is a failure the old
/// absolute threshold had.
enum VADSelfTest {
    static func run() -> Int32 {
        var pass = 0, fail = 0
        func ok(_ n: String, _ extra: String = "") { print("  ok   \(n)\(extra.isEmpty ? "" : " (\(extra))")"); pass += 1 }
        func bad(_ n: String, _ why: String) { print("  FAIL \(n): \(why)"); fail += 1 }
        func check(_ n: String, _ got: Bool, _ want: Bool) {
            got == want ? ok(n) : bad(n, "got \(got), want \(want)")
        }

        /// Feed `n` frames at `dB` and report whether speech was active at any point.
        func feed(_ vad: inout EnergyVAD, _ dB: Float, _ n: Int) -> Bool {
            var any = false
            for _ in 0..<n { if vad.push(dB: dB) { any = true } }
            return any
        }

        // 1. A silent room is never speech, however long you listen.
        var v = EnergyVAD()
        check("silence is never speech", feed(&v, -70, 400), false)

        // 2. Quiet room, then a talker. -45 dBFS is rms ≈ 0.0056, far *under* the old absolute
        //    0.035, so a far or quiet mic never registered speech at all: no pause was ever
        //    anchored, and every chunk got cut at the minimum length, mid-word.
        v.reset()
        _ = feed(&v, -62, 200)                     // learn the room
        check("quiet room + quiet talker", feed(&v, -45, 60), true)

        // 3. Loud room, same talker margin. -25 dBFS is rms ≈ 0.056, comfortably *over* the
        //    old absolute 0.035 — so the old code called the empty room speech, permanently,
        //    never detected a pause, and ran every chunk to the hard cap. That is the lag.
        v.reset()
        _ = feed(&v, -25, 200)
        check("loud room floor is not speech", v.active, false)
        check("loud room + louder talker", feed(&v, -10, 60), true)

        // 4. Hangover: a short gap between words must not end the utterance.
        v.reset()
        _ = feed(&v, -60, 200)
        _ = feed(&v, -40, 40)                       // talking
        _ = feed(&v, -60, 5)                        // ~100ms gap between words
        check("brief gap keeps speech active", v.active, true)
        _ = feed(&v, -60, 40)                       // a real pause
        check("real pause ends speech", v.active, false)

        // 5. The floor must not creep up during sustained speech, or the detector goes deaf.
        v.reset()
        _ = feed(&v, -60, 200)
        let floorBefore = v.floor
        _ = feed(&v, -35, 600)                      // 12s of continuous talking
        check("still speech after a long utterance", v.active, true)
        abs(v.floor - floorBefore) < 1.0
            ? ok("floor frozen during speech", String(format: "%.1f dB drift", abs(v.floor - floorBefore)))
            : bad("floor frozen during speech", String(format: "drifted %.1f dB", abs(v.floor - floorBefore)))

        // 6. The floor follows the room down when it gets quieter (gain change, AC switching off).
        v.reset()
        _ = feed(&v, -30, 300)
        _ = feed(&v, -66, 300)
        v.floor < -55 ? ok("floor follows the room down", String(format: "%.0f dB", v.floor))
                      : bad("floor follows the room down", String(format: "stuck at %.0f dB", v.floor))

        // 7. The tracker's per-chunk gate — the thing that stops silence reaching Whisper.
        let t = VoiceActivityTracker()
        for _ in 0..<300 { t.consume(rms: 0.0004) }          // ≈ -68 dBFS
        check("silent chunk has no speech", t.snapshot().chunkHadSpeech, false)
        for _ in 0..<80 { t.consume(rms: 0.05) }             // ≈ -26 dBFS
        check("chunk with a talker has speech", t.snapshot().chunkHadSpeech, true)
        t.beginChunk()
        check("beginChunk clears the gate", t.snapshot().chunkHadSpeech, false)
        t.snapshot().floorDB > -80
            ? ok("beginChunk keeps the learned floor", String(format: "%.0f dB", t.snapshot().floorDB))
            : bad("beginChunk keeps the learned floor", "floor was reset")

        print(fail == 0 ? "VAD SELFTEST: ALL PASS (\(pass))" : "VAD SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
