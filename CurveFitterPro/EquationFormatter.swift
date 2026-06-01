//
//  EquationFormatter.swift
//  CurveFitterPro
//
//  Created by Joseph Levy on 5/31/26.
//
import SwiftUI
import UIKit

public struct EquationFormatter {
	
	private struct ParseState {
		let fontSize: CGFloat
		let baselineOffset: Double
	}
	
	/// Scans and eliminates ALL variations of pow(base, exponent) regardless of content.
	private static func eliminatePow(_ expression: String) -> String {
		var src = expression
		let pattern = #"\bpow\s*\(\s*((?:[^,()]+|\([^()]*\))+)\s*,\s*((?:[^()]+|\([^()]*\))+)\)"#
		let regex = try! NSRegularExpression(pattern: pattern, options: [])
		
		var changed = true
		var iterations = 0
		while changed && iterations < 15 {
			let nsString = src as NSString
			if let match = regex.firstMatch(in: src, options: [], range: NSRange(location: 0, length: nsString.length)) {
				let baseRange = match.range(at: 1)
				let expRange = match.range(at: 2)
				
				let base = nsString.substring(with: baseRange).trimmingCharacters(in: .whitespaces)
				let exponent = nsString.substring(with: expRange).trimmingCharacters(in: .whitespaces)
				
				let containsOperators = base.contains("+") || base.contains("-") || base.contains("*") || base.contains("/")
				let isGrouped = base.hasPrefix("(") && base.hasSuffix(")")
				let replacementBase = (containsOperators && !isGrouped) ? "(\(base))" : base
				
				let replacement = "\(replacementBase)^[\(exponent)]"
				src = nsString.replacingCharacters(in: match.range, with: replacement)
			} else {
				changed = false
			}
			iterations += 1
		}
		return src
	}
	
	/// Formats a raw mathematical string into a typographically styled AttributedString supporting recursive superscripts and subscripts.
	public static func formatToAttributedString(_ expression: String, fontSize: CGFloat = 13, includeLHS: Bool = true) -> AttributedString {
		var eq = expression
		
		if eq.hasPrefix("y =") {
			eq = String(eq.dropFirst(3)).trimmingCharacters(in: .whitespaces)
		} else if eq.hasPrefix("y=") {
			eq = String(eq.dropFirst(2)).trimmingCharacters(in: .whitespaces)
		}
		
		// 1. 🎯 UPDATED: Shield verbatim blocks starting with a single backslash (e.g., \slope)
		var verbatimBlocks: [String] = []
		let verbatimRegex = try! NSRegularExpression(pattern: #"\\([A-Za-z0-9_]+)"#, options: [])
		while true {
			let nsString = eq as NSString
			if let match = verbatimRegex.firstMatch(in: eq, options: [], range: NSRange(location: 0, length: nsString.length)) {
				let content = nsString.substring(with: match.range(at: 1)) // Captures just the word
				verbatimBlocks.append(content)
				let placeholder = "__VERBATIM_BLOCK_\(verbatimBlocks.count - 1)__"
				eq = nsString.replacingCharacters(in: match.range, with: placeholder) // Replaces "\slope" entirely
			} else {
				break
			}
		}
		
		// 2. Eliminate ALL pow(_, _) variations completely
		eq = eliminatePow(eq)
		
		// 3. Collapse repeated multiplications (e.g. sigma * sigma -> sigma^[2])
		eq = eq.replacingOccurrences(of: #"(?<!\w)([a-zA-Z_]\w*|\([^()]+\))\s*\*\s*\1\s*\*\s*\1\s*\*\s*\1\s*\*\s*\1(?!\w)"#, with: "$1^[5]", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"(?<!\w)([a-zA-Z_]\w*|\([^()]+\))\s*\*\s*\1\s*\*\s*\1\s*\*\s*\1(?!\w)"#, with: "$1^[4]", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"(?<!\w)([a-zA-Z_]\w*|\([^()]+\))\s*\*\s*\1\s*\*\s*\1(?!\w)"#, with: "$1^[3]", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"(?<!\w)([a-zA-Z_]\w*|\([^()]+\))\s*\*\s*\1(?!\w)"#, with: "$1^[2]", options: .regularExpression)
		
		// 4. Greek word to Unicode Symbol translation
		let greekMap: [String: String] = [
			"alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
			"zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ",
			"lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο",
			"pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ",
			"phi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
			"Alpha": "Α", "Beta": "Β", "Gamma": "Γ", "Delta": "Δ", "Epsilon": "Ε",
			"Zeta": "Ζ", "Eta": "Η", "Theta": "Θ", "Iota": "Ι", "Kappa": "Κ",
			"Lambda": "鍵", "Mu": "Μ", "Nu": "Ν", "Xi": "Ξ", "Omicron": "Ο",
			"Pi": "Π", "Rho": "Ρ", "Sigma": "Σ", "Tau": "Τ", "Upsilon": "Υ",
			"Phi": "Φ", "Chi": "Χ", "Psi": "Ψ", "Omega": "Ω"
		]
		for (word, symbol) in greekMap {
			eq = eq.replacingOccurrences(of: "\\b\(word)\\b", with: symbol, options: .regularExpression)
		}
		
		// 5. Subscript multi-letter parameters (e.g. Vmax -> V_[max], ka -> k_[a])
		let subscriptPattern = #"\b(?!(?:sin|cos|tan|exp|log|ln|sqrt|pow)\b)([a-zA-Z])([a-zA-Z0-9]+)\b"#
		eq = eq.replacingOccurrences(of: subscriptPattern, with: "$1_[$2]", options: .regularExpression)
		
		// 6. Algebraic collapse
		eq = eq.replacingOccurrences(of: #"\s*\+\s*-\s*"#, with: " - ", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"\s*-\s*\+\s*"#, with: " - ", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"\s*-\s*-\s*"#, with: " + ", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"\s*\+\s*\+\s*"#, with: " + ", options: .regularExpression)
		
		// 7. Handle transcendental expressions
		let expPattern = #"\bexp\s*\(((?:[^()]+|\([^()]*\))+)\)"#
		eq = eq.replacingOccurrences(of: expPattern, with: "e^[$1]", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"\blog\s*\("#, with: "ln(", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"\bsqrt\s*\("#, with: "√(", options: .regularExpression)
		
		// 8. Conservative implicit multiplication logic
		eq = eq.replacingOccurrences(of: #"(?&lt;=\d)\s*\*\s*(?=[a-zA-Zα-ωΑ-Ω√\(\)])"#, with: "", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"(?&lt;=[\)\]³²⁴⁵])\s*\*\s*(?=[√\(\)])"#, with: "", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"(?&lt;=[a-zA-Zα-ωΑ-Ω])\s*\*\s*(?=[√\(\)])"#, with: "", options: .regularExpression)
		
		// 9. Format remaining standalone multiplications cleanly with a visible center dot
		eq = eq.replacingOccurrences(of: #"\s*\*\s*"#, with: " · ", options: .regularExpression)
		
		// 10. Uniform padding surrounding binary expressions
		eq = eq.replacingOccurrences(of: #"(?&lt;=[\d\w)²³⁴⁵\]])\s*\+\s*"#, with: " + ", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"(?&lt;=[\d\w)²³⁴⁵\]])\s*-\s*"#, with: " - ", options: .regularExpression)
		
		// 11. Typography structural cleanups
		eq = eq.replacingOccurrences(of: #"^\s*-\s*"#, with: "-", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"\(\s+"#, with: "(", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"\s+\)"#, with: ")", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
		
		// 12. 🎯 NEW: Restore verbatim placeholders back to their plain text values
		for (index, originalContent) in verbatimBlocks.enumerated() {
			eq = eq.replacingOccurrences(of: "__VERBATIM_BLOCK_\(index)__", with: originalContent)
		}
		
		let processedString = eq.trimmingCharacters(in: .whitespacesAndNewlines)
		
		// 13. Build Layout Engine Context
		let baseFont = UIFont.systemFont(ofSize: fontSize, weight: .regular)
		var baseContainer = AttributeContainer()
		baseContainer.font = baseFont
		
		var finalAttributedString = includeLHS ? AttributedString("y = ", attributes: baseContainer) : AttributedString()
		
		// Execute recursive linear structural parse
		let parsedLayout = parseToAttributedString(processedString, state: ParseState(fontSize: fontSize, baselineOffset: 0.0), baseFontWeight: .regular)
		finalAttributedString.append(parsedLayout)
		
		return finalAttributedString
	}
	
	/// Fallback plain string formatter utilizing standard formatting annotations for disk serialization.
	public static func formatToPlainString(_ expression: String) -> String {
		var eq = expression
		if eq.hasPrefix("y =") { eq = String(eq.dropFirst(3)) }
		else if eq.hasPrefix("y=") { eq = String(eq.dropFirst(2)) }
		
		// 🎯 UPDATED: Shield verbatim blocks starting with a single backslash (e.g., \slope)
		var verbatimBlocks: [String] = []
		let verbatimRegex = try! NSRegularExpression(pattern: #"\\([A-Za-z0-9_]+)"#, options: [])
		while true {
			let nsString = eq as NSString
			if let match = verbatimRegex.firstMatch(in: eq, options: [], range: NSRange(location: 0, length: nsString.length)) {
				let content = nsString.substring(with: match.range(at: 1)) // Captures just the word
				verbatimBlocks.append(content)
				let placeholder = "__VERBATIM_BLOCK_\(verbatimBlocks.count - 1)__"
				eq = nsString.replacingCharacters(in: match.range, with: placeholder) // Replaces "\slope" entirely
			} else {
				break
			}
		}
		
		eq = eliminatePow(eq)
		
		eq = eq.replacingOccurrences(of: #"(?<!\w)([a-zA-Z_]\w*|\([^()]+\))\s*\*\s*\1\s*\*\s*\1\s*\*\s*\1\s*\*\s*\1(?!\w)"#, with: "$1^[5]", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"(?<!\w)([a-zA-Z_]\w*|\([^()]+\))\s*\*\s*\1\s*\*\s*\1\s*\*\s*\1(?!\w)"#, with: "$1^[4]", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"(?<!\w)([a-zA-Z_]\w*|\([^()]+\))\s*\*\s*\1\s*\*\s*\1(?!\w)"#, with: "$1^[3]", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"(?<!\w)([a-zA-Z_]\w*|\([^()]+\))\s*\*\s*\1(?!\w)"#, with: "$1^[2]", options: .regularExpression)
		
		let greekMap: [String: String] = [
			"alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
			"zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ",
			"lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο",
			"pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ",
			"phi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
			"Alpha": "Α", "Beta": "Β", "Gamma": "Γ", "Delta": "Δ", "Epsilon": "Ε",
			"Zeta": "Ζ", "Eta": "Η", "Theta": "Θ", "Iota": "Ι", "Kappa": "Κ",
			"Lambda": "Λ", "Mu": "Μ", "Nu": "Ν", "Xi": "Ξ", "Omicron": "Ο",
			"Pi": "Π", "Rho": "Ρ", "Sigma": "Σ", "Tau": "Τ", "Upsilon": "Υ",
			"Phi": "Φ", "Chi": "Χ", "Psi": "Ψ", "Omega": "Ω"
		]
		for (word, symbol) in greekMap {
			eq = eq.replacingOccurrences(of: "\\b\(word)\\b", with: symbol, options: .regularExpression)
		}
		
		let subscriptPattern = #"\b(?!(?:sin|cos|tan|exp|log|ln|sqrt|pow)\b)([a-zA-Z])([a-zA-Z0-9]+)\b"#
		eq = eq.replacingOccurrences(of: subscriptPattern, with: "$1_[$2]", options: .regularExpression)
		
		eq = eq.replacingOccurrences(of: #"\s*\+\s*-\s*"#, with: "-", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"\s*-\s*\+\s*"#, with: "-", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"\s*-\s*-\s*"#, with: "+", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"\s*\+\s*\+\s*"#, with: "+", options: .regularExpression)
		
		//eq = eq.replacingOccurrences(of: #"exp\s*\("#, with: "e^(", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"log\s*\("#, with: "ln(", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"sqrt\s*\("#, with: "√(", options: .regularExpression)
		
		eq = eq.replacingOccurrences(of: #"(?<=\d)\s*\*\s*(?=[a-zA-Zα-ωΑ-Ω√\(\)])"#, with: "", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"(?<=[\)\]³²⁴⁵])\s*\*\s*(?=[√\(\)])"#, with: "", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"(?<=[a-zA-Zα-ωΑ-Ω])\s*\*\s*(?=[√\(\)])"#, with: "", options: .regularExpression)
		
		eq = eq.replacingOccurrences(of: #"\s*\*\s*"#, with: " · ", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"(?<=[\d\w)²³⁴⁵])\s*\+\s*"#, with: " + ", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"(?<=[\d\w)²³⁴⁵])\s*-\s*"#, with: " - ", options: .regularExpression)
		eq = eq.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
		
		// 🎯 Restore verbatim placeholders back to plain text
		for (index, originalContent) in verbatimBlocks.enumerated() {
			eq = eq.replacingOccurrences(of: "__VERBATIM_BLOCK_\(index)__", with: originalContent)
		}
		
		let processedString = eq.trimmingCharacters(in: .whitespacesAndNewlines)
		return "y = \(parseToPlainString(processedString))"
	}
	
	// MARK: - Balanced-Bracket Recursive Layout Layout Parsers
	
	private static func parseToAttributedString(_ text: String, state: ParseState, baseFontWeight: UIFont.Weight) -> AttributedString {
		var result = AttributedString()
		var idx = text.startIndex
		
		while idx < text.endIndex {
			// 🎯 Check for structural recursive superscript context: ^[ ... ]
			if idx < text.index(text.endIndex, offsetBy: -1),
			   text[idx] == "^", text[text.index(after: idx)] == "[" {
				
				let startOfInner = text.index(idx, offsetBy: 2)
				if let endOfInner = findMatchingBracket(in: text, startingAt: text.index(after: idx)) {
					let innerText = String(text[startOfInner..<endOfInner])
					
					let nextState = ParseState(
						fontSize: state.fontSize * 0.72,
						baselineOffset: state.baselineOffset + Double(state.fontSize * 0.38)
					)
					result.append(parseToAttributedString(innerText, state: nextState, baseFontWeight: .medium))
					idx = text.index(after: endOfInner)
					continue
				}
			}
			
			// 🎯 Check for structural recursive subscript context: _[ ... ]
			if idx < text.index(text.endIndex, offsetBy: -1),
			   text[idx] == "_", text[text.index(after: idx)] == "[" {
				
				let startOfInner = text.index(idx, offsetBy: 2)
				if let endOfInner = findMatchingBracket(in: text, startingAt: text.index(after: idx)) {
					let innerText = String(text[startOfInner..<endOfInner])
					
					let nextState = ParseState(
						fontSize: state.fontSize * 0.72,
						baselineOffset: state.baselineOffset - Double(state.fontSize * 0.15)
					)
					result.append(parseToAttributedString(innerText, state: nextState, baseFontWeight: .medium))
					idx = text.index(after: endOfInner)
					continue
				}
			}
			
			// Standard plain text segment mapping
			var container = AttributeContainer()
			container.font = UIFont.systemFont(ofSize: state.fontSize, weight: baseFontWeight)
			container.baselineOffset = state.baselineOffset
			
			result.append(AttributedString(String(text[idx]), attributes: container))
			idx = text.index(after: idx)
		}
		
		return result
	}
	
	private static func parseToPlainString(_ text: String) -> String {
		var result = ""
		var idx = text.startIndex
		
		while idx < text.endIndex {
			if idx < text.index(text.endIndex, offsetBy: -1),
			   text[idx] == "^", text[text.index(after: idx)] == "[" {
				let startOfInner = text.index(idx, offsetBy: 2)
				if let endOfInner = findMatchingBracket(in: text, startingAt: text.index(after: idx)) {
					let innerText = String(text[startOfInner..<endOfInner])
					let parsedInner = parseToPlainString(innerText)
					
					if parsedInner == "2" { result += "²" }
					else if parsedInner == "3" { result += "³" }
					else if parsedInner == "4" { result += "⁴" }
					else if parsedInner == "5" { result += "⁵" }
					else {
						if parsedInner.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil {
							result += "^\(parsedInner)"
						} else {
							result += "^(\(parsedInner))"
						}
					}
					idx = text.index(after: endOfInner)
					continue
				}
			}
			
			if idx < text.index(text.endIndex, offsetBy: -1),
			   text[idx] == "_", text[text.index(after: idx)] == "[" {
				let startOfInner = text.index(idx, offsetBy: 2)
				if let endOfInner = findMatchingBracket(in: text, startingAt: text.index(after: idx)) {
					let innerText = String(text[startOfInner..<endOfInner])
					let parsedInner = parseToPlainString(innerText)
					
					if parsedInner == "2" { result += "₂" }
					else if parsedInner == "3" { result += "₃" }
					else {
						if parsedInner.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil {
							result += "_\(parsedInner)"
						} else {
							result += "_(\(parsedInner))"
						}
					}
					idx = text.index(after: endOfInner)
					continue
				}
			}
			
			result.append(text[idx])
			idx = text.index(after: idx)
		}
		return result
	}
	
	private static func findMatchingBracket(in text: String, startingAt openIndex: String.Index) -> String.Index? {
		var depth = 0
		var idx = openIndex
		while idx < text.endIndex {
			if text[idx] == "[" {
				depth += 1
			} else if text[idx] == "]" {
				depth -= 1
				if depth == 0 {
					return idx
				}
			}
			idx = text.index(after: idx)
		}
		return nil
	}
}
