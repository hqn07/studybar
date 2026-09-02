import SwiftUI

/// Standard module container: title bar + optional trailing accessory + content.
struct ModulePane<Content: View, Bar: View>: View {
    let title: String
    @ViewBuilder var toolbar: () -> Bar
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                toolbar()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            content()
        }
    }
}

/// Header for any pushed sub-page/editor: a Back button (popovers have no window
/// toolbar, so the system back chevron never renders — this replaces it), a title,
/// and optional trailing controls.
struct SubHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dismiss) private var dismiss

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").fontWeight(.semibold)
            }.buttonStyle(.borderless).help("Back").keyboardShortcut("[", modifiers: .command)
            Text(title).font(.headline)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

/// Inline confirmation overlay — a real dialog would open a child window and
/// dismiss the menu-bar popover, so confirmations render inside the popover.
struct ConfirmCard: View {
    let title: String
    var message: String = ""
    let confirmLabel: String
    var destructive: Bool = true
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(spacing: 12) {
                Text(title).font(.headline).multilineTextAlignment(.center)
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    Button(confirmLabel, role: destructive ? .destructive : nil, action: onConfirm)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(maxWidth: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
            .shadow(radius: 20)
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    var subtitle: String = ""
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if !subtitle.isEmpty { Text(subtitle) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Small colored dot + course name.
struct CourseChip: View {
    let course: Course?
    var body: some View {
        if let course {
            HStack(spacing: 4) {
                Circle().fill(course.color).frame(width: 7, height: 7)
                Text(course.code.isEmpty ? course.name : course.code)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Course picker menu bound to an optional UUID.
struct CoursePicker: View {
    @EnvironmentObject var state: AppState
    @Binding var courseID: UUID?
    var body: some View {
        Menu {
            Button("None") { courseID = nil }
            Divider()
            ForEach(state.data.courses) { c in
                Button {
                    courseID = c.id
                } label: {
                    Label(c.name, systemImage: courseID == c.id ? "checkmark" : "circle.fill")
                }
            }
        } label: {
            if let c = state.course(courseID) {
                CourseChip(course: c)
            } else {
                Text("Course").font(.caption).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }
}

/// Optional picker over open assignments (for logging focus time to a task).
struct AssignmentPicker: View {
    @EnvironmentObject var state: AppState
    @Binding var assignmentID: UUID?
    var body: some View {
        Menu {
            Button("None") { assignmentID = nil }
            Divider()
            ForEach(state.data.assignments.filter { $0.status != .done }) { a in
                Button {
                    assignmentID = a.id
                } label: {
                    Label(a.title.isEmpty ? "Untitled" : a.title,
                          systemImage: assignmentID == a.id ? "checkmark" : "circle")
                }
            }
        } label: {
            if let a = state.data.assignments.first(where: { $0.id == assignmentID }) {
                HStack(spacing: 4) {
                    Image(systemName: "checklist").font(.caption2)
                    Text(a.title.isEmpty ? "Task" : a.title).font(.caption).lineLimit(1)
                }.foregroundStyle(.secondary)
            } else {
                Text("Task").font(.caption).foregroundStyle(.secondary)
            }
        }.menuStyle(.borderlessButton).fixedSize()
    }
}

extension Date {
    var relativeShort: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: .now)
    }
    var dayMonth: String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: self)
    }
}
