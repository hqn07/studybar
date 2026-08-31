import SwiftUI

struct SemesterView: View {
    @EnvironmentObject var state: AppState
    @State private var editing = false

    private var start: Date? { state.data.termStart }
    private var end: Date? { state.data.termEnd }

    private var progress: Double {
        guard let s = start, let e = end, e > s else { return 0 }
        return min(1, max(0, Date().timeIntervalSince(s) / e.timeIntervalSince(s)))
    }
    private var weeksLeft: Int? {
        guard let e = end else { return nil }
        let days = Calendar.current.dateComponents([.day], from: .now, to: e).day ?? 0
        return max(0, Int(ceil(Double(days) / 7)))
    }
    private var totalCredits: Double { state.data.courses.reduce(0) { $0 + $1.credits } }
    private var gpa: (value: Double, credits: Double, graded: Int)? {
        let graded = state.data.courses.filter { $0.gradePoints != nil }
        let creds = graded.reduce(0.0) { $0 + $1.credits }
        guard !graded.isEmpty, creds > 0 else { return nil }
        let weighted = graded.reduce(0.0) { $0 + ($1.gradePoints! * $1.credits) }
        return (weighted / creds, creds, graded.count)
    }

    var body: some View {
        NavigationStack {
        ModulePane(title: "Semester") {
            Button { editing = true } label: { Image(systemName: "calendar.badge.plus") }
                .help("Set term dates")
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if start == nil || end == nil {
                        EmptyState(symbol: "calendar", title: "Set your term",
                                   subtitle: "Add start and end dates to track how far into the semester you are.")
                        Button("Set term dates") { editing = true }.buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                    } else {
                        card {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(state.data.termName.isEmpty ? "Current Term" : state.data.termName)
                                    .font(.headline)
                                Text("\(start!.formatted(date: .abbreviated, time: .omitted)) – \(end!.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                                ProgressView(value: progress)
                                HStack {
                                    Text("\(Int(progress * 100))% complete").font(.caption)
                                    Spacer()
                                    if let w = weeksLeft { Text("\(w) weeks left").font(.caption.bold()).foregroundStyle(.tint) }
                                }
                            }
                        }
                        HStack(spacing: 10) {
                            metric("\(state.data.courses.count)", "courses")
                            metric(String(format: "%g", totalCredits), "credits")
                            metric(gpa != nil ? String(format: "%.2f", gpa!.value) : "—", "GPA")
                        }
                        if let g = gpa {
                            Text("GPA from \(g.graded) graded course\(g.graded == 1 ? "" : "s") · \(String(format: "%g", g.credits)) credits · US 4.0 scale")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text("Set a grade on your courses (tap a course → grade) to see your GPA.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("COURSES").font(.caption2.bold()).foregroundStyle(.secondary)
                        ForEach(state.data.courses) { c in
                            HStack {
                                Circle().fill(c.color).frame(width: 9, height: 9)
                                Text(c.name).fontWeight(.medium)
                                Spacer()
                                if !c.grade.isEmpty {
                                    Text(c.grade).font(.caption.bold())
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(c.color.opacity(0.2), in: Capsule()).foregroundStyle(c.color)
                                }
                                Text("\(c.credits, specifier: "%g") cr").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(9).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                        }
                    }
                }.padding(12)
            }
        }
        .navigationDestination(isPresented: $editing) { TermEditor() }
        }
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
    private func metric(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.title3.bold())
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }
}

struct TermEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var start = Date()
    @State private var end = Date()

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Term Dates")
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                TextField("Term name (e.g. Fall 2026)", text: $name).textFieldStyle(.roundedBorder)
                DatePicker("Start", selection: $start, displayedComponents: .date)
                DatePicker("End", selection: $end, displayedComponents: .date)
            }.padding(16)
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Save") {
                    state.data.termName = name; state.data.termStart = start; state.data.termEnd = end; dismiss()
                }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .onAppear {
            name = state.data.termName
            start = state.data.termStart ?? Date()
            end = state.data.termEnd ?? Calendar.current.date(byAdding: .month, value: 4, to: Date())!
        }
    }
}
