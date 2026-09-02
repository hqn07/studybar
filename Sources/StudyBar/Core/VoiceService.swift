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
    private var emptyRestarts = 0
    private var wantsRecording = false
    // Whisper (batch)
    private var whisper: WhisperKit?
    private var audioFile: AVAudioFile?
    private var recordURL: URL?
    private var whisperMode = false
    // Autosave draft — crash-safe raw transcript.
    private var lastDraftSave = Date.distantPast
    static var draftURL: URL { AppState.localDir.appendingPathComponent("voice-draft.txt") }

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
            if whisperMode { beginWhisperRecording() } else { startAppleSpeech() }
        }
    }

    func userStop() {
        wantsRecording = false
        if whisperMode { finishWhisperAndTranscribe() }
        else if task != nil { request?.endAudio() } else { finish() }
    }

    // MARK: - Apple Speech (live, chained segments)

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
                    self.commitAndContinue()   // segment error = a boundary, not a stop
                }
            }
        }
    }

    private func commitAndContinue() {
        if !currentPartial.isEmpty {
            committed = join(committed, currentPartial); transcript = committed; emptyRestarts = 0; saveDraft()
        } else { emptyRestarts += 1 }
        currentPartial = ""; task = nil; request = nil
        guard wantsRecording, engine.isRunning, emptyRestarts < 6 else { finish(); return }
        startSegment()
    }

    // MARK: - Whisper (record whole take → transcribe with progressive text)

    private func beginWhisperRecording() {
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

    private func finishWhisperAndTranscribe() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        audioFile = nil
        guard let url = recordURL else { status = .idle; return }
        Task { @MainActor in
            let text = await runWhisper(url)
            if case .unavailable = status {} else { status = .idle }
            transcript = text ?? transcript
            saveDraft()
            try? FileManager.default.removeItem(at: url)
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
            lastEngine = "Whisper (\(loadedModel ?? whisperModel))"
            return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
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
            whisper = try await WhisperKit(WhisperKitConfig(model: model, load: true, download: true))
        }
        loadedModel = model
    }

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
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel(); task = nil; request = nil
        if status == .recording { status = .idle }
    }

    private func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }; if b.isEmpty { return a }; return a + " " + b
    }
}
