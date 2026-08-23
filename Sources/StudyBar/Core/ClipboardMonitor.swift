import AppKit
import Combine

/// (5) Polls the system pasteboard and records text copies into AppData.clips.
@MainActor
final class ClipboardMonitor {
    private weak var state: AppState?
    private var lastChange: Int
    private var timer: AnyCancellable?
    private let maxItems = 60

    var enabled = true
    var userPaused = false

    init(state: AppState) {
        self.state = state
        lastChange = NSPasteboard.general.changeCount
    }

    func start() {
        timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.poll() }
    }

    func stop() { timer?.cancel() }

    private func poll() {
        guard enabled, !userPaused, let state else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        // Skip secrets: password managers mark the pasteboard concealed/transient.
        let types = pb.types ?? []
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            || types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) { return }
        guard let str = pb.string(forType: .string) else { return }
        let text = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Skip exact duplicate of the newest unpinned entry.
        if state.data.clips.first(where: { !$0.pinned })?.text == text { return }
        // Remove older identical copies.
        state.data.clips.removeAll { $0.text == text && !$0.pinned }
        state.data.clips.insert(ClipItem(text: text), at: 0)

        // Trim unpinned overflow.
        let unpinned = state.data.clips.filter { !$0.pinned }
        if unpinned.count > maxItems, let drop = unpinned.last {
            state.data.clips.removeAll { $0.id == drop.id }
        }
    }
}
