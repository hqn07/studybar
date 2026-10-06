import SwiftUI
import UniformTypeIdentifiers

/// Voice Note: record a memo, transcribe it on-device, save it as a note.
///
/// A two-line shell around `VoiceBody` so the recorder can be observed directly. The live
/// transcript and the ~30 Hz meter used to reach this view by way of `AppState` forwarding
/// every `VoiceService` change, which re-rendered every other module along with it — see
/// `RecordingBar`. `AppState` now forwards only the coarse recording state.
struct VoiceView: View {
    @EnvironmentObject var state: AppState
    var body: some View { VoiceBody(voice: state.voice) }
}

struct VoiceBody: View {
    @EnvironmentObject var state: AppState
    /// The recorder lives on AppState (app-lifetime) so recording survives leaving this
    /// module — this view just observes and drives it.
    @ObservedObject var voice: VoiceService
    @State private var courseID: UUID?
    @AppStorage("voiceLocale") private var voiceLocale = "en-US"
    @AppStorage("voiceEngine") private var voiceEngine = "apple"
    @AppStorage("voiceSource") private var voiceSource = "mic"
    @AppStorage("voiceWhisperModel") private var voiceWhisperModel = "base"
    @AppStorage("voiceWhisperLang") private var voiceWhisperLang = "auto"
    /// True while the model is being asked which course this belongs to.
    @State private var naming = false
    @State private var addingSlides = false
    @State private var draftAvailable = false
    /// What a new take or an imported file would replace, waiting for the student's word.
    @State private var replacing: Replace?
    /// "Make study notes" asks how first: detail, shape, how much filled in, a focus.
    @State private var choosingStyle = false
    @State private var notesFocus = ""
    @State private var confirmDiscard = false
    enum Replace: Identifiable {
        case record, transcribe(URL)
        var id: String { if case .transcribe(let u) = self { return u.path }; return "record" }
        var verb: String { if case .record = self { return "Record" }; return "Transcribe" }
    }

    /// Not recording or working: what's there can be saved, discarded or replaced. A take that
    /// ended in an error counts — its transcript is still worth keeping.
    private var idle: Bool { switch voice.status { case .idle, .unavailable: true; default: false } }
    private var problem: String? { if case .unavailable(let m) = voice.status { return m }; return voice.notice }
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
                            Picker("Listen to", selection: $voiceSource) {
                                Text("Microphone").tag("mic")
                                Text("The Mac's sound · Zoom, Teams, videos").tag("system")
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
                                    Label(voice.isModelDownloaded(voiceWhisperModel) ? "Model downloaded" : "Download model now",
                                          systemImage: voice.isModelDownloaded(voiceWhisperModel) ? "checkmark.circle" : "arrow.down.circle")
                                }.disabled(voice.isModelDownloaded(voiceWhisperModel))
                                Button { importAudio() } label: { Label("Transcribe an audio or video file…", systemImage: "waveform.badge.plus") }
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
                    // With nothing recorded, the error is the screen; with a transcript or audio,
                    // it's a line above them, so they can still be saved.
                    case .unavailable(let msg) where !voice.hasUnsaved:
                        VStack(spacing: 12) {
                            EmptyState(symbol: "mic.slash", title: "Can't record", subtitle: msg)
                            HStack(spacing: 8) {
                                Button("Open Privacy Settings") {
                                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                        NSWorkspace.shared.open(u)
                                    }
                                }.buttonStyle(.borderedProminent)
                                Button("Try again") { voice.toggle() }.buttonStyle(.bordered)
                            }
                        }
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
            // Permission is granted outside the app, so coming back to this module is the
            // moment to stop believing a remembered "denied".
            .onAppear { voice.clearDenied(); updateVocab(); draftAvailable = VoiceService.hasDraft }
            .onChange(of: courseID) { _, _ in updateVocab() }
            .confirmationDialog(replacing?.verb == "Record" ? "Start a new recording?" : "Transcribe a new file?",
                                isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
                                titleVisibility: .visible, presenting: replacing) { r in
                Button("Save as Note, Then \(r.verb)") { saveNote(open: false) { run(r) } }
                Button("Discard and \(r.verb)", role: .destructive) { discard(); run(r) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The transcript and recording you have now aren't saved as a note. Save them first, or discard them — a discarded recording goes to the Trash.")
            }
            .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Move to Trash", role: .destructive) { discard() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The transcript and its audio go to the Trash, where you can still put them back.")
            }
        }
    }

    /// Bias recognition toward the course's vocabulary: the picked course, else the one in
    /// session now. Its name for Whisper; its terms for Apple Speech.
    private func updateVocab() {
        if let c = state.course(courseID ?? state.courseID(at: .now)) {
            voice.vocabPrompt = "Course: \(c.name)\(c.code.isEmpty ? "" : " (\(c.code))")."
            voice.vocabulary = CourseVocabulary.terms(course: c, notes: state.data.notes)
        } else { voice.vocabPrompt = nil; voice.vocabulary = [] }
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
        VStack(spacing: 16) {
            TranscribingBars()
            HStack(spacing: 2) {
                Text("Transcribing with Whisper (\(voiceWhisperModel))").font(.callout.weight(.semibold))
                AnimatedEllipsis()
            }
            if voice.transcript.isEmpty {
                Text("Running on-device. Larger models are more accurate but take longer.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                // The decode callback streams text as it goes — show it so it never looks stuck.
                ScrollView {
                    Text(voice.transcript)
                        .font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(.sbSurface, in: RoundedRectangle(cornerRadius: 10))
                }
                .frame(maxHeight: 260)
                Text("Text appears as it decodes — the whole take is transcribed for accuracy.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(16)
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
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if voice.hasUnsaved { replacing = .transcribe(url) } else { transcribe(url) }
    }

    /// Record, or transcribe a file — asking first when either would replace unsaved work.
    private func record() { if voice.hasUnsaved { replacing = .record } else { voice.start() } }
    private func run(_ r: Replace) {
        switch r {
        case .record: voice.start()
        case .transcribe(let u): transcribe(u)
        }
    }
    private func discard() {
        voice.discardTake(); voice.slides = nil; voice.rawBeforeOrganize = nil; voice.organizeError = nil
        voice.notice = nil; voice.clearDenied(); draftAvailable = false
        if case .unavailable = voice.status { voice.status = .idle }
    }

    private func transcribe(_ url: URL) {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true else { voice.importFile(url); return }
        // A lecture video: transcribe its sound track. If that can't be pulled out, Whisper
        // gets the file itself and says what it makes of it.
        let m4a = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        Task {
            let ok = (try? await Converter.exportMedia(url, to: .audioOnly, out: m4a)) != nil
            voice.importFile(ok ? m4a : url)
        }
    }

    private var recorder: some View {
        VStack(spacing: 14) {
            if draftAvailable && !voice.hasUnsaved && idle {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("An unsaved recording was recovered").font(.caption.weight(.medium))
                        Text("From a session that ended unexpectedly — its transcript and audio were saved as you went.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: DS.Space.s)
                    Button("Recover") { Task { await voice.recover(); draftAvailable = false } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Move to Trash") { VoiceService.trashDraft(); draftAvailable = false }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.card))
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
            }

            // Three plain controls: Record (or Resume), Pause, Stop. Pausing keeps the take open —
            // Resume carries on in the same recording and the same transcript.
            HStack(spacing: 22) {
                Button { primary() } label: {
                    ZStack {
                        Circle().fill(voice.isRecording ? AnyShapeStyle(.orange) : voice.isPaused ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                            .frame(width: 74, height: 74)
                        Image(systemName: voice.isRecording ? "pause.fill" : "mic.fill")
                            .font(.system(size: 28)).foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .help(voice.isRecording ? "Pause — for a break; Resume carries on in the same recording" : voice.isPaused ? "Resume recording" : "Record")
                .accessibilityLabel(voice.isRecording ? "Pause" : voice.isPaused ? "Resume" : "Record")
                if voice.isActive {
                    Button { voice.userStop() } label: {
                        ZStack {
                            Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 1.5).frame(width: 54, height: 54)
                            Image(systemName: "stop.fill").font(.system(size: 20)).foregroundStyle(.red)
                        }
                    }
                    .buttonStyle(.plain).help("Stop — end the recording, then save it as a note").accessibilityLabel("Stop")
                }
            }
            .padding(.top, DS.Space.s)

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(caption).font(.caption.monospacedDigit()).foregroundStyle(voice.isPaused ? .orange : .secondary)
                    .multilineTextAlignment(.center)
            }

            if voice.isRecording {
                LevelMeter(meter: voice.meter).frame(height: 42).padding(.horizontal, 36)
                Text("Aim the mic at the speaker — the bars move when it's picking up their voice.")
                    .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                if voice.soFar.isEmpty, voice.lastEngine == "Apple Speech", LiveSummary.hosted(AIConfig.engine(for: .transcript)) {
                    Text("A few points on what's been said appear here every few minutes.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            slidesRow

            if !voice.soFar.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("So far", systemImage: "text.badge.checkmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(voice.soFar) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.minutes).font(.caption2).foregroundStyle(.tertiary)
                            RichText(text: s.points.map { "- " + $0 }.joined(separator: "\n"))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(.sbSurface, in: RoundedRectangle(cornerRadius: 10))
            }

            // An audio-only take (it stopped before any words were transcribed) can be saved too.
            if !voice.transcript.isEmpty || (idle && voice.hasUnsaved) {
                ScrollView {
                    Group {
                        // Study notes read as notes — headings, bold, math — not as their Markdown.
                        if voice.rawBeforeOrganize != nil, idle { RichText(text: voice.transcript) }
                        else { Text(voice.transcript.isEmpty ? "No words were transcribed before it stopped — the audio is kept." : voice.transcript).font(.callout) }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.sbSurface, in: RoundedRectangle(cornerRadius: 10))
                }
                .frame(maxHeight: voice.rawBeforeOrganize == nil ? 260 : 380)

                if !voice.lastEngine.isEmpty {
                    Label("Transcribed by \(voice.lastEngine)",
                          systemImage: voice.lastEngine.hasPrefix("Whisper") ? "cpu" : "waveform")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if let err = voice.organizeError {
                    Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                if voice.organizing {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        HStack(spacing: DS.Space.s) {
                            ProgressView().controlSize(.small)
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                let secs = max(0, Int(Date().timeIntervalSince(voice.organizeStart ?? Date())))
                                Text("Writing notes\(voice.organizePart.1 > 1 ? " — part \(voice.organizePart.0) of \(voice.organizePart.1)" : "")… \(secs)s · your raw transcript is kept")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !voice.organizeStream.isEmpty {
                            ScrollView {
                                Text(voice.organizeStream)
                                    .font(.callout).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .frame(maxHeight: 200)
                            .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if idle {
                    HStack(spacing: DS.Space.m) {
                        Button { saveNote() } label: {
                            Label(naming ? "Saving…" : "Save as note", systemImage: "note.text.badge.plus")
                        }
                        .disabled(naming)
                            .buttonStyle(.borderedProminent)
                        if AIConfig.isReady {
                            Button { choosingStyle = true } label: {
                                Label(voice.rawBeforeOrganize == nil ? "Make study notes…" : "Rewrite…", systemImage: "sparkles")
                            }
                            .buttonStyle(.bordered)
                            .help(voice.rawBeforeOrganize == nil
                                  ? "Turn the lecture into study notes — choose how detailed, what shape, and how much the AI fills in. The transcript is kept."
                                  : "Write the notes again from the original transcript, another way")
                            .popover(isPresented: $choosingStyle, arrowEdge: .bottom) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(voice.rawBeforeOrganize == nil ? "Study notes from this lecture" : "Write the notes again").font(.headline)
                                    NotesStyleForm(focus: $notesFocus)
                                    HStack {
                                        Spacer()
                                        Button("Cancel") { choosingStyle = false }
                                        Button("Write notes") { choosingStyle = false; organize() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                                    }
                                }.padding(16).frame(width: 520)
                            }
                        }
                        if let raw = voice.rawBeforeOrganize {
                            Button { voice.transcript = raw; voice.rawBeforeOrganize = nil; voice.organizeError = nil } label: {
                                Label("Revert to raw", systemImage: "arrow.uturn.backward")
                            }.buttonStyle(.bordered).help("Undo AI organize — restore the original transcript")
                        }
                        Button("Discard") { confirmDiscard = true }
                            .buttonStyle(.bordered)
                    }
                }
            } else if idle {
                if whisper && !voice.isModelDownloaded(voiceWhisperModel) {
                    downloadPrompt
                } else {
                    if whisper && voice.isModelDownloaded(voiceWhisperModel) {
                        Label("Whisper \(modelName) ready · offline", systemImage: "checkmark.circle")
                            .font(.caption2).foregroundStyle(.green)
                    }
                    Text(voiceSource == "system"
                         ? "Records what the Mac is playing — a Zoom or Teams lecture, a video — without the mic. Start it, then press record. The first time, macOS asks to let StudyBar record the screen and its sound."
                         : whisper
                         ? "Record a memo or a whole lecture — Whisper transcribes it after you stop. Higher accuracy, fully offline."
                         : "Speak a memo, a thought, or a whole lecture — StudyBar transcribes it live as you talk. Nothing leaves the device.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 420).padding(.top, DS.Space.l)
                }
            }
            Spacer()
        }
    }

    /// The deck the lecture is given from: the notes follow it, and it sits beside the note.
    @ViewBuilder private var slidesRow: some View {
        if let deck = voice.slides {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle")
                Text("Slides: \(deck.name)").lineLimit(1).truncationMode(.middle)
                Button { voice.slides = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                    .accessibilityLabel("Remove the slides")
            }
            .font(.caption).padding(.horizontal, 10).padding(.vertical, 4)
            .background(.sbSurface, in: Capsule())
        } else if addingSlides {
            ProgressView().controlSize(.small)
        } else {
            Button { pickSlides() } label: { Label("Add the lecture's slides…", systemImage: "rectangle.on.rectangle") }
                .buttonStyle(.borderless).font(.caption)
                .help("A PDF or PowerPoint of the slides: study notes then follow them slide by slide, and the note keeps them beside it")
        }
    }

    private func pickSlides() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["pdf", "pptx"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let course = courseID ?? state.courseID(at: voice.lastRecordingStart ?? .now)
        addingSlides = true
        Task {
            let file = await Task.detached { StudyMaterial.attach(url, courseID: course) }.value
            addingSlides = false
            guard let file else { return }
            state.data.studyFiles = (state.data.studyFiles ?? []) + [file]
            voice.slides = file
        }
    }

    private func organize() {
        // A rewrite starts from the transcript as it was said, not from the last notes.
        let raw = (voice.rawBeforeOrganize ?? voice.transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        let style = NotesStyleForm.style(focus: notesFocus)
        guard !raw.isEmpty, AIConfig.isReady, let provider = AIService.makeProvider(for: .transcript) else { return }
        voice.organizeError = nil; voice.organizeStream = ""; voice.organizeStart = Date(); voice.organizePart = (1, 1)
        voice.organizing = true
        let job = Jobs.shared.begin("Study notes from the recording", module: "voice")
        Task {
            // Detailed notes plus marked additions, part by part when the lecture is longer
            // than the engine can read at once — see LectureNotes.
            let course = courseID ?? state.courseID(at: voice.lastRecordingStart ?? .now)
            let text = await LectureNotes.run(voice.timeline.marking(raw), job: .lecture, provider: provider,
                                              mode: AIConfig.engine(for: .transcript),
                                              material: StudyMaterial.coursePassages(course, in: state.data),
                                              slides: voice.slides.map(StudyMaterial.slideOutline) ?? [], style: style) { notes, part, total in
                voice.organizeStream = notes; voice.organizePart = (part, total)
                if total > 1 { Jobs.shared.update(job, "part \(part) of \(total)") }
            }
            await MainActor.run {
                voice.organizing = false; voice.organizeStream = ""
                // Same reason as the Notes AI card: the system prompt above already asks for
                // `$…$` and the model still returns `\[…\]`, so normalize deterministically.
                // `NoteFormat.tidy` is the same bargain for list shape — the rules above ask
                // for a lead-in that isn't a bullet, and this is what happens when they don't
                // hold and a label lands as a sibling of the points it introduces.
                let cleaned = NoteFormat.tidy(
                    MathSupport.normalized((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
                Jobs.shared.end(job, done: isPlausibleNotes(cleaned) ? "Study notes ready" : "Couldn't write the study notes")
                if isPlausibleNotes(cleaned) {
                    voice.rawBeforeOrganize = raw            // keep the original — never lost, revertible
                    voice.transcript = cleaned
                } else {
                    // The model returned junk (e.g. a JSON blob) or a part failed. Leave the transcript ALONE.
                    voice.organizeError = "The AI returned an unusable result — your transcript is unchanged. A stronger engine (Settings ▸ Intelligence) organizes far better than the local model."
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
                       subtitle: "Allow StudyBar under System Settings ▸ Privacy & Security ▸ Microphone and Speech Recognition, then try again.")
            HStack(spacing: 8) {
                Button("Open Privacy Settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(u)
                    }
                }.buttonStyle(.borderedProminent)
                // Without this the screen is a dead end: granting access elsewhere leaves the
                // module showing it, and since nothing here calls `start()`, macOS is never
                // asked again and no prompt ever appears. The `.unavailable` state above has
                // always had this button; this one was missing it.
                Button("Try again") { voice.clearDenied(); voice.toggle() }.buttonStyle(.bordered)
            }
            Text("A rebuilt copy of StudyBar counts as a new app to macOS, so access granted to an earlier build doesn't carry over.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    /// Save the transcript as a note, named and filed the way this course's notes already are.
    ///
    /// "Voice note Sep 15" told you nothing and sorted next to nothing. The course comes from
    /// the timetable at the moment you pressed record — a fact, not a guess — and only when
    /// nothing was in session does the model get asked to place it. The title is then written
    /// in whatever convention that course's existing notes follow (see NoteTitleConvention),
    /// which differs per course and is read rather than imposed. `open` goes to the note after;
    /// `then` runs once it's saved (a new take, from the "Start a new recording?" question).
    private func saveNote(open: Bool = true, then next: (() -> Void)? = nil) {
        let words = voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty || voice.takeURL != nil, !naming else { return }
        let text = words.isEmpty ? "Recording — no transcript." : words
        naming = true
        Task {
            await voice.takeReady()              // the recording, finished as an M4A, goes with it
            // An explicit pick wins; then the schedule; then, if there is anything to go on, AI.
            var course = courseID ?? state.courseID(at: voice.lastRecordingStart ?? .now)
            if course == nil, AIConfig.isReady(for: .judge), let provider = AIService.makeProvider(for: .judge), !state.data.courses.isEmpty {
                let codes = state.data.courses.map { c in (id: c.id, code: c.code.isEmpty ? c.name : c.code) }
                let reply = (try? await provider.completePlain(
                    system: CourseGuess.system(codes: codes.map(\.code)),
                    messages: [AIMessage(role: .user, text: String(text.prefix(CourseGuess.sampleChars)))])) ?? ""
                course = CourseGuess.match(reply, courses: codes)
            }
            naming = false
            finishSave(text: text, course: course, open: open)
            next?()
        }
    }

    private var caption: String {
        let t = Int(voice.elapsed), clock = String(format: "%d:%02d", t / 60, t % 60)
        switch voice.status {
        case .recording: return "Recording · \(clock) — pause for a break, stop when you're done"
        case .paused: return "Paused at \(clock) — the transcript is kept. Resume carries on in the same recording."
        default: return voice.hasUnsaved ? "Record again to start a new recording" : "Tap to record"
        }
    }

    private func primary() {
        switch voice.status {
        case .recording: voice.pause()
        case .paused: voice.resume()
        default: record()
        }
    }

    private func finishSave(text: String, course: UUID?, open: Bool = true) {
        let code = state.course(course).map { $0.code.isEmpty ? $0.name : $0.code }
        let siblings = state.data.notes.filter { $0.courseID == course }.map(\.title)
        let shape = NoteTitleConvention.detect(titles: siblings, courseCode: code)
        let title = NoteTitleConvention.title(topic: NoteTitleConvention.topic(fromNoteBody: text),
                                              shape: shape, existing: siblings,
                                              date: voice.lastRecordingStart ?? .now,
                                              termStart: state.data.termStart)
        var note = Note(title: title, body: text, courseID: course)
        note.audioPath = voice.claimTake(for: note.id)
        if let deck = voice.slides {
            note.slidesID = deck.id
            // Added before the class was known: it belongs to the note's course.
            if let i = state.data.studyFiles?.firstIndex(where: { $0.id == deck.id }), state.data.studyFiles?[i].courseID == nil {
                state.data.studyFiles?[i].courseID = course
            }
            voice.slides = nil
        }
        note.updatedAt = .now
        state.data.notes.append(note)
        voice.transcript = ""
        voice.rawBeforeOrganize = nil
        voice.notice = nil
        if case .unavailable = voice.status { voice.status = .idle }
        VoiceService.clearDraft(); draftAvailable = false     // saved for real — clear the crash-safe draft
        guard open else { return }
        // Open it with the title selected: a generated name should be one keystroke from
        // being the name you wanted.
        state.pendingOpenNote = note.id
        state.pendingTitleFocus = true
        if note.audioPath != nil { state.justSavedLecture = note.id }   // the note offers what to do next
        state.selectedModuleID = "notes"
    }
}

/// Animated equalizer bars — a clear "working" effect while Whisper decodes (there's no
/// reliable progress %, so motion is the signal). Driven by TimelineView(.animation).
struct TranscribingBars: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<7, id: \.self) { i in
                    let h = 10 + 26 * (0.5 + 0.5 * sin(t * 5.5 + Double(i) * 0.65))
                    Capsule().fill(.tint).frame(width: 6, height: h)
                }
            }
            .frame(height: 40)
        }
        .accessibilityLabel("Transcribing")
    }
}

/// A trailing "…" that fills in one dot at a time.
struct AnimatedEllipsis: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { ctx in
            let n = Int(ctx.date.timeIntervalSinceReferenceDate / 0.4) % 4
            Text(String(repeating: ".", count: n) + String(repeating: " ", count: 3 - n))
                .font(.callout.weight(.semibold)).monospaced()
        }
    }
}

/// Live input-level meter: centered bars whose height tracks recent loudness. Gray = quiet,
/// green = good level, red = near clipping. Lets the user confirm the mic is catching the
/// speaker (not silence, not overload).
/// The mic level, drawn rather than built out of views.
///
/// It was 48 `Capsule` views in an `HStack` with an implicit animation over the whole array,
/// rebuilt on every meter tick — about thirty times a second, and 48 bars across the 44pt
/// recording bar is half a point each, which nobody can see. One `Canvas` pass costs no view
/// identity, no diff and no layout, and the bar count follows the width it actually has.
struct LevelMeter: View {
    @ObservedObject var meter: VoiceMeter

    var body: some View {
        let levels = meter.levels
        Canvas { ctx, size in
            guard !levels.isEmpty, size.width > 0, size.height > 0 else { return }
            let spacing: CGFloat = 2
            let bars = max(1, min(levels.count, Int((size.width + spacing) / (1 + spacing))))
            let width = (size.width - spacing * CGFloat(bars - 1)) / CGFloat(bars)
            // Newest samples are at the end, so group from the end and keep the loudest of
            // each group — a peak that lands in a dropped sample shouldn't vanish.
            let per = Double(levels.count) / Double(bars)
            for i in 0..<bars {
                let lo = Int(Double(i) * per)
                let hi = max(lo + 1, Int(Double(i + 1) * per))
                let level = levels[lo..<min(hi, levels.count)].max() ?? 0
                let h = max(1, CGFloat(max(0.02, level)) * size.height)
                let rect = CGRect(x: CGFloat(i) * (width + spacing), y: (size.height - h) / 2,
                                  width: width, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: min(width, h) / 2), with: .color(color(level)))
            }
        }
        .accessibilityHidden(true)
    }

    private func color(_ l: Float) -> Color {
        l > 0.85 ? .red : (l > 0.14 ? .green : Color.primary.opacity(0.28))
    }
}
