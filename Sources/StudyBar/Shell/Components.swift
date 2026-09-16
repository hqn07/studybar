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
            // Opaque, and above the content in z-order: scrolled rows have to pass *under* a
            // solid bar. Without this the first visible row reads as sliced in half — the
            // divider alone is nearly invisible on a dark ground.
            .background(.sbSurface)
            .zIndex(1)
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
    /// The one action that fills this space. An empty screen that only explains itself leaves
    /// the reader to go find the control it was describing.
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if !subtitle.isEmpty { Text(subtitle) }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Small colored dot + course name.
struct CourseChip: View {
    let course: Course?
    /// Rows that already show the course colour — a leading dot, a coloured spine — pass
    /// `false`, otherwise the same 7pt dot is drawn twice a line apart and reads as a
    /// rendering fault rather than as identity.
    var showsDot: Bool = true
    var body: some View {
        if let course {
            HStack(spacing: 4) {
                if showsDot { Circle().fill(course.color).frame(width: 7, height: 7) }
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
            ForEach(state.data.assignments.filter { $0.isOpen }) { a in
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

/// A vertical divider that resizes the pane on its left.
///
/// Panes in this app were fixed `frame(width:)` values, so the notes list was 268pt at the
/// minimum window size (44% of it) and still 268pt at full screen. This is the split-view
/// behaviour a Mac user expects — drag to size, double-click to reset — without adopting
/// `NSSplitView`; the caller owns the number and decides whether to persist it.
struct PaneDivider: View {
    @Binding var width: CGFloat
    var range: ClosedRange<CGFloat>
    var resetTo: CGFloat
    /// The pane being sized is on the RIGHT of the divider (an inspector), so dragging left
    /// widens it. Without this the gesture ran backwards for right-hand panes.
    var inverted: Bool = false

    @State private var dragStart: CGFloat?
    @State private var cursorPushed = false

    var body: some View {
        Divider()
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 9)               // a 1pt divider is not a drag target
                    .contentShape(Rectangle())
                    .onHover { inside in
                        // Balanced by hand: an unmatched pop resets someone else's cursor.
                        if inside, !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
                        else if !inside, cursorPushed { NSCursor.pop(); cursorPushed = false }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let base = dragStart ?? width
                                if dragStart == nil { dragStart = base }
                                let delta = inverted ? -value.translation.width : value.translation.width
                                width = min(max(base + delta, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in dragStart = nil })
                    .onTapGesture(count: 2) { width = resetTo }
                    .accessibilityHidden(true)
            }
    }
}

/// The horizontal twin of `PaneDivider`: drag up/down to size the pane *below* it.
struct HeightDivider: View {
    @Binding var height: CGFloat
    var range: ClosedRange<CGFloat>
    var resetTo: CGFloat

    @State private var dragStart: CGFloat?
    @State private var cursorPushed = false

    var body: some View {
        Divider()
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside, !cursorPushed { NSCursor.resizeUpDown.push(); cursorPushed = true }
                        else if !inside, cursorPushed { NSCursor.pop(); cursorPushed = false }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let base = dragStart ?? height
                                if dragStart == nil { dragStart = base }
                                // Dragging up (negative) makes the pane below taller.
                                height = min(max(base - value.translation.height, range.lowerBound),
                                             range.upperBound)
                            }
                            .onEnded { _ in dragStart = nil })
                    .onTapGesture(count: 2) { height = resetTo }
                    .accessibilityHidden(true)
            }
    }
}

