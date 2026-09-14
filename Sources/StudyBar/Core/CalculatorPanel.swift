import AppKit
import SwiftUI

/// The calculator as a SUMMONED floating panel — the same shape as the assistant and the command
/// palette, and for the same reason: you reach for a calculator *while* doing something else, so
/// it floats over the work instead of being a place you navigate to and back from.
///
/// This is not the retired Equation module returning. That one rendered LaTeX, which Notes
/// already does. This one computes.
@MainActor
final class CalculatorPanel {
    static let shared = CalculatorPanel()
    private var panel: NSPanel?
    /// The module and the panel share one calculator, so history, variables and angle mode are
    /// the same thing wherever you reached it from.
    var model: CalculatorModel { .shared }

    var isShown: Bool { panel != nil }
    func toggle() { isShown ? close() : show() }

    func show(seed: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        if let seed, !seed.isEmpty { model.input = seed }
        if panel == nil {
            let accent = Color(hex: UserDefaults.standard.string(forKey: "accentHex") ?? "") ?? .accentColor
            let view = CalculatorPanelView(model: model, close: { CalculatorPanel.shared.close() })
                .tint(accent)
            let hosting = NSHostingView(rootView: view)
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            // All three, not two: a titled panel still draws the close button, which showed as
            // a stray grey circle above the header.
            p.standardWindowButton(.closeButton)?.isHidden = true
            p.standardWindowButton(.miniaturizeButton)?.isHidden = true
            p.standardWindowButton(.zoomButton)?.isHidden = true
            p.contentView = hosting
            p.setContentSize(NSSize(width: 380, height: 460))
            positionTopTrailing(p)
            panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.close(); panel = nil }

    private func positionTopTrailing(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: sf.maxX - size.width - 40, y: sf.maxY - size.height - 60))
    }
}

/// Input, history and variables. Owned by the panel, not the view, so closing the panel doesn't
/// throw away what you were working out.
@MainActor
final class CalculatorModel: ObservableObject {
    static let shared = CalculatorModel()

    struct Entry: Identifiable {
        let id = UUID()
        let expression: String
        let value: Double
        var display: String { MathEval.format(value) }
    }

    @Published var input = ""
    @Published private(set) var history: [Entry] = []
    /// Everything the user has assigned, plus `ans`. Assignments are how a multi-step problem
    /// gets done without retyping intermediate numbers.
    @Published private(set) var variables: [String: Double] = [:]
    @AppStorage("calcAngleMode") var angleRaw = MathEval.AngleMode.radians.rawValue

    var angle: MathEval.AngleMode {
        get { MathEval.AngleMode(rawValue: angleRaw) ?? .radians }
        set { angleRaw = newValue.rawValue }
    }

    /// The running result shown under the field while typing — nil when the line isn't valid
    /// yet, which is most keystrokes, so a half-typed expression shows nothing rather than an
    /// error that flashes at every character.
    var preview: String? {
        let source = MathEval.assignment(in: input)?.expression ?? input
        guard !source.trimmingCharacters(in: .whitespaces).isEmpty,
              let r = try? MathEval.evaluate(source, variables: variables, angle: angle) else { return nil }
        return r.display
    }

    /// The error for the current line, shown only once the user commits — see `preview`.
    @Published var error: String?

    func commit() {
        let line = input.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        let assignment = MathEval.assignment(in: line)
        let source = assignment?.expression ?? line
        do {
            let r = try MathEval.evaluate(source, variables: variables, angle: angle)
            if let a = assignment { variables[a.name] = r.value }
            variables["ans"] = r.value
            history.append(Entry(expression: assignment.map { "\($0.name) = \($0.expression)" } ?? line,
                                 value: r.value))
            input = ""
            error = nil
        } catch let e as MathEval.EvalError {
            error = e.message
        } catch {
            self.error = "Couldn't calculate that"
        }
    }

    /// Keypad and chip taps write through the same field the keyboard does, so the two input
    /// paths can never disagree about what is being calculated.
    func append(_ text: String) {
        input += text
        error = nil
    }

    func clear() {
        history.removeAll()
        variables.removeAll()
        input = ""
        error = nil
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct CalculatorPanelView: View {
    @ObservedObject var model: CalculatorModel
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "function").foregroundStyle(.tint)
                Text("Calculator").font(.callout.weight(.semibold))
                Spacer()
                Picker("", selection: Binding(get: { model.angle }, set: { model.angle = $0 })) {
                    ForEach(MathEval.AngleMode.allCases, id: \.self) { Text($0.short).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 108)
                Button { close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
            Divider()
            CalculatorSurface(model: model, compact: true)
        }
        .frame(minWidth: 300, minHeight: 380)
        .background(.regularMaterial)
    }
}
