//
//  NumericTextField.swift
//  CurveFitterPro
//
//  Created by Joseph Levy on 2/22/26.
//

import Foundation

public var decimalNumberFormatter: NumberFormatter = {
	let formatter = NumberFormatter()
	formatter.usesSignificantDigits = true
	formatter.numberStyle = .none
	formatter.allowsFloats = true
	return formatter
}()

public var scientificFormatter: NumberFormatter = {
	let formatter = NumberFormatter()
	formatter.numberStyle = .scientific
	formatter.allowsFloats = true
	return formatter
}()

public var integerFormatter: NumberFormatter = {
	let formatter = NumberFormatter()
	formatter.numberStyle = .none
	formatter.allowsFloats = false
	return formatter
}()

extension NSNumber {
	public var scientificStyle: String {
		return scientificFormatter.string(from: self) ?? description
	}
	public var decimalStyle: String {
		return decimalNumberFormatter.string(from: self) ?? description
	}
	public var integerStyle: String {
		return integerFormatter.string(from: self) ?? description
	}
}

public struct NumericStringStyle {
	static public var defaultStyle = NumericStringStyle()
	static public var intStyle = NumericStringStyle(decimalSeparator: false, negatives: true, exponent: false, range: nil)
	static public var positiveStyle = NumericStringStyle(decimalSeparator: true, negatives: false, exponent: true, range: nil)
	public var decimalSeparator: Bool
	public var negatives: Bool
	public var exponent: Bool
	public var range: ClosedRange<Double>? = nil
	public init(decimalSeparator: Bool = true, negatives: Bool = true , exponent: Bool = true, range: ClosedRange<Double>? = nil) {
		self.decimalSeparator = decimalSeparator || exponent
		self.negatives = negatives
		self.exponent = exponent
		self.range = range
	}
}

import SwiftUI

public struct NumericTextField: View {
	public init(_ title: LocalizedStringKey, numericText: Binding<String>, style: NumericStringStyle = NumericStringStyle.defaultStyle, onEditingChanged: @escaping (Bool) -> Void = { _ in }, onCommit: @escaping () -> Void = { }, reformatter: @escaping (String) -> String = reformat) {
		self._numericText = numericText
		self.title = title
		self.style = style
		self.onEditingChanged = onEditingChanged
		self.onCommit = onCommit
		self.reformatter = reformatter
	}

	public let title: LocalizedStringKey
	@Binding public var numericText: String
	public var style: NumericStringStyle = .defaultStyle
	public var onEditingChanged: (Bool) -> Void = { _ in }
	public var onCommit: () -> Void = { }
	public var reformatter: (_ stringValue: String) -> String = reformat

	var range: ClosedRange<Double> {
		if let ld = style.range?.lowerBound {
			if let ud = style.range?.upperBound {
				return (ld...ud)
			} else {
				return ld...Double.infinity
			}
		} else {
			if let ud = style.range?.upperBound {
				return -Double.infinity...ud
			}
		}
		return -Double.infinity...Double.infinity
	}

	public var body: some View {
		TextField(title, text: $numericText,
				  onEditingChanged: { exited in
			if !exited {
				numericText = reformatter(numericText)
			}
			onEditingChanged(exited)
		},
				  onCommit: {
			numericText = reformatter(numericText)
			onCommit()
		})
		.numericText(number: $numericText, style: style)
		.modifier(KeyboardModifier(isDecimalAllowed: style.decimalSeparator))
		.onAppear { numericText = reformatter(numericText) }
	}
}

public func reformat(_ stringValue: String) -> String {
	let value = NumberFormatter().number(from: stringValue)
	if let v = value {
		let compare = v.compare(NSNumber(value: 0.0))
		if compare == .orderedSame {
			return String("0")
		}
		if compare == .orderedAscending {
			let compare = v.compare(NSNumber(value: -1e-3))
			if compare != .orderedDescending {
				let compare = v.compare(NSNumber(value: -1e5))
				if compare == .orderedDescending {
					return String(v.decimalStyle)
				}
			}
		} else {
			let compare = v.compare(NSNumber(value: 1e5))
			if compare == .orderedAscending {
				let compare = v.compare(NSNumber(value: 1e-3))
				if compare != .orderedAscending {
					return String(v.decimalStyle)
				}
			}
			return String(v.scientificStyle)
		}
	}
	return stringValue
}

private struct KeyboardModifier: ViewModifier {
	let isDecimalAllowed: Bool

	func body(content: Content) -> some View {
#if os(iOS)
		return content
			.keyboardType(isDecimalAllowed ? .numbersAndPunctuation : UIKeyboardType.default)
#else
		return content
#endif
	}
}

public struct NumericTextModifier: ViewModifier {
	@Binding public var number: String
	public var style = NumericStringStyle()

	public func body(content: Content) -> some View {
		content
			.onChange(of: number) { _, newValue in
				number = newValue.numericValue(style: style).uppercased()
			}
	}
}

public extension View {
	func numericText(number: Binding<String>, style: NumericStringStyle) -> some View {
		modifier(NumericTextModifier(number: number, style: style))
	}
}

public extension String {
	func numericValue(style: NumericStringStyle = NumericStringStyle()) -> String {
		var hasFoundDecimal = false
		var allowMinusSign = style.negatives
		var hasFoundExponent = !style.exponent
		var allowFindingExponent = false
		let retValue = self.filter {
			if allowMinusSign && "-".contains($0) {
				return true
			} else {
				allowMinusSign = false
				if $0.isWholeNumber {
					allowFindingExponent = true
					return true
				} else if style.decimalSeparator && String($0) == (Locale.current.decimalSeparator ?? ".") {
					defer { hasFoundDecimal = true }
					return !hasFoundDecimal
				} else if style.exponent && !hasFoundExponent && allowFindingExponent && "eE".contains($0) {
					allowMinusSign = true
					hasFoundDecimal = true
					allowFindingExponent = false
					hasFoundExponent = true
					return true
				}
			}
			return false
		}

		if let rV = Double(retValue), let r = style.range {
			if rV < r.lowerBound { return String(format: "%g", r.lowerBound) }
			if rV > r.upperBound { return String(format: "%g", r.upperBound) }
		}
		return retValue
	}

	func optionalNumber(formatter: NumberFormatter = NumberFormatter()) -> NSNumber? {
		formatter.number(from: self)
	}

	func optionalDouble(formatter: NumberFormatter = NumberFormatter()) -> Double? {
		if let value = optionalNumber(formatter: formatter) {
			return Double(truncating: value) } else { return nil }
	}

	func toDouble(formatter: NumberFormatter = NumberFormatter()) -> Double {
		if let value = optionalNumber(formatter: formatter) {
			return Double(truncating: value) } else { return 0.0 }
	}

	func toInt(formatter: NumberFormatter = NumberFormatter()) -> Int {
		if let value = optionalNumber(formatter: formatter) {
			return Int(truncating: value) } else { return 0 }
	}
}
