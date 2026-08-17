import Foundation
// MARK: - Expression Parser & Compiled Expression
//
// This file merges the parser + algebraic simplifier + index-based evaluator
// into CompiledExpression, the type CurveFitterPro actually calls into.
//
// Variables are supplied as a positional [Double] "env" array at evaluation
// time, indexed via VariableTable. "x" is always registered first, so it is
// permanently locked to env[0] — every other identifier discovered while
// parsing is a fit parameter, in first-use order.
//
// Supports: +, -, *, /, ^, unary minus, parentheses, named constants (pi, π,
// e), and functions: exp, log/ln, log10, log2, sqrt, cbrt, abs, sin, cos,
// tan, asin, acos, atan, atan2, sinh, cosh, tanh, asinh, acosh, atanh,
// floor, ceil, round, sign, min, max.

// MARK: - Operators

enum Op: String, Sendable {
    case add = "+"
    case sub = "-"
    case mul = "*"
    case div = "/"
    case pow = "^"
    case lt = "<"
    case le = "<="
    case gt = ">"
    case ge = ">="
    case eq = "=="
    case ne = "!="
    
    var isComparison: Bool {
        switch self {
        case .lt, .le, .gt, .ge, .eq, .ne: return true
        case .add, .sub, .mul, .div, .pow: return false
        }
    }
}

// MARK: - AST

indirect enum Expr: Equatable, Sendable {
    case number(Double)
    case variable(index: Int)
    case constant(name: String, value: Double)   // built-in named constant, e.g. π
    case binary(op: Op, left: Expr, right: Expr)
    case function(name: String, args: [Expr])
    case ternary(condition: Expr, then: Expr, otherwise: Expr)   // cond ? then : otherwise
}

// MARK: - Variable Table

struct VariableTable: Sendable {
    private(set) var nameToIndex: [String: Int] = [:]
    private(set) var indexToName: [String] = []
    
    init() {
        /// Pre-register "x" to guarantee it is always locked to index 0. This matches env[0] == x in evaluate(_:env:) and CompiledExpression.evaluateFast.
        _ = register("x")
    }
    
    @discardableResult
    mutating func register(_ name: String) -> Int {
        if let i = nameToIndex[name] { return i }
        let i = indexToName.count
        nameToIndex[name] = i
        indexToName.append(name)
        return i
    }
    
    mutating func index(for name: String) -> Int {
        return register(name)
    }
    
    func name(for index: Int) -> String? {
        (index >= 0 && index < indexToName.count) ? indexToName[index] : nil
    }
    
    var count: Int { indexToName.count }
}

// MARK: - Parse Error

enum ParseError: Error, LocalizedError, Sendable {
    case unexpectedToken(String)
    case unexpectedEndOfInput
    
    var errorDescription: String? {
        switch self {
        case .unexpectedToken(let t): return "Unexpected token: '\(t)'"
        case .unexpectedEndOfInput: return "Incomplete expression"
        }
    }
}

// MARK: - Parser

final class Parser {
    private var tokens: [String]
    private var index = 0
    private(set) var vars: VariableTable
    
    /// Identifiers that resolve to a fixed numeric value instead of becoming a user-entered variable. Both the word form and the Greek glyph map to the
    /// same canonical display symbol, so "pi" and "π" both render as "π".
    static let mathConstants: [String: (symbol: String, value: Double)] = [
        "pi": ("π", .pi),
        "π": ("π", .pi),
        "e": ("e", 2.718281828459045)
    ]
    
    init(_ input: String, vars: VariableTable = VariableTable()) {
        self.tokens = Parser.tokenize(input)
        self.vars = vars
    }
    
    // Identifier alternative accepts any Unicode letter (so Greek names like "α" or "θ" work,
    // not just A-Za-z), and an optional ".tail" suffix for subscripts, e.g. "sigma.max" or "α.max".
    // Multi-char comparison operators (<=, >=, ==, !=) are listed before the single-char
    // punctuation class so they're matched as one token rather than splitting into two.
    private static let tokenRegex = /((\d+(\.\d*)?|\.\d+)([eE][+\-]?\d+)?)|[\p{L}_][\p{L}\p{N}_]*(\.[\p{L}\p{N}_]+)?|<=|>=|==|!=|[\+\-\*\/\^\(\),\?:<>]/
    static func tokenize(_ s: String) -> [String] { s.matches(of: tokenRegex).map { String($0.output.0) } }
    
    func parse() throws -> Expr {
        let expr = try parseTernary()
        guard peek().isEmpty else { throw ParseError.unexpectedToken(peek()) }
        return expr
    }
    
    // Lowest precedence: cond ? then : else. Right-associative (a nested ternary
    // in the "then" or "else" branch parses as you'd expect without extra parens).
    private func parseTernary() throws -> Expr {
        let cond = try parseComparison()
        if match("?") {
            let thenExpr = try parseTernary()
            guard match(":") else { throw ParseError.unexpectedEndOfInput }
            let elseExpr = try parseTernary()
            return .ternary(condition: cond, then: thenExpr, otherwise: elseExpr)
        }
        return cond
    }
    
    private static let comparisonTokens: Set<String> = ["<", "<=", ">", ">=", "==", "!="]
    
    // Comparisons sit below +/- (so "a + b < c" parses as "(a + b) < c") and
    // are non-chaining: "a < b < c" parses as (a < b) < c, matching most C-family
    // languages rather than mathematical chained-inequality notation.
    private func parseComparison() throws -> Expr {
        var expr = try parseAddSub()
        while Parser.comparisonTokens.contains(peek()) {
            let opStr = advance()
            guard let op = Op(rawValue: opStr) else { throw ParseError.unexpectedToken(opStr) }
            let rhs = try parseAddSub()
            expr = .binary(op: op, left: expr, right: rhs)
        }
        return expr
    }
    
    private func parseAddSub() throws -> Expr {
        var expr = try parseMulDiv()
        while match("+", "-") {
            let op = tokens[index - 1]
            guard let op = Op(rawValue: op) else { throw ParseError.unexpectedToken(op) }
            let rhs = try parseMulDiv()
            expr = .binary(op: op, left: expr, right: rhs)
        }
        return expr
    }
    
    private func parseMulDiv() throws -> Expr {
        var expr = try parseUnary()
        while match("*", "/") {
            let op = tokens[index - 1]
            guard let op = Op(rawValue: op) else { throw ParseError.unexpectedToken(op) }
            let rhs = try parsePow()
            expr = .binary(op: op, left: expr, right: rhs)
        }
        return expr
    }
    
    private func parseUnary() throws -> Expr {
        if match("-") { return .binary(op: .mul, left: .number(-1), right: try parseUnary()) }
        if match("+") { return try parseUnary() }
        return try parsePow()
    }
    
    private func parsePow() throws -> Expr {
        let base = try parsePrimary()
        if match("^") {
            let exp = try parseUnary()
            return .binary(op: .pow, left: base, right: exp)
        }
        return base
    }
    
    private func parsePrimary() throws -> Expr {
        if match("(") {
            let e = try parseTernary()
            guard match(")") else { throw ParseError.unexpectedEndOfInput }
            return e
        }
        if let n = Double(peek()) {
            _ = advance()
            return .number(n)
        }
        if let c = peek().first, c.isLetter {
            let name = advance()
            
            if match("(") {
                var args: [Expr] = []
                if !match(")") {
                    repeat { args.append(try parseTernary()) } while match(",")
                    guard match(")") else { throw ParseError.unexpectedEndOfInput }
                }
                return .function(name: name, args: args)
            }
            
            // Built-in constants: matched only on an exact identifier, so "pi.max",
            // "piano", "e2", etc. still fall through to being ordinary variables —
            // only the tokenizer's optional ".tail" or trailing digits/letters
            // prevent an accidental match here.
            if let constant = Parser.mathConstants[name] {
                return .constant(name: constant.symbol, value: constant.value)
            }
            
            let idx = vars.index(for: name)
            return .variable(index: idx)
        }
        
        if peek().isEmpty {
            throw ParseError.unexpectedEndOfInput
        }
        
        throw ParseError.unexpectedToken(peek())
    }
    
    private func match(_ t: String...) -> Bool {
        if t.contains(peek()) {
            index += 1
            return true
        }
        return false
    }
    
    private func peek() -> String {
        index < tokens.count ? tokens[index] : ""
    }
    
    private func advance() -> String {
        defer { index += 1 }
        return tokens[index]
    }
}

// MARK: - Simplifier

func simplify(_ expr: Expr) -> Expr {
    switch expr {
        
    case .number, .variable, .constant:
        return expr
        
    case .function(let name, let args):
        let simplifiedArgs = args.map(simplify)
        // pow(a, b) is mathematically identical to a^b; folding it into a
        // binary .pow node here means it gets superscript rendering in
        // EquationFormatter and the same simplification rules (pow(x,1) -> x,
        // pow(x,0) -> 1, etc.) for free, instead of printing as "pow(a, b)".
        if name.lowercased() == "pow", simplifiedArgs.count == 2 {
            return simplifyPow(simplifiedArgs[0], simplifiedArgs[1])
        }
        // exp(x) is mathematically identical to e^x; folding it the same way
        // gets it the same superscript rendering and simplifications
        // (exp(0) -> e^0 -> 1, exp(1) -> e^1 -> e) instead of printing as "exp(x)".
        if name.lowercased() == "exp", simplifiedArgs.count == 1 {
            return simplifyPow(.constant(name: "e", value: 2.718281828459045), simplifiedArgs[0])
        }
        return .function(name: name, args: simplifiedArgs)
        
    case .binary(let op, let l, let r):
        return simplifyBinary(op, simplify(l), simplify(r))
        
    case .ternary(let cond, let thenExpr, let elseExpr):
        let simplifiedCond = simplify(cond)
        // If the condition folds to a constant, the branch is decidable at
        // parse time — collapse straight to whichever side wins.
        if case .number(let n) = simplifiedCond {
            return n != 0 ? simplify(thenExpr) : simplify(elseExpr)
        }
        return .ternary(condition: simplifiedCond, then: simplify(thenExpr), otherwise: simplify(elseExpr))
    }
}

func simplifyBinary(_ op: Op, _ l: Expr, _ r: Expr) -> Expr {
    switch op {
    case .add: simplifyAdd(l, r)
    case .sub: simplifySub(l, r)
    case .mul: simplifyMul(l, r)
    case .div: simplifyDiv(l, r)
    case .pow: simplifyPow(l, r)
    case .lt, .le, .gt, .ge, .eq, .ne: simplifyComparison(op, l, r)
    }
}

/// Comparisons don't participate in the algebraic term-collection machinery
/// (there's no useful notion of "combining like terms" across a `<`) — they
/// only fold when both sides are already numeric literals, otherwise they're
/// left as-is for the ternary condition (or evaluator) to handle.
func simplifyComparison(_ op: Op, _ l: Expr, _ r: Expr) -> Expr {
    guard case .number(let a) = l, case .number(let b) = r else {
        return .binary(op: op, left: l, right: r)
    }
    let result: Bool
    switch op {
    case .lt: result = a < b
    case .le: result = a <= b
    case .gt: result = a > b
    case .ge: result = a >= b
    case .eq: result = a == b
    case .ne: result = a != b
    case .add, .sub, .mul, .div, .pow: result = false // unreachable, guarded by caller
    }
    return .number(result ? 1 : 0)
}

func unaryMinusInner(_ expr: Expr) -> Expr? {
    switch expr {
    case .binary(.mul, .number(-1), let inner):
        return inner
    default:
        return nil
    }
}

/// If `expr` is negative — either a bare negative number literal, or the
/// `.binary(.mul, .number(-1), inner)` unary-minus marker — returns -1 and
/// the positive/unnegated form. Otherwise returns +1 and `expr` unchanged.
func extractSign(_ expr: Expr) -> (sign: Int, positive: Expr) {
    if case .number(let n) = expr, n < 0 { return (-1, .number(-n)) }
    if let inner = unaryMinusInner(expr) { return (-1, inner) }
    return (1, expr)
}

func simplifyPow(_ l: Expr, _ r: Expr) -> Expr {
    if case .number(0) = r { return .number(1) } // x^0 → 1
    if case .number(1) = r { return l }          // x^1 → x
    if case .number(1) = l { return .number(1) } // 1^x → 1
    
    // numeric^numeric → fold only if the result stays clean and fits under our 5-digit limit
    if case .number(let a) = l, case .number(let b) = r {
        let res = pow(a, b)
        if !res.isNaN && !res.isInfinite {
            if abs(res) < 100000 {
                return .number(res)
            }
        }
        return .binary(op: .pow, left: l, right: r)
    }
    
    return .binary(op: .pow, left: l, right: r)
}

func normalizeNegativeNumber(_ expr: Expr) -> Expr {
    if case .number(let n) = expr, n < 0 {
        return .binary(op: .mul, left: .number(-1), right: .number(abs(n)))
    }
    return expr
}

func simplifyAdd(_ l: Expr, _ r: Expr) -> Expr {
    var terms: [(sign: Int, expr: Expr)] = []
    collectAddTerms(l, into: &terms)
    collectAddTerms(r, into: &terms)
    return simplifyAddTerms(terms)
}

func simplifySub(_ l: Expr, _ r: Expr) -> Expr {
    return simplifyAdd(l, .binary(op: .mul, left: .number(-1), right: r))
}

func simplifyDiv(_ l: Expr, _ r: Expr) -> Expr {
    // numeric / numeric
    if case .number(let a) = l, case .number(let b) = r { return .number(a / b) }
    
    // (-a)/b -> -(a/b), a/(-b) -> -(a/b), (-a)/(-b) -> a/b: hoist sign(s) out
    // of the division entirely rather than leaving them trapped inside it.
    // This is what lets "3 * (-a/b)" simplify straight to "-3 * a/b" (which
    // then folds further to "-3a/b") instead of staying as an unsimplified
    // "3 * (-a/b)" that only the renderer's parens make safe to look at.
    let (signL, posL) = extractSign(l)
    let (signR, posR) = extractSign(r)
    if signL * signR == -1 {
        return simplifyMul(.number(-1), simplifyDiv(posL, posR))
    }
    if signL == -1 && signR == -1 {
        return simplifyDiv(posL, posR)
    }
    
    // x / 1 → x
    if case .number(1) = r { return l }
    
    // 0 / x → 0
    if case .number(0) = l { return .number(0) }
    
    // x / x → 1
    if l == r { return .number(1) }
    
    // x^n / x → x^(n-1)
    if case .binary(.pow, let base, let exp) = l, base == r {
        if case .number(let n) = exp { return .binary(op: .pow, left: base, right: .number(n - 1)) }
        return .binary(op: .pow, left: base, right: simplifyAdd(exp, .number(-1)))
    }
    
    // x / x^n → x^(1-n)
    if case .binary(.pow, let base, let exp) = r, base == l {
        if case .number(let n) = exp {
            return .binary(op: .pow, left: base, right: .number(1 - n))
        }
        return .binary(op: .pow,
                       left: base,
                       right: simplifyAdd(.number(1),
                                          .binary(op: .mul, left: .number(-1), right: exp)))
    }
    
    // general case – keep as-is for readable output
    return .binary(op: .div, left: l, right: r)
}

func simplifyMul(_ l: Expr, _ r: Expr) -> Expr {
    var factors: [Expr] = []
    collectMulFactors(l, into: &factors)
    collectMulFactors(r, into: &factors)
    return simplifyMulFactors(factors)
}

private func collectAddTerms(_ expr: Expr, into terms: inout [(sign: Int, expr: Expr)]) {
    switch expr {
        
    case .binary(.add, let l, let r):
        collectAddTerms(l, into: &terms)
        collectAddTerms(r, into: &terms)
        
    case .binary(.sub, let l, let r):
        collectAddTerms(l, into: &terms)
        collectAddTerms(.binary(op: .mul, left: .number(-1), right: r), into: &terms)
        
    case .binary(.mul, .number(-1), let inner):
        terms.append((-1, inner))
        
    default:
        terms.append((+1, expr))
    }
}

// Simple key for "identical term" grouping (not canonical algebra).
func debugKey(_ e: Expr) -> String {
    switch e {
    case .number(let n): return "N\(n)"
        
    case .variable(let i): return "V\(i)"
        
    case .constant(let name, _): return "C\(name)"
        
    case .binary(let op, let l, let r):
        let lk = debugKey(l), rk = debugKey(r)
        switch op {
        case .add, .mul:            // commutative: canonical child order
            let (a, b) = lk < rk ? (lk, rk) : (rk, lk)
            return "B\(op.rawValue)(\(a),\(b))"
        case .sub, .div, .pow,
                .lt, .le, .gt, .ge, .eq, .ne:      // non-commutative: order matters
            return "B\(op.rawValue)(\(lk),\(rk))"
        }
        
    case .function(let name, let args):
        // Function args are positional — order preserved
        return "F\(name)(" + args.map(debugKey).joined(separator: ",") + ")"
        
    case .ternary(let c, let t, let e):
        return "T(\(debugKey(c)),\(debugKey(t)),\(debugKey(e)))"
    }
}

private func simplifyAddTerms(_ raw: [(sign: Int, expr: Expr)]) -> Expr {
    
    var numeric: Double = 0
    var order: [String] = []
    var buckets: [String: (expr: Expr?, coeff: Double)] = [:]
    let numKey = "#NUM"
    
    for (sign, expr) in raw {
        let s = Double(sign)
        let e = simplify(expr)
        
        switch e {
            
        case .number(let n):
            numeric += s * n
            if buckets[numKey] == nil {
                order.append(numKey)
                buckets[numKey] = (expr: nil, coeff: 0)
            }
            buckets[numKey]!.coeff = numeric
            
        default:
            let (termCoeff, baseExpr) = termCoeffAndBase(e)
            let key = debugKey(baseExpr)
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = (expr: baseExpr, coeff: 0)
            }
            buckets[key]!.coeff += s * termCoeff
        }
        
    }
    
    var result: [Expr] = []
    
    for key in order {
        guard let entry = buckets[key] else { continue }
        let coeff = entry.coeff
        
        if key == numKey {
            if coeff != 0 {
                result.append(.number(coeff))
            }
            continue
        }
        
        guard let expr = entry.expr, coeff != 0 else { continue }
        
        if coeff == 1 {
            result.append(expr)
        } else if coeff == -1 {
            result.append(.binary(op: .mul, left: .number(-1), right: expr))
        } else {
            result.append(.binary(op: .mul, left: .number(coeff), right: expr))
        }
    }
    
    // if everything cancelled out
    if result.isEmpty { return .number(0) }
    
    // rebuild left‑associative addition
    return result.dropFirst().reduce(result.first!) { acc, next in
            .binary(op: .add, left: acc, right: next)
    }
}

func termCoeffAndBase(_ e: Expr) -> (Double, Expr) {
    switch e {
    case .binary(.mul, .number(let n), let base): return (n, base)
    default: return (1.0, e)
    }
}

private func collectMulFactors(_ expr: Expr, into factors: inout [Expr]) {
    switch expr {
        
    case .binary(let op, let l, let r) where op == .mul:
        collectMulFactors(l, into: &factors)
        collectMulFactors(r, into: &factors)
        
    default:
        factors.append(expr)
    }
}

private func rebuildMul(from factors: [Expr]) -> Expr {
    guard let first = factors.first else {
        return .number(1)
    }
    return factors.dropFirst().reduce(first) { acc, next in
            .binary(op: .mul, left: acc, right: next)
    }
}

private func simplifyMulFactors(_ rawFactors: [Expr]) -> Expr {
    let factors = rawFactors.map(simplify)
    
    var numeric: Double = 1
    var powerTerms: [(base: Expr, exp: Expr)] = []
    
    func addPower(base: Expr, exp newExp: Expr) {
        if let i = powerTerms.firstIndex(where: { $0.base == base }) {
            let oldExp = powerTerms[i].exp
            powerTerms[i].exp = simplifyAdd(oldExp, newExp)
        } else {
            powerTerms.append((base: base, exp: newExp))
        }
    }
    
    for f in factors {
        switch f {
        case .number(let n):
            // If n matches an existing power base, merge it as exponent +1
            if let i = powerTerms.firstIndex(where: {
                if case .number(let b) = $0.base { return b == n }
                return false
            }) {
                let oldExp = powerTerms[i].exp
                powerTerms[i].exp = simplifyAdd(oldExp, .number(1))
            } else {
                numeric *= n
            }
            
        case .binary(let op, let base, let exp) where op == .pow:
            addPower(base: base, exp: exp)
            
        default:
            addPower(base: f, exp: .number(1))
        }
    }
    
    if numeric == 0 { return .number(0) }
    
    // Fallback Recovery: If the product is large or triggers scientific notation strings,
    // test if it can be represented cleanly as a perfect integer power (e.g., 65536 * 32768 -> 2^31)
    if powerTerms.isEmpty && (abs(numeric) >= 100000 || String(format: "%g", numeric).lowercased().contains("e")) {
        if let (b, e) = findPerfectPower(abs(numeric)) {
            let sign = numeric < 0 ? -1.0 : 1.0
            if sign == 1.0 {
                powerTerms.append((.number(b), .number(e)))
                numeric = 1
            } else if Int(e) % 2 != 0 {
                powerTerms.append((.number(-b), .number(e)))
                numeric = 1
            } else {
                powerTerms.append((.number(b), .number(e)))
                numeric = -1
            }
        }
    }
    
    var result: [Expr] = []
    
    if numeric != 1 || powerTerms.isEmpty {
        result.append(.number(numeric))
    }
    
    for (base, exp) in powerTerms {
        let term = simplifyPow(base, exp)
        switch term {
        case .number(let n):
            if !result.isEmpty, case .number(let existing) = result[0] {
                result[0] = .number(existing * n)
            } else {
                result.insert(.number(n), at: 0)
            }
        default:
            result.append(term)
        }
    }
    
    // Final absolute consolidation pass for raw numeric values
    var finalFactors: [Expr] = []
    var finalNumeric: Double = 1
    for r in result {
        if case .number(let n) = r {
            finalNumeric *= n
        } else {
            finalFactors.append(r)
        }
    }
    
    if finalNumeric == 0 { return .number(0) }
    if finalNumeric != 1 || finalFactors.isEmpty {
        finalFactors.insert(.number(finalNumeric), at: 0)
    }
    
    return rebuildMul(from: finalFactors)
}

// Highly efficient perfect power checking utility using root factor strides
private func findPerfectPower(_ num: Double) -> (base: Double, exp: Double)? {
    guard num > 1, floor(num) == num else { return nil }
    
    let maxExp = Int(log2(num)) + 1
    guard maxExp >= 2 else { return nil }
    
    // Striding backwards handles lowest/cleanest base conversion efficiently
    for e in stride(from: maxExp, through: 2, by: -1) {
        let b = round(pow(num, 1.0 / Double(e)))
        if b >= 2 && floor(b) == b {
            if pow(b, Double(e)) == num {
                return (b, Double(e))
            }
        }
    }
    return nil
}

// MARK: - Evaluator

enum EvalResult: Sendable {
    case value(Double)
    case error(String)
}

func evaluate(_ expr: Expr, env: [Double]) -> EvalResult {
    switch expr {
        
    case .number(let n):
        return .value(n)
        
    case .variable(let i):
        guard i < env.count else {
            return .error("Missing value for variable \(i)")
        }
        return .value(env[i])
        
    case .constant(_, let value):
        return .value(value)
        
    case .ternary(let cond, let thenExpr, let elseExpr):
        let cv = evaluate(cond, env: env)
        guard case let .value(c) = cv else { return cv }
        // Short-circuit: only the taken branch is evaluated, so e.g. a guarded
        // division by zero on the untaken side never surfaces as an error.
        return c != 0 ? evaluate(thenExpr, env: env) : evaluate(elseExpr, env: env)
        
    case .binary(let op, let l, let r):
        // e^x evaluates via exp() directly rather than pow(e, x). Same result
        // either way, but exp() is the more direct computation for this case,
        // and it's the common one -- exp(x) itself folds into e^x during
        // simplify(), so this is on the hot path for any exponential model.
        if op == .pow, case .constant("e", _) = l {
            let rv = evaluate(r, env: env)
            guard case let .value(b) = rv else { return rv }
            return .value(exp(b))
        }
        
        let lv = evaluate(l, env: env)
        let rv = evaluate(r, env: env)
        
        guard case let .value(a) = lv else { return lv }
        guard case let .value(b) = rv else { return rv }
        
        switch op {
        case .add: return .value(a + b)
        case .sub: return .value(a - b)
        case .mul: return .value(a * b)
        case .div:
            if b == 0 { return .error("Division by zero") }
            return .value(a / b)
        case .pow:
            let result = pow(a, b)
            if result.isNaN { return .error("Invalid exponentiation") }
            return .value(result)
        case .lt: return .value(a < b ? 1 : 0)
        case .le: return .value(a <= b ? 1 : 0)
        case .gt: return .value(a > b ? 1 : 0)
        case .ge: return .value(a >= b ? 1 : 0)
        case .eq: return .value(a == b ? 1 : 0)
        case .ne: return .value(a != b ? 1 : 0)
        }
        
    case .function(let name, let args):
        let vals = args.map { evaluate($0, env: env) }
        
        for v in vals {
            if case .error = v { return v }
        }
        
        let v = vals.map { if case let .value(x) = $0 { return x } else { return .nan } }
        guard !v.isEmpty else { return .error("'\(name)' requires at least one argument") }
        
        switch name.lowercased() {
        case "sin": return .value(sin(v[0]))
        case "cos": return .value(cos(v[0]))
        case "tan": return .value(tan(v[0]))
        case "asin", "arcsin":
            if v[0] < -1 || v[0] > 1 { return .error("asin argument must be in [-1, 1]") }
            return .value(asin(v[0]))
        case "acos", "arccos":
            if v[0] < -1 || v[0] > 1 { return .error("acos argument must be in [-1, 1]") }
            return .value(acos(v[0]))
        case "atan", "arctan": return .value(atan(v[0]))
        case "atan2":
            guard v.count >= 2 else { return .error("'atan2' requires 2 arguments") }
            return .value(atan2(v[0], v[1]))
        case "sinh": return .value(sinh(v[0]))
        case "cosh": return .value(cosh(v[0]))
        case "tanh": return .value(tanh(v[0]))
        case "asinh": return .value(asinh(v[0]))
        case "acosh":
            if v[0] < 1 { return .error("acosh argument must be >= 1") }
            return .value(acosh(v[0]))
        case "atanh":
            if v[0] <= -1 || v[0] >= 1 { return .error("atanh argument must be in (-1, 1)") }
            return .value(atanh(v[0]))
        case "sqrt":
            if v[0] < 0 { return .error("Square root of negative number") }
            return .value(sqrt(v[0]))
        case "cbrt": return .value(cbrt(v[0]))
        case "log", "ln":
            if v[0] <= 0 { return .error("Log of non-positive number") }
            return .value(log(v[0]))
        case "log10":
            if v[0] <= 0 { return .error("Log of non-positive number") }
            return .value(log10(v[0]))
        case "log2":
            if v[0] <= 0 { return .error("Log of non-positive number") }
            return .value(log2(v[0]))
        case "exp": return .value(exp(v[0]))
        case "pow":
            // Normally folded into a .binary(.pow) node by simplify(), so this
            // only fires if evaluate() is called on an unsimplified AST.
            guard v.count >= 2 else { return .error("'pow' requires 2 arguments") }
            let result = pow(v[0], v[1])
            if result.isNaN { return .error("Invalid exponentiation") }
            return .value(result)
        case "abs": return .value(abs(v[0]))
        case "floor": return .value(floor(v[0]))
        case "ceil": return .value(ceil(v[0]))
        case "round": return .value(v[0].rounded())
        case "sign":
            return .value(v[0] > 0 ? 1 : (v[0] < 0 ? -1 : 0))
        case "min":
            guard v.count >= 2 else { return .error("'min' requires at least 2 arguments") }
            return .value(v.min()!)
        case "max":
            guard v.count >= 2 else { return .error("'max' requires at least 2 arguments") }
            return .value(v.max()!)
        default: return .error("Unknown function \(name)")
        }
    }
}

// MARK: - AST Serialization (Unparsing)

/// Converts a simplified AST back into a plain text mathematical string
/// that can be cleanly round-tripped back through the Parser or Evaluator.
/// (Pulled in without its AttributedString sibling `preFormat`/`format` — those
/// stay in the SwiftUI presenter app, since CompiledExpression has no UI needs.)

func decomposeSignedTerm(_ expr: Expr) -> (sign: Int, inner: Expr) {
    if let inner = unaryMinusInner(expr) { return (-1, inner) }
    else if case .number(let n) = expr, n < 0 { return (-1, .number(-n)) }
    else { return (1, expr) }
}

func precedence(_ expr: Expr) -> Int {
    switch expr {
    case .ternary: return 0
    case .binary(let op, _, _) where op.isComparison: return 1
    case .binary(.add, _, _),
            .binary(.sub, _, _): return 2
    case .binary(.mul, _, _): return 3
    case .binary(.div, _, _): return 3
    case .binary(.pow, _, _): return 4
    default:                  return 5
    }
}

func precedenceForOp(_ op: Op) -> Int {
    switch op {
    case .pow: return 4
    case .mul: return 3
    case .div: return 3
    case .add, .sub: return 2
    case .lt, .le, .gt, .ge, .eq, .ne: return 1
    }
}

func needsParens(parentOp: Op?, child: Expr, isRightOperand: Bool = false) -> Bool {
    // A ternary binds more loosely than everything else in the language, so
    // whenever it's embedded as a child of any other expression it needs
    // parens to round-trip correctly — even under another ternary's branches.
    if case .ternary = child, parentOp != nil { return true }
    guard let parentOp else { return false }
    // A right-hand */÷ operand that renders with a bare leading "-" (e.g. the
    // numerator of "-a/b") needs parens for two reasons: this grammar doesn't
    // allow a unary minus to immediately follow "*" or "/" (only "^" permits
    // it), so an unparenthesized "3*-a/b" wouldn't round-trip back through
    // the parser; and visually, "3·-a/b" reads as if the dot and minus
    // merged into a stray "-" sign next to the 3. The left operand doesn't
    // need this check: a leading "-" at the very start of an expression (or
    // right after another operator) is never ambiguous the same way.
    if isRightOperand, (parentOp == .mul || parentOp == .div), rendersLeadingMinus(child) {
        return true
    }
    let cp = precedence(child), pp = precedenceForOp(parentOp)
    if cp < pp { return true }
    if cp == pp && isRightOperand && (parentOp == .sub || parentOp == .div) { return true }
    return false
}

/// True if `expr` renders with a bare leading "-" that isn't already protected by its own parens. Deliberately narrow: a plain negative
/// number, or the canonical unary-minus marker `.binary(.mul, .number(-1), _)`, or (recursively) a division whose numerator
/// does. Every other construct either can't survive simplify() as an unparenthesized leading-minus mul/div sibling in the first place, or
/// already gets its own parens from the ordinary precedence rules above (e.g. a mul/add/sub used as a pow base) — so this doesn't
/// need to walk further than that.
func rendersLeadingMinus(_ expr: Expr) -> Bool {
    switch expr {
    case .number(let n):
        return n < 0
    case .binary(.mul, .number(-1), _):
        return true
    case .binary(.div, let l, _):
        return rendersLeadingMinus(l)
    default:
        return false
    }
}

func cleanupSigns(_ input: String) -> String {
    var s = input
    
    // Map exact patterns to exact replacements to preserve spacing context
    let replacements: [(pattern: String, replacement: String)] = [
        ("- -", "+ "), ("--", "+"), ("+ -", "- "), ("+-", "-")
    ]
    
    // Continuously sweep the string until no more double-signs exist.
    // This ensures that edge cases like "---" properly collapse down to "-".
    var previousState: String
    repeat {
        previousState = s
        for (pattern, replacement) in replacements {
            s = s.replacingOccurrences(of: pattern, with: replacement)
        }
    } while s != previousState
    
    return s
}

func toRawExpression(_ rawExpr: Expr, vars: VariableTable, parentOp: Op? = nil, isRightOperand: Bool = false, isExponent: Bool = false) -> String {
    // Normalize raw negative numbers (e.g. -5 -> -1 * 5) so the unary minus layout logic catches them uniformly
    let expr = normalizeNegativeNumber(rawExpr)
    var result = ""
    
    switch expr {
    case .number(let n):
        result = String(format: "%g", n)
        
    case .variable(let i):
        result = vars.name(for: i) ?? "x"
        
    case .constant(let name, _):
        result = name
        
    case .binary(.mul, .number(-1), let inner):
        let innerStr = toRawExpression(inner, vars: vars, parentOp: .mul, isRightOperand: true, isExponent: isExponent)
        let exprStr = "-\(innerStr)"
        
        var wrap = needsParens(parentOp: parentOp, child: expr, isRightOperand: isRightOperand)
        
        // Safety fallback: If this unary minus sits on the right side of a multiplication, division, or power
        // it is much safer for round-tripping to explicitly wrap it as a * (-b).
        if isRightOperand && (parentOp == .mul || parentOp == .div || parentOp == .pow) {
            wrap = true
        }
        
        result = wrap ? "(\(exprStr))" : exprStr
        
    case .binary(.add, let l, let r):
        let leftStr = toRawExpression(l, vars: vars, parentOp: .add, isRightOperand: false, isExponent: isExponent)
        let (signR, innerR) = decomposeSignedTerm(r)
        let rightStr = toRawExpression(innerR, vars: vars, parentOp: .add, isRightOperand: true, isExponent: isExponent)
        
        let opStr = signR < 0 ? (isExponent ? "-" : " - ") : (isExponent ? "+" : " + ")
        let exprStr = "\(leftStr)\(opStr)\(rightStr)"
        
        if needsParens(parentOp: parentOp, child: expr, isRightOperand: isRightOperand) {
            return "(\(exprStr))"
        }
        result = exprStr
        
    case .binary(.sub, let l, let r):
        let leftStr = toRawExpression(l, vars: vars, parentOp: .sub, isRightOperand: false, isExponent: isExponent)
        let (signR, innerR) = decomposeSignedTerm(r)
        let rightStr = toRawExpression(innerR, vars: vars, parentOp: .sub, isRightOperand: true, isExponent: isExponent)
        
        let opStr = signR < 0 ? (isExponent ? "+" : " + ") : (isExponent ? "-" : " - ")
        let exprStr = "\(leftStr)\(opStr)\(rightStr)"
        
        if needsParens(parentOp: parentOp, child: expr, isRightOperand: isRightOperand) {
            return "(\(exprStr))"
        }
        result = exprStr
        
    case .binary(.pow, let base, let exp):
        let leftStr = toRawExpression(base, vars: vars, parentOp: .pow, isRightOperand: false, isExponent: isExponent)
        let rightStr = toRawExpression(exp, vars: vars, parentOp: .pow, isRightOperand: true, isExponent: true)
        
        let exprStr = "\(leftStr)^\(rightStr)"
        
        if needsParens(parentOp: parentOp, child: expr, isRightOperand: isRightOperand) {
            return "(\(exprStr))"
        }
        result = exprStr
        
    case .binary(let op, let l, let r):
        let leftStr = toRawExpression(l, vars: vars, parentOp: op, isRightOperand: false, isExponent: isExponent)
        let rightStr = toRawExpression(r, vars: vars, parentOp: op, isRightOperand: true, isExponent: isExponent)
        
        let exprStr = "\(leftStr)\(op.rawValue)\(rightStr)"
        
        if needsParens(parentOp: parentOp, child: expr, isRightOperand: isRightOperand) {
            return "(\(exprStr))"
        }
        result = exprStr
        
    case .function(let name, let args):
        let separator = isExponent ? "," : ", "
        let argsStr = args.map { toRawExpression($0, vars: vars, isExponent: isExponent) }.joined(separator: separator)
        result = "\(name)(\(argsStr))"
        
    case .ternary(let c, let t, let e):
        let condStr = toRawExpression(c, vars: vars, isExponent: isExponent)
        let thenStr = toRawExpression(t, vars: vars, isExponent: isExponent)
        let elseStr = toRawExpression(e, vars: vars, isExponent: isExponent)
        let exprStr = isExponent ? "\(condStr)?\(thenStr):\(elseStr)" : "\(condStr) ? \(thenStr) : \(elseStr)"
        
        if needsParens(parentOp: parentOp, child: expr, isRightOperand: isRightOperand) {
            result = "(\(exprStr))"
        } else {
            result = exprStr
        }
    }
    
    return cleanupSigns(result)
}

// MARK: - Compiled Expression

/// Parses a math expression once, simplifies it, and caches the resulting AST so it can be evaluated repeatedly against many (x, parameters) pairs
/// without re-parsing — the hot path for curve fitting.
///
/// "x" is always the independent variable; every other identifier discovered while parsing (excluding named constants like pi/e) becomes a fit
/// parameter, listed in `parameterNames` in first-use order.
struct CompiledExpression: Sendable {
    let source: String
    let parameterNames: [String]
    private let ast: Expr
    private let vars: VariableTable
    
    init(source: String) throws {
        self.source = source
        let parser = Parser(source)
        let rawAST = try parser.parse()
        self.ast = simplify(rawAST)
        self.vars = parser.vars
        // vars.indexToName[0] is always "x" (registered in VariableTable.init),
        // so everything after it is a genuine fit parameter, in first-use order.
        self.parameterNames = Array(vars.indexToName.dropFirst())
    }
    
    /// Fast, non-throwing evaluator for tight fitting loops. `parameters` must be ordered to match `parameterNames`; if it's shorter, missing entries
    /// default to 1.0. On any evaluation error (divide-by-zero, log of a negative number, etc.) this returns `.nan` so callers can treat it like
    /// any other invalid residual instead of handling a thrown error per-sample.
    func evaluateFast(x: Double, parameters: [Double]) -> Double {
        var env = [Double](repeating: 1.0, count: vars.count)
        if vars.count > 0 { env[0] = x }
        for i in 0..<parameterNames.count {
            let envIndex = i + 1
            guard envIndex < vars.count else { break }
            env[envIndex] = i < parameters.count ? parameters[i] : 1.0
        }
        switch evaluate(ast, env: env) {
        case .value(let v): return v
        case .error: return .nan
        }
    }
    
    /// Same evaluation, but with the error message preserved — handy for surfacing "why did this fail" in a UI rather than a bare NaN.
    func evaluateDetailed(x: Double, parameters: [Double]) -> EvalResult {
        var env = [Double](repeating: 1.0, count: vars.count)
        if vars.count > 0 { env[0] = x }
        for i in 0..<parameterNames.count {
            let envIndex = i + 1
            guard envIndex < vars.count else { break }
            env[envIndex] = i < parameters.count ? parameters[i] : 1.0
        }
        return evaluate(ast, env: env)
    }
    
    /// Convenience overload for callers that prefer name-keyed parameters over a positional array ordered by `parameterNames`.
    func evaluateFast(x: Double, parameters: [String: Double]) -> Double {
        let ordered = parameterNames.map { parameters[$0] ?? 1.0 }
        return evaluateFast(x: x, parameters: ordered)
    }
    
    /// The simplified expression, rendered back to a plain-text string (e.g. "3*x^2 + 2" collapses redundant terms). Useful for display or
    /// for round-tripping into a fresh CompiledExpression.
    func simplifiedSource() -> String {
        toRawExpression(ast, vars: vars)
    }
}
