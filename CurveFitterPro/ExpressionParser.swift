import Foundation

// MARK: - Expression Parser
//
// A lightweight recursive-descent math expression parser.
// Supports: +, -, *, /, ^, unary minus, parentheses,
//           and built-in functions: exp, log, log10, log2,
//           sin, cos, tan, asin, acos, atan, sqrt, abs, pow, sign
//
// Variables are supplied as a [String: Double] context at evaluation time.
// The independent variable is always "x".

enum ExprError: Error, LocalizedError {
    case unexpectedChar(Character)
    case unexpectedEnd
    case unknownVariable(String)
    case unknownFunction(String)
    case divisionByZero
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedChar(let c): return "Unexpected character: '\(c)'"
        case .unexpectedEnd: return "Unexpected end of expression"
        case .unknownVariable(let v): return "Unknown variable: '\(v)'"
        case .unknownFunction(let f): return "Unknown function: '\(f)'"
        case .divisionByZero: return "Division by zero"
        case .parseError(let m): return m
        }
    }
}

// MARK: - AST Nodes

indirect enum ExprNode: Sendable {
    case number(Double)
    case variable(String)
    case unaryMinus(ExprNode)
    case binary(op: Character, left: ExprNode, right: ExprNode)
    case call(name: String, args: [ExprNode])
}

// MARK: - Parser

struct ExpressionParser {

    private let input: [Character]
    private var pos: Int = 0

    init(_ source: String) {
        self.input = Array(source)
    }

    mutating func parse() throws -> ExprNode {
        let node = try parseExpr()
        skipSpaces()
        if pos < input.count {
            throw ExprError.unexpectedChar(input[pos])
        }
        return node
    }

    // ── Grammar ──────────────────────────────────────────────────────────
    // expr   → term (('+' | '-') term)*
    // term   → factor (('*' | '/') factor)*
    // factor → power ('^' factor)?         (right-assoc)
    // power  → '-' power | atom
    // atom   → number | '(' expr ')' | identifier ['(' args ')']

    private mutating func parseExpr() throws -> ExprNode {
        var left = try parseTerm()
        while true {
            skipSpaces()
            if peek() == "+" { advance(); left = .binary(op: "+", left: left, right: try parseTerm()) }
            else if peek() == "-" { advance(); left = .binary(op: "-", left: left, right: try parseTerm()) }
            else { break }
        }
        return left
    }

    private mutating func parseTerm() throws -> ExprNode {
        var left = try parsePower()
        while true {
            skipSpaces()
            if peek() == "*" { advance(); left = .binary(op: "*", left: left, right: try parsePower()) }
            else if peek() == "/" { advance(); left = .binary(op: "/", left: left, right: try parsePower()) }
            else { break }
        }
        return left
    }

    private mutating func parsePower() throws -> ExprNode {
        let base = try parseUnary()
        skipSpaces()
        if peek() == "^" {
            advance()
            let exp = try parsePower()  // right-associative
            return .binary(op: "^", left: base, right: exp)
        }
        return base
    }

    private mutating func parseUnary() throws -> ExprNode {
        skipSpaces()
        if peek() == "-" { advance(); return .unaryMinus(try parseUnary()) }
        return try parseAtom()
    }

    private mutating func parseAtom() throws -> ExprNode {
        skipSpaces()
        guard pos < input.count else { throw ExprError.unexpectedEnd }
        let c = input[pos]

        // Number
        if c.isNumber || c == "." {
            return .number(try parseNumber())
        }

        // Parenthesis
        if c == "(" {
            advance()
            let inner = try parseExpr()
            skipSpaces()
            guard peek() == ")" else { throw ExprError.parseError("Expected ')'") }
            advance()
            return inner
        }

        // Identifier (variable or function)
        if c.isLetter || c == "_" {
            let name = parseIdentifier()
            skipSpaces()
            if peek() == "(" {
                advance()
                var args: [ExprNode] = []
                skipSpaces()
                if peek() != ")" {
                    args.append(try parseExpr())
                    while peek() == "," {
                        advance()
                        args.append(try parseExpr())
                    }
                }
                skipSpaces()
                guard peek() == ")" else { throw ExprError.parseError("Expected ')' after function args") }
                advance()
                return .call(name: name, args: args)
            }
            return .variable(name)
        }

        throw ExprError.unexpectedChar(c)
    }

    private mutating func parseNumber() throws -> Double {
        var s = ""
        while pos < input.count && (input[pos].isNumber || input[pos] == ".") {
            s.append(input[pos]); pos += 1
        }
        // Optional exponent
        if pos < input.count && (input[pos] == "e" || input[pos] == "E") {
            s.append(input[pos]); pos += 1
            if pos < input.count && (input[pos] == "+" || input[pos] == "-") {
                s.append(input[pos]); pos += 1
            }
            while pos < input.count && input[pos].isNumber {
                s.append(input[pos]); pos += 1
            }
        }
        guard let v = Double(s) else { throw ExprError.parseError("Bad number: \(s)") }
        return v
    }

    private mutating func parseIdentifier() -> String {
        var s = ""
        while pos < input.count && (input[pos].isLetter || input[pos].isNumber || input[pos] == "_") {
            s.append(input[pos]); pos += 1
        }
        return s
    }

    @discardableResult
    private mutating func advance() -> Character {
        let c = input[pos]; pos += 1; return c
    }

    private func peek() -> Character? {
        pos < input.count ? input[pos] : nil
    }

    private mutating func skipSpaces() {
        while pos < input.count && input[pos].isWhitespace { pos += 1 }
    }
}

// MARK: - Evaluator

struct ExpressionEvaluator {

    static func evaluate(_ node: ExprNode, context: [String: Double]) throws -> Double {
        switch node {
        case .number(let v):
            return v

        case .variable(let name):
            // Built-in constants
            if name == "pi" || name == "π" { return Double.pi }
            if name == "e" { return M_E }
            guard let v = context[name] else { throw ExprError.unknownVariable(name) }
            return v

        case .unaryMinus(let child):
            return try -evaluate(child, context: context)

        case .binary(let op, let left, let right):
            let l = try evaluate(left, context: context)
            let r = try evaluate(right, context: context)
            switch op {
            case "+": return l + r
            case "-": return l - r
            case "*": return l * r
            case "/":
                if r == 0 { throw ExprError.divisionByZero }
                return l / r
            case "^": return pow(l, r)
            default: throw ExprError.parseError("Unknown operator: \(op)")
            }

        case .call(let name, let args):
            return try evalFunction(name: name, args: args, context: context)
        }
    }

    private static func evalFunction(name: String, args: [ExprNode], context: [String: Double]) throws -> Double {
        func a(_ i: Int) throws -> Double { try evaluate(args[i], context: context) }
        func require(_ n: Int) throws {
            guard args.count == n else { throw ExprError.parseError("\(name)() requires \(n) arg(s)") }
        }

        switch name {
        case "exp":   try require(1); return exp(try a(0))
        case "log", "ln": try require(1); return log(try a(0))
        case "log10": try require(1); return log10(try a(0))
        case "log2":  try require(1); return log2(try a(0))
        case "sqrt":  try require(1); return sqrt(try a(0))
        case "abs":   try require(1); return abs(try a(0))
        case "sin":   try require(1); return sin(try a(0))
        case "cos":   try require(1); return cos(try a(0))
        case "tan":   try require(1); return tan(try a(0))
        case "asin":  try require(1); return asin(try a(0))
        case "acos":  try require(1); return acos(try a(0))
        case "atan":  try require(1); return atan(try a(0))
        case "atan2": try require(2); return atan2(try a(0), try a(1))
        case "pow":   try require(2); return pow(try a(0), try a(1))
        case "sign":  try require(1); let v = try a(0); return v > 0 ? 1 : v < 0 ? -1 : 0
        case "ceil":  try require(1); return ceil(try a(0))
        case "floor": try require(1); return floor(try a(0))
        case "min":   try require(2); return min(try a(0), try a(1))
        case "max":   try require(2); return max(try a(0), try a(1))
        default: throw ExprError.unknownFunction(name)
        }
    }
}

// MARK: - Compiled Expression (cached AST)

struct CompiledExpression: Sendable {
    let source: String
    let ast: ExprNode
    let parameterNames: [String]  // detected non-x variables

    init(source: String) throws {
        self.source = source
        var parser = ExpressionParser(source)
        self.ast = try parser.parse()
        // Preserve expression order, deduplicate, exclude known constants
        let excluded: Set<String> = ["x", "pi", "e", "π"]
        var seen = Set<String>()
        self.parameterNames = CompiledExpression.extractVariables(ast)
            .filter { excluded.contains($0) == false && seen.insert($0).inserted }
    }

    func evaluate(x: Double, parameters: [String: Double]) throws -> Double {
        var ctx = parameters
        ctx["x"] = x
        return try ExpressionEvaluator.evaluate(ast, context: ctx)
    }

    private static func extractVariables(_ node: ExprNode) -> [String] {
        switch node {
        case .number: return []
        case .variable(let n): return [n]
        case .unaryMinus(let child): return extractVariables(child)
        case .binary(_, let l, let r): return extractVariables(l) + extractVariables(r)
        case .call(_, let args): return args.flatMap { extractVariables($0) }
        }
    }
}
