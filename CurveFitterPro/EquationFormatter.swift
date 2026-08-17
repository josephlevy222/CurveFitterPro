import SwiftUI
// MARK: - Equation Formatter
//
// SwiftUI-facing presentation layer for equations. Everything that needs
// AttributedString + Color lives here, on top of the shared, UI-free engine
// in ExpressionParser.swift (Parser / Expr / VariableTable / simplify /
// toRawExpression / needsParens / decomposeSignedTerm / normalizeNegativeNumber).
// ExpressionParser.swift stays free of SwiftUI so it can be used from the
// fast fitting path without pulling in the UI framework.

enum EquationFormatter {
    
    /// Parses, simplifies, and re-serializes an expression to a clean plain
    /// string (e.g. "3*x^2 + 2 - 2" -> "3*x^2"). Falls back to the original
    /// text, unchanged, if it doesn't parse — callers store this as they type,
    /// so a bad in-progress edit shouldn't get mangled or lose the user's text.
    static func formatToPlainString(_ expression: String) -> String {
        guard !expression.isEmpty else { return expression }
        do {
            let parser = Parser(expression)
            let ast = simplify(try parser.parse())
            return toRawExpression(ast, vars: parser.vars)
        } catch {
            return expression
        }
    }
    
    /// Rich, colorized rendering with true baseline-shifted exponents and
    /// subscripted parameter names (e.g. "sigma.max" renders as sigma with a
    /// small "max" subscript). Falls back to plain text at the requested size
    /// if the expression doesn't parse.
    static func formatToAttributedStringEquation(_ expression: String, fontSize: CGFloat = 15) -> AttributedString {
        guard !expression.isEmpty else { return AttributedString(expression) }
        do {
            let parser = Parser(expression)
            let ast = simplify(try parser.parse())
            return format(ast, vars: parser.vars, fontSize: fontSize)
        } catch {
            var s = AttributedString(expression)
            s.font = .system(size: fontSize, design: .monospaced)
            s.foregroundColor = .secondary
            return s
        }
    }
}

// MARK: - Variable name subscripting

/// Renders a variable name like "sigma.max" or "α.max" as base + subscript.  Names with no "." render as plain text at the given size, unchanged.
/// Sets font explicitly on every run it returns, so callers should NOT set `.font` on the result afterward — doing so would apply uniformly across
/// the whole string and erase the subscript's smaller size.
private func formatVariableName(_ name: String, fontSize: CGFloat) -> AttributedString {
    guard let dotIndex = name.firstIndex(of: ".") else {
        var s = AttributedString(name)
        s.font = .system(size: fontSize)
        return s
    }
    let base = String(name[name.startIndex..<dotIndex])
    let sub  = String(name[name.index(after: dotIndex)...])
    
    var baseStr = AttributedString(base)
    baseStr.font = .system(size: fontSize)
    
    var subStr = AttributedString(sub)
    subStr.font = .system(size: fontSize * 0.7)
    subStr.baselineOffset = -fontSize * 0.2
    
    return baseStr + subStr
}

// MARK: - Implicit-multiplication dot

private func startsWithVariable(_ expr: Expr) -> Bool {
    switch expr {
    case .variable:              true
    case .binary(_, let l, _):   startsWithVariable(l)
    default:                     false
    }
}

private func needsDot(_ l: Expr, _ r: Expr) -> Bool {
    switch (l, r) {
    case (.number, .variable):     return false
    case (.number, .function):     return false
    case (.number, .binary):
        // "2(x + 1)"  — binary will be wrapped in parens in a mul context
        if needsParens(parentOp: .mul, child: r, isRightOperand: true) { return false }
        // "2x²", "2x/y"  — binary's first rendered character is a variable
        if startsWithVariable(r) { return false }
        return true
        
    case (.number, .number):       return true
    case (.variable, .variable):   return true
    case (.variable, .binary):     return true
    case (.binary, .variable):     return true
    case (.binary, .binary):       return true
    case (_, .function):           return true
    case (.function, _):           return true
    case (_, .variable):           return true
    case (_, .number):             return true
        
    default:                       return false
    }
}

// MARK: - Parenthesis wrapping

private func wrapIfNeeded(_ s: AttributedString, parentOp: Op?, child: Expr, fontSize: CGFloat, isExponent: Bool, isRightOperand: Bool = false) -> AttributedString {
    guard needsParens(parentOp: parentOp, child: child, isRightOperand: isRightOperand) else { return s }
    let font = Font.system(size: isExponent ? fontSize * 0.7 : fontSize)
    var open = AttributedString("(")
    open.font = font
    var close = AttributedString(")")
    close.font = font
    var result = open
    result.append(s)
    result.append(close)
    return result
}

// MARK: - Baseline offset stacking

/// Adds `delta` to the baselineOffset of every run in `s`, on top of whatever offset (if any) that run already has, rather than overwriting it. This is
/// what lets a subscripted variable name inside an exponent (e.g. "e^(V.50 - x)") keep its own relative shift instead of an outer superscript's blanket
/// baselineOffset assignment clobbering it — both offsets compose instead of the last one written winning.
private func addBaselineOffset(_ delta: CGFloat, to s: AttributedString) -> AttributedString {
    var result = s
    for run in s.runs {
        let existing = run.baselineOffset ?? 0
        result[run.range].baselineOffset = existing + delta
    }
    return result
}

// MARK: - Sign cleanup (AttributedString)

/// Collapses adjacent sign runs ("- -" -> "+", "+ -" -> "-", etc.) that can appear once negative terms are decomposed and re-joined, while preserving
/// the font/color attributes of the run being kept.
private func cleanupSigns(_ input: AttributedString) -> AttributedString {
    var s = input
    
    let replacements: [(pattern: String, replacement: String)] = [
        ("- -", "+ "), ("-\u{2009}-", "+\u{2009}"), ("--", "+"),
        ("+ -", "- "), ("+\u{2009}-", "-\u{2009}"), ("+-", "-")
    ]
    
    for (pattern, replacement) in replacements {
        var searchStart = s.startIndex
        
        while searchStart < s.endIndex,
              let range = s[searchStart..<s.endIndex].range(of: pattern) {
            
            // Grab the attributes of the first character to preserve formatting (colors, fonts, and baseline offsets)
            let attrs = s[range.lowerBound..<s.index(afterCharacter: range.lowerBound)].runs.first?.attributes ?? AttributeContainer()
            
            var newAttrStr = AttributedString(replacement)
            newAttrStr.setAttributes(attrs)
            
            s.replaceSubrange(range, with: newAttrStr)
            searchStart = s.index(s.startIndex, offsetByCharacters: s.characters.distance(from: s.startIndex, to: range.lowerBound) + replacement.count)
        }
    }
    return s
}

// MARK: - Core recursive formatter

private func preFormat(_ rawExpr: Expr, vars: VariableTable, fontSize: CGFloat, parentOp: Op? = nil, isRightOperand: Bool = false, isExponent: Bool = false, colorize: Bool = true) -> AttributedString {
    let expr = normalizeNegativeNumber(rawExpr)
    let baseFont = Font.system(size: isExponent ? fontSize * 0.7 : fontSize)
    
    var formatted = AttributedString()
    switch expr {
        
        // numbers
    case .number(let n):
        var s = AttributedString(String(format: "%g", n))
        s.font = baseFont
        if colorize { s.foregroundColor = .blue }
        formatted = s
        
        // variables
    case .variable(let i):
        if let name = vars.name(for: i) {
            var s = formatVariableName(name, fontSize: isExponent ? fontSize * 0.7 : fontSize)
            if colorize { s.foregroundColor = .green }
            formatted = s
        } else {
            var s = AttributedString("<?>")
            s.font = baseFont
            if colorize { s.foregroundColor = .red }
            formatted = s
        }
        
        // built-in constants (π, e, ...)
    case .constant(let name, _):
        var s = AttributedString(name)
        s.font = baseFont
        if colorize { s.foregroundColor = .purple }
        formatted = s
        
        // unary minus: -x
    case .binary(.mul, .number(-1), let inner):
        var s = AttributedString("-")
        s.font = baseFont
        s.append(preFormat(inner, vars: vars, fontSize: fontSize, parentOp: .mul, isRightOperand: true, isExponent: isExponent, colorize: colorize))
        formatted = wrapIfNeeded(s, parentOp: parentOp, child: expr, fontSize: fontSize, isExponent: isExponent, isRightOperand: isRightOperand)
        
        // exponent
    case .binary(.pow, let base, let exp):
        var baseStr = preFormat(base, vars: vars, fontSize: fontSize, parentOp: .pow, isExponent: isExponent, colorize: colorize)
        // Force isExponent to true for the exponent branch
        let expStr = addBaselineOffset(fontSize * 0.4, to: preFormat(exp, vars: vars, fontSize: fontSize, isExponent: true, colorize: colorize))
        
        baseStr.append(expStr)
        formatted = wrapIfNeeded(baseStr, parentOp: parentOp, child: expr, fontSize: fontSize, isExponent: isExponent, isRightOperand: isRightOperand)
        
        // addition
    case .binary(.add, let l, let r):
        var s = preFormat(l, vars: vars, fontSize: fontSize, parentOp: .add, isExponent: isExponent, colorize: colorize)
        let (signR, innerR) = decomposeSignedTerm(r)
        
        var opStr = AttributedString(signR < 0
                                      ? (isExponent ? "-" : "\u{2009}-\u{2009}")
                                      : (isExponent ? "+" : "\u{2009}+\u{2009}"))
        opStr.font = baseFont
        s.append(opStr)
        s.append(preFormat(innerR, vars: vars, fontSize: fontSize, parentOp: .add, isRightOperand: true, isExponent: isExponent, colorize: colorize))
        
        return wrapIfNeeded(s, parentOp: parentOp, child: expr, fontSize: fontSize, isExponent: isExponent, isRightOperand: isRightOperand)
        
        // subtraction
    case .binary(.sub, let l, let r):
        var s = preFormat(l, vars: vars, fontSize: fontSize, parentOp: .sub, isExponent: isExponent, colorize: colorize)
        let (signR, innerR) = decomposeSignedTerm(r)
        
        var opStr = AttributedString(signR < 0
                                      ? (isExponent ? "+" : "\u{2009}+\u{2009}")
                                      : (isExponent ? "-" : "\u{2009}-\u{2009}"))
        opStr.font = baseFont
        s.append(opStr)
        s.append(preFormat(innerR, vars: vars, fontSize: fontSize, parentOp: .sub, isRightOperand: true, isExponent: isExponent, colorize: colorize))
        
        return wrapIfNeeded(s, parentOp: parentOp, child: expr, fontSize: fontSize, isExponent: isExponent, isRightOperand: isRightOperand)
        
        // explicit/implicit multiplication
    case .binary(.mul, let l, let r):
        var s = preFormat(l, vars: vars, fontSize: fontSize, parentOp: .mul, isExponent: isExponent, colorize: colorize)
        var sep = AttributedString(needsDot(l, r) ? "·" : (isExponent ? "" : "\u{2009}"))
        sep.font = baseFont
        s.append(sep)
        s.append(preFormat(r, vars: vars, fontSize: fontSize, parentOp: .mul, isRightOperand: true, isExponent: isExponent, colorize: colorize))
        formatted = wrapIfNeeded(s, parentOp: parentOp, child: expr, fontSize: fontSize, isExponent: isExponent, isRightOperand: isRightOperand)
        
        // division
    case .binary(.div, let l, let r):
        var s = preFormat(l, vars: vars, fontSize: fontSize, parentOp: .div, isExponent: isExponent, colorize: colorize)
        var sep = AttributedString(isExponent ? "/" : "\u{2009}/\u{2009}")
        sep.font = baseFont
        s.append(sep)
        s.append(preFormat(r, vars: vars, fontSize: fontSize, parentOp: .div, isRightOperand: true, isExponent: isExponent, colorize: colorize))
        formatted = wrapIfNeeded(s, parentOp: parentOp, child: expr, fontSize: fontSize, isExponent: isExponent, isRightOperand: isRightOperand)
        
        // comparisons: <, <=, >, >=, ==, != (only ever appear as a ternary's condition)
    case .binary(let op, let l, let r):
        var s = preFormat(l, vars: vars, fontSize: fontSize, parentOp: op, isExponent: isExponent, colorize: colorize)
        var sep = AttributedString(isExponent ? op.rawValue : "\u{2009}\(op.rawValue)\u{2009}")
        sep.font = baseFont
        s.append(sep)
        s.append(preFormat(r, vars: vars, fontSize: fontSize, parentOp: op, isRightOperand: true, isExponent: isExponent, colorize: colorize))
        formatted = wrapIfNeeded(s, parentOp: parentOp, child: expr, fontSize: fontSize, isExponent: isExponent, isRightOperand: isRightOperand)
        
        // functions
    case .function(let name, let args):
        var s = AttributedString(name)
        s.font = baseFont
        var open = AttributedString("(")
        open.font = baseFont
        s.append(open)
        for (i, a) in args.enumerated() {
            if i > 0 {
                var comma = AttributedString(isExponent ? "," : ", ")
                comma.font = baseFont
                s.append(comma)
            }
            s.append(preFormat(a, vars: vars, fontSize: fontSize, isExponent: isExponent, colorize: colorize))
        }
        var close = AttributedString(")")
        close.font = baseFont
        s.append(close)
        formatted = s
        
        // ternary: cond ? then : else
    case .ternary(let c, let t, let e):
        var s = preFormat(c, vars: vars, fontSize: fontSize, isExponent: isExponent, colorize: colorize)
        var qMark = AttributedString(isExponent ? "?" : "\u{2009}?\u{2009}")
        qMark.font = baseFont
        s.append(qMark)
        s.append(preFormat(t, vars: vars, fontSize: fontSize, isExponent: isExponent, colorize: colorize))
        var colon = AttributedString(isExponent ? ":" : "\u{2009}:\u{2009}")
        colon.font = baseFont
        s.append(colon)
        s.append(preFormat(e, vars: vars, fontSize: fontSize, isExponent: isExponent, colorize: colorize))
        formatted = wrapIfNeeded(s, parentOp: parentOp, child: expr, fontSize: fontSize, isExponent: isExponent, isRightOperand: isRightOperand)
    }
    return formatted
}

private func format(_ expr: Expr, vars: VariableTable, fontSize: CGFloat, parentOp: Op? = nil, colorize: Bool = false) -> AttributedString {
    let preformatOutput = AttributedString("y = ") + preFormat(expr, vars: vars, fontSize: fontSize, parentOp: parentOp, colorize: colorize)
    return cleanupSigns(preformatOutput)
}
