import SwiftUI

/// Math — the module the calculator lives in.
///
/// Tabs the way Time & Focus holds Timer/Stopwatch/Focus/History, rather than one module per
/// tool: Calculator, Graph (functions or a slope field), 3D surfaces, Finance for engineering
/// economy, and Tools for lab uncertainty and linear systems. A tool that isn't built yet does
/// not get a disabled tab.
struct MathView: View {
    @ObservedObject private var model = CalculatorModel.shared
    @ObservedObject private var graph = GraphModel.shared
    @AppStorage("mathTab") private var tab = Tab.calculator.rawValue

    enum Tab: String, CaseIterable, Identifiable {
        case calculator, graph, surface, finance, tools
        var id: String { rawValue }
        var title: String {
            switch self {
            case .calculator: return "Calculator"
            case .graph:      return "Graph"
            case .surface:    return "3D"
            case .finance:    return "Finance"
            case .tools:      return "Tools"
            }
        }
    }

    private var current: Tab { Tab(rawValue: tab) ?? .calculator }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Math") {
                // The one setting that changes an answer, so it sits in the header rather than
                // in Settings: sin(30) is 0.5 in DEG and −0.988 in RAD. The graphs read the same
                // mode, so a plotted sine matches the number in the tape.
                Picker("", selection: Binding(get: { model.angle },
                                              set: { model.angle = $0 })) {
                    ForEach(MathEval.AngleMode.allCases, id: \.self) { Text($0.short).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 128)
                .help("Radians or degrees — ° always means degrees whichever is selected")
            } content: {
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .frame(maxWidth: 460)
                    .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.m)

                    switch current {
                    case .calculator: CalculatorSurface(model: model)
                    case .graph:      MathGraphView(model: graph)
                    case .surface:    MathSurfaceView(model: graph)
                    case .finance:    MathFinanceView(model: FinanceModel.shared)
                    case .tools:      MathToolsView(model: ToolsModel.shared)
                    }
                }
            }
        }
    }
}

/// The calculator itself, shared by the Math module and the summoned panel so history,
/// variables and angle mode are the same wherever you reach it from.
struct CalculatorSurface: View {
    @ObservedObject var model: CalculatorModel
    /// The panel and the menu-bar popover are narrow; the window has room for a wider keypad.
    var compact = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            tape
            Divider()
            display
            functions
            keypad
        }
        .onAppear { focused = true }
    }

    // MARK: - Tape (what you've worked out so far)

    @ViewBuilder private var tape: some View {
        if model.history.isEmpty {
            VStack(spacing: DS.Space.s) {
                Spacer(minLength: 0)
                Image(systemName: "function").font(.title2).foregroundStyle(.tertiary)
                Text("2pi · sqrt(2) · sin(30°) · 1,250 * 1.07 ^ 4")
                    .font(.caption2).foregroundStyle(.tertiary)
                Text("x = 12 keeps a value · ans reuses the last answer")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 80 : 120)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .trailing, spacing: DS.Space.s) {
                        ForEach(model.history) { e in
                            VStack(alignment: .trailing, spacing: 0) {
                                Text(e.expression)
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                Text(e.display)
                                    .font(.title3.monospacedDigit().weight(.medium)).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .id(e.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.copy(e.display) }
                            .contextMenu {
                                Button("Copy result") { model.copy(e.display) }
                                Button("Copy expression") { model.copy(e.expression) }
                                Button("Edit again") { model.input = e.expression; focused = true }
                            }
                            .help("Click to copy \(e.display)")
                        }
                    }
                    .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
                }
                .frame(minHeight: compact ? 80 : 120)
                .onChange(of: model.history.count) { _, _ in
                    if let last = model.history.last {
                        withAnimation(.snappy) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    // MARK: - Display

    private var display: some View {
        VStack(alignment: .trailing, spacing: 2) {
            // The field is the display — typed into directly, and also what the keypad writes
            // to, so keyboard and buttons are never two different input paths that disagree.
            TextField("0", text: $model.input)
                .textFieldStyle(.plain)
                .font(.system(size: compact ? 24 : 30, weight: .regular, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit { model.commit() }
                .onChange(of: model.input) { _, _ in model.error = nil }

            HStack(spacing: DS.Space.m) {
                if let e = model.error {
                    Label(e, systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange).lineLimit(1)
                } else if !model.variables.isEmpty {
                    FadingHScroll {
                        HStack(spacing: DS.Space.xs) {
                            ForEach(model.variables.sorted(by: { $0.key < $1.key }), id: \.key) { name, value in
                                Button { model.append(name) } label: {
                                    Chip("\(name) = \(MathEval.format(value))", .tag)
                                }
                                .buttonStyle(.plain)
                                .help("Insert \(name)")
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                // The running answer, so the result is visible before you commit to it.
                if let p = model.preview {
                    Text("= \(p)")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(height: 20)
        }
        .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.m).padding(.bottom, DS.Space.s)
    }

    // MARK: - Functions

    private let functionKeys = ["sin", "cos", "tan", "√", "ln", "log", "π", "e", "^", "%", "ans"]

    private var functions: some View {
        FadingHScroll {
            HStack(spacing: DS.Space.xs) {
                ForEach(functionKeys, id: \.self) { key in
                    Button { model.append(insertion(for: key)) } label: {
                        Chip(key, .key)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Space.l)
        }
        .padding(.bottom, DS.Space.s)
    }

    /// A tapped function inserts what you would type, with its bracket already open — the
    /// closing one is optional, since the parser accepts an unclosed call only as an error and
    /// the preview line shows nothing until it balances.
    private func insertion(for key: String) -> String {
        switch key {
        case "sin", "cos", "tan", "ln", "log": return key + "("
        case "√":   return "sqrt("
        case "π":   return "pi"
        default:    return key
        }
    }

    // MARK: - Keypad

    private struct Key: Identifiable {
        let id = UUID()
        let label: String
        let insert: String?          // nil = a command, handled by `tap`
        var wide = false
        var role: Role = .normal
        enum Role { case normal, operatorKey, command, equals }
    }

    private var keys: [Key] {
        [
            .init(label: "C", insert: nil, role: .command),
            .init(label: "(", insert: "("), .init(label: ")", insert: ")"),
            .init(label: "⌫", insert: nil, role: .command),
            .init(label: "÷", insert: " / ", role: .operatorKey),

            .init(label: "7", insert: "7"), .init(label: "8", insert: "8"), .init(label: "9", insert: "9"),
            .init(label: "×", insert: " * ", role: .operatorKey),
            .init(label: "^", insert: "^", role: .operatorKey),

            .init(label: "4", insert: "4"), .init(label: "5", insert: "5"), .init(label: "6", insert: "6"),
            .init(label: "−", insert: " - ", role: .operatorKey),
            .init(label: "√", insert: "sqrt(", role: .operatorKey),

            .init(label: "1", insert: "1"), .init(label: "2", insert: "2"), .init(label: "3", insert: "3"),
            .init(label: "+", insert: " + ", role: .operatorKey),
            .init(label: "°", insert: "°", role: .operatorKey),

            .init(label: "0", insert: "0"), .init(label: ".", insert: "."),
            .init(label: "ans", insert: "ans"),
            .init(label: "=", insert: nil, wide: true, role: .equals),
        ]
    }

    private var keypad: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.s), count: 5),
                  spacing: DS.Space.s) {
            ForEach(keys) { key in
                Button { tap(key) } label: {
                    Text(key.label)
                        .font(.system(size: compact ? 14 : 16, weight: key.role == .normal ? .regular : .medium,
                                      design: key.role == .normal ? .monospaced : .default))
                        .frame(maxWidth: .infinity)
                        .frame(height: compact ? 30 : 34)
                        .background(background(for: key.role),
                                    in: RoundedRectangle(cornerRadius: DS.Radius.control))
                        .foregroundStyle(key.role == .equals ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
                }
                .buttonStyle(.plain)
                .gridCellColumns(key.wide ? 2 : 1)
            }
        }
        .padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.l)
    }

    private func background(for role: Key.Role) -> AnyShapeStyle {
        switch role {
        case .equals:      return AnyShapeStyle(.tint)
        case .operatorKey: return AnyShapeStyle(.quaternary)
        case .command:     return AnyShapeStyle(.quinary)
        case .normal:      return AnyShapeStyle(.quinary)
        }
    }

    private func tap(_ key: Key) {
        if let insert = key.insert { model.append(insert); focused = true; return }
        switch key.label {
        case "C": model.input.isEmpty ? model.clear() : (model.input = "")
        case "⌫": if !model.input.isEmpty { model.input.removeLast() }
        case "=": model.commit()
        default:  break
        }
        focused = true
    }
}
