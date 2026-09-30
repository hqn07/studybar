import SwiftUI
import UniformTypeIdentifiers

/// The study assistant, one course at a time: tick what to study from — notes, slides, the
/// textbook PDF, the syllabus, anything dropped in — then ask the tutor, take a quiz, sit a
/// practice exam, or have a study guide written. Everything the AI says is drawn from the
/// ticked material first, with its source named.
struct StudyModuleView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("studyCourse") private var courseRaw = ""
    @State private var excluded: Set<StudySource> = []
    @State private var tab: Tab = .tutor
    @State private var reading: [String] = []            // files being read in
    @State private var dropTargeted = false

    enum Tab: String, CaseIterable, Identifiable {
        case tutor = "Tutor", quiz = "Quiz", exam = "Practice exam", guide = "Study guide"
        var id: String { rawValue }
    }

    private var course: Course? {
        state.data.courses.first { $0.id.uuidString == courseRaw } ?? state.data.courses.first
    }
    private var sources: [(source: StudySource, title: String, detail: String)] {
        StudyMaterial.sources(course: course?.id, in: state.data)
    }
    private var selected: [StudySource] { sources.map(\.source).filter { !excluded.contains($0) } }

    /// The ticked material as passages, read when a tool asks for it.
    private func material() -> [StudyPassage] { selected.flatMap { StudyMaterial.passages($0, in: state.data) } }

    var body: some View {
        ModulePane(title: "Study") {
            if !state.data.courses.isEmpty {
                Picker("", selection: Binding(get: { course?.id.uuidString ?? "" },
                                              set: { courseRaw = $0; excluded = [] })) {
                    ForEach(state.data.courses) { c in Text(c.code.isEmpty ? c.name : "\(c.code) — \(c.name)").tag(c.id.uuidString) }
                }.labelsHidden().fixedSize()
            }
        } content: {
            if state.data.courses.isEmpty {
                EmptyState(symbol: "graduationcap", title: "Add a course to study",
                           subtitle: "Study works from a course's notes, slides, textbook and syllabus.")
            } else {
                HStack(spacing: 0) {
                    sourceColumn.frame(width: 250)
                    Divider()
                    VStack(spacing: 0) {
                        Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().padding(10)
                        Divider()
                        if !AIConfig.isReady(for: .ask) {
                            EmptyState(symbol: "sparkles", title: "Pick an AI engine",
                                       subtitle: "Settings ▸ Intelligence — on-device, Ollama, or your own Claude / OpenAI key.")
                        } else {
                            // All four stay alive, so a quiz in progress survives a look at the tutor.
                            ZStack {
                                TutorPane(course: course, material: material).opacity(tab == .tutor ? 1 : 0).allowsHitTesting(tab == .tutor)
                                QuizPane(exam: false, course: course, material: material).opacity(tab == .quiz ? 1 : 0).allowsHitTesting(tab == .quiz)
                                QuizPane(exam: true, course: course, material: material).opacity(tab == .exam ? 1 : 0).allowsHitTesting(tab == .exam)
                                GuidePane(course: course, material: material).opacity(tab == .guide ? 1 : 0).allowsHitTesting(tab == .guide)
                            }
                        }
                    }
                    .id(course?.id)                   // a new course starts every pane over
                }
                .studyFocus(course.map { .course($0.id) })
            }
        }
    }

    // MARK: Sources

    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader(title: "Sources", count: selected.count)
                Spacer()
                Button(excluded.isEmpty ? "None" : "All") {
                    excluded = excluded.isEmpty ? Set(sources.map(\.source)) : []
                }.buttonStyle(.borderless).font(.caption)
            }.padding(.horizontal, 10).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sources, id: \.source) { s in sourceRow(s) }
                    ForEach(reading, id: \.self) { name in
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Reading \(name)…").font(.caption).lineLimit(1) }
                            .padding(.horizontal, 10).padding(.vertical, 4)
                    }
                    if sources.isEmpty && reading.isEmpty {
                        Text("No notes, files or syllabus for this course yet. Add slides, handouts or a textbook below.")
                            .font(.caption).foregroundStyle(.secondary).padding(10)
                    }
                }.padding(.vertical, 4)
            }
            Divider()
            Button { pickFiles() } label: { Label("Add files…", systemImage: "plus") }
                .buttonStyle(.borderless).padding(10)
                .help("Slides (.pptx), PDFs, Word documents, text, or photos of handouts")
        }
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in add([url]) } }
                }
            }
            return true
        }
    }

    private func sourceRow(_ s: (source: StudySource, title: String, detail: String)) -> some View {
        let on = !excluded.contains(s.source)
        return Button {
            if on { excluded.insert(s.source) } else { excluded.remove(s.source) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title).font(.callout).lineLimit(2)
                    Text(s.detail).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if case .file(let id) = s.source, let f = state.data.studyFiles?.first(where: { $0.id == id }) {
                Button("Open") { NSWorkspace.shared.open(StudyMaterial.fileURL(f)) }
                Button("Remove", role: .destructive) {
                    state.withUndo("Removed \(f.name)") { state.data.studyFiles?.removeAll { $0.id == id } }
                }
            }
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = StudyMaterial.fileTypes.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        let courseID = course?.id
        for url in urls where StudyMaterial.fileTypes.contains(url.pathExtension.lowercased()) {
            reading.append(url.lastPathComponent)
            Task {
                let file = await Task.detached { StudyMaterial.attach(url, courseID: courseID) }.value
                reading.removeAll { $0 == url.lastPathComponent }
                if let file {
                    state.data.studyFiles = (state.data.studyFiles ?? []) + [file]
                } else {
                    Diagnostics.warn(.data, "Study: no readable text in \(url.pathExtension) file")
                }
            }
        }
    }
}

// MARK: - Chat beside another module (⌘J)

/// The tutor in the right half of a split, reading whatever the left half has open: the note,
/// the book at its page, the assignment. Its course's material is searched for each question.
struct ContextChatPane: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var win: WindowModel

    var body: some View {
        let limit = LectureNotes.chunkChars(for: AIConfig.engine(for: .ask)) / 3
        let open = Tutor.open(win.focus, in: state.data, limit: limit)
        let course = state.course(open?.course)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").foregroundStyle(.secondary)
                Text(open.map { "About: \($0.title)" } ?? "Open a note, book or assignment on the left")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }.padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            if AIConfig.isReady(for: .ask) {
                TutorPane(course: course,
                          material: { StudyMaterial.coursePassages(course?.id, in: state.data, excludingNote: nil) },
                          openItem: { Tutor.open(win.focus, in: state.data, limit: limit).map { ($0.title, $0.text) } })
                    .id(course?.id)
            } else {
                EmptyState(symbol: "sparkles", title: "Pick an AI engine", subtitle: "Settings ▸ Intelligence.")
            }
        }
    }
}

// MARK: - Tutor

struct TutorPane: View {
    @EnvironmentObject var state: AppState
    let course: Course?
    let material: () -> [StudyPassage]
    /// What's open beside the chat, when it sits next to another module.
    var openItem: () -> (title: String, text: String)? = { nil }
    @State private var thread: [Tutor.Turn] = []
    @State private var input = ""
    @State private var mode: Tutor.Mode = .explain
    @State private var images: [Data] = []
    /// Files dropped on the chat (from the Shelf, Finder…): their text goes with the next question.
    @State private var attached: [Attached] = []
    @State private var dropping = false
    @State private var busy = false
    struct Attached: Identifiable, Hashable { let id = UUID(); let name: String; let text: String }
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if thread.isEmpty {
                            Text("Ask about the material, or attach a photo or screenshot of a problem. Hint and Next step help you work it yourself; Full solution works it through and checks the arithmetic.")
                                .font(.callout).foregroundStyle(.secondary).padding(.top, 24)
                        }
                        ForEach(thread) { turn in turnView(turn).id(turn.id) }
                    }
                    .padding(16).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                }
                .onChange(of: thread.last?.answer) { _, _ in if let id = thread.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            Divider()
            composer
        }
        .background(dropping ? Color.accentColor.opacity(0.06) : Color.clear)
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { _ in take(NSPasteboard(name: .drag)) }
    }

    /// Images go to the model as images; any other file StudyBar can read goes as its text.
    private func take(_ pb: NSPasteboard) -> Bool {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        for u in urls {
            if UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) == true, let img = NSImage(contentsOf: u), let d = Self.jpeg(img) {
                images.append(d)
            } else if StudyMaterial.fileTypes.contains(u.pathExtension.lowercased()) {
                let name = u.lastPathComponent
                Task {
                    let text = await Task.detached { StudyMaterial.extract(u).map(\.text).joined(separator: "\n\n") }.value
                    if !text.isEmpty { attached.append(Attached(name: name, text: text)) }
                }
            }
        }
        if urls.isEmpty, let img = NSImage(pasteboard: pb), let d = Self.jpeg(img) { images.append(d) }
        return true
    }

    private func turnView(_ t: Tutor.Turn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(t.mode.rawValue).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.12), in: Capsule())
                Text(t.question.isEmpty ? "(the problem in the image)" : t.question).font(.callout.weight(.medium))
            }
            if !t.images.isEmpty {
                HStack { ForEach(t.images, id: \.self) { d in NSImage(data: d).map { Image(nsImage: $0).resizable().scaledToFit().frame(height: 90) } } }
            }
            if t.answer.isEmpty { ProgressView().controlSize(.small) }
            else { RichText(text: t.answer).textSelection(.enabled) }
            if !t.checks.isEmpty { checksView(t.checks) }
        }
    }

    private func checksView(_ checks: [MathCheck.Result]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(checks, id: \.self) { c in
                switch c.ok {
                case true?:
                    Label("\(c.expression) = \(c.claimed) — arithmetic checked", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                case false?:
                    Label("\(c.expression) is \(MathEval.format(c.actual ?? 0)), not \(c.claimed) — recheck this step", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case nil:
                    Label("Couldn't check \(c.expression)", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .padding(8).background(.sbSurface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $mode) { ForEach(Tutor.Mode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            if !attached.isEmpty {
                HStack {
                    ForEach(attached) { a in
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                            Text(a.name).lineLimit(1)
                            Button { attached.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                        }
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.sbSurface, in: Capsule())
                    }
                }
            }
            if !images.isEmpty {
                HStack {
                    ForEach(images.indices, id: \.self) { i in
                        ZStack(alignment: .topTrailing) {
                            NSImage(data: images[i]).map { Image(nsImage: $0).resizable().scaledToFit().frame(height: 54) }
                            Button { images.remove(at: i) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { attach() } label: { Image(systemName: "paperclip") }.help("Attach a photo or screenshot of the problem")
                Button { pasteImage() } label: { Image(systemName: "doc.on.clipboard") }.help("Paste an image from the clipboard")
                TextField("Ask, or describe what you're stuck on…", text: $input, axis: .vertical)
                    .lineLimit(1...6).textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                if busy {
                    Button("Stop") { task?.cancel(); busy = false }
                } else {
                    Button("Send") { send() }.buttonStyle(.borderedProminent)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty && images.isEmpty && attached.isEmpty)
                }
            }
        }
        .padding(10)
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        images += panel.urls.compactMap { NSImage(contentsOf: $0).flatMap(Self.jpeg) }
    }

    private func pasteImage() {
        if let img = NSImage(pasteboard: .general), let d = Self.jpeg(img) { images.append(d) }
    }

    /// At most 1600 px on the long side: enough to read a problem, small enough to send.
    static func jpeg(_ img: NSImage) -> Data? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 1600 / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) }
    }

    private func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !q.isEmpty || !images.isEmpty || !attached.isEmpty, let provider = AIService.makeProvider(for: .ask) else { return }
        let engine = AIConfig.engine(for: .ask)
        let sees = AIConfig.canSee(engine)
        let imgs = images, turnMode = mode, prior = thread
        // An engine that can't see gets the text read off the image instead.
        let imageText = sees ? "" : imgs.compactMap { NSImage(data: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            .map(StudyMaterial.ocr).joined(separator: "\n\n")
        let query = [q, imageText].filter { !$0.isEmpty }.joined(separator: " ")
        let found = query.isEmpty ? [] : StudyIndex.search(query, in: material(), k: 5)
        let code = course.map { $0.code.isEmpty ? $0.name : $0.code }
        // Dropped files ride along as material, ahead of what the search found.
        let budget = LectureNotes.chunkChars(for: engine) / 3
        let files = attached.map { "[\($0.name)]\n\($0.text.prefix(budget / max(1, attached.count)))" }.joined(separator: "\n\n")
        let open = openItem()

        thread.append(Tutor.Turn(question: q, mode: turnMode, images: imgs))
        let idx = thread.count - 1
        input = ""; images = []; attached = []; busy = true
        task = Task {
            let msgs = Tutor.messages(thread: prior, question: q, material: [files, StudyMaterial.block(found)].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                                      images: sees ? imgs : [], imageText: imageText, mode: turnMode, open: open)
            let out = try? await provider.streamPlain(system: Tutor.system(turnMode, course: code), messages: msgs,
                                                      temperature: 0.3) { partial in
                if thread.indices.contains(idx) { thread[idx].answer = MathCheck.run(partial).text }
            }
            await MainActor.run {
                busy = false
                guard thread.indices.contains(idx) else { return }
                let (text, checks) = MathCheck.run(out ?? thread[idx].answer)
                thread[idx].answer = text.isEmpty ? "Couldn't get an answer — try again, or another engine in Settings ▸ Intelligence."
                                                  : NoteFormat.tidy(MathSupport.normalized(text))
                thread[idx].checks = checks
            }
        }
    }
}

// MARK: - Quiz and practice exam

private struct QuizPane: View {
    @EnvironmentObject var state: AppState
    let exam: Bool
    let course: Course?
    let material: () -> [StudyPassage]

    enum Phase { case setup, generating, taking, done }
    @State private var phase: Phase = .setup
    @State private var count = 10
    @State private var minutes = 30
    @State private var questions: [QuizQuestion] = []
    @State private var responses: [UUID: QuizResponse] = [:]
    @State private var revealed: Set<UUID> = []
    @State private var index = 0
    @State private var progress = (0, 0)
    @State private var deadline: Date?
    @State private var error: String?
    @State private var addedTo: String?
    @State private var feedback: [UUID: String] = [:]
    @State private var task: Task<Void, Never>?

    var body: some View {
        switch phase {
        case .setup: setup
        case .generating:
            VStack(spacing: 10) {
                ProgressView()
                Text(progress.1 > 1 ? "Writing questions — part \(progress.0) of \(progress.1)…" : "Writing questions…")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Cancel") { task?.cancel(); phase = .setup }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .taking: exam ? AnyView(examSheet) : AnyView(quizCard)
        case .done: results
        }
    }

    private var setup: some View {
        VStack(spacing: 14) {
            Image(systemName: exam ? "timer" : "questionmark.bubble").font(.largeTitle).foregroundStyle(.tint)
            Text(exam ? "A timed exam from the ticked material, marked at the end."
                      : "Questions one at a time, with the answer and why after each.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Picker("Questions", selection: $count) {
                ForEach(exam ? [10, 20, 30] : [5, 10, 15, 20], id: \.self) { Text("\($0)").tag($0) }
            }.fixedSize()
            if exam {
                Picker("Time", selection: $minutes) {
                    ForEach([15, 30, 45, 60, 90], id: \.self) { Text("\($0) min").tag($0) }
                }.fixedSize()
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            Button(exam ? "Start exam" : "Start quiz") { start() }.buttonStyle(.borderedProminent)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if exam { count = 20 } }
    }

    private func start() {
        let passages = material()
        guard !passages.isEmpty else { error = "Tick at least one source with some text in it."; return }
        guard let provider = AIService.makeProvider(for: .ask) else { return }
        error = nil; phase = .generating; progress = (0, 0)
        let n = count, isExam = exam
        task = Task {
            let qs = await Quiz.generate(from: passages, count: n, exam: isExam, provider: provider,
                                         mode: AIConfig.engine(for: .ask)) { p, t in progress = (p, t) }
            await MainActor.run {
                guard phase == .generating else { return }
                guard let qs, !qs.isEmpty else {
                    error = "The AI didn't return usable questions. Try again, or a stronger engine in Settings ▸ Intelligence."
                    phase = .setup; return
                }
                questions = qs; responses = [:]; revealed = []; index = 0; addedTo = nil; feedback = [:]
                deadline = isExam ? Date().addingTimeInterval(Double(minutes) * 60) : nil
                phase = .taking
            }
        }
    }

    private func binding(_ q: QuizQuestion) -> Binding<QuizResponse> {
        Binding(get: { responses[q.id] ?? QuizResponse() }, set: { responses[q.id] = $0 })
    }

    private var correctCount: Int { questions.filter { Quiz.isCorrect($0, responses[$0.id] ?? QuizResponse()) == true }.count }

    // Quiz: one at a time.
    private var quizCard: some View {
        let q = questions[min(index, questions.count - 1)]
        let shown = revealed.contains(q.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Question \(index + 1) of \(questions.count) · \(correctCount) correct").font(.caption).foregroundStyle(.secondary)
                QuestionCard(q: q, response: binding(q), revealed: shown, feedback: feedback[q.id], check: { aiCheck(q) })
                HStack {
                    Spacer()
                    if !shown {
                        Button("Check") { revealed.insert(q.id) }.buttonStyle(.borderedProminent)
                            .disabled(!(responses[q.id]?.answered ?? false))
                        Button("Skip") { revealed.insert(q.id) }
                    } else if index + 1 < questions.count {
                        Button("Next") { index += 1 }.buttonStyle(.borderedProminent)
                            .disabled(q.kind == .short && responses[q.id]?.answered == true && responses[q.id]?.selfGrade == nil)
                    } else {
                        Button("Finish") { phase = .done }.buttonStyle(.borderedProminent)
                    }
                }
            }.padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
    }

    // Exam: all at once, against the clock.
    private var examSheet: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int((deadline ?? ctx.date).timeIntervalSince(ctx.date)))
                HStack {
                    Label(String(format: "%d:%02d left", left / 60, left % 60), systemImage: "timer")
                        .foregroundStyle(left < 60 ? .orange : .secondary)
                    Spacer()
                    Text("\(responses.values.filter(\.answered).count) of \(questions.count) answered").foregroundStyle(.secondary)
                    Button("Submit") { phase = .done }.buttonStyle(.borderedProminent)
                }
                .font(.callout).padding(10)
                .onChange(of: left) { _, l in if l == 0, phase == .taking { phase = .done } }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(questions.enumerated()), id: \.element.id) { i, q in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(i + 1).").font(.caption.bold()).foregroundStyle(.secondary)
                            QuestionCard(q: q, response: binding(q), revealed: false, feedback: nil, check: {})
                        }
                    }
                }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
        }
    }

    private var missed: [QuizQuestion] {
        questions.filter { Quiz.isCorrect($0, responses[$0.id] ?? QuizResponse()) == false }
    }
    private var ungraded: Int {
        questions.filter { Quiz.isCorrect($0, responses[$0.id] ?? QuizResponse()) == nil }.count
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let pct = questions.isEmpty ? 0 : Int((Double(correctCount) / Double(questions.count) * 100).rounded())
                Text("\(correctCount) of \(questions.count) — \(pct)%").font(.largeTitle.bold())
                if ungraded > 0 {
                    Text("\(ungraded) short answer\(ungraded == 1 ? "" : "s") to mark below — compare with the model answer, or ask the AI.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                topicBreakdown
                HStack {
                    if let addedTo {
                        Label("Added to \(addedTo)", systemImage: "checkmark").foregroundStyle(.green).font(.callout)
                    } else if !missed.isEmpty {
                        Button("Add \(missed.count) missed to flashcards") {
                            addedTo = Quiz.addMissed(missed, course: course, state: state)
                        }.buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    Button(exam ? "New exam" : "New quiz") { phase = .setup }
                }
                Divider()
                ForEach(Array(questions.enumerated()), id: \.element.id) { i, q in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(i + 1).").font(.caption.bold()).foregroundStyle(.secondary)
                        QuestionCard(q: q, response: binding(q), revealed: true, feedback: feedback[q.id], check: { aiCheck(q) })
                    }
                }
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
    }

    /// Where the marks were lost, by topic — what to study next.
    @ViewBuilder private var topicBreakdown: some View {
        let topics = Dictionary(grouping: questions) { $0.topic.isEmpty ? "Other" : $0.topic }
        if topics.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(topics.keys.sorted(), id: \.self) { t in
                    let qs = topics[t] ?? []
                    let right = qs.filter { Quiz.isCorrect($0, responses[$0.id] ?? QuizResponse()) == true }.count
                    HStack {
                        Text(t).font(.callout).frame(width: 180, alignment: .leading).lineLimit(1)
                        ProgressView(value: Double(right), total: Double(max(1, qs.count)))
                        Text("\(right)/\(qs.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func aiCheck(_ q: QuizQuestion) {
        guard let provider = AIService.makeProvider(for: .ask), let r = responses[q.id], r.answered else { return }
        feedback[q.id] = "Checking…"
        Task {
            let g = await Quiz.grade(q, answer: r.text, provider: provider)
            await MainActor.run {
                guard let g else { feedback[q.id] = "Couldn't check — mark it yourself."; return }
                responses[q.id]?.selfGrade = g.correct
                feedback[q.id] = g.feedback
            }
        }
    }
}

/// One question: its answer controls, and once revealed, whether it was right and why.
private struct QuestionCard: View {
    let q: QuizQuestion
    @Binding var response: QuizResponse
    let revealed: Bool
    let feedback: String?
    let check: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RichText(text: q.prompt).font(.body.weight(.medium))
            switch q.kind {
            case .mcq:
                ForEach(q.choices.indices, id: \.self) { i in
                    choice(RichText(text: q.choices[i]), picked: response.choice == i, right: i == q.answerIndex) { response.choice = i }
                }
            case .tf:
                HStack {
                    ForEach([true, false], id: \.self) { b in
                        choice(Text(b ? "True" : "False"), picked: response.bool == b, right: b == q.answerBool) { response.bool = b }
                    }
                }
            case .fill:
                TextField("Answer", text: $response.text).textFieldStyle(.roundedBorder).disabled(revealed).frame(maxWidth: 320)
            case .short:
                TextField("Your answer", text: $response.text, axis: .vertical).lineLimit(2...6)
                    .textFieldStyle(.roundedBorder).disabled(revealed)
            }
            if revealed { verdict }
        }
        .padding(14)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func choice<L: View>(_ label: L, picked: Bool, right: Bool, pick: @escaping () -> Void) -> some View {
        let tint: Color? = revealed ? (right ? .green : picked ? .red : nil) : (picked ? .accentColor : nil)
        return Button(action: pick) {
            HStack(spacing: 8) {
                Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                label
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background((tint ?? .clear).opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder((tint ?? .secondary).opacity(tint == nil ? 0.25 : 0.7)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(revealed)
    }

    @ViewBuilder private var verdict: some View {
        let ok = Quiz.isCorrect(q, response)
        VStack(alignment: .leading, spacing: 6) {
            switch ok {
            case true?: Label("Correct", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case false?: Label(response.answered ? "Not quite — the answer is \(q.correctText)" : "The answer is \(q.correctText)",
                               systemImage: "xmark.circle.fill").foregroundStyle(.red)
            case nil:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model answer").font(.caption.bold()).foregroundStyle(.secondary)
                    RichText(text: q.answerText)
                    HStack {
                        Button("I got it") { response.selfGrade = true }
                        Button("I missed it") { response.selfGrade = false }
                        Button("Check with AI", action: check)
                    }.controlSize(.small)
                }
            }
            if q.kind == .short, ok != nil {
                Text("Model answer: \(q.answerText)").font(.caption).foregroundStyle(.secondary)
            }
            if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
            if !q.explanation.isEmpty { RichText(text: q.explanation).font(.callout).foregroundStyle(.secondary) }
            if !q.source.isEmpty { Label(q.source, systemImage: "book").font(.caption2).foregroundStyle(.tertiary) }
        }
    }
}

// MARK: - Study guide

private struct GuidePane: View {
    @EnvironmentObject var state: AppState
    let course: Course?
    let material: () -> [StudyPassage]
    @State private var guide: String?
    @State private var busy = false
    @State private var progress = (0, 0)
    @State private var saved = false
    @State private var error: String?

    private var title: String {
        "Study guide — \(course.map { $0.code.isEmpty ? $0.name : $0.code } ?? "Course") — \(Date().formatted(date: .abbreviated, time: .omitted))"
    }

    var body: some View {
        if let guide, !busy {
            VStack(spacing: 0) {
                HStack {
                    Button(saved ? "Saved" : "Save as note") { save(guide) }.disabled(saved).buttonStyle(.borderedProminent)
                    Button("Export PDF") { PDFExportWindow.show(body: NoteHTML.body(from: NSAttributedString(string: guide)),
                                                                  meta: .init(title: "", subtitle: course?.code ?? "")) }
                    Spacer()
                    Button("Rewrite") { generate() }
                }.padding(10)
                Divider()
                ScrollView {
                    NotePreview(text: guide).padding(20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                        .textSelection(.enabled)
                }
            }
        } else {
            VStack(spacing: 14) {
                if busy {
                    ProgressView()
                    Text(progress.1 > 1 ? "Reading part \(progress.0) of \(progress.1)…" : "Writing the guide…").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(.tint)
                    Text("Key concepts, definitions, formulas and worked examples from the ticked material — each with its source.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                    Button("Write study guide") { generate() }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func generate() {
        let passages = material()
        guard !passages.isEmpty else { error = "Tick at least one source with some text in it."; return }
        guard let provider = AIService.makeProvider(for: .ask) else { return }
        busy = true; saved = false; error = nil; progress = (0, 0)
        let t = title
        Task {
            let out = await StudyGuide.generate(from: passages, title: t, provider: provider,
                                                mode: AIConfig.engine(for: .ask)) { p, n in progress = (p, n) }
            await MainActor.run {
                busy = false
                if let out { guide = out } else { error = "The AI didn't return a guide. Try again, or a stronger engine." }
            }
        }
    }

    private func save(_ text: String) {
        var note = Note(title: title, body: text, courseID: course?.id)
        note.updatedAt = .now
        state.data.notes.append(note)
        saved = true
    }
}

// MARK: - Snapshot (STUDYBAR_DATA_DIR=<scratch> StudyBar --study-snapshot <dir>)

/// Renders the module and the question card in each of its states to PNGs, against a
/// throwaway store — for looking at the layout without a live window. Refuses to run on the
/// real store: it adds sample data.
@MainActor
enum StudySnapshot {
    static func run(state: AppState, out: String) -> Int32 {
        guard ProcessInfo.processInfo.environment["STUDYBAR_DATA_DIR"] != nil else {
            print("Set STUDYBAR_DATA_DIR to a scratch folder first — this adds sample data."); return 1
        }
        let course = Course(name: "Physics II", code: "PHY2049")
        state.data.courses = [course]
        state.data.notes = [Note(title: "Week 3 — Gauss's Law", body: "## Flux\n- **Flux** — field through a surface", courseID: course.id),
                            Note(title: "Week 4 — Potential", body: "## Potential\n- $V = kq/r$", courseID: course.id)]
        UserDefaults.standard.set(course.id.uuidString, forKey: "studyCourse")

        var mcq = QuizQuestion(kind: .mcq, prompt: "The electric field inside a conductor in equilibrium is",
                               choices: ["zero", "$\\sigma/\\epsilon_0$", "infinite", "$kq/r^2$"], answerIndex: 0,
                               explanation: "Free charges move until the field inside cancels.", topic: "Conductors", source: "Serway, p. 745")
        mcq.answerText = ""
        let tf = QuizQuestion(kind: .tf, prompt: "Charges outside a closed surface change the net flux through it.", answerBool: false,
                              explanation: "Their field lines enter and leave, so they cancel.", topic: "Flux", source: "Week 3 — Gauss's Law")
        let short = QuizQuestion(kind: .short, prompt: "Why is Gauss's law only useful with symmetry?",
                                 answerText: "Symmetry makes E constant on the surface so it comes out of the integral.",
                                 explanation: "", topic: "Gauss's law", source: "")
        func save(_ view: some View, _ name: String, _ size: CGSize) {
            let host = NSHostingView(rootView: view.environmentObject(state).frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.frame = CGRect(origin: .zero, size: size)
            host.appearance = NSAppearance(named: .aqua)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            win.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            win.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
            win.orderOut(nil)
        }
        save(StudyModuleView(), "module.png", CGSize(width: 1000, height: 640))
        save(VStack(spacing: 16) {
            QuestionCard(q: mcq, response: .constant(QuizResponse(choice: 1)), revealed: true, feedback: nil, check: {})
            QuestionCard(q: tf, response: .constant(QuizResponse(bool: true)), revealed: false, feedback: nil, check: {})
            QuestionCard(q: short, response: .constant(QuizResponse(text: "Because E is constant on it")), revealed: true, feedback: nil, check: {})
        }.padding(20), "cards.png", CGSize(width: 720, height: 760))
        if let files = ProcessInfo.processInfo.environment["SB_CONVERT_FILES"] {
            ConvertQueue.shared.add(files.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
            save(ConvertView(), "convert.png", CGSize(width: 900, height: 560))
        }
        print("wrote \(out)/module.png, cards.png")
        return 0
    }
}
