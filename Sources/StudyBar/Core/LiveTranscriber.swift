import AVFoundation
import Speech

/// Live transcription with SpeechAnalyzer (macOS 26), which Voice uses for Apple Speech where
/// it can. Measured against the SFSpeechRecognizer it replaces (`--stt-bench`, a lecture read
/// aloud): 11.0% of words wrong against 16.7% clean, 16.7 against 24.9 at 10 dB of noise, 23.6
/// against 36.2 at 5 dB — and three to nine times faster. It has no one-minute wall either, so
/// the request rotation the old engine needs is gone.
@available(macOS 26.0, *)
final class LiveTranscriber: @unchecked Sendable {
    /// What a result means for the transcript: text so far that may still change, or final text
    /// with its place in the audio (seconds from the start) and each word's time within it.
    struct Piece { let text: String; let final: Bool; let start: Double; let end: Double; let words: [(offset: Int, t: Double)] }

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let stream: AsyncStream<AnalyzerInput>
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?        // the audio thread's alone
    private var reading: Task<Void, Never>?

    private init(_ t: SpeechTranscriber, _ a: SpeechAnalyzer, _ f: AVAudioFormat) {
        transcriber = t; analyzer = a; format = f
        (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
    }

    /// nil when this Mac has no model for the language yet — Voice then records with the old
    /// engine, and the model is fetched for next time.
    static func make(locale: Locale, vocabulary: [String]) async -> LiveTranscriber? {
        guard await SpeechTranscriber.supportedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else { return nil }
        let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                  attributeOptions: [.audioTimeRange])
        guard await AssetInventory.status(forModules: [t]) == .installed else {
            Task.detached { try? await AssetInventory.assetInstallationRequest(supporting: [t])?.downloadAndInstall() }
            return nil
        }
        guard let f = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else { return nil }
        let a = SpeechAnalyzer(modules: [t])
        if !vocabulary.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = Array(vocabulary.prefix(100))
            try? await a.setContext(ctx)
        }
        try? await a.prepareToAnalyze(in: f)
        return LiveTranscriber(t, a, f)
    }

    /// Starts listening; `onPiece` is called on the main actor as text arrives.
    func start(_ onPiece: @escaping @MainActor (Piece) -> Void) async throws {
        let t = transcriber
        reading = Task {
            do {
                for try await r in t.results {
                    let text = String(r.text.characters)
                    let start = r.range.start.seconds.isFinite ? r.range.start.seconds : 0
                    var words: [(offset: Int, t: Double)] = [], offset = 0
                    for run in r.text.runs {
                        if let range = run.audioTimeRange, range.start.seconds.isFinite { words.append((offset, range.start.seconds - start)) }
                        offset += (String(r.text[run.range].characters) as NSString).length
                    }
                    let end = r.range.end.seconds.isFinite ? r.range.end.seconds : start
                    await onPiece(Piece(text: text, final: r.isFinal, start: start, end: end, words: words))
                }
            } catch {
                Diagnostics.warn(.voice, "SpeechAnalyzer results ended: \(error.localizedDescription)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// One captured buffer, from the audio thread: converted to the model's format and queued.
    func append(_ buf: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != buf.format { converter = AVAudioConverter(from: buf.format, to: format) }
        guard let converter,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * format.sampleRate / buf.format.sampleRate) + 32)
        else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        if out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    /// No more audio: everything heard is finalized and delivered before this returns.
    func finish() async {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await reading?.value
    }
}
