import SwiftUI

/// Engineering economy (EIN3354): the five time-value variables, and the amortization schedule
/// that follows from them.
///
/// Laid out as five fields rather than a wizard because that is how the relationship is taught
/// and how a calculator presents it — you fill in what you know, and the one you picked is the
/// answer. The solved field shows its result in place rather than in a separate panel, so the
/// row you are reading is the row that changed.
struct MathFinanceView: View {
    @ObservedObject var model: FinanceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                solveFor
                fields
                answer
                if !model.schedule.isEmpty { scheduleTable }
            }
            .padding(DS.Space.l)
        }
    }

    private var solveFor: some View {
        HStack(spacing: DS.Space.m) {
            Text("Solve for").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $model.unknown) {
                ForEach(TVM.Unknown.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
    }

    private var fields: some View {
        VStack(spacing: DS.Space.s) {
            row("Present value", .presentValue, $model.inputs.presentValue,
                hint: "What it is worth today. Money you receive is positive, money you pay is negative.")
            row("Payment", .payment, $model.inputs.payment, hint: "Per period, same sign convention.")
            row("Future value", .futureValue, $model.inputs.futureValue, hint: "What is left at the end.")
            row("Rate", .rate, $model.ratePercent, suffix: "% per period",
                hint: "Per period, not per year — divide an annual rate by the periods in a year.")
            row("Periods", .periods, $model.inputs.periods, hint: "How many payments, not how many years.")
            Toggle("Payments at the start of each period", isOn: $model.inputs.dueAtStart)
                .toggleStyle(.checkbox).font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func row(_ label: String, _ unknown: TVM.Unknown,
                                  _ binding: Binding<Double>, suffix: String = "",
                                  hint: String) -> some View {
        let isUnknown = model.unknown == unknown
        HStack(spacing: DS.Space.m) {
            Text(label).font(.callout).frame(width: 110, alignment: .leading)
                .foregroundStyle(isUnknown ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            if isUnknown {
                // The unknown is not typed into — showing an editable field for the value being
                // computed invites you to type an answer into the question.
                Text(model.solvedText)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: Binding(
                    get: { MathEval.format(binding.wrappedValue) },
                    set: { if let r = try? MathEval.evaluate($0) { binding.wrappedValue = r.value } }))
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospacedDigit())
                    .frame(maxWidth: 160)
                Text(suffix).font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .help(hint)
    }

    private var answer: some View {
        HStack(spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.unknown.title).font(.caption2).foregroundStyle(.secondary)
                Text(model.solvedText).font(.title2.monospacedDigit().weight(.medium))
            }
            Spacer()
            Button("Copy") { model.copyAnswer() }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private var scheduleTable: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: "Amortization", count: model.schedule.count, systemImage: "tablecells")
            HStack(spacing: 0) {
                Text("#").frame(width: 34, alignment: .trailing)
                Text("Payment").frame(maxWidth: .infinity, alignment: .trailing)
                Text("Interest").frame(maxWidth: .infinity, alignment: .trailing)
                Text("Principal").frame(maxWidth: .infinity, alignment: .trailing)
                Text("Balance").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption2).foregroundStyle(.secondary)
            ForEach(model.schedule) { p in
                HStack(spacing: 0) {
                    Text("\(p.number)").frame(width: 34, alignment: .trailing).foregroundStyle(.secondary)
                    Text(money(p.payment)).frame(maxWidth: .infinity, alignment: .trailing)
                    Text(money(p.interest)).frame(maxWidth: .infinity, alignment: .trailing)
                    Text(money(p.principal)).frame(maxWidth: .infinity, alignment: .trailing)
                    Text(money(p.balance)).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.caption.monospacedDigit())
                .padding(.vertical, 1)
            }
            HStack {
                Spacer()
                Text("Total interest \(money(model.totalInterest))")
                    .font(.caption.monospacedDigit().weight(.medium))
            }
            Button("Copy as a table") { model.copySchedule() }
                .buttonStyle(.borderless).font(.caption)
        }
    }

    private func money(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
}

/// The finance tab's state. Kept out of the view so the schedule is computed once per change
/// rather than once per redraw — 360 rows of a mortgage is not free.
@MainActor
final class FinanceModel: ObservableObject {
    static let shared = FinanceModel()

    @Published var inputs = TVM.Inputs()
    @Published var unknown = TVM.Unknown.payment

    /// Rate is stored as a fraction and shown as a percent, because every problem statement is
    /// written in percent and every formula wants the fraction.
    var ratePercent: Double {
        get { inputs.rate * 100 }
        set { inputs.rate = newValue / 100 }
    }

    var solved: Double? { TVM.solve(for: unknown, inputs) }

    var solvedText: String {
        guard let s = solved else { return "no solution" }
        switch unknown {
        case .rate:    return String(format: "%.4f%%", s * 100)
        case .periods: return MathEval.format((s * 1000).rounded() / 1000)
        default:       return String(format: "%.2f", s)
        }
    }

    /// The schedule is about a balance being paid down, and which side of zero the present value
    /// sits on is a bookkeeping convention — a student who typed the amount as negative (money
    /// paid out) still wants the table. Magnitudes, therefore, not signs.
    var schedule: [TVM.Period] {
        let n = Int(inputs.periods.rounded())
        let principal = abs(inputs.presentValue)
        guard principal > 0, n > 0, n <= 600, inputs.rate >= 0 else { return [] }
        let payment = unknown == .payment ? solved : inputs.payment
        return TVM.schedule(principal: principal, rate: inputs.rate,
                            periods: n, payment: payment.map { -abs($0) })
    }

    var totalInterest: Double { schedule.reduce(0) { $0 + $1.interest } }

    func copyAnswer() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(solvedText, forType: .string)
    }

    /// Markdown, so it pastes into a note as a real table — the reading view renders those.
    func copySchedule() {
        var out = "| # | Payment | Interest | Principal | Balance |\n|---|---|---|---|---|\n"
        for p in schedule {
            out += String(format: "| %d | %.2f | %.2f | %.2f | %.2f |\n",
                          p.number, p.payment, p.interest, p.principal, p.balance)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out, forType: .string)
    }
}
