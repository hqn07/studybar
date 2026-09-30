import Foundation
import Speech
import AVFoundation
import WhisperKit
import IOKit.ps
import NaturalLanguage

/// The mic level, deliberately kept off `VoiceService`.
///
/// Levels arrive about thirty times a second. Published on the recorder, each one invalidated
/// every view observing it — the whole Voice module, and the recording bar that sits under every
/// other module — to redraw a strip 44 points wide. As its own object, only the view that draws
/// the meter is listening, and the recorder's coarse state stays cheap to observe.
@MainActor
final class VoiceMeter: ObservableObject {
    static let bars = 48
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: bars)
    /// Loudest sample still on screen — the watchdog uses it to tell a dead mic from a quiet room.
    var peak: Float { levels.max() ?? 0 }

    func push(_ level: Float) {
        var next = levels
        next.removeFirst(); next.append(level)
        levels = next
    }
    func reset() { levels = Array(repeating: 0, count: Self.bars) }
}

/// Records a voice memo and transcribes it on-device — nothing leaves the Mac. Two engines:
///  • **Apple Speech** (default): live streaming transcript, instant. Segments chain past the
///    recognizer's ~1-minute auto-finalize so long dictation accumulates instead of resetting.
///  • **Whisper** (opt-in, WhisperKit/CoreML): higher accuracy. Records the whole take, then
///    transcribes in one pass — the text appears progressively as it decodes, so you can see
///    it working. Real-time streaming of the large models can't keep up on-device, so batch
///    is deliberately used for quality. Model downloads once (with a progress bar), then offline.
@MainActor
final class VoiceService: ObservableObject {
    enum Status: Equatable { case idle, recording, preparing, transcribing, denied, unavailable(String) }
    @Published var status: Status = .idle { didSet { holdAwake(status == .recording || status == .transcribing) } }
    @Published var transcript = ""
    /// "Make study notes" in progress, and the transcript it replaced (so it can be reverted).
    /// Here rather than in the view so that leaving Voice mid-job doesn't drop either.
    @Published var organizing = false
    @Published var organizeStream = ""
    @Published var organizeStart: Date?
    @Published var rawBeforeOrganize: String?
    @Published var organizeError: String?
    @Published var organizePart = (1, 1)      // which part of a long lecture is being written
    /// Not `@Published`: see `VoiceMeter`. Its own object so a 30 Hz meter doesn't re-render
    /// every view that observes the recorder.
    let meter = VoiceMeter()
    @Published var prepProgress: Double = 0
    @Published var lastEngine = ""
    @Published private(set) var loadedModel: String?
    /// When the current recording began — nil when not recording. Drives the persistent
    /// recording bar + menu-bar elapsed clock so recording is visible/controllable from any module.
    @Published private(set) var startedAt: Date?
    /// When the recording that produced the current transcript began. `startedAt` is cleared
    /// the moment transcription starts, and saving happens after that — but which class you
    /// were in is a fact about when you pressed record, not about when you pressed save.
    private(set) var lastRecordingStart: Date?
    var vocabPrompt: String?
    /// The course's own terms, handed to Apple Speech as `contextualStrings` so "eigenvalue"
    /// comes out as a word rather than as "I can value".
    var vocabulary: [String] = []
    /// The whole take as AAC, written alongside transcription so a note can keep its lecture.
    /// Survives until it is saved with a note (`claimTake`) or discarded.
    @Published private(set) var takeURL: URL?
    private nonisolated(unsafe) var takeFile: AVAudioFile?
    private let takeLock = NSLock()
    /// Frames written to the take, and its rate: the clock for the timeline and stars, so a
    /// time in them is a time in the audio that plays back.
    private nonisolated(unsafe) var takeFrames: AVAudioFramePosition = 0
    private nonisolated(unsafe) var takeRate: Double = 48_000
    private var takeElapsed: Double {
        takeLock.lock(); defer { takeLock.unlock() }
        return Double(takeFrames) / takeRate
    }
    /// This recording's sentences with their times, and its stars — saved beside the take.
    @Published private(set) var timeline = LectureTimeline()
    /// Where the current Apple Speech request began in the take, and its latest word times.
    private var segmentOffset: Double = 0
    private var lastWords: [(offset: Int, t: Double)] = []
    private var awake: NSObjectProtocol?
    private var healthTimer: Timer?
    /// Which low-battery / low-disk warnings this recording has already given.
    private var warned: Set<String> = []
    private nonisolated let meterLock = NSLock()
    private nonisolated(unsafe) var lastMeterAt = Date.distantPast

    static let locales: [(id: String, label: String)] = [
        ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("es-ES", "Spanish"),
        ("fr-FR", "French"), ("de-DE", "German"), ("it-IT", "Italian"),
        ("pt-BR", "Portuguese"), ("zh-CN", "Chinese"), ("ja-JP", "Japanese"),
        ("ko-KR", "Korean"), ("hi-IN", "Hindi"), ("ar-SA", "Arabic"),
    ]
    static let whisperModels: [(id: String, label: String)] = [
        ("tiny", "Tiny · ~75 MB · fastest"), ("base", "Base · ~150 MB · balanced"),
        ("small", "Small · ~500 MB · better"),
        // OpenAI's large-v3-turbo (WhisperKit names it by date), compressed: close to Large v3, several times faster.
        ("large-v3-v20240930_626MB", "Large v3 Turbo · ~630 MB · near-best, fast"),
        ("large-v3", "Large v3 · ~1.5 GB · best"),
    ]
    static let whisperLangs: [(id: String, label: String)] = [
        ("auto", "Auto-detect"), ("en", "English"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("zh", "Chinese"), ("ja", "Japanese"), ("hi", "Hindi"),
    ]

    var localeID: String { UserDefaults.standard.string(forKey: "voiceLocale") ?? "en-US" }
    private var useWhisper: Bool { (UserDefaults.standard.string(forKey: "voiceEngine") ?? "apple") == "whisper" }
    var whisperModel: String { UserDefaults.standard.string(forKey: "voiceWhisperModel") ?? "base" }
    private var whisperLang: String { UserDefaults.standard.string(forKey: "voiceWhisperLang") ?? "auto" }

    private let engine = AVAudioEngine()
    // Apple Speech
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var committed = ""
    private var currentPartial = ""
    private var wantsRecording = false
    private var segmentStart = Date()
    private var segmentID = 0
    private var rotating = false
    private var rotateTimer: Timer?
    private var segmentGotResult = false
    private var emptyStreak = 0
    private var recordingStart = Date()
    private var everGotResult = false
    // Whisper (chunked streaming: transcribe short chunks in the background while recording)
    private var whisper: WhisperKit?
    private var whisperLoadTask: Task<Void, Error>?   // dedupes concurrent model loads
    private var whisperMode = false
    private let chunkLock = NSLock()
    private var chunkFile: AVAudioFile?
    private var chunkURL: URL?
    private var chunkFrames: AVAudioFramePosition = 0
    private var totalFrames: AVAudioFramePosition = 0
    private var chunkStart = Date()
    private var chunkSettings: [String: Any] = [:]
    private var sampleRate: Double = 48_000
    private let activity = VoiceActivityTracker()
    private var chunkTimer: Timer?
    // Per-recording chunk tally, logged on finish so the chunker's behaviour is measurable
    // instead of inferred (there was no per-chunk logging at all before).
    private var chunksSent = 0
    /// Silent chunks dropped back-to-back, and chunks kept despite sounding silent because
    /// the gate wasn't confident. Both are reported when the recording finishes.
    private var consecutiveSilentDrops = 0
    private var chunksKeptUnsure = 0
    private var chunksDroppedSilent = 0
    private var chunksEmptyResult = 0
    private var transcribeChain: Task<Void, Never>?
    private var whisperCommitted = ""
    private var chunkLang: String?        // language detected on the first chunk, reused after
    private let minChunkSec = 8.0         // small enough that each transcribes fast (text stays current)
    private let maxChunkSec = 18.0        // hard cut, so text never lags too far behind live
    // 0.4s sat inside a normal gap between words, so a "pause" was often mid-sentence —
    // exactly where Whisper does worst. This is closer to a real sentence boundary.
    private let pauseGapSec = 0.7
    // Autosave draft — crash-safe raw transcript.
    private var lastDraftSave = Date.distantPast
    static var draftURL: URL { AppState.localDir.appendingPathComponent("voice-draft.txt") }

    var whisperReady: Bool { loadedModel == whisperModel }
    /// Whether a model's files are on disk (survives launches) — distinct from `whisperReady`,
    /// which only means "loaded into memory this session". The download prompt uses THIS so a
    /// model that's already downloaded isn't asked to download again on every launch.
    private func modelFolderKey(_ model: String) -> String { "whisperFolder-\(model)" }
    /// WhisperKit's default on-disk location for a variant (non-sandboxed app → ~/Documents).
    private func defaultModelFolder(_ model: String) -> String? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let p = docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-\(model)")
        return FileManager.default.fileExists(atPath: p.path) ? p.path : nil
    }
    func isModelDownloaded(_ model: String) -> Bool {
        if let p = UserDefaults.standard.string(forKey: modelFolderKey(model)),
           FileManager.default.fileExists(atPath: p) { return true }
        // Recognize a model downloaded before this session (or by an earlier build) so we don't
        // re-prompt: probe WhisperKit's default folder and remember it if present.
        if let p = defaultModelFolder(model) {
            UserDefaults.standard.set(p, forKey: modelFolderKey(model))
            return true
        }
        return false
    }
    var whisperDownloaded: Bool { isModelDownloaded(whisperModel) }
    /// Which Whisper variants have files on disk — for the diagnostics report.
    nonisolated static func downloadedModels() -> [String] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        return whisperModels.map(\.id).filter {
            FileManager.default.fileExists(atPath: docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-\($0)").path)
        }
    }
    var isRecording: Bool { status == .recording }
    func toggle() {
        switch status {
        case .recording: userStop()
        case .preparing, .transcribing: break
        default: start()
        }
    }

    func start() {
        discardTake()                         // a new take replaces one that was never saved
        transcript = ""; committed = ""; currentPartial = ""; wantsRecording = true
        timeline = LectureTimeline()
        meter.reset()
        whisperMode = useWhisper
        Task { @MainActor in
            guard await AVCaptureDevice.requestAccess(for: .audio) else { status = .denied; return }
            if whisperMode { beginWhisperRecording() } else { startAppleSpeech() }
        }
    }

    /// Drop a latched `.denied` so the module can ask again.
    ///
    /// `.denied` is remembered for the life of the process, and the permission it reflects is
    /// granted *outside* the app — in System Settings, or by a prompt that was dismissed. Without
    /// this, granting access changed nothing until the app was relaunched: the view stayed on the
    /// "access off" screen, which never calls `start()`, so macOS was never asked again and the
    /// user saw no prompt. Clearing on the module's appearance means coming back to Voice after
    /// granting is enough.
    func clearDenied() {
        if status == .denied { status = .idle }
    }

    func userStop() {
        wantsRecording = false
        if whisperMode { finishWhisperAndTranscribe() }
        else if task != nil { request?.endAudio() } else { finish() }
    }

    // MARK: - Apple Speech (live, gap-free chained segments)
    //
    // SFSpeechRecognizer finalizes on-device recognition after ~1 minute and can truncate
    // the tail when it slams into that wall. We never let it hit the wall: a 0.25s timer
    // rotates to a FRESH request proactively — preferring a natural pause (from the live mic
    // level) in a 40–55s window, with a 58s hard cap. Committed text only ever grows; a stale
    // callback from a rotated-out task is ignored via a monotonically-increasing segment id.

    private func startAppleSpeech() {
        lastEngine = "Apple Speech"
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard auth == .authorized else { self.status = .denied; return }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        guard let recognizer, recognizer.isAvailable else {
            status = .unavailable("Speech recognition isn't available for this language yet."); return
        }
        startInput(prepare: { [weak self] format in self?.openTake(format); return true },
                   handle: { [weak self] buf in
                       guard let self else { return }
                       self.request?.append(buf)
                       self.writeTake(buf)
                       if let r = Self.rms(buf) { self.pushLevel(rms: r) }
                   }) { [weak self] ok in
            guard let self else { return }
            guard ok else { self.finish(); return }
            self.status = .recording
            self.emptyStreak = 0; self.everGotResult = false
            self.recordingStart = Date(); self.startedAt = Date(); self.lastRecordingStart = self.recordingStart
            self.startSegment()
            // 1s timer: watchdog for a silent/dead mic, and rotate before SFSpeech's ~60s wall.
            self.rotateTimer?.invalidate()
            self.rotateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.watchdog(); self?.maybeRotate() }
            }
        }
    }

    /// If we've been "recording" for a while with no recognized text AND the input meter is
    /// flat, the mic is delivering silence — almost always a mic/Speech permission that reset
    /// when the app was rebuilt (ad-hoc signing). Surface it instead of looking frozen.
    private func watchdog() {
        guard status == .recording, wantsRecording else { return }
        let elapsed = Date().timeIntervalSince(recordingStart)
        let live = meter.peak > 0.03
        guard elapsed > 8, !everGotResult, !live else { return }
        if fromSystem {
            status = .unavailable("Nothing is playing on the Mac. Start the call or the video, then record.")
            finish(); return
        }
        status = .unavailable("The mic isn't picking up any sound. Grant Microphone and Speech Recognition to StudyBar in System Settings ▸ Privacy & Security (ad-hoc builds reset these on each update), then try again.")
        finish()
    }

    private func startSegment() {
        guard let recognizer, wantsRecording, capturing else { finish(); return }
        segmentID &+= 1
        let myID = segmentID
        segmentStart = Date(); rotating = false; segmentGotResult = false
        segmentOffset = takeElapsed; lastWords = []
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.contextualStrings = Array(vocabulary.prefix(100))
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.segmentID == myID else { return }   // ignore a rotated-out task
                if let result {
                    self.segmentGotResult = true; self.everGotResult = true
                    self.currentPartial = result.bestTranscription.formattedString
                    self.lastWords = result.bestTranscription.segments.map { ($0.substringRange.location, $0.timestamp) }
                    self.transcript = self.join(self.committed, self.currentPartial)
                    if result.isFinal { self.rotate(restart: self.wantsRecording) }
                } else if error != nil {
                    self.rotate(restart: self.wantsRecording)   // ended/limit: commit + continue
                }
            }
        }
    }

    private func maybeRotate() {
        guard status == .recording, wantsRecording, !rotating, task != nil else { return }
        guard Date().timeIntervalSince(segmentStart) > 50 else { return }
        rotate(restart: true)
    }

    /// Commit the current partial and start a fresh request (chained recognition). Guards
    /// against an error-thrash loop: if several segments in a row produce no text at all,
    /// stop with a helpful message instead of spinning silently.
    private func rotate(restart: Bool) {
        guard !rotating else { return }
        rotating = true
        let hadText = !currentPartial.isEmpty
        commitCurrent()
        emptyStreak = (segmentGotResult || hadText) ? 0 : emptyStreak + 1
        let old = task; task = nil; request = nil
        segmentID &+= 1                                  // ignore the rotated-out task's late callback
        old?.cancel()
        guard restart, wantsRecording, capturing else { finish(); return }
        if emptyStreak >= 4 {
            status = .unavailable("Apple Speech isn't producing any text on this Mac — switch to Whisper (menu, top-right), which runs fully offline.")
            finish(); return
        }
        startSegment()
    }

    private func commitCurrent() {
        guard !currentPartial.isEmpty else { return }
        timeline.add(currentPartial, from: segmentOffset, to: takeElapsed, words: lastWords)
        committed = join(committed, currentPartial)
        transcript = committed
        currentPartial = ""
        saveDraft()
    }

    // MARK: - Whisper (chunked streaming)
    //
    // Instead of recording the whole take and transcribing once at the end (a multi-GB temp
    // file and a long wait for a lecture), the audio is cut into short chunks — at a natural
    // pause when possible, with a hard cap — and each is transcribed on a background serial
    // queue while recording continues. Text appears live, only one small chunk is ever on disk,
    // and stopping just drains the last chunk.

    private func beginWhisperRecording() {
        // Capture from t=0 immediately; load the model in parallel. Otherwise the seconds spent
        // loading a large model on the first record would drop the start of the recording. Each
        // chunk's transcription waits for the model, so no audio is lost.
        startChunkedMic()
        Task { @MainActor in try? await ensureWhisper() }
    }

    private func startChunkedMic() {
        startInput(prepare: { [weak self] format in
            guard let self else { return false }
            self.chunkSettings = format.settings; self.sampleRate = format.sampleRate
            self.whisperCommitted = ""; self.transcript = ""; self.totalFrames = 0; self.chunkLang = nil
            self.activity.resetAll()
            self.chunksSent = 0; self.chunksDroppedSilent = 0; self.chunksEmptyResult = 0
            self.consecutiveSilentDrops = 0; self.chunksKeptUnsure = 0
            guard self.openNewChunk() else { self.status = .unavailable("Couldn't start recording."); return false }
            self.openTake(format)
            return true
        }, handle: { [weak self] buf in
            guard let self else { return }
            self.writeTake(buf)
            self.chunkLock.lock()
            try? self.chunkFile?.write(from: buf)
            self.chunkFrames += AVAudioFramePosition(buf.frameLength)
            self.totalFrames += AVAudioFramePosition(buf.frameLength)
            self.chunkLock.unlock()
            self.observe(buf)
        }) { [weak self] ok in
            guard let self else { return }
            guard ok else { self.finish(); return }
            self.status = .recording; self.startedAt = Date()
            Diagnostics.info(.voice, "Whisper recording started · model \(self.whisperModel) · sr \(Int(self.sampleRate))\(self.fromSystem ? " · the Mac's sound" : "")")
            self.chunkTimer?.invalidate()
            self.chunkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.maybeCutChunk() }
            }
        }
    }

    @discardableResult private func openNewChunk() -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vchunk-\(UUID().uuidString).caf")
        guard let f = try? AVAudioFile(forWriting: url, settings: chunkSettings) else { return false }
        chunkLock.lock(); chunkFile = f; chunkURL = url; chunkFrames = 0; chunkStart = Date(); chunkLock.unlock()
        activity.beginChunk()
        return true
    }

    nonisolated private static func rms(_ buf: AVAudioPCMBuffer) -> Float? {
        guard let ch = buf.floatChannelData?[0] else { return nil }
        let n = Int(buf.frameLength); guard n > 0 else { return nil }
        var sum: Float = 0
        for i in 0..<n { let s = ch[i]; sum += s * s }
        return (sum / Float(n)).squareRoot()
    }

    /// One pass over each buffer: RMS once, fed to both the detector and the level meter.
    /// Runs on the audio thread and stays there — the previous code spawned a main-actor
    /// `Task` per buffer (~47 a second) in each of two functions, and the meter then threw
    /// most of them away with a throttle *inside* the hop.
    nonisolated private func observe(_ buf: AVAudioPCMBuffer) {
        guard let r = Self.rms(buf) else { return }
        activity.consume(rms: r)
        pushLevel(rms: r)
    }

    private func maybeCutChunk() {
        guard status == .recording, wantsRecording else { return }
        let dur = Date().timeIntervalSince(chunkStart)
        let s = activity.snapshot()

        // Never hand Whisper a chunk with no speech in it. It hallucinates on silence
        // ("Thank you.", "you"), and that text is not empty, so it used to pass the
        // `!text.isEmpty` guard downstream and land in the transcript.
        guard s.chunkHadSpeech else {
            // Recycle rather than accumulate: a lecturer who steps out for ten minutes
            // shouldn't leave a ten-minute file of silence on disk. But dropping deletes
            // audio unheard, so SilentChunkGate decides whether the verdict has earned that
            // yet — otherwise transcribe and let a stray "Thank you." be the cost.
            if dur >= maxChunkSec {
                switch SilentChunkGate.decide(everHeardSpeech: s.everHeardSpeech,
                                              consecutiveDrops: consecutiveSilentDrops) {
                case .drop:
                    recycleChunk()
                case .transcribe:
                    chunksKeptUnsure += 1
                    cutChunk(final: false)
                }
            }
            return
        }

        // Speech in this chunk means the detector is still hearing the room, so the run of
        // drops starts over. (Not reset by a kept-unsure chunk — otherwise a deaf floor
        // would drop three, keep one, and drop three more.)
        consecutiveSilentDrops = 0

        let quietFor = Date().timeIntervalSince(s.lastSpeechAt)
        let paused = !s.isSpeech && quietFor >= pauseGapSec
        if dur >= maxChunkSec || (dur >= minChunkSec && paused) { cutChunk(final: false) }
    }

    /// Drop the current chunk unheard and start a fresh one — silence only, nothing to
    /// transcribe. Keeps the learned noise floor.
    private func recycleChunk() {
        chunkLock.lock()
        let url = chunkURL
        chunkFile = nil; chunkURL = nil
        chunkLock.unlock()
        if let url { try? FileManager.default.removeItem(at: url) }
        chunksDroppedSilent += 1
        consecutiveSilentDrops += 1
        openNewChunk()
    }

    /// Close the current chunk (flushing it to disk) and enqueue it, then open the next.
    private func cutChunk(final: Bool) {
        chunkLock.lock()
        let url = chunkURL; let frames = chunkFrames
        let start = Double(totalFrames - frames) / sampleRate   // where this chunk sits in the take
        chunkFile = nil; chunkURL = nil          // dropping the ref flushes + closes the file
        chunkLock.unlock()
        let hadSpeech = activity.snapshot().chunkHadSpeech
        if let url {
            if frames > AVAudioFramePosition(sampleRate * 0.4) && hadSpeech {
                chunksSent += 1
                enqueueTranscribe(url, at: start)
            } else {
                // Too short to be worth a pass, or silence only.
                if !hadSpeech { chunksDroppedSilent += 1 }
                try? FileManager.default.removeItem(at: url)
            }
        }
        if !final { openNewChunk() }
    }

    /// Serial background transcription: chunk N is appended before N+1 is transcribed.
    private func enqueueTranscribe(_ url: URL, at start: Double) {
        let prev = transcribeChain
        transcribeChain = Task { @MainActor in
            _ = await prev?.value
            let heard = await transcribeChunk(url)
            try? FileManager.default.removeItem(at: url)
            let text = heard?.text
            for seg in heard?.segments ?? [] { timeline.add(seg.text, from: start + seg.start, to: start + seg.end) }
            if let text, !text.isEmpty {
                whisperCommitted = join(whisperCommitted, text)
                transcript = whisperCommitted
                saveDraft()
            } else {
                chunksEmptyResult += 1
            }
        }
    }

    private func transcribeChunk(_ url: URL) async -> (text: String, segments: [(start: Double, end: Double, text: String)])? {
        try? await ensureWhisper()      // first chunk waits for the model; the rest are instant
        guard let whisper else { return nil }
        // No promptTokens: seeding Whisper with the previous text makes it intermittently emit
        // nothing for a chunk whose audio doesn't continue that prompt. Detect the language once
        // (on auto) and reuse it, so later chunks don't re-detect and occasionally come back empty.
        let fixedLang: String? = whisperLang == "auto" ? chunkLang : whisperLang
        let opts = DecodingOptions(language: fixedLang,
                                   detectLanguage: whisperLang == "auto" && chunkLang == nil,
                                   skipSpecialTokens: true)
        guard let results = try? await whisper.transcribe(audioPath: url.path, decodeOptions: opts) else { return nil }
        if whisperLang == "auto", chunkLang == nil { chunkLang = results.first?.language }
        let segments = results.flatMap(\.segments).map { (Double($0.start), Double($0.end), $0.text) }
        return (results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines), segments)
    }

    private func finishWhisperAndTranscribe() {
        chunkTimer?.invalidate(); chunkTimer = nil
        stopInput()
        closeTake()
        let recorded = totalFrames
        cutChunk(final: true)             // flush + enqueue the final chunk
        status = .transcribing; startedAt = nil
        Task { @MainActor in
            _ = await transcribeChain?.value   // let the queue drain
            if case .unavailable = status { return }
            if recorded < 4000 {
                status = .unavailable("Nothing was recorded — the mic didn't pick up any audio. Check Microphone access in System Settings ▸ Privacy & Security (ad-hoc builds reset it), then try again.")
                return
            }
            if whisperCommitted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                status = .unavailable("No speech detected in the recording. Speak a little closer to the mic and try again.")
                Diagnostics.warn(.voice, "Recording finished but transcript was empty (\(recorded) frames)")
            } else {
                lastEngine = "Whisper (\(loadedModel ?? whisperModel))"
                status = .idle
                Diagnostics.info(.voice, "Recording transcribed · \(whisperCommitted.count) chars from \(String(format: "%.0f", Double(recorded)/sampleRate))s · chunks: \(chunksSent) sent, \(chunksDroppedSilent) silent-dropped, \(chunksKeptUnsure) kept-unsure, \(chunksEmptyResult) empty")
            }
            saveDraft()
        }
    }

    /// Transcribe an existing audio file the user imported.
    func importFile(_ url: URL) {
        transcript = ""; whisperMode = true
        Task { @MainActor in
            let text = await runWhisper(url)
            if case .unavailable = status {} else { status = .idle }
            transcript = text ?? ""; saveDraft()
        }
    }

    private func runWhisper(_ url: URL) async -> String? {
        do {
            try await ensureWhisper()
            status = .transcribing
            transcript = ""
            var promptTokens: [Int]? = nil
            if let v = vocabPrompt, !v.isEmpty, let tok = whisper?.tokenizer {
                let toks = tok.encode(text: " " + v); if !toks.isEmpty { promptTokens = toks }
            }
            let opts = DecodingOptions(language: whisperLang == "auto" ? nil : whisperLang,
                                       detectLanguage: whisperLang == "auto",
                                       skipSpecialTokens: true, promptTokens: promptTokens)
            // `ensureWhisper` can return without a handle: its load task starts with
            // `guard let self else { return }`, so if the service is torn down mid-load the
            // task completes successfully having assigned nothing. Force-unwrapping there
            // crashed the app in the middle of transcribing a lecture.
            guard let engine = whisper else {
                status = .unavailable("The speech model didn't finish loading. Try again.")
                return nil
            }
            // The callback streams the decoded text so far — shown live so it doesn't look stuck.
            let results = try await engine.transcribe(audioPath: url.path, decodeOptions: opts) { [weak self] progress in
                let t = progress.text
                Task { @MainActor in if !t.isEmpty { self?.transcript = t } }
                return nil
            }
            let out = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !out.isEmpty else {
                status = .unavailable("No speech detected in the recording. Speak a little closer to the mic and try again.")
                return nil
            }
            lastEngine = "Whisper (\(loadedModel ?? whisperModel))"
            return out
        } catch {
            status = .unavailable("Whisper couldn't transcribe: \(error.localizedDescription)")
            return nil
        }
    }

    func prepareWhisper() {
        Task { @MainActor in
            do { try await ensureWhisper(); if case .preparing = status { status = .idle } }
            catch { status = .unavailable("Couldn't prepare Whisper: \(error.localizedDescription)") }
        }
    }

    /// Load the model, deduping concurrent callers (the parallel prewarm and the first chunk's
    /// transcription both call this) onto one in-flight load task.
    private func ensureWhisper() async throws {
        if whisperReady { return }
        if let t = whisperLoadTask { try await t.value; return }
        let model = whisperModel
        if status != .recording { status = .preparing; prepProgress = 0 }   // don't flip UI mid-record
        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { return }
            self.whisper = nil; self.loadedModel = nil
            // Already downloaded? Load straight from the saved folder — no network, no re-download.
            if let saved = UserDefaults.standard.string(forKey: self.modelFolderKey(model)),
               FileManager.default.fileExists(atPath: saved),
               let w = try? await WhisperKit(WhisperKitConfig(modelFolder: saved, load: true, download: false)) {
                self.whisper = w; self.loadedModel = model
                Diagnostics.info(.voice, "Whisper model loaded from disk: \(model)")
                return
            }
            do {
                let folder = try await WhisperKit.download(variant: "openai_whisper-\(model)") { [weak self] p in
                    Task { @MainActor in self?.prepProgress = p.fractionCompleted }
                }
                UserDefaults.standard.set(folder.path, forKey: self.modelFolderKey(model))   // remember it's on disk
                self.whisper = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, load: true, download: false))
            } catch {
                self.whisper = try await WhisperKit(WhisperKitConfig(model: model, load: true, download: true))
            }
            self.loadedModel = model
        }
        whisperLoadTask = task
        do { try await task.value; whisperLoadTask = nil }
        catch { whisperLoadTask = nil; throw error }
    }

    // MARK: - Shared

    /// Mic tap for Apple Speech — appends buffers to the live recognition request. (Whisper
    /// installs its own tap that writes to chunk files.)
    // MARK: - Input: the microphone, or what the Mac is playing

    /// Record the Mac's own sound — a Zoom or Teams call, a lecture video — instead of the mic.
    var fromSystem: Bool { UserDefaults.standard.string(forKey: "voiceSource") == "system" }
    private let systemAudio = SystemAudio()
    /// Buffers are flowing from the source; what recognition and rotation check before going on.
    private var capturing = false

    /// Start the chosen source. `prepare` gets the buffers' format before the first one arrives
    /// (the take and chunks open in it), `handle` every buffer on the audio thread, and
    /// `started` whether it's running.
    private func startInput(prepare: @escaping (AVAudioFormat) -> Bool,
                            handle: @escaping (AVAudioPCMBuffer) -> Void,
                            started: @escaping @MainActor (Bool) -> Void) {
        if fromSystem {
            guard prepare(SystemAudio.format) else { started(false); return }
            Task { @MainActor in
                do {
                    try await systemAudio.start(handle)
                    capturing = true
                    started(true)
                } catch {
                    Diagnostics.warn(.voice, "System audio didn't start: \(error.localizedDescription)")
                    status = .unavailable(SystemAudio.denied)
                    started(false)
                }
            }
            return
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { status = .unavailable("No microphone input available."); started(false); return }
        guard prepare(format) else { started(false); return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in handle(buf) }
        engine.prepare()
        do {
            try engine.start()
            capturing = true
            started(true)
        } catch {
            status = .unavailable(error.localizedDescription)
            started(false)
        }
    }

    private func stopInput() {
        capturing = false
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        systemAudio.stop()
    }

    /// Throttled *before* the hop, not inside it.
    nonisolated private func pushLevel(rms: Float) {
        let now = Date()
        meterLock.lock()
        let due = now.timeIntervalSince(lastMeterAt) > 0.033
        if due { lastMeterAt = now }
        meterLock.unlock()
        guard due else { return }
        let level = max(0, min(1, (20 * log10(max(rms, 1e-7)) + 50) / 50))
        Task { @MainActor in self.meter.push(level) }
    }

    private func saveDraft() {
        guard Date().timeIntervalSince(lastDraftSave) > 2 else { return }
        lastDraftSave = Date()
        let text = transcript; let url = Self.draftURL
        Task.detached { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
    static func draftText() -> String? {
        guard let t = try? String(contentsOf: draftURL, encoding: .utf8),
              !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return t
    }
    static func clearDraft() { try? FileManager.default.removeItem(at: draftURL) }

    private func finish() {
        rotateTimer?.invalidate(); rotateTimer = nil
        chunkTimer?.invalidate(); chunkTimer = nil
        stopInput()
        task?.cancel(); task = nil; request = nil
        chunkLock.lock(); chunkFile = nil; chunkURL = nil; chunkLock.unlock()
        closeTake()
        startedAt = nil
        if status == .recording { status = .idle }
    }

    // MARK: - The take (audio kept with the note)

    /// Beside the store when a build runs on a throwaway one (STUDYBAR_DATA_DIR), so a test
    /// recording never lands among the student's lectures.
    static var recordingsDir: URL {
        let base = ProcessInfo.processInfo.environment["STUDYBAR_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? AppState.localDir
        let d = base.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// AAC at the mic's own rate. The encoder treats the bitrate as a hint — measured at about
    /// 110 kbps, so roughly 50 MB for an hour of lecture. A device with more than two channels
    /// gets no take rather than a failed recording.
    fileprivate func openTake(_ format: AVAudioFormat) {
        guard format.channelCount <= 2 else { return }
        let url = Self.recordingsDir.appendingPathComponent("take-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                       AVSampleRateKey: format.sampleRate,
                                       AVNumberOfChannelsKey: format.channelCount,
                                       AVEncoderBitRateKey: 64_000 * Int(format.channelCount)]
        guard let f = try? AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: format.commonFormat, interleaved: format.isInterleaved) else {
            Diagnostics.warn(.voice, "Couldn't open the audio take; recording continues without it")
            return
        }
        takeLock.lock(); takeFile = f; takeFrames = 0; takeRate = format.sampleRate; takeLock.unlock()
        takeURL = url
    }

    nonisolated fileprivate func writeTake(_ buf: AVAudioPCMBuffer) {
        takeLock.lock(); try? takeFile?.write(from: buf); takeFrames += AVAudioFramePosition(buf.frameLength); takeLock.unlock()
    }

    /// Dropping the file is what writes the M4A's index; a take that is never closed can't be played.
    fileprivate func closeTake() {
        takeLock.lock(); takeFile = nil; takeLock.unlock()
    }

    /// Mark this moment of the lecture as one that matters: it gets a ⭐ in the note's
    /// transcript, and "Make study notes" gives it prominence.
    func star() {
        guard status == .recording else { return }
        timeline.stars.append(takeElapsed)
    }

    /// Quitting mid-recording: stop the mic and close the take so the file is playable.
    func stopForQuit() {
        wantsRecording = false
        finish()
    }

    func discardTake() {
        closeTake()
        if let url = takeURL { try? FileManager.default.removeItem(at: url) }
        takeURL = nil
    }

    /// Move the take next to the note it belongs to; returns the file name to store on it.
    func claimTake(for noteID: UUID) -> String? {
        guard !isRecording, let url = takeURL else { return nil }
        let name = "\(noteID.uuidString).m4a"
        let dst = Self.recordingsDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dst)
        guard (try? FileManager.default.moveItem(at: url, to: dst)) != nil else { return nil }
        takeURL = nil
        if !timeline.lines.isEmpty { try? JSONEncoder().encode(timeline).write(to: LectureTimeline.url(beside: dst)) }
        return name
    }

    /// An idle MacBook on battery sleeps, and a sleeping Mac records nothing — so a lecture
    /// holds the system awake from the first word until its transcript is done.
    private func holdAwake(_ on: Bool) {
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                          reason: "Recording a lecture")
            warned = []
            checkPowerAndDisk()
            healthTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkPowerAndDisk() }
            }
        } else if !on, let a = awake {
            ProcessInfo.processInfo.endActivity(a); awake = nil
            healthTimer?.invalidate(); healthTimer = nil
        }
    }

    /// A dead battery or a full disk ends a lecture without a word, so say so while there's
    /// still time to plug in or free space — once each per recording.
    private func checkPowerAndDisk() {
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        if let free, free < 1_000_000_000, warned.insert("disk").inserted {
            Notifier.post(title: "Disk almost full", body: "Under 1 GB left. The recording stops if the disk fills, so free some space.")
        }
        if let pct = Self.batteryPercentOnBattery(), pct <= 15, warned.insert("battery").inserted {
            Notifier.post(title: "Battery at \(pct)%", body: "Plug in so the lecture isn't cut off.")
        }
    }

    /// Charge in percent while running on battery; nil on power, or on a Mac without one.
    static func batteryPercentOnBattery() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return cur * 100 / max
        }
        return nil
    }

    private func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }; if b.isEmpty { return a }; return a + " " + b
    }
}

// MARK: - Timeline

/// A recording's sentences and when in the audio each was said — so a note can play any of
/// them back — plus the moments starred while recording. Kept beside the audio
/// (`Recordings/<note>.json`), not in the synced store.
struct LectureTimeline: Codable, Equatable {
    struct Line: Codable, Equatable { var t: Double; var text: String }
    var lines: [Line] = []
    var stars: [Double] = []

    /// Text heard between two times, one line per sentence. With word times (Apple Speech) a
    /// sentence starts at its first word; without, at its share of the span.
    // ponytail: proportional placement is off by a few seconds in a long Apple Speech segment
    // without word times; playback starts a moment early to cover it.
    mutating func add(_ text: String, from t0: Double, to t1: Double, words: [(offset: Int, t: Double)] = []) {
        let length = Double(max(1, (text as NSString).length))
        let timed = words.contains { $0.t > 0 }
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let sentence = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return true }
            let at = NSRange(r, in: text).location
            let dt = timed ? (words.last { $0.offset <= at }?.t ?? 0) : Double(at) / length * (t1 - t0)
            lines.append(Line(t: t0 + dt, text: sentence))
            return true
        }
    }

    /// The line being said at each star, or the one just before — you star what you just heard.
    var starred: Set<Int> { Set(stars.compactMap { s in lines.lastIndex { $0.t <= s + 0.5 } }) }

    /// The transcript with ⭐ before each starred sentence, for the notes to give it prominence.
    func marking(_ transcript: String) -> String {
        var out = transcript
        for i in starred {
            if let r = out.range(of: lines[i].text) { out.replaceSubrange(r, with: "⭐ " + lines[i].text) }
        }
        return out
    }

    static func url(beside audio: URL) -> URL { audio.deletingPathExtension().appendingPathExtension("json") }
    static func load(beside audio: URL) -> LectureTimeline? {
        (try? Data(contentsOf: url(beside: audio))).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
}

// MARK: - Self-test (StudyBar --take-selftest)

/// The take is written on the audio thread with no one listening, so its encoder settings are
/// checked here with synthetic audio: a mic-shaped buffer in, a playable M4A of the same length
/// out. Also the course vocabulary that recognition is handed.
@MainActor
enum VoiceTakeSelfTest {
    static func run() -> Int32 {
        var fail = 0
        func check(_ n: String, _ ok: Bool, _ d: String = "") {
            print("  \(ok ? "ok  " : "FAIL") \(n) \(d)"); if !ok { fail += 1 }
        }
        for channels: AVAudioChannelCount in [1, 2] {
            let voice = VoiceService()
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
            voice.openTake(fmt)
            check("\(channels)ch take opens", voice.takeURL != nil)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1024)!
            buf.frameLength = 1024
            var phase: Float = 0
            for _ in 0..<(48_000 * 3 / 1024) {          // three seconds of a 440 Hz tone
                for i in 0..<1024 {
                    phase += 2 * .pi * 440 / 48_000
                    for c in 0..<Int(channels) { buf.floatChannelData![c][i] = 0.3 * sin(phase) }
                }
                voice.writeTake(buf)
            }
            voice.closeTake()
            guard let url = voice.takeURL, let back = try? AVAudioFile(forReading: url) else {
                check("\(channels)ch take is readable", false); continue
            }
            let secs = Double(back.length) / back.fileFormat.sampleRate
            check("\(channels)ch take is ~3 s", abs(secs - 3) < 0.2, String(format: "(%.2f s)", secs))
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            check("\(channels)ch take is compressed", bytes > 0 && bytes < 100_000, "(\(bytes) bytes)")
            let id = UUID()
            let name = voice.claimTake(for: id)
            check("\(channels)ch claim moves it beside the note", name == "\(id.uuidString).m4a"
                  && FileManager.default.fileExists(atPath: VoiceService.recordingsDir.appendingPathComponent(name ?? "").path)
                  && voice.takeURL == nil)
            if let name { try? FileManager.default.removeItem(at: VoiceService.recordingsDir.appendingPathComponent(name)) }
        }

        let course = Course(name: "Linear Algebra", code: "MAS3105")
        var other = Note(title: "x", body: "**Unrelated**", courseID: UUID())
        other.tags = []
        let notes = [Note(title: "W1", body: "# Eigenvalues\n- **eigenvector**: a vector…\n- **$\\lambda$** skipped\n## Diagonalization", courseID: course.id), other]
        let terms = CourseVocabulary.terms(course: course, notes: notes)
        check("vocabulary from the course's notes", ["Linear Algebra", "MAS3105", "Eigenvalues", "eigenvector", "Diagonalization"].allSatisfy(terms.contains), "\(terms)")
        check("vocabulary skips math and other courses", !terms.contains { $0.contains("$") || $0 == "Unrelated" })

        // The timeline: sentences placed in time, stars on the line just heard, ⭐ for the notes.
        do {
            var t = LectureTimeline()
            t.add("Flux is field through area. Gauss's law counts the charge inside. Pick a symmetric surface.", from: 10, to: 40)
            let ts = t.lines.map(\.t)
            check("one line per sentence", t.lines.count == 3 && t.lines[1].text == "Gauss's law counts the charge inside.", "\(t.lines.map(\.text))")
            check("placed in order within the span", ts.first == 10 && ts == ts.sorted() && ts.last! < 40, "\(ts)")
            t.add("A second block. With word times.", from: 60, to: 70, words: [(0, 0.5), (2, 1.0), (16, 4.0)])
            check("word times place a sentence at its first word", t.lines.last.map { abs($0.t - 64) < 0.01 } == true, "\(t.lines.map(\.t))")
            t.stars = [ts[1] + 3]
            check("a star marks the line just heard", t.starred == [1])
            check("starred sentences are marked for the notes",
                  t.marking("Flux is field through area. Gauss's law counts the charge inside.").contains("⭐ Gauss's law"))
            let audio = FileManager.default.temporaryDirectory.appendingPathComponent("tl-\(UUID().uuidString).m4a")
            try? JSONEncoder().encode(t).write(to: LectureTimeline.url(beside: audio))
            check("kept beside the recording", LectureTimeline.load(beside: audio) == t)
            try? FileManager.default.removeItem(at: LectureTimeline.url(beside: audio))
        }

        print(fail == 0 ? "TAKE SELFTEST: ALL PASS" : "TAKE SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
