import SwiftUI
import AppKit

/// `StudyBar --switch-bench` (run it with scripts/switch-bench.sh): how long switching to each
/// module takes in the window shell — the store in STUDYBAR_DATA_DIR, or the audit's seeded term
/// with SWITCH_SEED=1. Offscreen, so nothing on the screen moves. Test copy only.
enum SwitchBench {
    @MainActor
    static func run(state: AppState) -> Int32 {
        guard ModuleAudit.mayRun(env: ProcessInfo.processInfo.environment, bundleID: Bundle.main.bundleIdentifier) else {
            print("Run this from a test copy with STUDYBAR_DATA_DIR set.")
            return 1
        }
        UserDefaults.standard.set(true, forKey: "onboarded")
        if ProcessInfo.processInfo.environment["SWITCH_SEED"] == "1" { state.data = AppData(); ModuleAudit.seed(state) }
        let size = CGSize(width: 1280, height: 820)
        let model = WindowModel(moduleID: "today")
        let host = NSHostingView(rootView: RootView(surface: .window, win: model).environmentObject(state)
            .frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        win.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!

        // SWITCH_LOOP="notes,convert": switch between these for 15 s, for a profiler to watch.
        if let loop = ProcessInfo.processInfo.environment["SWITCH_LOOP"]?.split(separator: ",").map(String.init), !loop.isEmpty {
            let end = Date().addingTimeInterval(15)
            var i = 0
            while Date() < end {
                model.moduleID = loop[i % loop.count]; i += 1
                host.layoutSubtreeIfNeeded(); host.cacheDisplay(in: host.bounds, to: rep)
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            print("\(i) switches")
            return 0
        }
        print("Store: \(state.data.notes.count) notes, \(state.data.assignments.count) assignments, \(state.data.flashcards.count) cards")
        print(String(format: "%-12@ %8@ %8@ %8@", "module" as NSString, "update" as NSString, "draw" as NSString, "settle" as NSString))
        var rows: [(String, Double, Double, Double)] = []
        for round in 0..<3 {
            for m in ModuleRegistry.all {
                let t0 = CACurrentMediaTime()
                model.moduleID = m.id
                host.layoutSubtreeIfNeeded()           // SwiftUI updates the graph and lays it out
                let t1 = CACurrentMediaTime()
                host.cacheDisplay(in: host.bounds, to: rep)
                let t2 = CACurrentMediaTime()
                // What runs after the first frame — onAppear, .task, a second layout pass.
                let busy0 = CACurrentMediaTime()
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                host.layoutSubtreeIfNeeded()
                let settle = CACurrentMediaTime() - busy0 - 0.25
                if round > 0 { rows.append((m.id, (t1 - t0) * 1000, (t2 - t1) * 1000, max(0, settle) * 1000)) }
            }
        }
        for m in ModuleRegistry.all {
            let r = rows.filter { $0.0 == m.id }
            func med(_ k: KeyPath<(String, Double, Double, Double), Double>) -> Double {
                let v = r.map { $0[keyPath: k] }.sorted(); return v.isEmpty ? 0 : v[v.count / 2]
            }
            print(String(format: "%-12@ %7.1fms %7.1fms %7.1fms", m.id as NSString, med(\.1), med(\.2), med(\.3)))
        }
        win.orderOut(nil)
        return 0
    }
}
