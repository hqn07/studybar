import Foundation
import Combine

/// (20) Periodic "take a break" nudges via local notifications.
@MainActor
final class BreakReminders: ObservableObject {
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "breaksEnabled"); reschedule() }
    }
    @Published var intervalMinutes: Int {
        didSet { UserDefaults.standard.set(intervalMinutes, forKey: "breaksInterval"); reschedule() }
    }
    private var timer: AnyCancellable?

    init() {
        enabled = UserDefaults.standard.bool(forKey: "breaksEnabled")
        let saved = UserDefaults.standard.integer(forKey: "breaksInterval")
        intervalMinutes = saved == 0 ? 50 : saved
        reschedule()
    }

    private func reschedule() {
        timer?.cancel()
        guard enabled, intervalMinutes > 0 else { return }
        let interval = TimeInterval(intervalMinutes * 60)
        timer = Timer.publish(every: interval, on: .main, in: .common).autoconnect()
            .sink { _ in
                Notifier.post(title: "Time for a break",
                              body: "You've been at it \(self.intervalMinutes) min. Stretch, water, eyes.")
            }
    }
}
