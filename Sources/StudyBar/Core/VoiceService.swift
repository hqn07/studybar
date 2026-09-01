import Foundation
import Speech
import AVFoundation
import WhisperKit

/// Records a voice memo and transcribes it on-device — nothing leaves the Mac. Two engines:
///  • **Apple Speech** (default): live streaming transcript, instant, tiny. Segments chain
///    past the recognizer's ~1-minute auto-finalize so dictation runs as long as you talk.
///  • **Whisper** (opt-in, WhisperKit/CoreML): higher accuracy. The model downloads once
///    (with visible progress) and then runs fully offline; a course-vocabulary prompt biases
///    recognition toward the class's terms.
@MainActor
final class VoiceService: ObservableObject {
    enum Status: Equatable { case idle, recording, preparing, transcribing, denied, unavailable(String) }
    @Published var status: Status = .idle
    @Published var transcript = ""
    /// Rolling input loudness (0…1), newest last — drives the live level meter.
    @Published var waveform: [Float] = Array(repeating: 0, count: 48)
    /// Model-download progress (0…1) while `.preparing`.
    @Published var prepProgress: Double = 0
    /// What produced the current transcript, e.g. "Whisper (base)" or "Apple Speech".
    @Published var lastEngine = ""
    /// Course-vocabulary bias for Whisper (set by the view when a course is picked).
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
    private var emptyRestarts = 0
    private var wantsRecording = false
    // Whisper
    private var whisper: WhisperKit?
    @Published private(set) var loadedModel: String?   // published so the UI knows when a model is ready
    private var audioFile: AVAudioFile?
    private var recordURL: URL?
    private var whisperMode = false

    /// True when the loaded Whisper model matches the current pref (no download needed).
    var whisperReady: Bool { loadedModel == whisperModel }

    var isRecording: Bool { status == .recording }
    func toggle() {
        switch status {
        case .recording: userStop()
        case .preparing, .transcribing: break
        default: start()
        }
    }

    func start() {
        transcript = ""; committed = ""; currentPartial = ""; emptyRestarts = 0; wantsRecording = true
        waveform = Array(repeating: 0, count: 48)
        whisperMode = useWhisper
        Task { @MainActor in
            guard await AVCaptureDevice.requestAccess(for: .audio) else { status = .denied; return }
            if whisperMode { beginFileRecording() } else { startAppleSpeech() }
        }
    }

    func userStop() {
        wantsRecording = false
        if whisperMode { finishFileRecordingAndTranscribe() }
        else if task != nil { request?.endAudio() } else { finish() }
    }

    // MARK: - Apple Speech (live)

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
        guard installTap(write: false) else { return }
        do { try engine.start() } catch { status = .unavailable(error.localizedDescription); finish(); return }
        status = .recording
        startSegment()
    }

    private func startSegment() {
        guard let recognizer, wantsRecording else { finish(); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.currentPartial = result.bestTranscription.formattedString
                    self.transcript = self.join(self.committed, self.currentPartial)
                    if result.isFinal { self.commitAndContinue() }
                } else if error != nil {
                    // On-device Speech ends a segment with an error (not just isFinal),
                    // routinely near the ~1-minute cap. Commit what we have and keep going,
                    // rather than stopping and dropping the paragraph.
                    self.commitAndContinue()
                }
            }
        }
    }

    /// A segment ended (final or errored): fold its text into the running transcript, then
    /// start the next segment if the user is still recording. Bails out only if the user
    /// stopped or several segments in a row produced nothing (a real fault, not a boundary).
    private func commitAndContinue() {
        if !currentPartial.isEmpty {
            committed = join(committed, currentPartial)
            transcript = committed
            emptyRestarts = 0
        } else {
            emptyRestarts += 1
        }
        currentPartial = ""
        task = nil; request = nil
        guard wantsRecording, engine.isRunning, emptyRestarts < 6 else { finish(); return }
        startSegment()
    }

    // MARK: - Whisper (record to file → transcribe)

    private func beginFileRecording() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).caf")
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { status = .unavailable("No microphone input available."); return }
        do { audioFile = try AVAudioFile(forWriting: url, settings: format.settings) }
        catch { status = .unavailable(error.localizedDescription); return }
        recordURL = url
        guard installTap(write: true) else { return }
        do { try engine.start() } catch { status = .unavailable(error.localizedDescription); finish(); return }
        status = .recording
    }

    private func finishFileRecordingAndTranscribe() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        audioFile = nil
        guard let url = recordURL else { status = .idle; return }
        Task { @MainActor in
            let text = await runWhisper(url)
            if case .unavailable = status {} else { status = .idle }
            transcript = text ?? transcript
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Transcribe an existing audio file the user imported (record on a phone, drop it here).
    func importFile(_ url: URL) {
        transcript = ""; whisperMode = true
        Task { @MainActor in
            let text = await runWhisper(url)
            if case .unavailable = status {} else { status = .idle }
            transcript = text ?? ""
        }
    }

    /// Pre-download + load the model so the first lecture isn't interrupted. Idempotent.
    func prepareWhisper() {
        Task { @MainActor in
            do { try await ensureWhisper(); if case .preparing = status { status = .idle } }
            catch { status = .unavailable("Couldn't prepare Whisper: \(error.localizedDescription)") }
        }
    }

    /// Ensure the current Whisper model is downloaded (with progress) and loaded.
    private func ensureWhisper() async throws {
        if whisperReady { return }
        whisper = nil; loadedModel = nil
        status = .preparing; prepProgress = 0
        let model = whisperModel
        do {
            let folder = try await WhisperKit.download(variant: "openai_whisper-\(model)") { [weak self] p in
                Task { @MainActor in self?.prepProgress = p.fractionCompleted }
            }
            whisper = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, load: true, download: false))
        } catch {
            // Fallback: let WhisperKit resolve + fetch the short name itself (no progress bar).
            whisper = try await WhisperKit(WhisperKitConfig(model: model, load: true, download: true))
        }
        loadedModel = model
    }

    private func runWhisper(_ url: URL) async -> String? {
        do {
            try await ensureWhisper()
            status = .transcribing
            var promptTokens: [Int]? = nil
            if let v = vocabPrompt, !v.isEmpty, let toks = whisper?.tokenizer?.encode(text: " " + v), !toks.isEmpty {
                promptTokens = toks
            }
            let opts = DecodingOptions(language: whisperLang == "auto" ? nil : whisperLang,
                                       detectLanguage: whisperLang == "auto",
                                       promptTokens: promptTokens)
            let results = try await whisper!.transcribe(audioPath: url.path, decodeOptions: opts)
            lastEngine = "Whisper (\(loadedModel ?? model(from: url)))"
            return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            status = .unavailable("Whisper couldn't transcribe: \(error.localizedDescription)")
            return nil
        }
    }
    private func model(from _: URL) -> String { whisperModel }

    // MARK: - Shared

    private func installTap(write: Bool) -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { status = .unavailable("No microphone input available."); return false }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self else { return }
            if write { try? self.audioFile?.write(from: buf) } else { self.request?.append(buf) }
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
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (db + 50) / 50))
        Task { @MainActor in
            guard Date().timeIntervalSince(self.lastMeter) > 0.033 else { return }
            self.lastMeter = Date()
            var w = self.waveform; w.removeFirst(); w.append(level); self.waveform = w
        }
    }

    private func finish() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel(); task = nil; request = nil
        if status == .recording { status = .idle }
    }

    private func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }; if b.isEmpty { return a }; return a + " " + b
    }
}
