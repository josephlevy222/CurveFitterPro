//
//  GreekEntry.swift
//  CurveFitterPro
//
//  Created by Joseph Levy on 8/4/26.
//
import SwiftUI
// MARK: - Greek Phonetic Entry
//
// Ported from ExpressionParserAndPresenterApp's LiveExpressionView, where it
// was wired up but only exercised in that standalone demo view. Typing "\"
// followed by a Latin letter replaces those two characters with the
// corresponding Greek glyph in place, e.g. "\s" -> "σ", "\S" -> "Σ" — a
// stand-in for MathCad's Ctrl+G chord, which has no equivalent on the iOS
// software keyboard.

let phoneticGreek: [Character: Character] = [
    "a": "α", "b": "β", "g": "γ", "d": "δ", "e": "ε", "z": "ζ", "h": "η", "q": "θ",
    "i": "ι", "k": "κ", "l": "λ", "m": "μ", "n": "ν", "x": "ξ", "o": "ο", "p": "π",
    "r": "ρ", "s": "σ", "t": "τ", "u": "υ", "f": "φ", "c": "χ", "y": "ψ", "w": "ω",
    "G": "Γ", "D": "Δ", "Q": "Θ", "L": "Λ", "X": "Ξ", "P": "Π", "S": "Σ", "F": "Φ",
    "C": "Χ", "Y": "Ψ", "W": "Ω"
]

/// Buttons for a keyboard accessory toolbar / quick-tap insertion, if a text
/// field wants one. Not wired up anywhere yet — CustomModelSheet only uses
/// the phonetic "\<letter>" substitution below for now.
let greekQuickPicks: [String] = ["α", "β", "γ", "δ", "θ", "λ", "μ", "π", "σ", "φ", "ω", "Δ", "Σ", "Ω"]

/// Extracts the caret position (start of selection) from a TextSelection, defaulting
/// to the end of the string if there's no selection yet (e.g. before first focus).
func cursorIndex(from selection: TextSelection?, in text: String) -> String.Index {
    guard let selection else { return text.endIndex }
    switch selection.indices {
    case .selection(let range):
        return range.lowerBound
    case .multiSelection(let rangeSet):
        return rangeSet.ranges.first?.lowerBound ?? text.endIndex
    @unknown default:
        return text.endIndex
    }
}

/// Checks for a "\<letter>" pattern ending right at the cursor and, if the letter has a Greek mapping, returns `text` with those two characters
/// replaced by the Greek glyph, plus the caret position just after it. This works anywhere in the expression, not just at the end, so editing earlier
/// in a long expression still triggers the substitution correctly. Returns nil if there's nothing to substitute, so callers can leave `text`/the
/// selection untouched in that case.
func applyGreekPhoneticSubstitution(to text: String, selection: TextSelection?) -> (text: String, newCursor: String.Index)? {
    var text = text
    let idx = cursorIndex(from: selection, in: text)
    
    guard let backTwo = text.index(idx, offsetBy: -2, limitedBy: text.startIndex) else { return nil }
    let backOne = text.index(after: backTwo)
    guard text[backTwo] == "\\", let greek = phoneticGreek[text[backOne]] else { return nil }
    
    text.replaceSubrange(backTwo..<idx, with: String(greek))
    let newIdx = text.index(backTwo, offsetBy: 1)
    return (text, newIdx)
}
