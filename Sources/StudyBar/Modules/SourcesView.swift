import SwiftUI
import EventKit
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var cal: CalendarService
    let rangeDays: Int
    @Binding var showAssignments: Bool
    @Binding var showClasses: Bool
    @Binding var showFeeds: Bool
    let reloadFeeds: () async -> Void

    @State private var editingFeed: ICSFeed?
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Sources & Filters")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    overlays
                    macCalendars
                    feeds
                }.padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .navigationDestination(item: $editingFeed) { FeedEditor(feed: $0) }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "ics") ?? .plainText]) { result in
            if case .success(let url) = result { importICS(url) }
        }
    }

    private var overlays: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SHOW IN AGENDA").font(.caption2.bold()).foregroundStyle(.secondary)
            Toggle("Assignment due dates", isOn: $showAssignments)
            Toggle("Class schedule", isOn: $showClasses)
            Toggle("Subscribed feeds", isOn: $showFeeds)
        }
    }

    private var macCalendars: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("macOS CALENDARS").font(.caption2.bold()).foregroundStyle(.secondary)
            if !cal.authorized {
                Button("Connect Calendar") { cal.requestAndLoad(days: rangeDays) }.buttonStyle(.bordered)
                if cal.denied {
                    Text("Denied — enable in System Settings ▸ Privacy ▸ Calendars.")
                        .font(.caption2).foregroundStyle(.red)
                }
            } else if cal.calendars.isEmpty {
                Text("No calendars found.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Uncheck calendars you don't want (e.g. old or unrelated ones).")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(cal.calendars, id: \.calendarIdentifier) { c in
                    Button { cal.toggle(c, days: rangeDays) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: cal.disabled.contains(c.calendarIdentifier) ? "square" : "checkmark.square.fill")
                                .foregroundStyle(cal.disabled.contains(c.calendarIdentifier) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                            Circle().fill(c.cgColor.map { Color(cgColor: $0) } ?? .gray).frame(width: 8, height: 8)
                            Text(c.title).foregroundStyle(.primary)
                            Spacer()
                            Text(c.source.title).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var feeds: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SUBSCRIBED FEEDS").font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless).help("Import .ics file")
                Button { editingFeed = ICSFeed() } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
            }
            NavigationLink { ConnectCanvasView() } label: {
                Label("Connect Canvas (no API needed)", systemImage: "link.badge.plus")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).controlSize(.large)
            Text("Guided setup imports your assignment due dates. Or add a raw feed with ＋.")
                .font(.caption2).foregroundStyle(.secondary)
            if state.data.icsFeeds.isEmpty {
                Text("No feeds yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(state.data.icsFeeds) { feed in
                    Button { editingFeed = feed } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.up.forward").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(feed.name.isEmpty ? "Feed" : feed.name).fontWeight(.medium)
                                Text(feed.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            CourseChip(course: state.course(feed.courseID))
                            Image(systemName: "pencil").foregroundStyle(.secondary).font(.caption)
                        }
                        .padding(9).background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func importICS(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let events = ICSParser.parse(text).filter { ($0.start ?? .distantPast) > Date().addingTimeInterval(-86400) }
        for e in events {
            let exists = state.data.assignments.contains { $0.title == e.title && $0.due == e.start }
            if !exists {
                state.data.assignments.append(Assignment(title: e.title, due: e.start, link: e.url, notes: e.location))
            }
        }
    }
}
