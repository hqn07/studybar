import Foundation
import Speech
import AVFoundation

/// Records a voice memo and transcribes it on-device (Apple Speech, forced on-device — the
/// audio never leaves the Mac). The recognizer auto-finalizes a segment roughly every
/// minute; we commit that segment and start the next one seamlessly, so dictation runs as
/// long as you keep talking (a memo, a thought, a whole lecture). The transcript becomes a note.
@MainActor
final class VoiceService: ObservableObject {
    enum Status: Equatable { case idle, recording, denied, unavailable(String) }
    @Published var status: Status = .idle
    @Published var transcript = ""

    /// Locales students commonly dictate in. Persisted at `voiceLocale`.
    static let locales: [(id: String, label: String)] = [
        ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("es-ES", "Spanish"),
        ("fr-FR", "French"), ("de-DE", "German"), ("it-IT", "Italian"),
        ("pt-BR", "Portuguese"), ("zh-CN", "Chinese"), ("ja-JP", "Japanese"),
        ("ko-KR", "Korean"), ("hi-IN", "Hindi"), ("ar-SA", "Arabic"),
    ]
    var localeID: String { UserDefaults.standard.string(forKey: "voiceLocale") ?? "en-US" }

    private var recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var committed = ""            // finalized segments so far
    private var wantsRecording = false    // true from user-start until user-stop

    var isRecording: Bool { status == .recording }
    func toggle() { isRecording ? userStop() : start() }

    func start() {
        transcript = ""; committed = ""; wantsRecording = true
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard auth == .authorized else { self.status = .denied; return }
                guard await AVCaptureDevice.requestAccess(for: .audio) else { self.status = .denied; return }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        guard let recognizer, recognizer.isAvailable else {
            status = .unavailable("Speech recognition isn't available for this language yet."); return
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { status = .unavailable("No microphone input available."); return }
        // One tap for the whole session; it feeds whichever segment request is live.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.request?.append(buf)
        }
        engine.prepare()
        do { try engine.start() } catch { status = .unavailable(error.localizedDescription); finish(); return }
        status = .recording
        startSegment()
    }

    /// Start a fresh recognition segment on the still-running audio engine.
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
                    let partial = result.bestTranscription.formattedString
                    self.transcript = self.join(self.committed, partial)
                    if result.isFinal { self.segmentFinished(partial) }
                } else if error != nil {
                    self.finish()   // hard error — keep what we have, stop
                }
            }
        }
    }

    /// A segment auto-finalized (or the user ended audio): commit it, then continue with the
    /// next segment if the user is still recording — otherwise wrap up.
    private func segmentFinished(_ partial: String) {
        committed = join(committed, partial)
        transcript = committed
        task = nil; request = nil
        if wantsRecording && engine.isRunning { startSegment() } else { finish() }
    }

    /// User tapped stop: end the current segment's audio so it finalizes, then finish.
    func userStop() {
        wantsRecording = false
        if task != nil { request?.endAudio() } else { finish() }
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
