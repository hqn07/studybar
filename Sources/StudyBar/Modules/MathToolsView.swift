import SwiftUI

/// The two tools that don't need a plot: propagating lab uncertainty, and solving a linear
/// system. Stacked in one scrolling tab rather than given a tab each — neither is big enough to
/// be a destination, and both are reached for in the middle of something else.
struct MathToolsView: View {
    @ObservedObject var model: ToolsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                uncertainty
                Divider()
                linearSystem
            }
            .padding(DS.Space.l)
        }
    }

    // MARK: - Uncertainty

    private var uncertainty: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: "Uncertainty", systemImage: "plusminus")
            Text("Every measurement's uncertainty, carried through the formula in quadrature.")
                .font(.caption2).foregroundStyle(.secondary)

            HStack(spacing: DS.Space.m) {
                Text("f =").font(.callout.monospaced()).foregroundStyle(.secondary)
                TextField("a formula in your variables", text: $model.formula)
                    .textFieldStyle(.plain).font(.callout.monospaced())
            }

            ForEach($model.variables) { $v in
                HStack(spacing: DS.Space.m) {
                    TextField("name", text: $v.name)
                        .textFieldStyle(.roundedBorder).font(.caption.monospaced()).frame(width: 64)
                    NumberField(label: "=", value: $v.value, width: 84)
                    NumberField(label: "±", value: $v.uncertainty, width: 84)
                    if let share = model.share(of: v.name) {
                        // Which measurement to improve is the real question a lab asks; the bar
                        // answers it without arithmetic.
                        HStack(spacing: DS.Space.xs) {
                            ProgressView(value: share).frame(width: 60)
                            Text("\(Int((share * 100).rounded()))%")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .leading)
                        }
                        .help("Share of the total uncertainty that comes from \(v.name)")
                    }
                    Spacer()
                    Button { model.removeVariable(v.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            Button { model.addVariable() } label: { Label("Add a measurement", systemImage: "plus") }
                .buttonStyle(.borderless).font(.caption)

            if let r = model.uncertaintyResult {
                HStack(spacing: DS.Space.l) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Result").font(.caption2).foregroundStyle(.secondary)
                        Text(Uncertainty.formatted(r)).font(.title3.monospacedDigit().weight(.medium))
                    }
                    if r.relative.isFinite {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Relative").font(.caption2).foregroundStyle(.secondary)
                            Text(String(format: "%.2f%%", r.relative * 100))
                                .font(.callout.monospacedDigit())
                        }
                    }
                    Spacer()
                    Button("Copy") { model.copy(Uncertainty.formatted(r)) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(DS.Space.l).frame(maxWidth: .infinity, alignment: .leading).dsCard()
            } else if !model.formula.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Give every name in the formula a value.")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Linear system

    private var linearSystem: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: "Linear system", systemImage: "square.grid.3x3")
            Text("One row per line. Put the right-hand side after a “|” to solve A x = b.")
                .font(.caption2).foregroundStyle(.secondary)

            TextEditor(text: $model.matrixText)
                .font(.callout.monospaced())
                .frame(height: 78)
                .padding(DS.Space.s)
                .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))

            if let answer = model.matrixAnswer {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    if let solution = answer.solution {
                        HStack(spacing: DS.Space.m) {
                            Text("x =").font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(solution.enumerated()), id: \.offset) { i, v in
                                Chip("x\(i + 1) = \(trim(v))", .tag)
                            }
                        }
                    }
                    HStack(spacing: DS.Space.l) {
                        if let det = answer.determinant {
                            Text("det = \(trim(det))").font(.caption.monospacedDigit())
                        }
                        if answer.singular {
                            Text("Singular — no unique solution")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        if answer.inverse != nil {
                            Button("Copy inverse") { model.copyInverse() }
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                    if let inverse = answer.inverse {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Inverse").font(.caption2).foregroundStyle(.secondary)
                            ForEach(Array(inverse.enumerated()), id: \.offset) { _, row in
                                Text(row.map { trim($0) }.joined(separator: "   "))
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                }
                .padding(DS.Space.l).frame(maxWidth: .infinity, alignment: .leading).dsCard()
            } else if !model.matrixText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Every row needs the same number of entries.")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    /// Numbers a solver produces are 2.9999999999999996 as often as 3; four decimals is past
    /// what any coursework needs and short of where the noise lives.
    private func trim(_ v: Double) -> String {
        MathEval.format((v * 10000).rounded() / 10000)
    }
}

@MainActor
final class ToolsModel: ObservableObject {
    static let shared = ToolsModel()

    // Uncertainty — seeded with the worked example every lab manual opens with.
    @Published var formula = "w * h"
    @Published var variables: [Uncertainty.Variable] = [
        .init(name: "w", value: 5, uncertainty: 0.1),
        .init(name: "h", value: 3, uncertainty: 0.2),
    ]
    @Published var matrixText = "2 1 | 5\n1 3 | 10"

    var uncertaintyResult: Uncertainty.Result? {
        Uncertainty.propagate(formula, variables: variables, angle: CalculatorModel.shared.angle)
    }

    func share(of name: String) -> Double? {
        uncertaintyResult?.contributions.first { $0.name == name }?.share
    }

    func addVariable() {
        variables.append(.init(name: "", value: 0, uncertainty: 0))
    }
    func removeVariable(_ id: UUID) {
        variables.removeAll { $0.id == id }
    }

    struct MatrixAnswer {
        var solution: [Double]?
        var determinant: Double?
        var inverse: [[Double]]?
        var singular: Bool
    }

    var matrixAnswer: MatrixAnswer? {
        guard let parsed = LinearAlgebra.parse(matrixText) else { return nil }
        let square = parsed.a.count == parsed.a[0].count
        let det = square ? LinearAlgebra.determinant(parsed.a) : nil
        let singular = det.map { abs($0) < 1e-12 } ?? false
        return MatrixAnswer(
            solution: parsed.b.flatMap { LinearAlgebra.solve(parsed.a, $0) },
            determinant: det,
            inverse: singular ? nil : (square ? LinearAlgebra.inverse(parsed.a) : nil),
            singular: singular)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyInverse() {
        guard let inverse = matrixAnswer?.inverse else { return }
        copy(inverse.map { row in row.map { MathEval.format((($0) * 10000).rounded() / 10000) }
            .joined(separator: " ") }.joined(separator: "\n"))
    }
}
