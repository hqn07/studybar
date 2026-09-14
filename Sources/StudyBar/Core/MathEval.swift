import Foundation

/// The calculator engine: text in, number out.
///
/// Hand-rolled rather than taken from a package, for two reasons. The AST is the valuable part
/// — plotting evaluates one expression a thousand times across a viewport, which wants a parsed
/// tree compiled once rather than a string re-parsed per pixel, and a tree is also what symbolic
/// differentiation would need later. And the awkward parts of a *student's* calculator are not
/// the parsing: they are degrees-vs-radians, implicit multiplication, and printing 0.1 + 0.2 as
/// `0.3`. Those are decisions, not algorithms.
///
/// Deliberately not a spreadsheet language: no strings, no dates, no cell references. Numbers,
/// the functions on a scientific calculator, and named variables.
enum MathEval {

    // MARK: - Public surface

    struct Result {
        let value: Double
        /// The value formatted the way a calculator would show it.
        var display: String { MathEval.format(value) }
    }

    enum EvalError: Error, Equatable {
        case empty
        case unexpected(String)          // token that couldn't be placed
        case unknownName(String)         // identifier that is neither variable nor function
        case badArgs(String, Int, Int)   // function, given, expected
        case trailing(String)
        case divideByZero

        var message: String {
            switch self {
            case .empty:                   return "Nothing to calculate"
            case .unexpected(let t):       return "Unexpected \(t.isEmpty ? "end of expression" : "“\(t)”")"
            case .unknownName(let n):      return "Unknown name “\(n)”"
            case .badArgs(let f, let g, let w):
                return "\(f)() takes \(w) argument\(w == 1 ? "" : "s"), got \(g)"
            case .trailing(let t):         return "Unexpected “\(t)” after the expression"
            case .divideByZero:            return "Division by zero"
            }
        }
    }

    /// Angle handling. A student in PHY2049 types `sin(30)` and means degrees; the same student
    /// in MAP2302 types `sin(pi/2)` and means radians. Neither default is right for both, so it
    /// is a visible mode rather than a guess — and `°` forces degrees whichever mode is on.
    enum AngleMode: String, CaseIterable {
        case radians, degrees
        var short: String { self == .radians ? "RAD" : "DEG" }
    }

    /// Evaluate `source`. `variables` supplies named values (`ans`, anything the user assigned).
    static func evaluate(_ source: String, variables: [String: Double] = [:],
                         angle: AngleMode = .radians) throws -> Result {
        let node = try parse(source)
        return Result(value: try node.eval(variables: variables, angle: angle))
    }

    /// Parse without evaluating — for plotting, which compiles once and evaluates per pixel.
    static func parse(_ source: String) throws -> Node {
        var parser = Parser(tokens: try tokenize(source))
        let node = try parser.parseExpression()
        if let extra = parser.peek { throw EvalError.trailing(extra.text) }
        return node
    }

    /// An assignment (`x = 3 * 4`) split into its name and expression, or nil if this isn't one.
    /// Comparison isn't supported, so a lone `=` is unambiguous.
    static func assignment(in source: String) -> (name: String, expression: String)? {
        guard let eq = source.firstIndex(of: "=") else { return nil }
        let name = String(source[source.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        let rest = String(source[source.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !rest.isEmpty, isName(name), functions[name] == nil,
              constants[name] == nil else { return nil }
        return (name, rest)
    }

    private static func isName(_ s: String) -> Bool {
        guard let f = s.first, f.isLetter || f == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Whether a string looks like arithmetic worth offering to calculate — used by the command
    /// palette, which sees every keystroke the user types and must not offer "= 3" for the note
    /// titled "3". Requires an operator or a function call, not merely digits.
    static func looksCalculable(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3, t.rangeOfCharacter(from: .decimalDigits) != nil
                || constants.keys.contains(where: { t.contains($0) }) else { return false }
        let hasOperator = t.contains(where: { "+-*/^%(".contains($0) }) || t.contains("×") || t.contains("÷")
        guard hasOperator else { return false }
        return (try? evaluate(t)) != nil
    }

    // MARK: - Formatting

    /// Print like a calculator, not like a `Double`.
    ///
    /// `0.1 + 0.2` is 0.30000000000000004 and every student who sees that in a study app
    /// concludes the app is broken. Twelve significant digits is below the noise floor of binary
    /// rounding and above anything coursework needs; trailing zeros come off, and magnitudes
    /// that would print as a wall of digits switch to scientific.
    static func format(_ v: Double) -> String {
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v < 0 ? "−∞" : "∞" }
        if v == 0 { return "0" }
        let magnitude = abs(v)
        if magnitude >= 1e12 || magnitude < 1e-9 {
            var s = String(format: "%.11e", v)
            // 1.250000e+04 → 1.25e4
            s = s.replacingOccurrences(of: "e+0", with: "e").replacingOccurrences(of: "e-0", with: "e-")
            s = s.replacingOccurrences(of: "e+", with: "e")
            if let e = s.firstIndex(of: "e") {
                var mantissa = String(s[s.startIndex..<e])
                if mantissa.contains(".") {
                    while mantissa.hasSuffix("0") { mantissa.removeLast() }
                    if mantissa.hasSuffix(".") { mantissa.removeLast() }
                }
                s = mantissa + String(s[e...])
            }
            return s
        }
        var s = String(format: "%.12g", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    // MARK: - Tokens

    enum Token: Equatable {
        case number(Double)
        case name(String)
        case op(Character)
        case lparen, rparen, comma
        case degreeSign

        var text: String {
            switch self {
            case .number(let d):  return format(d)
            case .name(let n):    return n
            case .op(let c):      return String(c)
            case .lparen:         return "("
            case .rparen:         return ")"
            case .comma:          return ","
            case .degreeSign:     return "°"
            }
        }
    }

    static func tokenize(_ s: String) throws -> [Token] {
        var out: [Token] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var text = ""
                while i < chars.count {
                    if chars[i].isNumber || chars[i] == "." { text.append(chars[i]); i += 1; continue }
                    // A thousands separator, as pasted from a table: 1,000 is one number. It has
                    // to be eaten *inside* the number — skipping it between tokens leaves "1" and
                    // "500", which implicit multiplication then turns into 500. A comma only
                    // groups when exactly three digits follow and nothing numeric follows those,
                    // so max(1,2) keeps its argument separator; max(1,200) is ambiguous in any
                    // calculator and reads here as 1200.
                    if chars[i] == ",", i + 3 < chars.count,
                       chars[i + 1].isNumber, chars[i + 2].isNumber, chars[i + 3].isNumber,
                       !(i + 4 < chars.count && chars[i + 4].isNumber) {
                        i += 1; continue
                    }
                    break
                }
                // Exponent: 1.5e3, 2e-4. Only when a digit or sign follows, so `2e` stays 2×e.
                if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                    let next = i + 1 < chars.count ? chars[i + 1] : " "
                    if next.isNumber || ((next == "+" || next == "-") && i + 2 < chars.count && chars[i + 2].isNumber) {
                        text.append("e"); i += 1
                        if chars[i] == "+" || chars[i] == "-" { text.append(chars[i]); i += 1 }
                        while i < chars.count, chars[i].isNumber { text.append(chars[i]); i += 1 }
                    }
                }
                guard let d = Double(text) else { throw EvalError.unexpected(text) }
                out.append(.number(d))
                continue
            }
            if c.isLetter || c == "_" {
                var text = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                    text.append(chars[i]); i += 1
                }
                out.append(.name(text))
                continue
            }
            switch c {
            case "(", "[", "{": out.append(.lparen); i += 1
            case ")", "]", "}": out.append(.rparen); i += 1
            case ",":           out.append(.comma); i += 1
            case "°":           out.append(.degreeSign); i += 1
            case "+", "-", "*", "/", "^", "%": out.append(.op(c)); i += 1
            // The characters a calculator prints and a keyboard doesn't have.
            case "×", "·":      out.append(.op("*")); i += 1
            case "÷":           out.append(.op("/")); i += 1
            case "−":           out.append(.op("-")); i += 1
            case "√":           out.append(.name("sqrt")); i += 1
            case "π":           out.append(.name("pi")); i += 1
            default:            throw EvalError.unexpected(String(c))
            }
        }
        return out
    }

    // MARK: - AST

    indirect enum Node {
        case number(Double)
        case variable(String)
        case unary(Character, Node)
        case binary(Character, Node, Node)
        case call(String, [Node])
        /// `x°` — degrees, whatever the current angle mode says.
        case degrees(Node)

        func eval(variables: [String: Double], angle: AngleMode) throws -> Double {
            switch self {
            case .number(let d): return d
            case .variable(let n):
                if let v = variables[n] { return v }
                if let c = constants[n] { return c }
                throw EvalError.unknownName(n)
            case .degrees(let n):
                return try n.eval(variables: variables, angle: angle) * .pi / 180
            case .unary(let op, let n):
                let v = try n.eval(variables: variables, angle: angle)
                switch op {
                case "-": return -v
                case "+": return v
                // Postfix percent: 15% is 0.15. Deliberately not the "200 + 10% = 220"
                // convention — that rule silently changes what the `+` means, and a student
                // checking a calculation should be able to read the expression literally.
                case "%": return v / 100
                default:  throw EvalError.unexpected(String(op))
                }
            case .binary(let op, let l, let r):
                let a = try l.eval(variables: variables, angle: angle)
                let b = try r.eval(variables: variables, angle: angle)
                switch op {
                case "+": return a + b
                case "-": return a - b
                case "*": return a * b
                case "/":
                    if b == 0 { throw EvalError.divideByZero }
                    return a / b
                case "^": return pow(a, b)
                default:  throw EvalError.unexpected(String(op))
                }
            case .call(let name, let args):
                guard let fn = functions[name] else { throw EvalError.unknownName(name) }
                let values = try args.map { try $0.eval(variables: variables, angle: angle) }
                guard fn.arity.contains(values.count) else {
                    throw EvalError.badArgs(name, values.count, fn.arity.lowerBound)
                }
                return fn.apply(values, angle)
            }
        }

        /// Every variable this expression reads — the plotter uses it to know whether a
        /// function is one of x, and the panel to warn about an undefined name before it runs.
        var names: Set<String> {
            switch self {
            case .number:                return []
            case .variable(let n):       return constants[n] == nil ? [n] : []
            case .unary(_, let n):       return n.names
            case .degrees(let n):        return n.names
            case .binary(_, let l, let r): return l.names.union(r.names)
            case .call(_, let a):        return a.reduce(into: Set<String>()) { $0.formUnion($1.names) }
            }
        }
    }

    // MARK: - Parser

    /// Recursive descent. Precedence, lowest first: + −, * / , unary −, ^ (right-associative),
    /// postfix % and °, then atoms.
    struct Parser {
        let tokens: [Token]
        var i = 0

        var peek: Token? { i < tokens.count ? tokens[i] : nil }
        mutating func advance() -> Token? { defer { i += 1 }; return peek }

        mutating func parseExpression() throws -> Node {
            guard !tokens.isEmpty else { throw EvalError.empty }
            return try parseAdditive()
        }

        private mutating func parseAdditive() throws -> Node {
            var left = try parseMultiplicative()
            while case .op(let c)? = peek, c == "+" || c == "-" {
                i += 1
                left = .binary(c, left, try parseMultiplicative())
            }
            return left
        }

        private mutating func parseMultiplicative() throws -> Node {
            var left = try parseUnary()
            while true {
                if case .op(let c)? = peek, c == "*" || c == "/" {
                    i += 1
                    left = .binary(c, left, try parseUnary())
                    continue
                }
                // Implicit multiplication, the way it is written on paper: 2pi, 3(x+1), 2sin(x).
                // Only after a complete value, and never before an operator, so `2 -3` stays a
                // subtraction rather than becoming 2 × (−3).
                if let t = peek, startsValue(t) {
                    left = .binary("*", left, try parseUnary())
                    continue
                }
                return left
            }
        }

        private func startsValue(_ t: Token) -> Bool {
            switch t {
            case .number, .lparen: return true
            case .name(let n):     return functions[n] != nil || constants[n] != nil || true
            default:               return false
            }
        }

        private mutating func parseUnary() throws -> Node {
            if case .op(let c)? = peek, c == "-" || c == "+" {
                i += 1
                return .unary(c, try parseUnary())
            }
            return try parsePower()
        }

        private mutating func parsePower() throws -> Node {
            let base = try parsePostfix()
            if case .op("^")? = peek {
                i += 1
                // Right-associative, and the exponent may be signed: 2^-1.
                let exponent = try parseUnary()
                return .binary("^", base, exponent)
            }
            return base
        }

        private mutating func parsePostfix() throws -> Node {
            var node = try parseAtom()
            loop: while let t = peek {
                switch t {
                case .op("%"):    i += 1; node = .unary("%", node)
                case .degreeSign: i += 1; node = .degrees(node)
                default:          break loop
                }
            }
            return node
        }

        private mutating func parseAtom() throws -> Node {
            guard let t = peek else { throw EvalError.unexpected("") }
            switch t {
            case .number(let d):
                i += 1
                return .number(d)
            case .name(let n):
                i += 1
                if case .lparen? = peek {
                    i += 1
                    var args: [Node] = []
                    if case .rparen? = peek { i += 1 } else {
                        while true {
                            args.append(try parseAdditive())
                            if case .comma? = peek { i += 1; continue }
                            guard case .rparen? = peek else { throw EvalError.unexpected(peek?.text ?? "") }
                            i += 1
                            break
                        }
                    }
                    return .call(n, args)
                }
                return .variable(n)
            case .lparen:
                i += 1
                let inner = try parseAdditive()
                guard case .rparen? = peek else { throw EvalError.unexpected(peek?.text ?? "") }
                i += 1
                return inner
            case .op(let c) where c == "-" || c == "+":
                i += 1
                return .unary(c, try parseUnary())
            default:
                throw EvalError.unexpected(t.text)
            }
        }
    }

    // MARK: - Library

    static let constants: [String: Double] = [
        "pi": .pi, "e": M_E, "tau": .pi * 2,
        // The two a physics student reaches for constantly. Named, not magic numbers in a note.
        "g": 9.80665,            // standard gravity, m/s²
        "c": 299_792_458,        // speed of light, m/s
    ]

    struct Function {
        let arity: ClosedRange<Int>
        let apply: ([Double], AngleMode) -> Double
    }

    /// Angle-taking functions respect the mode; everything else ignores it.
    private static func angled(_ f: @escaping (Double) -> Double) -> Function {
        Function(arity: 1...1) { a, mode in f(mode == .degrees ? a[0] * .pi / 180 : a[0]) }
    }
    private static func returnsAngle(_ f: @escaping (Double) -> Double) -> Function {
        Function(arity: 1...1) { a, mode in
            let r = f(a[0])
            return mode == .degrees ? r * 180 / .pi : r
        }
    }
    private static func plain(_ n: Int = 1, _ f: @escaping ([Double]) -> Double) -> Function {
        Function(arity: n...n) { a, _ in f(a) }
    }

    static let functions: [String: Function] = [
        "sin": angled(sin), "cos": angled(cos), "tan": angled(tan),
        "asin": returnsAngle(asin), "acos": returnsAngle(acos), "atan": returnsAngle(atan),
        "sinh": plain(1) { sinh($0[0]) }, "cosh": plain(1) { cosh($0[0]) }, "tanh": plain(1) { tanh($0[0]) },
        "sqrt": plain(1) { sqrt($0[0]) }, "cbrt": plain(1) { cbrt($0[0]) },
        "ln": plain(1) { log($0[0]) }, "log": plain(1) { log10($0[0]) },
        "log10": plain(1) { log10($0[0]) }, "log2": plain(1) { log2($0[0]) },
        "exp": plain(1) { exp($0[0]) },
        "abs": plain(1) { abs($0[0]) },
        "floor": plain(1) { floor($0[0]) }, "ceil": plain(1) { ceil($0[0]) },
        "round": plain(1) { $0[0].rounded() },
        "sign": plain(1) { $0[0] > 0 ? 1 : ($0[0] < 0 ? -1 : 0) },
        "min": Function(arity: 1...8) { a, _ in a.min() ?? .nan },
        "max": Function(arity: 1...8) { a, _ in a.max() ?? .nan },
        "mod": plain(2) { $0[0].truncatingRemainder(dividingBy: $0[1]) },
        "pow": plain(2) { pow($0[0], $0[1]) },
        "hypot": plain(2) { hypot($0[0], $0[1]) },
        "atan2": Function(arity: 2...2) { a, mode in
            let r = atan2(a[0], a[1])
            return mode == .degrees ? r * 180 / .pi : r
        },
        "deg": plain(1) { $0[0] * 180 / .pi },
        "rad": plain(1) { $0[0] * .pi / 180 },
        // Rounding to a number of significant figures — a physics lab writes every answer this
        // way, and doing it by hand is where marks are lost.
        "sigfig": plain(2) { args in
            let v = args[0]
            guard v != 0, v.isFinite else { return v }
            let digits = Swift.max(1, Swift.min(15, Int(args[1])))
            let exponent = floor(log10(abs(v)))
            let factor = pow(10, Double(digits) - 1 - exponent)
            return (v * factor).rounded() / factor
        },
    ]
}

// MARK: - Self-test (`StudyBar --calc-selftest`)

enum MathEvalSelfTest {
    @MainActor
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ got: String, _ want: String) {
            let ok = got == want
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(name)")
            if !ok { print("       want \(want)   got \(got)") }
        }
        /// Evaluate and print, so a thrown error shows as its message rather than a crash.
        func calc(_ s: String, angle: MathEval.AngleMode = .radians,
                  vars: [String: Double] = [:]) -> String {
            do { return try MathEval.evaluate(s, variables: vars, angle: angle).display }
            catch let e as MathEval.EvalError { return "!" + e.message }
            catch { return "!unknown" }
        }

        print("MathEval self-test")

        // Arithmetic and precedence — the part a hand-rolled parser gets wrong.
        check("addition", calc("2 + 3"), "5")
        check("precedence: × before +", calc("2 + 3 * 4"), "14")
        check("parentheses win", calc("(2 + 3) * 4"), "20")
        check("unary minus", calc("-4 + 10"), "6")
        check("subtraction is not unary", calc("10 - 4"), "6")
        check("power binds tighter than ×", calc("2 * 3 ^ 2"), "18")
        check("power is right-associative", calc("2 ^ 3 ^ 2"), "512")
        check("signed exponent", calc("2 ^ -1"), "0.5")
        check("unary minus below power", calc("-2 ^ 2"), "-4")
        check("division", calc("7 / 2"), "3.5")
        check("nested calls", calc("max(1, min(9, 4))"), "4")

        // Floating point printed the way a calculator prints it.
        check("0.1 + 0.2 is 0.3", calc("0.1 + 0.2"), "0.3")
        check("1/3", calc("1 / 3"), "0.333333333333")
        // 2^60 is 1152921504606846976; twelve significant digits rounds the last kept one.
        check("big magnitudes go scientific", calc("2 ^ 60"), "1.15292150461e18")
        check("tiny magnitudes go scientific", calc("1 / 10 ^ 12"), "1e-12")
        check("integers stay integers", calc("10 ^ 6"), "1000000")
        check("negative zero prints as zero", calc("0 * -1"), "0")

        // Implicit multiplication, as written on paper.
        check("2pi", calc("2pi"), "6.28318530718")
        check("3(4)", calc("3(4)"), "12")
        check("2sin(0) + 1", calc("2sin(0) + 1"), "1")
        check("a space is not a multiply", calc("2 - 3"), "-1")

        // Angle mode, and ° overriding it.
        check("sin(pi/2) in radians", calc("sin(pi / 2)"), "1")
        check("sin(30) in degrees", calc("sin(30)", angle: .degrees), "0.5")
        check("sin(30°) while in radians", calc("sin(30°)"), "0.5")
        check("asin returns degrees in DEG", calc("asin(0.5)", angle: .degrees), "30")
        check("deg() converts", calc("deg(pi)"), "180")

        // Student-facing helpers.
        check("percent is a hundredth", calc("15%"), "0.15")
        check("percent of a number", calc("15% * 200"), "30")
        check("sigfig rounds", calc("sigfig(9.80665, 3)"), "9.81")
        check("thousands separator", calc("1,500 + 1"), "1501")
        check("comma still separates arguments", calc("max(1,2)"), "2")
        check("constants: g", calc("g * 2"), "19.6133")
        check("variables", calc("x ^ 2", vars: ["x": 7]), "49")
        check("ans", calc("ans + 1", vars: ["ans": 41]), "42")

        // Errors are messages, not crashes.
        check("divide by zero", calc("1 / 0"), "!Division by zero")
        check("unknown name", calc("frobnicate(2)"), "!Unknown name “frobnicate”")
        check("unbalanced paren", calc("2 * (3 + 4"), "!Unexpected end of expression")
        check("trailing operator", calc("2 +"), "!Unexpected end of expression")
        check("empty", calc(""), "!Nothing to calculate")

        // The palette sees every keystroke; it must not offer to calculate prose.
        func calculable(_ s: String) -> String { MathEval.looksCalculable(s) ? "yes" : "no" }
        check("offers on arithmetic", calculable("12*4"), "yes")
        check("offers on a function call", calculable("sqrt(2)"), "yes")
        check("silent on a bare number", calculable("2049"), "no")
        check("silent on a note title", calculable("Gauss's Law"), "no")
        check("silent on a course code", calculable("MAP2302"), "no")
        check("silent on a date", calculable("9/14"), "yes")   // genuinely is a division
        check("silent on prose with a number", calculable("read chapter 4 tonight"), "no")

        // Assignment detection, for the calculator's variable list.
        func assign(_ s: String) -> String {
            guard let a = MathEval.assignment(in: s) else { return "none" }
            return "\(a.name)=\(a.expression)"
        }
        check("assignment", assign("x = 3 * 4"), "x=3 * 4")
        check("not an assignment", assign("3 * 4"), "none")
        check("cannot reassign a constant", assign("pi = 3"), "none")
        check("cannot shadow a function", assign("sin = 3"), "none")

        // Parsing once and evaluating many times is what plotting needs.
        if let node = try? MathEval.parse("x ^ 2 + 1") {
            let ys = [0.0, 1, 2, 3].map { (try? node.eval(variables: ["x": $0], angle: .radians)) ?? .nan }
            check("compiled tree evaluates per point", ys.map { MathEval.format($0) }.joined(separator: ","),
                  "1,2,5,10")
            check("tree reports its variables", node.names.sorted().joined(separator: ","), "x")
        } else {
            failures += 1; print("  FAIL compiled tree parses")
        }

        print(failures == 0 ? "MATHEVAL SELFTEST: ALL PASS" : "MATHEVAL SELFTEST: \(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
