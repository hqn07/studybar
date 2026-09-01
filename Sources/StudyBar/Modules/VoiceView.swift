import SwiftUI
import UniformTypeIdentifiers

/// Voice Note: record a memo, transcribe it on-device, save it as a note.
struct VoiceView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var voice = VoiceService()
    @State private var courseID: UUID?
    @AppStorage("voiceLocale") private var voiceLocale = "en-US"
    @AppStorage("voiceEngine") private var voiceEngine = "apple"
    @AppStorage("voiceWhisperModel") private var voiceWhisperModel = "base"
    @AppStorage("voiceWhisperLang") private var voiceWhisperLang = "auto"
    @State private var organizing = false
    @State private var rawBeforeOrganize: String?
    @State private var organizeError: String?
    @State private var draftAvailable = false

    private var idle: Bool { voice.status == .idle }
    private var whisper: Bool { voiceEngine == "whisper" }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Voice Note") {
                HStack(spacing: 8) {
                    if idle {
                        Menu {
                            Picker("Engine", selection: $voiceEngine) {
                                Text("Apple Speech · instant, live").tag("apple")
                                Text("Whisper · higher quality").tag("whisper")
                            }
                            if whisper {
                                Picker("Model", selection: $voiceWhisperModel) {
                                    ForEach(VoiceService.whisperModels, id: \.id) { Text($0.label).tag($0.id) }
                                }
                                Picker("Language", selection: $voiceWhisperLang) {
                                    ForEach(VoiceService.whisperLangs, id: \.id) { Text($0.label).tag($0.id) }
                                }
                                Divider()
                                Button { voice.prepareWhisper() } label: {
                                    Label(voice.whisperReady ? "Model ready" : "Download model now",
                                          systemImage: voice.whisperReady ? "checkmark.circle" : "arrow.down.circle")
                                }.disabled(voice.whisperReady)
                                Button { importAudio() } label: { Label("Transcribe an audio file…", systemImage: "waveform.badge.plus") }
                            }
                        } label: { Image(systemName: whisper ? "cpu" : "waveform") }
                            .help("Transcription engine")
                        if voiceEngine == "apple" {
                            Menu {
                                ForEach(VoiceService.locales, id: \.id) { loc in
                                    Button { voiceLocale = loc.id } label: {
                                        Label(loc.label, systemImage: voiceLocale == loc.id ? "checkmark" : "globe")
                                    }
                                }
                            } label: { Image(systemName: "globe") }.help("Dictation language")
                        }
                    }
                    if !voice.transcript.isEmpty && idle {
                        CoursePicker(courseID: $courseID)
                    }
                }
            } content: {
                VStack(spacing: 16) {
                    switch voice.status {
                    case .denied:
                        deniedState
                    case .unavailable(let msg):
                        EmptyState(symbol: "mic.slash", title: "Can't record", subtitle: msg)
                    case .preparing:
                        preparingState
                    case .transcribing:
                        transcribingState
                    default:
                        recorder
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            }
            .onAppear { updateVocab(); draftAvailable = VoiceService.draftText() != nil }
            .onChange(of: courseID) { _, _ in updateVocab() }
        }
    }

    /// Bias Whisper toward the picked course's vocabulary.
    private func updateVocab() {
        if let c = state.course(courseID) {
            voice.vocabPrompt = "Course: \(c.name)\(c.code.isEmpty ? "" : " (\(c.code))")."
        } else { voice.vocabPrompt = nil }
    }

    private var preparingState: some View {
        VStack(spacing: 14) {
            Image(systemName: "cpu").font(.largeTitle).foregroundStyle(.tint)
            ProgressView(value: voice.prepProgress).frame(width: 240)
            Text("Downloading Whisper \(voiceWhisperModel) model — \(Int(voice.prepProgress * 100))%")
                .font(.callout.weight(.medium))
            Text("One-time download from Apple/Hugging Face; after this it runs fully offline.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcribingState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Transcribing with Whisper (\(voiceWhisperModel))…").font(.callout.weight(.medium))
            Text("Running on-device. Larger models are more accurate but take longer.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var modelName: String {
        VoiceService.whisperModels.first { $0.id == voiceWhisperModel }?.label
            .components(separatedBy: " · ").first ?? voiceWhisperModel
    }

    private var downloadPrompt: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: "arrow.down.circle").font(.largeTitle).foregroundStyle(.tint)
            Text("Whisper \(modelName) model isn't downloaded yet").font(.callout.weight(.medium))
            Button { voice.prepareWhisper() } label: {
                Label("Download now", systemImage: "arrow.down.circle.fill")
            }.buttonStyle(.borderedProminent)
            Text("One-time download; then it runs fully offline. Or switch to Apple Speech (menu) for instant, no-download transcription.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }.padding(.top, DS.Space.l)
    }

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { voice.importFile(url) }
    }

    private var recorder: some View {
        VStack(spacing: 14) {
            if draftAvailable && voice.transcript.isEmpty && idle {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Unsaved transcript recovered").font(.caption.weight(.medium))
                        Text("From an interrupted session — autosaved as you spoke.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: DS.Space.s)
                    Button("Recover") { if let t = VoiceService.draftText() { voice.transcript = t }; draftAvailable = false }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Dismiss") { VoiceService.clearDraft(); draftAvailable = false }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.card))
            }
            Button { voice.toggle() } label: {
                ZStack {
                    Circle().fill(voice.isRecording ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                        .frame(width: 74, height: 74)
                    Image(systemName: voice.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28)).foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain).padding(.top, DS.Space.s)

            Text(voice.isRecording ? "Recording — tap to stop" : "Tap to record")
                .font(.caption).foregroundStyle(.secondary)

            if voice.isRecording {
                LevelMeter(levels: voice.waveform).frame(height: 42).padding(.horizontal, 36)
                Text("Aim the mic at the speaker — the bars move when it's picking up their voice.")
                    .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }

            if !voice.transcript.isEmpty {
                ScrollView {
                    Text(voice.transcript)
                        .font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.sbSurface, in: RoundedRectangle(cornerRadius: 10))
                }
                .frame(maxHeight: 260)

                if !voice.lastEngine.isEmpty {
                    Label("Transcribed by \(voice.lastEngine)",
                          systemImage: voice.lastEngine.hasPrefix("Whisper") ? "cpu" : "waveform")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if let err = organizeError {
                    Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                if organizing {
                    HStack(spacing: DS.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Organizing into notes… your raw transcript is kept.").font(.caption).foregroundStyle(.secondary)
                    }
                } else if idle {
                    HStack(spacing: DS.Space.m) {
                        Button { saveNote() } label: { Label("Save as note", systemImage: "note.text.badge.plus") }
                            .buttonStyle(.borderedProminent)
                        if let raw = rawBeforeOrganize {
                            Button { voice.transcript = raw; rawBeforeOrganize = nil; organizeError = nil } label: {
                                Label("Revert to raw", systemImage: "arrow.uturn.backward")
                            }.buttonStyle(.bordered).help("Undo AI organize — restore the original transcript")
                        } else if AIConfig.isReady {
                            Button { organize() } label: { Label("Organize with AI", systemImage: "sparkles") }
                                .buttonStyle(.bordered)
                                .help("Reshape the raw transcript into structured notes — the original is kept, revertible")
                        }
                        Button("Discard") { voice.transcript = ""; rawBeforeOrganize = nil; organizeError = nil; VoiceService.clearDraft(); draftAvailable = false }
                            .buttonStyle(.bordered)
                    }
                }
            } else if idle {
                if whisper && !voice.whisperReady {
                    downloadPrompt
                } else {
                    if whisper && voice.whisperReady {
                        Label("Whisper \(modelName) ready · offline", systemImage: "checkmark.circle")
                            .font(.caption2).foregroundStyle(.green)
                    }
                    Text(whisper
                         ? "Record a memo or a whole lecture — Whisper transcribes it after you stop. Higher accuracy, fully offline."
                         : "Speak a memo, a thought, or a whole lecture — StudyBar transcribes it live as you talk. Nothing leaves the device.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 420).padding(.top, DS.Space.l)
                }
            }
            Spacer()
        }
    }

    private func organize() {
        let raw = voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, AIConfig.isReady, let provider = AIService.makeProvider() else { return }
        organizeError = nil
        organizing = true
        Task {
            let sys = """
            You are a study assistant. Reorganize the student's own lecture transcript into \
            clean, structured study notes: a short title line, section headings, and concise \
            bullet points capturing the key facts, terms, definitions, dates, and numbers. Be \
            faithful — do NOT add information that isn't in the transcript, don't answer \
            questions or editorialize. Output ONLY the notes as plain markdown — no JSON, no \
            code fences, no preamble.
            """
            let text = try? await provider.complete(system: sys, messages: [AIMessage(role: .user, text: raw)])
            await MainActor.run {
                organizing = false
                let cleaned = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if isPlausibleNotes(cleaned) {
                    rawBeforeOrganize = raw            // keep the original — never lost, revertible
                    voice.transcript = cleaned
                } else {
                    // The model returned junk (e.g. a JSON blob). Leave the transcript ALONE.
                    organizeError = "The AI returned an unusable result — your transcript is unchanged. A stronger engine (Settings ▸ Intelligence) organizes far better than the local model."
                }
            }
        }
    }

    /// Guard against a broken model reply overwriting good text — must be substantial and
    /// not an obvious JSON/garbage blob.
    private func isPlausibleNotes(_ s: String) -> Bool {
        guard s.count >= 24 else { return false }
        if s.first == "{" && s.last == "}" { return false }
        if s.first == "[" && s.last == "]" { return false }
        return true
    }

    private var deniedState: some View {
        VStack(spacing: 12) {
            EmptyState(symbol: "mic.slash", title: "Microphone or speech access off",
                       subtitle: "Allow StudyBar under System Settings ▸ Privacy & Security ▸ Microphone and Speech Recognition.")
            Button("Open Privacy Settings") {
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(u)
                }
            }.buttonStyle(.borderedProminent)
        }
    }

    private func saveNote() {
        let text = voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let title = "Voice note \(Date().dayMonth)"
        state.data.notes.append(Note(title: title, body: text, courseID: courseID))
        voice.transcript = ""
        rawBeforeOrganize = nil
        VoiceService.clearDraft(); draftAvailable = false     // saved for real — clear the crash-safe draft
        state.selectedModuleID = "notes"
    }
}

/// Live input-level meter: centered bars whose height tracks recent loudness. Gray = quiet,
/// green = good level, red = near clipping. Lets the user confirm the mic is catching the
/// speaker (not silence, not overload).
struct LevelMeter: View {
    let levels: [Float]
    var body: some View {
        GeometryReader { geo in
            let n = max(1, levels.count)
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<levels.count, id: \.self) { i in
                    let lv = CGFloat(max(0.02, levels[i]))
                    Capsule()
                        .fill(color(levels[i]))
                        .frame(height: lv * geo.size.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.linear(duration: 0.05), value: levels)
            .accessibilityHidden(true)
            .id(n)
        }
    }
    private func color(_ l: Float) -> Color {
        l > 0.85 ? .red : (l > 0.14 ? .green : Color.secondary.opacity(0.35))
    }
}
