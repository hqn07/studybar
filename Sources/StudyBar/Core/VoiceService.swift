import Foundation
import Speech
import AVFoundation
import WhisperKit

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
    @Published var status: Status = .idle
    @Published var transcript = ""
    @Published var waveform: [Float] = Array(repeating: 0, count: 48)
    @Published var prepProgress: Double = 0
    @Published var lastEngine = ""
    @Published private(set) var loadedModel: String?
    var vocabPrompt: String?
    private var lastMeter = Date.distantPast

    static let locales: [(id: String, label: String)] = [
        ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("es-ES", "Spanish"),
        ("fr-FR", "French"), ("de-DE", "German"), ("it-IT", "Italian"),
        ("pt-BR", "Portuguese"), ("zh-CN", "Chinese"), ("ja-JP", "Japanese"),
        ("ko-KR", "Korean"), ("hi-IN", "Hindi"), ("ar-SA", "Arabic"),
    ]
    static let whisperModels: [(id: String, label: String)] = [
        ("tiny", "Tiny · ~75 MB · fastest"), ("base", "Base · ~150 MB · balanced"),
        ("small", "Small · ~500 MB · better"), ("large-v3", "Large v3 · ~1.5 GB · best"),
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
    private var lastLoudAt = Date()
    private var chunkTimer: Timer?
    private var transcribeChain: Task<Void, Never>?
    private var whisperCommitted = ""
    private var chunkLang: String?        // language detected on the first chunk, reused after
    private let minChunkSec = 8.0         // small enough that each transcribes fast (text stays current)
    private let maxChunkSec = 18.0        // hard cut, so text never lags too far behind live
    private let pauseGapSec = 0.4         // prefer cutting at a natural pause
    private let silenceRMS: Float = 0.035
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
        transcript = ""; committed = ""; currentPartial = ""; wantsRecording = true
        waveform = Array(repeating: 0, count: 48)
        whisperMode = useWhisper
        Task { @MainActor in
            guard await AVCaptureDevice.requestAccess(for: .audio) else { status = .denied; return }
            if whisperMode { beginWhisperRecording() } else { startAppleSpeech() }
        }
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
        guard installTap() else { return }
        do { try engine.start() } catch { status = .unavailable(error.localizedDescription); finish(); return }
        status = .recording
        emptyStreak = 0; everGotResult = false; recordingStart = Date()
        startSegment()
        // 1s timer: watchdog for a silent/dead mic, and rotate before SFSpeech's ~60s wall.
        rotateTimer?.invalidate()
        rotateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdog(); self?.maybeRotate() }
        }
    }

    /// If we've been "recording" for a while with no recognized text AND the input meter is
    /// flat, the mic is delivering silence — almost always a mic/Speech permission that reset
    /// when the app was rebuilt (ad-hoc signing). Surface it instead of looking frozen.
    private func watchdog() {
        guard status == .recording, wantsRecording else { return }
        let elapsed = Date().timeIntervalSince(recordingStart)
        let live = (waveform.max() ?? 0) > 0.03
        guard elapsed > 8, !everGotResult, !live else { return }
        status = .unavailable("The mic isn't picking up any sound. Grant Microphone and Speech Recognition to StudyBar in System Settings ▸ Privacy & Security (ad-hoc builds reset these on each update), then try again.")
        finish()
    }

    private func startSegment() {
        guard let recognizer, wantsRecording, engine.isRunning else { finish(); return }
        segmentID &+= 1
        let myID = segmentID
        segmentStart = Date(); rotating = false; segmentGotResult = false
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.segmentID == myID else { return }   // ignore a rotated-out task
                if let result {
                    self.segmentGotResult = true; self.everGotResult = true
                    self.currentPartial = result.bestTranscription.formattedString
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
        guard restart, wantsRecording, engine.isRunning else { finish(); return }
        if emptyStreak >= 4 {
            status = .unavailable("Apple Speech isn't producing any text on this Mac — switch to Whisper (menu, top-right), which runs fully offline.")
            finish(); return
        }
        startSegment()
    }

    private func commitCurrent() {
        guard !currentPartial.isEmpty else { return }
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
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { status = .unavailable("No microphone input available."); return }
        chunkSettings = format.settings; sampleRate = format.sampleRate
        whisperCommitted = ""; transcript = ""; totalFrames = 0; lastLoudAt = Date(); chunkLang = nil
        guard openNewChunk() else { status = .unavailable("Couldn't start recording."); return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self else { return }
            self.chunkLock.lock()
            try? self.chunkFile?.write(from: buf)
            self.chunkFrames += AVAudioFramePosition(buf.frameLength)
            self.totalFrames += AVAudioFramePosition(buf.frameLength)
            self.chunkLock.unlock()
            self.meter(buf)
            self.trackLoud(buf)
        }
        engine.prepare()
        do { try engine.start() } catch { status = .unavailable(error.localizedDescription); finish(); return }
        status = .recording
        Diagnostics.info(.voice, "Whisper recording started · model \(whisperModel) · sr \(Int(sampleRate))")
        chunkTimer?.invalidate()
        chunkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.maybeCutChunk() }
        }
    }

    @discardableResult private func openNewChunk() -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vchunk-\(UUID().uuidString).caf")
        guard let f = try? AVAudioFile(forWriting: url, settings: chunkSettings) else { return false }
        chunkLock.lock(); chunkFile = f; chunkURL = url; chunkFrames = 0; chunkStart = Date(); chunkLock.unlock()
        return true
    }

    /// Note the last time the mic heard real sound, so a chunk can be cut at a pause.
    nonisolated private func trackLoud(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength); guard n > 0 else { return }
        var sum: Float = 0; for i in 0..<n { let s = ch[i]; sum += s * s }
        if (sum / Float(n)).squareRoot() > silenceRMS {
            let now = Date(); Task { @MainActor in self.lastLoudAt = now }
        }
    }

    private func maybeCutChunk() {
        guard status == .recording, wantsRecording else { return }
        let dur = Date().timeIntervalSince(chunkStart)
        let paused = Date().timeIntervalSince(lastLoudAt) >= pauseGapSec
        if dur >= maxChunkSec || (dur >= minChunkSec && paused) { cutChunk(final: false) }
    }

    /// Close the current chunk (flushing it to disk) and enqueue it, then open the next.
    private func cutChunk(final: Bool) {
        chunkLock.lock()
        let url = chunkURL; let frames = chunkFrames
        chunkFile = nil; chunkURL = nil          // dropping the ref flushes + closes the file
        chunkLock.unlock()
        if let url {
            if frames > AVAudioFramePosition(sampleRate * 0.4) { enqueueTranscribe(url) }
            else { try? FileManager.default.removeItem(at: url) }   // < 0.4s of audio — skip
        }
        if !final { openNewChunk() }
    }

    /// Serial background transcription: chunk N is appended before N+1 is transcribed.
    private func enqueueTranscribe(_ url: URL) {
        let prev = transcribeChain
        transcribeChain = Task { @MainActor in
            _ = await prev?.value
            let text = await transcribeChunk(url)
            try? FileManager.default.removeItem(at: url)
            if let text, !text.isEmpty {
                whisperCommitted = join(whisperCommitted, text)
                transcript = whisperCommitted
                saveDraft()
            }
        }
    }

    private func transcribeChunk(_ url: URL) async -> String? {
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
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finishWhisperAndTranscribe() {
        chunkTimer?.invalidate(); chunkTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        let recorded = totalFrames
        cutChunk(final: true)             // flush + enqueue the final chunk
        status = .transcribing
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
                Diagnostics.info(.voice, "Recording transcribed · \(whisperCommitted.count) chars from \(String(format: "%.0f", Double(recorded)/sampleRate))s")
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
            // The callback streams the decoded text so far — shown live so it doesn't look stuck.
            let results = try await whisper!.transcribe(audioPath: url.path, decodeOptions: opts) { [weak self] progress in
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
    private func installTap() -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { status = .unavailable("No microphone input available."); return false }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self else { return }
            self.request?.append(buf)
            self.meter(buf)
        }
        engine.prepare()
        return true
    }

    nonisolated private func meter(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength); guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { let s = ch[i]; sum += s * s }
        let rms = (sum / Float(n)).squareRoot()
        let level = max(0, min(1, (20 * log10(max(rms, 1e-7)) + 50) / 50))
        Task { @MainActor in
            guard Date().timeIntervalSince(self.lastMeter) > 0.033 else { return }
            self.lastMeter = Date()
            var w = self.waveform; w.removeFirst(); w.append(level); self.waveform = w
        }
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
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel(); task = nil; request = nil
        chunkLock.lock(); chunkFile = nil; chunkURL = nil; chunkLock.unlock()
        if status == .recording { status = .idle }
    }

    private func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }; if b.isEmpty { return a }; return a + " " + b
    }
}
