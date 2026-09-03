import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings ▸ Diagnostics — a local, privacy-safe view of the app's health, environment and
/// recent technical events, with a one-tap redacted report for bug reports.
///
/// Rendered as its OWN scroll view (not inside the settings Form): a grouped Form won't give a
/// long child a bounded width, so wide content (the crash log, long event lines) overflowed the
/// pane and grew the window. Here a plain vertical ScrollView bounds the width, so every text
/// wraps and nothing pushes the window.
struct DiagnosticsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var diag = Diagnostics.shared
    @AppStorage("diagVerbose") private var verbose = false
    @State private var health: [HealthCheck] = []
    @State private var loadingHealth = false
    @State private var catFilter: DiagCategory?
    @State private var minLevel = DiagLevel.debug
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if diag.lastCrash != nil { crashCard }
                card("Health") { healthContent }
                card("Environment") { environmentContent }
                card("Events (\(diag.events.count))") { eventsContent }
                card("Report") { reportContent }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await refreshHealth() }
    }

    /// A titled surface card; content wraps within the (bounded) scroll width.
    @ViewBuilder private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.sbSurfaceStroke, lineWidth: 0.5))
    }

    private func rowText(_ s: String, font: Font = .callout, color: Color = .primary) -> some View {
        Text(s).font(font).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Crash

    private var crashCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Previous session ended unexpectedly", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            rowText("A crash, force-quit or power loss. The full log leading up to it is in the report below — Copy or Save it to send so this can be fixed.", color: .secondary)
            Button { diag.lastCrash = nil } label: { Label("Dismiss", systemImage: "xmark") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.4), lineWidth: 0.5))
    }

    // MARK: Health

    @ViewBuilder private var healthContent: some View {
        if loadingHealth && health.isEmpty {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Running checks…").foregroundStyle(.secondary) }
        }
        ForEach(health) { h in
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: h.status.symbol).foregroundStyle(color(h.status)).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(h.name)
                    rowText(h.detail, font: .caption, color: .secondary)
                }
            }
        }
        Button { Task { await refreshHealth() } } label: { Label("Re-run checks", systemImage: "arrow.clockwise") }
            .buttonStyle(.bordered).controlSize(.small).disabled(loadingHealth).padding(.top, 2)
    }

    // MARK: Environment

    @ViewBuilder private var environmentContent: some View {
        ForEach(Diagnostics.environment(state.data), id: \.0) { row in
            HStack(alignment: .top, spacing: 12) {
                Text(row.0).font(.callout).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 8)
                Text(row.1).font(.callout).multilineTextAlignment(.trailing).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if row.0 != Diagnostics.environment(state.data).last?.0 { Divider() }
        }
    }

    // MARK: Events

    private var filtered: [DiagEvent] {
        diag.events.filter { $0.level >= minLevel && (catFilter == nil || $0.category == catFilter) }
    }

    @ViewBuilder private var eventsContent: some View {
        HStack(spacing: 8) {
            Text("Level").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $minLevel) {
                ForEach(DiagLevel.allCases) { Text($0.label).tag($0) }
            }.labelsHidden().pickerStyle(.menu).fixedSize()
            Text("Category").font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
            Picker("", selection: $catFilter) {
                Text("All").tag(DiagCategory?.none)
                ForEach(DiagCategory.allCases) { Text($0.label).tag(DiagCategory?.some($0)) }
            }.labelsHidden().pickerStyle(.menu).fixedSize()
            Spacer(minLength: 8)
            Toggle("Verbose", isOn: $verbose).controlSize(.small).fixedSize()
        }
        Divider()
        let rows = Array(filtered.suffix(150).reversed())     // newest first
        if rows.isEmpty {
            Text(diag.events.isEmpty ? "No events yet — use the app and technical events appear here."
                                     : "No events match the filter.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(rows) { eventRow($0) }
        }
    }

    private func eventRow(_ e: DiagEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: e.level.symbol).font(.caption2).foregroundStyle(levelColor(e.level)).frame(width: 14)
            Text(time(e.date)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 58, alignment: .leading)
            Text(e.category.label.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 54, alignment: .leading)
            Text(e.message).font(.caption).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)   // wraps within the bounded card
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Report

    @ViewBuilder private var reportContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { copyReport() } label: { Label(copied ? "Copied ✓" : "Copy report", systemImage: "doc.on.doc") }
                Button { saveReport() } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                Button(role: .destructive) { diag.clear() } label: { Label("Clear log", systemImage: "trash") }
            }.buttonStyle(.bordered).controlSize(.small)
            rowText("The report includes app version, macOS, engine + model state, record counts and recent technical events — never your note text, transcripts or other content.",
                    font: .caption2, color: .secondary)
        }
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
