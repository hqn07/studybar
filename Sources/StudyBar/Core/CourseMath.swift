import Foundation

/// The tools that exist because of what is actually on the timetable: engineering economy
/// (EIN3354), differential equations (MAP2302) and lab work (PHY2049). Each is a small piece of
/// numerics the coursework uses constantly and that is tedious and error-prone by hand.
///
/// All of it is deliberately pure — no views, no state — so the arithmetic can be checked against
/// worked examples with `--course-selftest` rather than by squinting at a screen.

// MARK: - Time value of money (EIN3354)

/// The five-variable relationship every engineering-economy problem is a rearrangement of:
///
///     PV·(1+i)^n + PMT·[((1+i)^n − 1) / i] + FV = 0
///
/// Four knowns give the fifth. Rate is the exception — it can't be isolated, so it is found by
/// bisection, which is slower than Newton's method and cannot diverge on the inputs a student
/// types (a 0% rate, a negative payment, a term of half a period).
enum TVM {
    /// Which unknown to solve for.
    enum Unknown: String, CaseIterable, Identifiable {
        case presentValue, futureValue, payment, rate, periods
        var id: String { rawValue }
        var title: String {
            switch self {
            case .presentValue: return "Present value"
            case .futureValue:  return "Future value"
            case .payment:      return "Payment"
            case .rate:         return "Rate"
            case .periods:      return "Periods"
            }
        }
    }

    struct Inputs {
        var presentValue: Double = -1000
        var futureValue: Double = 0
        var payment: Double = 0
        /// Per period, as a fraction: 0.07 is 7%.
        var rate: Double = 0.07
        var periods: Double = 10
        /// Payments at the end of each period (ordinary annuity) unless set.
        var dueAtStart = false
    }

    /// The cash-flow identity, written so its value is zero when the five agree. Everything else
    /// here is a way of hunting for that zero.
    static func residual(_ v: Inputs) -> Double {
        let growth = pow(1 + v.rate, v.periods)
        let annuity: Double
        if abs(v.rate) < 1e-12 {
            // A 0% rate is not a degenerate case a student won't type — it is how you sanity-check
            // a schedule. The annuity factor's limit as i → 0 is simply n.
            annuity = v.periods
        } else {
            annuity = (growth - 1) / v.rate * (v.dueAtStart ? (1 + v.rate) : 1)
        }
        return v.presentValue * growth + v.payment * annuity + v.futureValue
    }

    static func solve(for unknown: Unknown, _ v: Inputs) -> Double? {
        var input = v
        switch unknown {
        case .futureValue:
            input.futureValue = 0
            return -residual(input)

        case .presentValue:
            input.presentValue = 0
            let growth = pow(1 + v.rate, v.periods)
            guard growth != 0 else { return nil }
            return -residual(input) / growth

        case .payment:
            input.payment = 0
            let growth = pow(1 + v.rate, v.periods)
            let annuity = abs(v.rate) < 1e-12
                ? v.periods
                : (growth - 1) / v.rate * (v.dueAtStart ? (1 + v.rate) : 1)
            guard annuity != 0 else { return nil }
            return -residual(input) / annuity

        case .periods:
            // Bisection on n, for the same reason as rate: the closed form needs logs of
            // quantities that go negative for perfectly ordinary inputs.
            return bisect(lo: 1e-6, hi: 1200) { n in
                var t = v; t.periods = n; return residual(t)
            }

        case .rate:
            return bisect(lo: -0.9999, hi: 10) { i in
                var t = v; t.rate = i; return residual(t)
            }
        }
    }

    /// Bisection with a bracket check. Returns nil rather than a plausible-looking wrong number
    /// when the answer isn't inside the bracket — an unsolvable set of inputs should say so.
    static func bisect(lo: Double, hi: Double, tolerance: Double = 1e-10,
                       _ f: (Double) -> Double) -> Double? {
        var a = lo, b = hi
        var fa = f(a), fb = f(b)
        guard fa.isFinite, fb.isFinite else { return nil }
        guard fa == 0 || fb == 0 || (fa < 0) != (fb < 0) else { return nil }
        if fa == 0 { return a }
        if fb == 0 { return b }
        for _ in 0..<200 {
            let mid = (a + b) / 2
            let fm = f(mid)
            if !fm.isFinite { return nil }
            if abs(b - a) < tolerance || fm == 0 { return mid }
            if (fm < 0) != (fa < 0) { b = mid; fb = fm } else { a = mid; fa = fm }
            _ = fb
        }
        return (a + b) / 2
    }

    struct Period: Identifiable {
        var id: Int { number }
        let number: Int
        let payment: Double
        let interest: Double
        let principal: Double
        let balance: Double
    }

    /// The amortization schedule — the table the coursework asks for, and the one the user has
    /// been keeping by hand in a note.
    ///
    /// The final payment is adjusted to clear the balance exactly. Rounding each period to cents
    /// otherwise leaves a few cents outstanding at the end, which is both wrong and the first
    /// thing a marker looks at.
    static func schedule(principal: Double, rate: Double, periods: Int, payment: Double? = nil) -> [Period] {
        guard periods > 0, principal != 0 else { return [] }
        var v = Inputs(presentValue: principal, futureValue: 0, payment: 0,
                       rate: rate, periods: Double(periods))
        let pmt = payment ?? solve(for: .payment, v) ?? 0
        v.payment = pmt
        var balance = principal
        var rows: [Period] = []
        for n in 1...periods {
            let interest = balance * rate
            var pay = -pmt
            var principalPart = pay - interest
            if n == periods || principalPart > balance {
                principalPart = balance
                pay = principalPart + interest
            }
            balance -= principalPart
            rows.append(Period(number: n, payment: pay, interest: interest,
                               principal: principalPart, balance: max(0, balance)))
        }
        return rows
    }
}

// MARK: - Linear systems (MAP2302, and anything with a circuit in it)

/// Gaussian elimination with partial pivoting. Hand-written rather than LAPACK: Accelerate's
/// LAPACK signatures changed with the new SDK, and a 20-line solver that is read once beats a
/// build-configuration problem that returns every time the SDK moves.
enum LinearAlgebra {

    /// Solve `A x = b`. Nil when the matrix is singular — a system with no unique solution must
    /// say so rather than return the numerical noise that division by a tiny pivot produces.
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = a.count
        guard n > 0, b.count == n, a.allSatisfy({ $0.count == n }) else { return nil }
        var m = a
        var rhs = b
        for col in 0..<n {
            // Partial pivoting: the largest available pivot, which keeps the arithmetic stable.
            var pivotRow = col
            for row in (col + 1)..<n where abs(m[row][col]) > abs(m[pivotRow][col]) { pivotRow = row }
            guard abs(m[pivotRow][col]) > 1e-12 else { return nil }
            if pivotRow != col { m.swapAt(col, pivotRow); rhs.swapAt(col, pivotRow) }
            let pivot = m[col][col]
            for row in (col + 1)..<n {
                let factor = m[row][col] / pivot
                guard factor != 0 else { continue }
                for k in col..<n { m[row][k] -= factor * m[col][k] }
                rhs[row] -= factor * rhs[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = rhs[row]
            for k in (row + 1)..<n { sum -= m[row][k] * x[k] }
            x[row] = sum / m[row][row]
        }
        return x.allSatisfy { $0.isFinite } ? x : nil
    }

    static func determinant(_ a: [[Double]]) -> Double? {
        let n = a.count
        guard n > 0, a.allSatisfy({ $0.count == n }) else { return nil }
        var m = a
        var det = 1.0
        for col in 0..<n {
            var pivotRow = col
            for row in (col + 1)..<n where abs(m[row][col]) > abs(m[pivotRow][col]) { pivotRow = row }
            if abs(m[pivotRow][col]) < 1e-14 { return 0 }
            if pivotRow != col { m.swapAt(col, pivotRow); det = -det }
            det *= m[col][col]
            for row in (col + 1)..<n {
                let factor = m[row][col] / m[col][col]
                for k in col..<n { m[row][k] -= factor * m[col][k] }
            }
        }
        return det
    }

    /// The inverse, by solving `A x = e` for each basis vector. Nil when singular.
    static func inverse(_ a: [[Double]]) -> [[Double]]? {
        let n = a.count
        guard n > 0, a.allSatisfy({ $0.count == n }) else { return nil }
        var columns: [[Double]] = []
        for i in 0..<n {
            var e = [Double](repeating: 0, count: n)
            e[i] = 1
            guard let col = solve(a, e) else { return nil }
            columns.append(col)
        }
        // `columns[i]` is the i-th column of the inverse; transpose into rows.
        return (0..<n).map { row in (0..<n).map { col in columns[col][row] } }
    }

    /// Parse the grid a student types: rows on lines, entries separated by spaces or commas, an
    /// optional `|` marking the right-hand side.
    static func parse(_ text: String) -> (a: [[Double]], b: [Double]?)? {
        var rows: [[Double]] = []
        var rhs: [Double] = []
        var sawBar = false
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let halves = trimmed.components(separatedBy: "|")
            if halves.count > 1 { sawBar = true }
            func numbers(_ s: String) -> [Double] {
                s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" })
                    .compactMap { Double($0) ?? (try? MathEval.evaluate(String($0)).value) }
            }
            let left = numbers(halves[0])
            guard !left.isEmpty else { return nil }
            rows.append(left)
            if halves.count > 1, let value = numbers(halves[1]).first { rhs.append(value) }
        }
        guard !rows.isEmpty, rows.allSatisfy({ $0.count == rows[0].count }) else { return nil }
        return (rows, sawBar && rhs.count == rows.count ? rhs : nil)
    }
}

// MARK: - Uncertainty (PHY2049 labs)

/// Propagating measurement uncertainty through a formula, which is what every lab report needs
/// and what the standard formula sheet makes tedious:
///
///     u_f = sqrt( Σ (∂f/∂xᵢ · uᵢ)² )
///
/// The partial derivatives are taken numerically on the expression tree, so it works for whatever
/// the student types rather than for a fixed list of formula shapes. Step size is scaled to each
/// variable — a fixed h is either noise on a value of 1e-6 or meaningless on a value of 1e6.
enum Uncertainty {
    struct Variable: Identifiable, Equatable {
        var id = UUID()
        var name: String
        var value: Double
        var uncertainty: Double
    }

    struct Result {
        let value: Double
        let uncertainty: Double
        /// Each variable's contribution to the total, as a fraction — which measurement to
        /// improve is usually the real question, and the table answers it.
        let contributions: [(name: String, share: Double)]
        var relative: Double { value == 0 ? .nan : abs(uncertainty / value) }
    }

    static func propagate(_ expression: String, variables: [Variable],
                          angle: MathEval.AngleMode = .radians) -> Result? {
        guard let node = try? MathEval.parse(expression) else { return nil }
        var values: [String: Double] = [:]
        for v in variables { values[v.name] = v.value }
        guard let base = try? node.eval(variables: values, angle: angle), base.isFinite else { return nil }

        var squares: [(String, Double)] = []
        for v in variables where v.uncertainty != 0 {
            let h = max(abs(v.value) * 1e-6, 1e-9)
            var up = values, down = values
            up[v.name] = v.value + h
            down[v.name] = v.value - h
            guard let fUp = try? node.eval(variables: up, angle: angle),
                  let fDown = try? node.eval(variables: down, angle: angle),
                  fUp.isFinite, fDown.isFinite else { continue }
            let partial = (fUp - fDown) / (2 * h)
            let term = partial * v.uncertainty
            squares.append((v.name, term * term))
        }
        let total = squares.reduce(0) { $0 + $1.1 }
        let contributions = squares.map { (name: $0.0, share: total > 0 ? $0.1 / total : 0) }
            .sorted { $0.share > $1.share }
        return Result(value: base, uncertainty: total.squareRoot(), contributions: contributions)
    }

    /// How a lab report writes it: the uncertainty to one significant figure, and the value to
    /// the same decimal place.
    static func formatted(_ r: Result) -> String {
        guard r.uncertainty > 0, r.uncertainty.isFinite else { return MathEval.format(r.value) }
        let exponent = floor(log10(r.uncertainty))
        let factor = pow(10, -exponent)
        let roundedUncertainty = (r.uncertainty * factor).rounded() / factor
        let decimals = max(0, Int(-exponent))
        return String(format: "%.\(min(9, decimals))f ± %.\(min(9, decimals))f", r.value, roundedUncertainty)
    }
}

// MARK: - Differential equations (MAP2302)

/// A slope field and a numerical solution for `y' = f(x, y)`.
///
/// MAP2302 spends its first half on equations whose closed-form solution is the point of the
/// exercise, and the slope field is how the shape of that solution is seen before the algebra.
/// Fourth-order Runge-Kutta rather than Euler: Euler visibly drifts off a circle on the sort of
/// step a screen-sized plot uses, and a student comparing the curve against their own answer
/// would be comparing against the method's error.
enum ODE {

    /// A short line segment at each grid point, in plane coordinates, with its slope clamped so a
    /// near-vertical field doesn't draw a full-height stroke through the plot.
    static func slopeField(_ node: MathEval.Node, viewport v: Viewport, columns: Int = 22, rows: Int = 14,
                           angle: MathEval.AngleMode = .radians) -> [(from: CGPoint, to: CGPoint)] {
        guard columns > 1, rows > 1 else { return [] }
        var out: [(CGPoint, CGPoint)] = []
        let dx = v.width / Double(columns)
        let dy = v.height / Double(rows)
        let length = min(dx, dy) * 0.42
        for i in 0...columns {
            let x = v.xMin + Double(i) * dx
            for j in 0...rows {
                let y = v.yMin + Double(j) * dy
                guard let slope = try? node.eval(variables: ["x": x, "y": y], angle: angle),
                      slope.isFinite else { continue }
                // Normalize so every tick is the same length: the field shows direction, and a
                // steep region drawn with long strokes reads as "more" rather than "steeper".
                let norm = (1 + slope * slope).squareRoot()
                let ux = length / norm, uy = length * slope / norm
                out.append((CGPoint(x: x - ux, y: y - uy), CGPoint(x: x + ux, y: y + uy)))
            }
        }
        return out
    }

    /// One RK4 step.
    static func step(_ node: MathEval.Node, x: Double, y: Double, h: Double,
                     angle: MathEval.AngleMode) -> Double? {
        func f(_ x: Double, _ y: Double) -> Double? {
            let v = (try? node.eval(variables: ["x": x, "y": y], angle: angle)) ?? .nan
            return v.isFinite ? v : nil
        }
        guard let k1 = f(x, y),
              let k2 = f(x + h / 2, y + h * k1 / 2),
              let k3 = f(x + h / 2, y + h * k2 / 2),
              let k4 = f(x + h, y + h * k3) else { return nil }
        let next = y + h * (k1 + 2 * k2 + 2 * k3 + k4) / 6
        return next.isFinite ? next : nil
    }

    /// The solution curve through (x0, y0), integrated both ways so the initial condition sits in
    /// the middle of what is drawn rather than at its left edge.
    static func solution(_ node: MathEval.Node, from x0: Double, y0: Double, viewport v: Viewport,
                         steps: Int = 400, angle: MathEval.AngleMode = .radians) -> [CGPoint] {
        let h = v.width / Double(steps)
        var forward: [CGPoint] = [CGPoint(x: x0, y: y0)]
        var x = x0, y = y0
        while x < v.xMax {
            guard let next = step(node, x: x, y: y, h: h, angle: angle) else { break }
            // Stop when the solution leaves the window by a wide margin: it has either blown up
            // or is no longer the thing being looked at.
            guard abs(next) < 1e6 else { break }
            x += h; y = next
            forward.append(CGPoint(x: x, y: y))
        }
        var backward: [CGPoint] = []
        x = x0; y = y0
        while x > v.xMin {
            guard let next = step(node, x: x, y: y, h: -h, angle: angle) else { break }
            guard abs(next) < 1e6 else { break }
            x -= h; y = next
            backward.append(CGPoint(x: x, y: y))
        }
        return backward.reversed() + forward
    }
}

// MARK: - Self-test (`StudyBar --course-selftest`)

enum CourseMathSelfTest {
    @MainActor
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ got: String, _ want: String) {
            let ok = got == want
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(name)")
            if !ok { print("       want \(want)   got \(got)") }
        }
        /// Compare to a number of decimals, since these are numerical answers, not exact ones.
        func near(_ name: String, _ got: Double?, _ want: Double, _ places: Int = 2) {
            guard let got else { failures += 1; print("  FAIL \(name): no answer"); return }
            check(name, String(format: "%.\(places)f", got), String(format: "%.\(places)f", want))
        }

        print("Course-math self-test")

        // TVM, against textbook answers rather than against this implementation.
        // $1,000 at 7% for 10 years compounds to $1,967.15.
        near("future value of a lump sum",
             TVM.solve(for: .futureValue, TVM.Inputs(presentValue: -1000, futureValue: 0, payment: 0,
                                                     rate: 0.07, periods: 10)), 1967.15)
        // The present value of that same future amount is where it started.
        near("present value round-trips",
             TVM.solve(for: .presentValue, TVM.Inputs(presentValue: 0, futureValue: 1967.15, payment: 0,
                                                      rate: 0.07, periods: 10)), -1000.00)
        // A $200,000 mortgage at 0.5%/month for 360 months pays $1,199.10 a month.
        near("mortgage payment",
             TVM.solve(for: .payment, TVM.Inputs(presentValue: 200_000, futureValue: 0, payment: 0,
                                                 rate: 0.005, periods: 360)), -1199.10)
        // $100/period for 10 periods at 6% is worth $736.01 today.
        near("present value of an annuity",
             TVM.solve(for: .presentValue, TVM.Inputs(presentValue: 0, futureValue: 0, payment: 100,
                                                      rate: 0.06, periods: 10)), -736.01)
        // An annuity due is one period's interest more valuable.
        near("annuity due is worth more",
             TVM.solve(for: .presentValue, TVM.Inputs(presentValue: 0, futureValue: 0, payment: 100,
                                                      rate: 0.06, periods: 10, dueAtStart: true)), -780.17)
        // Rate and periods come back by bisection.
        near("rate recovered from the other four",
             TVM.solve(for: .rate, TVM.Inputs(presentValue: -1000, futureValue: 1967.15, payment: 0,
                                              rate: 0, periods: 10)), 0.07, 4)
        near("periods recovered",
             TVM.solve(for: .periods, TVM.Inputs(presentValue: -1000, futureValue: 1967.15, payment: 0,
                                                 rate: 0.07, periods: 0)), 10.00)
        // A 0% rate is a sanity check a student actually types, not a degenerate case.
        near("zero rate is linear",
             TVM.solve(for: .futureValue, TVM.Inputs(presentValue: -100, futureValue: 0, payment: -10,
                                                     rate: 0, periods: 10)), 200.00)
        check("an unsolvable set says so",
              TVM.solve(for: .rate, TVM.Inputs(presentValue: 100, futureValue: 100, payment: 100,
                                               rate: 0, periods: 10)) == nil ? "nil" : "value", "nil")

        // Amortization: the table has to close out at exactly zero.
        let schedule = TVM.schedule(principal: 1000, rate: 0.01, periods: 12)
        check("a row per period", "\(schedule.count)", "12")
        near("the balance clears", schedule.last?.balance, 0, 6)
        near("first period's interest", schedule.first?.interest, 10.00)
        let totalPrincipal = schedule.reduce(0) { $0 + $1.principal }
        near("principal sums to the loan", totalPrincipal, 1000.00, 6)

        // Linear systems.
        near("2x2 solve, first unknown", LinearAlgebra.solve([[2, 1], [1, 3]], [5, 10])?.first, 1.00)
        near("2x2 solve, second unknown", LinearAlgebra.solve([[2, 1], [1, 3]], [5, 10])?.last, 3.00)
        // A system needing a pivot swap: the naive algorithm divides by zero here.
        near("pivoting handles a zero leading entry",
             LinearAlgebra.solve([[0, 1], [1, 0]], [2, 3])?.first, 3.00)
        check("a singular system returns nil",
              LinearAlgebra.solve([[1, 2], [2, 4]], [3, 6]) == nil ? "nil" : "value", "nil")
        near("determinant of a 3x3",
             LinearAlgebra.determinant([[6, 1, 1], [4, -2, 5], [2, 8, 7]]), -306.00)
        near("determinant of a singular matrix",
             LinearAlgebra.determinant([[1, 2], [2, 4]]), 0.00)
        if let inv = LinearAlgebra.inverse([[4, 7], [2, 6]]) {
            near("inverse [0][0]", inv[0][0], 0.6, 4)
            near("inverse [0][1]", inv[0][1], -0.7, 4)
            near("inverse [1][0]", inv[1][0], -0.2, 4)
            near("inverse [1][1]", inv[1][1], 0.4, 4)
        } else { failures += 1; print("  FAIL inverse computes") }

        // The grid a student types.
        if let parsed = LinearAlgebra.parse("2 1 | 5\n1 3 | 10") {
            check("parsed a 2x2", "\(parsed.a.count)x\(parsed.a[0].count)", "2x2")
            check("parsed the right-hand side", parsed.b.map { "\($0.count)" } ?? "nil", "2")
        } else { failures += 1; print("  FAIL matrix parses") }
        check("a ragged grid is refused",
              LinearAlgebra.parse("1 2 3\n4 5") == nil ? "nil" : "value", "nil")
        check("commas work as separators",
              LinearAlgebra.parse("1,2\n3,4").map { "\($0.a[1][1])" } ?? "nil", "4.0")

        // Uncertainty. A rectangle's area: the classic worked example.
        // 5.0 ± 0.1 by 3.0 ± 0.2 → 15.0 ± 1.04.
        let area = Uncertainty.propagate("w * h", variables: [
            .init(name: "w", value: 5, uncertainty: 0.1),
            .init(name: "h", value: 3, uncertainty: 0.2),
        ])
        near("propagated value", area?.value, 15.00)
        near("propagated uncertainty", area?.uncertainty, 1.0440, 4)
        check("the bigger contributor is named first", area?.contributions.first?.name ?? "", "h")
        // Adding in quadrature: 3 ± 0.3 plus 4 ± 0.4 is 7 ± 0.5.
        let sum = Uncertainty.propagate("a + b", variables: [
            .init(name: "a", value: 3, uncertainty: 0.3),
            .init(name: "b", value: 4, uncertainty: 0.4),
        ])
        near("quadrature sum", sum?.uncertainty, 0.5, 4)
        // A variable with no stated uncertainty contributes nothing.
        let exact = Uncertainty.propagate("2 * r", variables: [.init(name: "r", value: 5, uncertainty: 0)])
        near("an exact value adds no uncertainty", exact?.uncertainty, 0, 6)
        // Lab convention: the uncertainty to one significant figure, the value to the same
        // decimal place. 1.044 rounds to 1, so the value is stated to the units place too.
        check("report format rounds the uncertainty to one figure",
              Uncertainty.formatted(Uncertainty.Result(value: 15.0, uncertainty: 1.044, contributions: [])),
              "15 ± 1")
        check("a smaller uncertainty pulls in decimals",
              Uncertainty.formatted(Uncertainty.Result(value: 15.0, uncertainty: 0.044, contributions: [])),
              "15.00 ± 0.04")
        check("a formula that can't be read returns nil",
              Uncertainty.propagate("w *", variables: []) == nil ? "nil" : "value", "nil")

        // ODE. y' = y with y(0) = 1 is e^x — the one every method is checked against.
        if let node = try? MathEval.parse("y") {
            let v = Viewport(xMin: 0, xMax: 1, yMin: -2, yMax: 4)
            let curve = ODE.solution(node, from: 0, y0: 1, viewport: v, steps: 100)
            near("RK4 matches e^x at x = 1", curve.last.map { Double($0.y) }, M_E, 6)
            check("the curve starts at the left edge",
                  String(format: "%.2f", curve.first?.x ?? -99), "0.00")
        } else { failures += 1; print("  FAIL ODE parses") }
        // y' = -2xy with y(0) = 1 is exp(-x^2): 0.36788 at x = 1.
        if let node = try? MathEval.parse("-2 * x * y") {
            let v = Viewport(xMin: 0, xMax: 1, yMin: -2, yMax: 2)
            let curve = ODE.solution(node, from: 0, y0: 1, viewport: v, steps: 200)
            near("RK4 on a non-autonomous equation", curve.last.map { Double($0.y) }, 0.367879, 5)
        }
        if let node = try? MathEval.parse("x + y") {
            let field = ODE.slopeField(node, viewport: Viewport(), columns: 10, rows: 10)
            check("slope field covers the grid", "\(field.count)", "121")
            // Every tick is the same length, or a steep region reads as "more" rather than
            // "steeper".
            let lengths = field.map { hypot($0.to.x - $0.from.x, $0.to.y - $0.from.y) }
            let spread = (lengths.max() ?? 0) - (lengths.min() ?? 0)
            check("ticks are a uniform length", spread < 1e-9 ? "yes" : "no", "yes")
        }

        print(failures == 0 ? "COURSE SELFTEST: ALL PASS" : "COURSE SELFTEST: \(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
