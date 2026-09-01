import Foundation
import Speech
import AVFoundation
import WhisperKit

/// Records a voice memo and transcribes it on-device — nothing leaves the Mac. Two engines:
///  • **Apple Speech** (default): live streaming transcript, instant, tiny. Segments chain
///    past the recognizer's ~1-minute auto-finalize so dictation runs as long as you talk.
///  • **Whisper** (opt-in): records to a file, then transcribes with WhisperKit (CoreML) for
///    higher accuracy. The model downloads once on first use, then works fully offline.
@MainActor
final class VoiceService: ObservableObject {
    enum Status: Equatable { case idle, recording, transcribing, denied, unavailable(String) }
    @Published var status: Status = .idle
    @Published var transcript = ""
    /// Recent input loudness (0…1), newest last — drives the live level meter so the user can
    /// see sound is being captured and how loud it is (aim the mic at the professor).
    @Published var waveform: [Float] = Array(repeating: 0, count: 48)
    private var lastMeter = Date.distantPast

    static let locales: [(id: String, label: String)] = [
        ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("es-ES", "Spanish"),
        ("fr-FR", "French"), ("de-DE", "German"), ("it-IT", "Italian"),
        ("pt-BR", "Portuguese"), ("zh-CN", "Chinese"), ("ja-JP", "Japanese"),
        ("ko-KR", "Korean"), ("hi-IN", "Hindi"), ("ar-SA", "Arabic"),
    ]
    var localeID: String { UserDefaults.standard.string(forKey: "voiceLocale") ?? "en-US" }
    private var useWhisper: Bool { (UserDefaults.standard.string(forKey: "voiceEngine") ?? "apple") == "whisper" }
    private var whisperModel: String { UserDefaults.standard.string(forKey: "voiceWhisperModel") ?? "base" }

    private let engine = AVAudioEngine()
    // Apple Speech
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var committed = ""
    private var wantsRecording = false
    // Whisper
    private var whisper: WhisperKit?
    private var audioFile: AVAudioFile?
    private var recordURL: URL?
    private var whisperMode = false

    var isRecording: Bool { status == .recording }
    func toggle() {
        switch status {
        case .recording: userStop()
        case .transcribing: break            // busy — ignore taps
        default: start()
        }
    }

    func start() {
        transcript = ""; committed = ""; wantsRecording = true
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
                    self.transcript = self.join(self.committed, result.bestTranscription.formattedString)
                    if result.isFinal { self.segmentFinished(result.bestTranscription.formattedString) }
                } else if error != nil { self.finish() }
            }
        }
    }

    private func segmentFinished(_ partial: String) {
        committed = join(committed, partial); transcript = committed
        task = nil; request = nil
        if wantsRecording && engine.isRunning { startSegment() } else { finish() }
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
        audioFile = nil                                   // close/flush the file
        guard let url = recordURL else { status = .idle; return }
        status = .transcribing
        Task { @MainActor in
            let text = await transcribeWhisper(url)
            if case .unavailable = status {} else { status = .idle }
            transcript = text ?? transcript
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func transcribeWhisper(_ url: URL) async -> String? {
        do {
            if whisper == nil { whisper = try await WhisperKit(model: whisperModel) }
            let results = try await whisper!.transcribe(audioPath: url.path)
            let text = results.map(\.text).joined(separator: " ")
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            status = .unavailable("Whisper couldn't transcribe: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Shared

    /// Install the input tap. `write` = also stream buffers into `audioFile` (Whisper mode).
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

    /// RMS → dBFS → 0…1, pushed into the rolling waveform (throttled to ~30 fps).
    nonisolated private func meter(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength); guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { let s = ch[i]; sum += s * s }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (db + 50) / 50))          // -50 dBFS … 0 → 0 … 1
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
