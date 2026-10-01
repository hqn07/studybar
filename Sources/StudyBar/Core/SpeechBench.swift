import AVFoundation
import Speech

/// Dev hook: `StudyBar --stt-bench <audio> <reference.txt> [--noise <dB SNR>]` puts the same audio
/// through Apple Speech the way Voice uses it today (SFSpeechRecognizer, on-device, punctuated)
/// and through SpeechAnalyzer (macOS 26), and scores each by word error rate against the text the
/// audio was made from. Whether Voice should switch is decided by this, not by the announcement.
enum SpeechBench {
    @MainActor
    static func run(_ args: [String]) async -> Int32 {
        guard let i = args.firstIndex(of: "--stt-bench"), i + 2 < args.count,
              let ref = try? String(contentsOfFile: args[i + 2], encoding: .utf8) else { print("usage: --stt-bench <audio> <ref.txt>"); return 1 }
        var audio = URL(fileURLWithPath: args[i + 1])
        if let n = args.firstIndex(of: "--noise").flatMap({ Double(args[$0 + 1]) }) {
            guard let noisy = withNoise(audio, snr: n) else { print("couldn't add noise"); return 1 }
            audio = noisy
            print("noise: \(n) dB SNR")
        }
        let locale = Locale(identifier: "en-US")
        print("speech recognition permission: \(SFSpeechRecognizer.authorizationStatus().rawValue) (3 = granted)")

        var t0 = Date()
        let a = await appleSpeech(audio, locale: locale)
        print(String(format: "Apple Speech    WER %.1f%%  %.0fs  %d words", wer(ref, a) * 100, Date().timeIntervalSince(t0), words(a).count))

        if #available(macOS 26.0, *) {
            t0 = Date()
            do {
                let b = try await analyzer(audio, locale: locale)
                print(String(format: "SpeechAnalyzer  WER %.1f%%  %.0fs  %d words", wer(ref, b) * 100, Date().timeIntervalSince(t0), words(b).count))
                if args.contains("--show") { print("--- Apple Speech ---\n\(a)\n--- SpeechAnalyzer ---\n\(b)") }
                t0 = Date()
                let (c, timeline, volatile) = try await live(audio, locale: locale)
                let times = timeline.lines.map(\.t)
                let duration = (try? AVAudioFile(forReading: audio)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
                print(String(format: "Live, as Voice  WER %.1f%%  %.0fs  %d words · %d interim updates · %d timed sentences, in order: %@, within the audio: %@",
                             wer(ref, c) * 100, Date().timeIntervalSince(t0), words(c).count, volatile, times.count,
                             times == times.sorted() ? "yes" : "no", (times.last ?? 0) <= duration ? "yes" : "no"))
            } catch { print("SpeechAnalyzer: \(error.localizedDescription)") }
        }
        return 0
    }

    /// In 50-second pieces, as Voice feeds it live: given a whole file it stops after about a minute.
    static func appleSpeech(_ url: URL, locale: Locale) async -> String {
        guard let f = try? AVAudioFile(forReading: url) else { return "" }
        let piece = AVAudioFrameCount(f.processingFormat.sampleRate * 50)
        var out: [String] = [], n = 0
        while f.framePosition < f.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: piece),
                  (try? f.read(into: buf, frameCount: piece)) != nil, buf.frameLength > 0 else { break }
            let part = FileManager.default.temporaryDirectory.appendingPathComponent("stt-\(n).caf")
            n += 1
            guard let w = try? AVAudioFile(forWriting: part, settings: buf.format.settings), (try? w.write(from: buf)) != nil else { break }
            out.append(await appleSpeechPiece(part, locale: locale))
            try? FileManager.default.removeItem(at: part)
        }
        return out.joined(separator: " ")
    }

    static func appleSpeechPiece(_ url: URL, locale: Locale) async -> String {
        guard let rec = SFSpeechRecognizer(locale: locale) else { return "" }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.addsPunctuation = true
        req.shouldReportPartialResults = false
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        return await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            var done = false
            rec.recognitionTask(with: req) { r, e in
                guard !done else { return }
                if let r, r.isFinal { done = true; c.resume(returning: r.bestTranscription.formattedString) }
                else if let e { done = true; print("Apple Speech: \(e.localizedDescription)"); c.resume(returning: "") }
            }
        }
    }

    @available(macOS 26.0, *)
    static func analyzer(_ url: URL, locale: Locale) async throws -> String {
        let t = SpeechTranscriber(locale: locale, preset: .transcription)
        var status = await AssetInventory.status(forModules: [t])
        print("SpeechAnalyzer model: \(status)")
        // `--install`: Apple's model for the language, downloaded and installed by macOS.
        if status < .installed, CommandLine.arguments.contains("--install") {
            let reserved = try await AssetInventory.reserve(locale: locale)
            print("reserved \(locale.identifier): \(reserved); supported: \(await SpeechTranscriber.supportedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) })")
        }
        if status < .installed, CommandLine.arguments.contains("--install"),
           let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            let started = Date()
            let watch = Task { while !Task.isCancelled { print(String(format: "  downloading %.0f%%", request.progress.fractionCompleted * 100)); try? await Task.sleep(nanoseconds: 5_000_000_000) } }
            try await request.downloadAndInstall()
            watch.cancel()
            status = await AssetInventory.status(forModules: [t])
            print("SpeechAnalyzer model: \(status), in \(Int(Date().timeIntervalSince(started)))s")
        }
        if status < .installed { print("not reported installed — trying anyway") }
        let file = try AVAudioFile(forReading: url)
        let collect = Task { () throws -> String in
            var s = ""
            for try await r in t.results { s += String(r.text.characters) }
            return s
        }
        _ = try await SpeechAnalyzer(inputAudioFile: file, modules: [t], finishAfterFile: true)
        return try await collect.value
    }

    /// The file fed to LiveTranscriber in 1,024-frame buffers, the way the mic tap feeds it, and
    /// the transcript and timeline assembled as Voice assembles them.
    @available(macOS 26.0, *)
    @MainActor
    static func live(_ url: URL, locale: Locale) async throws -> (String, LectureTimeline, Int) {
        let made = Date()
        guard let lt = await LiveTranscriber.make(locale: locale, vocabulary: ["Gauss", "epsilon naught"]) else { throw CocoaError(.featureUnsupported) }
        print(String(format: "ready to listen in %.2fs", Date().timeIntervalSince(made)))
        var committed = "", timeline = LectureTimeline(), volatile = 0
        try await lt.start { p in
            if p.final { committed += (committed.isEmpty ? "" : " ") + p.text; timeline.add(p.text, from: p.start, to: p.end, words: p.words) }
            else { volatile += 1 }
        }
        let f = try AVAudioFile(forReading: url)
        while f.framePosition < f.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 1024),
                  (try? f.read(into: buf, frameCount: 1024)) != nil, buf.frameLength > 0 else { break }
            lt.append(buf)
        }
        await lt.finish()
        return (committed, timeline, volatile)
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    /// Word-level edit distance over the reference's length.
    static func wer(_ ref: String, _ hyp: String) -> Double {
        let r = words(ref), h = words(hyp)
        guard !r.isEmpty else { return 0 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }

    /// The audio with white noise at `snr` dB below it, as a WAV beside it — a hall, not a booth.
    static func withNoise(_ url: URL, snr: Double) -> URL? {
        guard let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength)
        var power = 0.0
        for k in 0..<n { power += Double(ch[0][k] * ch[0][k]) }
        let sigma = Float((power / Double(max(n, 1)) / pow(10, snr / 10)).squareRoot())
        for c in 0..<Int(buf.format.channelCount) {
            for k in 0..<n {   // Box–Muller
                let u1 = Float.random(in: 1e-7..<1), u2 = Float.random(in: 0..<1)
                ch[c][k] += sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
            }
        }
        let out = url.deletingPathExtension().appendingPathExtension("noisy.wav")
        guard let w = try? AVAudioFile(forWriting: out, settings: buf.format.settings), (try? w.write(from: buf)) != nil else { return nil }
        return out
    }
}
