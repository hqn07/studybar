import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings ▸ Diagnostics — a local, privacy-safe view of the app's health, environment and
/// recent technical events, with a one-tap redacted report for bug reports. Rendered as Form
/// sections to match the other settings tabs.
struct DiagnosticsSections: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var diag = Diagnostics.shared
    @AppStorage("diagVerbose") private var verbose = false
    @State private var health: [HealthCheck] = []
    @State private var loadingHealth = false
    @State private var catFilter: DiagCategory?
    @State private var minLevel = DiagLevel.debug
    @State private var copied = false

    var body: some View {
        Group {
            if diag.lastCrash != nil { crashSection }
            healthSection
            environmentSection
            eventsSection
            actionsSection
        }
        .task { await refreshHealth() }
    }

    @ViewBuilder private var crashSection: some View {
        if let crash = diag.lastCrash {
            Section {
                // A plain Text in a Form row wraps to the pane width reliably (a ScrollView here
                // does not, and overflowed). Cap the height with a line limit; the full log is in
                // the exported report.
                Text(crash)
                    .font(.caption2.monospaced()).textSelection(.enabled)
                    .lineLimit(12)
                    .frame(maxWidth: 460, alignment: .leading)   // concrete cap → wraps, never pushes the pane
                    .padding(8)
                    .background(.sbSurface, in: RoundedRectangle(cornerRadius: 8))
                Text("Truncated here — the full details are in the report below. Copy or save it and send it so this can be fixed.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button { diag.lastCrash = nil } label: { Label("Dismiss", systemImage: "xmark") }
            } header: {
                Label("Previous session ended unexpectedly", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    // MARK: Health

    private var healthSection: some View {
        Section {
            if loadingHealth && health.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Running checks…").foregroundStyle(.secondary) }
            }
            ForEach(health) { h in
                HStack(spacing: 10) {
                    Image(systemName: h.status.symbol).foregroundStyle(color(h.status))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(h.name)
                        Text(h.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
            }
            Button { Task { await refreshHealth() } } label: { Label("Re-run checks", systemImage: "arrow.clockwise") }
                .disabled(loadingHealth)
        } header: { Text("Health") }
    }

    // MARK: Environment

    private var environmentSection: some View {
        Section {
            ForEach(Diagnostics.environment(state.data), id: \.0) { row in
                HStack(alignment: .top) {
                    Text(row.0).foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 12)
                    Text(row.1).multilineTextAlignment(.trailing).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)   // wrap, don't push width
                }.font(.callout)
            }
        } header: { Text("Environment") }
    }

    // MARK: Events

    private var filtered: [DiagEvent] {
        diag.events.filter { $0.level >= minLevel && (catFilter == nil || $0.category == catFilter) }
    }

    private var eventsSection: some View {
        Section {
            HStack(spacing: 10) {
                Picker("Level", selection: $minLevel) {
                    ForEach(DiagLevel.allCases) { Text($0.label).tag($0) }
                }.fixedSize()
                Picker("Category", selection: $catFilter) {
                    Text("All").tag(DiagCategory?.none)
                    ForEach(DiagCategory.allCases) { Text($0.label).tag(DiagCategory?.some($0)) }
                }.fixedSize()
                Spacer()
                Toggle("Verbose", isOn: $verbose).toggleStyle(.switch).controlSize(.mini)
            }
            let rows = Array(filtered.suffix(200).reversed())     // newest first
            if rows.isEmpty {
                Text(diag.events.isEmpty ? "No events yet — use the app and technical events appear here."
                                         : "No events match the filter.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { eventRow($0) }
            }
        } header: { Text("Events (\(diag.events.count))") }
    }

    private func eventRow(_ e: DiagEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: e.level.symbol).font(.caption2).foregroundStyle(levelColor(e.level)).frame(width: 14)
            Text(time(e.date)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 58, alignment: .leading)
            Text(e.category.label.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Text(e.message).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Actions

    private var actionsSection: some View {
        Section {
            Button { copyReport() } label: { Label(copied ? "Copied ✓" : "Copy diagnostics report", systemImage: "doc.on.doc") }
            Button { saveReport() } label: { Label("Save report…", systemImage: "square.and.arrow.down") }
            Button(role: .destructive) { diag.clear() } label: { Label("Clear log", systemImage: "trash") }
            Text("The report includes app version, macOS, engine + model state, record counts and recent technical events — never your note text, transcripts or other content.")
                .font(.caption2).foregroundStyle(.secondary)
        } header: { Text("Report") }
    }

    // MARK: Helpers

    private func refreshHealth() async {
        loadingHealth = true
        health = await Diagnostics.runHealthChecks(state)
        loadingHealth = false
    }
    private func copyReport() {
        let r = Diagnostics.report(state.data, health: health)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r, forType: .string)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); copied = false }
    }
    private func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "StudyBar-diagnostics.txt"
        if #available(macOS 11, *), let t = UTType(filenameExtension: "txt") { panel.allowedContentTypes = [t] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Diagnostics.report(state.data, health: health).write(to: url, atomically: true, encoding: .utf8)
    }
    private func color(_ s: HealthStatus) -> Color { switch s { case .pass: .green; case .warn: .orange; case .fail: .red } }
    private func levelColor(_ l: DiagLevel) -> Color { switch l { case .debug: .secondary; case .info: .blue; case .warn: .orange; case .error: .red } }
    private func time(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d) }
}
