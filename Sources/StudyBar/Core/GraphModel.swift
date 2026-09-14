import SwiftUI

/// Plotting, on the same expression tree the calculator uses.
///
/// A plot evaluates one expression once per pixel column — around a thousand times per redraw,
/// per curve — so the string is parsed once into a `MathEval.Node` and the tree is what gets
/// walked. That is the whole reason the parser is ours.

// MARK: - Viewport

/// The slice of the plane currently on screen, and the mapping to pixels. Kept separate from the
/// view so panning, zooming and the maths of "which x is this pixel" are testable without a
/// Canvas.
struct Viewport: Equatable {
    var xMin: Double = -10, xMax: Double = 10
    var yMin: Double = -6,  yMax: Double = 6

    var width: Double { xMax - xMin }
    var height: Double { yMax - yMin }
    var centerX: Double { (xMin + xMax) / 2 }
    var centerY: Double { (yMin + yMax) / 2 }

    static let `default` = Viewport()

    func x(atPixel px: Double, width w: Double) -> Double {
        xMin + (px / max(w, 1)) * width
    }
    func y(atPixel py: Double, height h: Double) -> Double {
        // Screen y grows downward; the plane's does not.
        yMax - (py / max(h, 1)) * height
    }
    func pixelX(_ x: Double, width w: Double) -> Double {
        (x - xMin) / width * w
    }
    func pixelY(_ y: Double, height h: Double) -> Double {
        (yMax - y) / height * h
    }

    /// Zoom about a point — the point under the cursor stays under the cursor, which is what
    /// makes scroll-to-zoom feel like a map rather than a slider.
    func zoomed(by factor: Double, aboutX ax: Double? = nil, aboutY ay: Double? = nil) -> Viewport {
        let fx = ax ?? centerX, fy = ay ?? centerY
        var v = self
        v.xMin = fx + (xMin - fx) * factor
        v.xMax = fx + (xMax - fx) * factor
        v.yMin = fy + (yMin - fy) * factor
        v.yMax = fy + (yMax - fy) * factor
        return v
    }

    func panned(dx: Double, dy: Double) -> Viewport {
        var v = self
        v.xMin += dx; v.xMax += dx
        v.yMin += dy; v.yMax += dy
        return v
    }

    /// Keep one plane-unit the same length on both axes, so a circle is round. Called when the
    /// view's aspect ratio is known.
    func squared(forAspect aspect: Double) -> Viewport {
        guard aspect > 0, width > 0 else { return self }
        var v = self
        let targetHeight = width / aspect
        let cy = centerY
        v.yMin = cy - targetHeight / 2
        v.yMax = cy + targetHeight / 2
        return v
    }
}

// MARK: - Curves

/// One plotted expression. `node` is nil while the source doesn't parse, which is most keystrokes
/// — the curve simply isn't drawn rather than the whole plot erroring.
struct PlotCurve: Identifiable {
    let id = UUID()
    var source: String
    var visible = true
    var colorIndex: Int
    var node: MathEval.Node?
    var error: String?

    /// Curves are told apart by colour, and these are picked to stay distinguishable on both
    /// light and dark backgrounds — not the semantic state colours, which mean urgency elsewhere.
    static let palette: [Color] = [
        Color(red: 0.25, green: 0.52, blue: 0.96),   // blue
        Color(red: 0.92, green: 0.34, blue: 0.29),   // red
        Color(red: 0.18, green: 0.66, blue: 0.45),   // green
        Color(red: 0.85, green: 0.55, blue: 0.13),   // amber
        Color(red: 0.58, green: 0.38, blue: 0.84),   // purple
        Color(red: 0.14, green: 0.64, blue: 0.70),   // teal
    ]
    var color: Color { Self.palette[colorIndex % Self.palette.count] }

    mutating func compile() {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        // "y = x^2" and "f(x) = x^2" are how a student writes it; plot the right-hand side.
        let body = Self.rightHandSide(trimmed)
        guard !body.isEmpty else { node = nil; error = nil; return }
        do {
            let n = try MathEval.parse(body)
            let unknown = n.names.subtracting(["x", "y"])
            if let first = unknown.sorted().first, MathEval.functions[first] == nil {
                node = nil; error = "Unknown name “\(first)”"
                return
            }
            node = n; error = nil
        } catch let e as MathEval.EvalError {
            node = nil; error = e.message
        } catch {
            node = nil; self.error = "Couldn't read that"
        }
    }

    /// Strip a leading `y =` or `f(x) =`. Anything else keeps its `=`, which then fails to parse
    /// and shows as an error rather than silently plotting half an equation.
    static func rightHandSide(_ s: String) -> String {
        guard let eq = s.firstIndex(of: "=") else { return s }
        let lhs = s[s.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        let rhs = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        let plottableLHS = ["y", "f(x)", "g(x)", "h(x)", "z", "f(x,y)", "f(x, y)"]
        return plottableLHS.contains(lhs) ? rhs : s
    }
}

// MARK: - Sampling

enum PlotMath {

    /// Gridline spacing that lands on numbers a human reads: 1, 2, 5 and their powers of ten.
    /// A plain `range / ticks` gives 0.7734 per line, which is unreadable on an axis.
    static func niceStep(range: Double, targetTicks: Int = 8) -> Double {
        guard range > 0, targetTicks > 0 else { return 1 }
        let raw = range / Double(targetTicks)
        let magnitude = pow(10, floor(log10(raw)))
        let normalized = raw / magnitude
        let step: Double
        switch normalized {
        case ..<1.5:  step = 1
        case ..<3:    step = 2
        case ..<7:    step = 5
        default:      step = 10
        }
        return step * magnitude
    }

    /// Every multiple of `step` inside the range, so gridlines stay put while panning rather
    /// than sliding with the viewport.
    static func ticks(from lo: Double, to hi: Double, step: Double) -> [Double] {
        guard step > 0, hi > lo, (hi - lo) / step < 1000 else { return [] }
        var out: [Double] = []
        var t = (lo / step).rounded(.up) * step
        while t <= hi {
            // -0 prints as "-0" and looks like a bug on an axis.
            out.append(t == 0 ? 0 : t)
            t += step
        }
        return out
    }

    /// Axis labels: as many decimals as the step needs, and no more.
    static func label(_ value: Double, step: Double) -> String {
        if abs(value) < step / 1000 { return "0" }
        let decimals = max(0, Int(ceil(-log10(step))) + (step < 1 ? 0 : 0))
        if abs(value) >= 10000 || (abs(value) < 0.001 && value != 0) {
            return MathEval.format(value)
        }
        return String(format: "%.\(min(6, decimals))f", value)
    }

    /// Sample a curve across the viewport, one point per pixel column, split into the segments
    /// that should actually be joined by a line.
    ///
    /// The splitting is the whole difficulty. `tan(x)` and `1/x` jump from +∞ to −∞ between two
    /// adjacent columns, and a plotter that joins every consecutive pair draws a vertical line
    /// through the asymptote that a student will read as part of the function. A segment breaks
    /// when the value stops being finite, and when a step is both enormous relative to the
    /// window *and* changes sign — the signature of a pole, as opposed to a merely steep curve.
    static func segments(_ node: MathEval.Node, viewport v: Viewport, pixelWidth: Double,
                         angle: MathEval.AngleMode = .radians, samplesPerPixel: Double = 1)
    -> [[CGPoint]] {
        let columns = max(2, Int(pixelWidth * samplesPerPixel))
        var out: [[CGPoint]] = []
        var current: [CGPoint] = []
        var previous: Double?
        for i in 0...columns {
            let x = v.xMin + (Double(i) / Double(columns)) * v.width
            let y = (try? node.eval(variables: ["x": x], angle: angle)) ?? .nan
            guard y.isFinite else {
                if current.count > 1 { out.append(current) }
                current = []; previous = nil
                continue
            }
            if let p = previous {
                let jump = abs(y - p)
                let crossedSign = (y > 0) != (p > 0)
                if jump > v.height * 4 && crossedSign {
                    if current.count > 1 { out.append(current) }
                    current = []
                }
            }
            current.append(CGPoint(x: x, y: y))
            previous = y
        }
        if current.count > 1 { out.append(current) }
        return out
    }

    /// A number for the trace readout: enough decimals to tell neighbouring pixels apart, and
    /// no more. The calculator's twelve significant digits are right for an answer and absurd
    /// for a cursor position — "x = -9.5231097561" is reporting picometres on a plot 38 units
    /// wide.
    static func readout(_ value: Double, span: Double) -> String {
        guard value.isFinite else { return "—" }
        guard span > 0 else { return MathEval.format(value) }
        let resolution = span / 800           // roughly one pixel
        let decimals = max(0, min(6, Int(ceil(-log10(resolution)))))
        if abs(value) >= 1e6 || (abs(value) < 1e-4 && value != 0) { return MathEval.format(value) }
        var text = String(format: "%.\(decimals)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    /// A y for a given x, for the trace readout.
    static func value(_ node: MathEval.Node, at x: Double, angle: MathEval.AngleMode) -> Double? {
        let y = (try? node.eval(variables: ["x": x], angle: angle)) ?? .nan
        return y.isFinite ? y : nil
    }
}

// MARK: - 3D surfaces

/// A height field for `z = f(x, y)`, evaluated on a grid and handed to SceneKit as a mesh.
struct Surface3D {
    var resolution: Int
    var xMin: Double, xMax: Double
    var yMin: Double, yMax: Double
    /// Row-major, `resolution + 1` values per row. NaN where the function has no value there —
    /// the mesh skips those triangles rather than spiking to zero.
    var z: [Double]
    var zMin: Double
    var zMax: Double

    var side: Int { resolution + 1 }

    static func sample(_ node: MathEval.Node, resolution: Int,
                       xMin: Double, xMax: Double, yMin: Double, yMax: Double,
                       angle: MathEval.AngleMode = .radians) -> Surface3D {
        let n = max(2, min(200, resolution))
        var z = [Double](repeating: .nan, count: (n + 1) * (n + 1))
        var lo = Double.infinity, hi = -Double.infinity
        for row in 0...n {
            let y = yMin + (Double(row) / Double(n)) * (yMax - yMin)
            for col in 0...n {
                let x = xMin + (Double(col) / Double(n)) * (xMax - xMin)
                let v = (try? node.eval(variables: ["x": x, "y": y], angle: angle)) ?? .nan
                z[row * (n + 1) + col] = v
                if v.isFinite { lo = Swift.min(lo, v); hi = Swift.max(hi, v) }
            }
        }
        if !lo.isFinite || !hi.isFinite { lo = 0; hi = 0 }
        return Surface3D(resolution: n, xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax,
                         z: z, zMin: lo, zMax: hi)
    }

    /// Height mapped to 0…1 for the colour ramp. A flat surface has no range to normalize
    /// against, so it sits in the middle of the ramp rather than dividing by zero.
    func normalized(_ value: Double) -> Double {
        guard zMax > zMin else { return 0.5 }
        return (value - zMin) / (zMax - zMin)
    }
}

// MARK: - Model

/// Everything the graph tabs share. One instance, like the calculator, so switching tabs or
/// closing the window doesn't throw away what you were looking at.
@MainActor
final class GraphModel: ObservableObject {
    static let shared = GraphModel()

    @Published var curves: [PlotCurve] = [
        { var c = PlotCurve(source: "sin(x)", colorIndex: 0); c.compile(); return c }()
    ]
    @Published var viewport = Viewport.default
    /// The 3D tab's expression, kept separate: `z = x^2 - y^2` is a different thing from the
    /// curves list, not another entry in it.
    @Published var surfaceSource = "sin(x) * cos(y)" { didSet { compileSurface() } }
    @Published private(set) var surfaceNode: MathEval.Node?
    @Published private(set) var surfaceError: String?
    @Published var surfaceRange: Double = 5
    @Published var surfaceResolution = 60
    @Published var wireframe = false

    // MARK: Slope fields (MAP2302)

    /// The 2D tab plots either functions of x or the direction field of y' = f(x, y). Same
    /// viewport, same pan and zoom — a slope field is a 2D plot, not a separate module.
    enum Mode: String, CaseIterable, Identifiable {
        case function, slopeField
        var id: String { rawValue }
        var title: String { self == .function ? "Function" : "Slope field" }
    }
    @Published var mode = Mode.function
    @Published var odeSource = "x + y" { didSet { compileODE() } }
    @Published private(set) var odeNode: MathEval.Node?
    @Published private(set) var odeError: String?
    /// The initial condition the solution curve is drawn through.
    @Published var odeX0: Double = 0
    @Published var odeY0: Double = 1
    @Published var showSolution = true

    private func compileODE() {
        let body = PlotCurve.rightHandSide(odeSource.trimmingCharacters(in: .whitespaces))
        guard !body.isEmpty else { odeNode = nil; odeError = nil; return }
        do {
            let n = try MathEval.parse(body)
            let unknown = n.names.subtracting(["x", "y"])
            if let first = unknown.sorted().first {
                odeNode = nil; odeError = "Unknown name “\(first)”"
                return
            }
            odeNode = n; odeError = nil
        } catch let e as MathEval.EvalError {
            odeNode = nil; odeError = e.message
        } catch {
            odeNode = nil; odeError = "Couldn't read that"
        }
    }

    /// Shared with the calculator, so a plot drawn in degrees matches the numbers in the tape.
    var angle: MathEval.AngleMode { CalculatorModel.shared.angle }

    init() { compileSurface(); compileODE() }

    func addCurve(_ source: String = "") {
        // The lowest colour nobody is using, rather than the count — add, remove, add would
        // otherwise hand out the same blue twice.
        let taken = Set(curves.map { $0.colorIndex % PlotCurve.palette.count })
        let next = (0..<PlotCurve.palette.count).first { !taken.contains($0) } ?? curves.count
        var c = PlotCurve(source: source, colorIndex: next)
        c.compile()
        curves.append(c)
    }

    func remove(_ id: UUID) {
        curves.removeAll { $0.id == id }
        if curves.isEmpty { addCurve("x") }
    }

    func update(_ id: UUID, source: String) {
        guard let i = curves.firstIndex(where: { $0.id == id }) else { return }
        curves[i].source = source
        curves[i].compile()
    }

    func resetViewport() { viewport = .default }

    private func compileSurface() {
        let body = PlotCurve.rightHandSide(surfaceSource.trimmingCharacters(in: .whitespaces))
        guard !body.isEmpty else { surfaceNode = nil; surfaceError = nil; return }
        do {
            let n = try MathEval.parse(body)
            let unknown = n.names.subtracting(["x", "y"])
            if let first = unknown.sorted().first {
                surfaceNode = nil; surfaceError = "Unknown name “\(first)”"
                return
            }
            surfaceNode = n; surfaceError = nil
        } catch let e as MathEval.EvalError {
            surfaceNode = nil; surfaceError = e.message
        } catch {
            surfaceNode = nil; surfaceError = "Couldn't read that"
        }
    }

    func surface() -> Surface3D? {
        guard let node = surfaceNode else { return nil }
        return Surface3D.sample(node, resolution: surfaceResolution,
                                xMin: -surfaceRange, xMax: surfaceRange,
                                yMin: -surfaceRange, yMax: surfaceRange, angle: angle)
    }
}

// MARK: - Self-test (`StudyBar --graph-selftest`)

enum GraphSelfTest {
    @MainActor
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ got: String, _ want: String) {
            let ok = got == want
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(name)")
            if !ok { print("       want \(want)   got \(got)") }
        }

        print("Graph self-test")

        // Gridlines a human reads. A plain range/ticks gives 0.7734 per line.
        check("nice step for 20", MathEval.format(PlotMath.niceStep(range: 20)), "2")
        check("nice step for 1", MathEval.format(PlotMath.niceStep(range: 1)), "0.1")
        check("nice step for 0.03", MathEval.format(PlotMath.niceStep(range: 0.03)), "0.005")
        check("nice step for 7500", MathEval.format(PlotMath.niceStep(range: 7500)), "1000")
        check("degenerate range", MathEval.format(PlotMath.niceStep(range: 0)), "1")

        // Ticks land on multiples, so gridlines stay put while panning.
        check("ticks are multiples of the step",
              PlotMath.ticks(from: -3.2, to: 3.2, step: 1).map { MathEval.format($0) }.joined(separator: ","),
              "-3,-2,-1,0,1,2,3")
        check("no runaway tick list", "\(PlotMath.ticks(from: 0, to: 1e9, step: 0.001).count)", "0")

        // Viewport transforms, both directions.
        let v = Viewport(xMin: -10, xMax: 10, yMin: -6, yMax: 6)
        check("left edge maps to xMin", MathEval.format(v.x(atPixel: 0, width: 800)), "-10")
        check("right edge maps to xMax", MathEval.format(v.x(atPixel: 800, width: 800)), "10")
        check("screen y is flipped", MathEval.format(v.y(atPixel: 0, height: 600)), "6")
        check("pixel round-trip",
              MathEval.format(v.pixelX(v.x(atPixel: 321, width: 800), width: 800)), "321")

        // Zoom about a point keeps that point under the cursor — what makes it feel like a map.
        let zoomed = v.zoomed(by: 0.5, aboutX: 4, aboutY: 0)
        check("zoom keeps the focus point", MathEval.format(zoomed.x(atPixel: 800 * (4 - zoomed.xMin) / zoomed.width, width: 800)), "4")
        check("zoom halves the width", MathEval.format(zoomed.width), "10")
        check("pan moves both edges",
              MathEval.format(v.panned(dx: 3, dy: 0).xMin) + "," + MathEval.format(v.panned(dx: 3, dy: 0).xMax),
              "-7,13")
        check("squaring matches the aspect",
              MathEval.format(v.squared(forAspect: 2).height), "10")

        // Sampling, and the reason it is not a simple loop: a pole must break the line.
        func segmentCount(_ src: String, _ vp: Viewport) -> Int {
            guard let n = try? MathEval.parse(src) else { return -1 }
            return PlotMath.segments(n, viewport: vp, pixelWidth: 400).count
        }
        check("a continuous curve is one segment", "\(segmentCount("sin(x)", v))", "1")
        check("1/x breaks at the pole", "\(segmentCount("1 / x", v))", "2")
        // Four poles in [-5, 5] — ±π/2 and ±3π/2 — so five pieces of curve.
        check("tan(x) breaks at each pole",
              "\(segmentCount("tan(x)", Viewport(xMin: -5, xMax: 5, yMin: -6, yMax: 6)))", "5")
        // A steep but continuous curve must NOT be broken — the bug this rule risks.
        check("a steep curve stays whole", "\(segmentCount("x ^ 3", v))", "1")
        check("a curve with no real values draws nothing",
              "\(segmentCount("sqrt(x - 1000)", v))", "0")

        if let node = try? MathEval.parse("x ^ 2") {
            let segs = PlotMath.segments(node, viewport: v, pixelWidth: 100)
            check("one point per column", "\(segs.first?.count ?? 0)", "101")
            check("trace reads a value", MathEval.format(PlotMath.value(node, at: 3, angle: .radians) ?? .nan), "9")
            check("trace refuses a non-value",
                  PlotMath.value(try! MathEval.parse("sqrt(x)"), at: -1, angle: .radians) == nil ? "nil" : "value", "nil")
        } else {
            failures += 1; print("  FAIL sampling parses")
        }

        // Plottable left-hand sides, because that is how a student writes it down.
        check("y = is stripped", PlotCurve.rightHandSide("y = x^2"), "x^2")
        check("f(x) = is stripped", PlotCurve.rightHandSide("f(x) = 2x + 1"), "2x + 1")
        check("z = is stripped", PlotCurve.rightHandSide("z = x*y"), "x*y")
        check("an equation is left alone", PlotCurve.rightHandSide("x^2 + y^2 = 9"), "x^2 + y^2 = 9")
        check("no equals sign", PlotCurve.rightHandSide("sin(x)"), "sin(x)")

        // A curve that doesn't parse is simply not drawn — it must not take the plot down.
        var broken = PlotCurve(source: "sin(", colorIndex: 0); broken.compile()
        check("a broken curve has no node", broken.node == nil ? "nil" : "node", "nil")
        check("a broken curve explains itself", broken.error != nil ? "yes" : "no", "yes")
        var unknown = PlotCurve(source: "x + q", colorIndex: 0); unknown.compile()
        check("an unknown name is caught before drawing", unknown.error ?? "", "Unknown name “q”")
        var good = PlotCurve(source: "y = 2x", colorIndex: 0); good.compile()
        check("a good curve compiles", good.node != nil ? "yes" : "no", "yes")

        // 3D: the height field, its extent, and the NaN holes that must not become spikes.
        if let node = try? MathEval.parse("x ^ 2 + y ^ 2") {
            let s = Surface3D.sample(node, resolution: 10, xMin: -1, xMax: 1, yMin: -1, yMax: 1)
            check("grid is (n+1)^2", "\(s.z.count)", "121")
            check("surface minimum at the origin", MathEval.format(s.zMin), "0")
            check("surface maximum at a corner", MathEval.format(s.zMax), "2")
            check("height normalizes into 0…1", MathEval.format(s.normalized(1)), "0.5")
        } else {
            failures += 1; print("  FAIL surface parses")
        }
        if let flat = try? MathEval.parse("3") {
            let s = Surface3D.sample(flat, resolution: 4, xMin: -1, xMax: 1, yMin: -1, yMax: 1)
            check("a flat surface doesn't divide by zero", MathEval.format(s.normalized(3)), "0.5")
        }
        if let holes = try? MathEval.parse("sqrt(1 - x ^ 2 - y ^ 2)") {
            let s = Surface3D.sample(holes, resolution: 8, xMin: -2, xMax: 2, yMin: -2, yMax: 2)
            check("outside the domain stays NaN, not zero",
                  s.z.contains { $0.isNaN } ? "yes" : "no", "yes")
            check("the dome's peak is 1", MathEval.format(s.zMax), "1")
        }

        print(failures == 0 ? "GRAPH SELFTEST: ALL PASS" : "GRAPH SELFTEST: \(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
