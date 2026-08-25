import SwiftUI

/// Guided "Connect Canvas (no API needed)" flow: paste the personal Calendar
/// Feed URL, preview the assignments it will import, fix up course mapping, then
/// confirm. Uses the .ics feed — no token. (Inline pushes + ConfirmCard only;
/// no sheets/alerts — the popover dismisses on focus loss.)
struct ConnectCanvasView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case input, preview, done }
    @State private var phase: Phase = .input
    @State private var url = ""
    @State private var name = "Canvas"
    @State private var loading = false
    @State private var errorMsg = ""

    @State private var planned: [CanvasFeedImport.Planned] = []
    @State private var codeCourse: [String: UUID?] = [:]   // per-[CODE] override ("" = untagged group)
    @State private var showConfirm = false
    @State private var result = CanvasFeedImport.Summary()

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Connect Canvas")
            Divider()
            ScrollView {
                switch phase {
                case .input:   inputStep
                case .preview: previewStep
                case .done:    doneStep
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .overlay {
            if showConfirm {
                ConfirmCard(
                    title: "Import \(planned.count) assignment\(planned.count == 1 ? "" : "s")?",
                    message: "Adds due dates from this feed. Existing items update in place; your edits are kept.",
                    confirmLabel: "Import", destructive: false,
                    onConfirm: { showConfirm = false; runImport() },
                    onCancel: { showConfirm = false })
            }
        }
    }

    // MARK: Step 1 — paste

    private var inputStep: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Label("No API or token needed", systemImage: "checkmark.seal.fill")
                .font(.callout.weight(.medium)).foregroundStyle(Color.dsDone)

            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Where to find your feed URL").font(.caption.weight(.semibold))
                stepLine("1", "In Canvas, open **Calendar**.")
                stepLine("2", "Click **Calendar Feed** (bottom-right).")
                stepLine("3", "Copy the URL and paste it below.")
            }.dsCard()

            TextField("Feed URL (.ics or webcal://)", text: $url)
                .textFieldStyle(.roundedBorder)
                .onSubmit(fetchPreview)
            TextField("Name (e.g. Canvas)", text: $name).textFieldStyle(.roundedBorder)

            if !errorMsg.isEmpty {
                Text(errorMsg).font(.caption).foregroundStyle(Color.dsNow)
            }
            Button(action: fetchPreview) {
                HStack(spacing: DS.Space.s) {
                    if loading { ProgressView().controlSize(.small) }
                    Text(loading ? "Fetching…" : "Fetch & preview")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || loading)
        }.padding(DS.Space.l)
    }

    private func stepLine(_ n: String, _ md: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Text(n).font(.caption2.bold().monospacedDigit())
                .frame(width: 16, height: 16)
                .background(.tint.opacity(0.15), in: Circle()).foregroundStyle(.tint)
            Text((try? AttributedString(markdown: md)) ?? AttributedString(md))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Step 2 — preview + course fixups

    @ViewBuilder private var previewStep: some View {
        if planned.isEmpty {
            VStack(spacing: DS.Space.m) {
                Image(systemName: "tray").font(.title).foregroundStyle(.secondary)
                Text("No upcoming assignments found in this feed.").font(.callout).foregroundStyle(.secondary)
                Text("The feed may only contain past items, or it isn't a Canvas assignment feed.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Back") { phase = .input }.buttonStyle(.bordered)
            }.frame(maxWidth: .infinity).padding(DS.Space.xl)
        } else {
            let newN = planned.filter(\.isNew).count
            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack(spacing: DS.Space.s) {
                    Chip("\(newN) new", .status(.done))
                    if planned.count - newN > 0 { Chip("\(planned.count - newN) update", .status(.neutral)) }
                    Spacer()
                    Text("\(planned.count) assignment\(planned.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.key) { group in
                    courseGroup(code: group.key, items: group.value)
                }
                HStack {
                    Button("Back") { phase = .input }.buttonStyle(.bordered)
                    Spacer()
                    Button("Import \(planned.count)") { showConfirm = true }
                        .buttonStyle(.borderedProminent)
                }
            }.padding(DS.Space.l)
        }
    }

    /// planned grouped by their Canvas [CODE] tag ("" = untagged).
    private var groups: [(key: String, value: [CanvasFeedImport.Planned])] {
        Dictionary(grouping: planned, by: { $0.code ?? "" })
            .sorted { ($0.key.isEmpty ? "~" : $0.key) < ($1.key.isEmpty ? "~" : $1.key) }
            .map { ($0.key, $0.value.sorted { $0.due < $1.due }) }
    }

    private func courseGroup(code: String, items: [CanvasFeedImport.Planned]) -> some View {
        let detected = items.first?.courseID
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text(code.isEmpty ? "No course tag" : code).font(.caption.weight(.semibold))
                Text("·").foregroundStyle(.secondary)
                Text("\(items.count) item\(items.count == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                CoursePicker(courseID: binding(for: code, default: detected))
            }
            ForEach(items) { p in
                HStack(spacing: DS.Space.s) {
                    Text(p.title).font(.caption).lineLimit(1)
                    Spacer(minLength: DS.Space.s)
                    Text(p.due.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    if p.isNew { Circle().fill(Color.dsDone).frame(width: 5, height: 5) }
                }
            }
        }.dsCard()
    }

    private func binding(for code: String, default def: UUID?) -> Binding<UUID?> {
        Binding(get: { codeCourse[code] ?? def }, set: { codeCourse[code] = $0 })
    }

    // MARK: Step 3 — done

    private var doneStep: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(Color.dsDone)
            Text("Canvas connected").font(.title3.weight(.semibold))
            Text("\(result.created) added · \(result.updated) updated. This feed now refreshes automatically.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
            Button("View assignments") { state.selectedModuleID = "assignments"; dismiss() }
                .buttonStyle(.borderless)
        }.frame(maxWidth: .infinity).padding(DS.Space.xl)
    }

    // MARK: Actions

    private func fetchPreview() {
        let u = url.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { return }
        loading = true; errorMsg = ""
        Task { @MainActor in
            guard let p = await CanvasFeedImport.plan(feedURL: u, feedCourseID: nil, state: state) else {
                errorMsg = "Couldn't fetch or read that feed — double-check the URL."
                loading = false; return
            }
            planned = p; codeCourse = [:]; loading = false; phase = .preview
        }
    }

    private func runImport() {
        // Resolve per-group course overrides onto each planned item.
        let resolved: [CanvasFeedImport.Planned] = planned.map { p in
            var q = p
            if let override = codeCourse[p.code ?? ""] { q.courseID = override }
            return q
        }
        // Subscribe the feed so future launches auto-refresh (dedupe by URL).
        let u = url.trimmingCharacters(in: .whitespaces)
        if !state.data.icsFeeds.contains(where: { $0.url == u }) {
            state.data.icsFeeds.append(ICSFeed(name: name.isEmpty ? "Canvas" : name, url: u))
        }
        result = CanvasFeedImport.apply(resolved, into: state)
        phase = .done
    }
}
