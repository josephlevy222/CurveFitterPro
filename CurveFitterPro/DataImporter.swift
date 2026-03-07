import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Data Importer

enum ImportError: Error, LocalizedError {
    case emptyFile
    case noValidRows
    case tooFewColumns
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .emptyFile: return "The file appears to be empty."
        case .noValidRows: return "No valid numeric rows found."
        case .tooFewColumns: return "Need at least 2 columns (X and Y)."
        case .parseError(let m): return "Parse error: \(m)"
        }
    }
}

struct DataImporter {

    // MARK: - Robust number parser
    //
    // Handles all of the following that Swift's Double() initializer rejects:
    //   • Uppercase E in scientific notation ("1.23E5", "-4.5E-3", "1.23E+05")
    //   • Locale decimal separators (comma in many European locales)
    //   • Values produced by reformat() such as "1.23E+05"

    static func parseDouble(_ string: String) -> Double? {
        // Fast path: Swift's own parser (plain decimals, lowercase-e scientific)
        if let v = Double(string) { return v }

        // Normalise uppercase E → lowercase e, locale comma → period
        let s = string
            .replacingOccurrences(of: "E+", with: "e+")
            .replacingOccurrences(of: "E-", with: "e-")
            .replacingOccurrences(of: "E", with: "e")
            .replacingOccurrences(of: ",", with: ".")

        if let v = Double(s) { return v }

        // Final fallback: POSIX-locale NumberFormatter
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        return formatter.number(from: s)?.doubleValue
    }

    // MARK: Parse from string (CSV, TSV, or space-delimited)

    static func parse(text: String) throws -> [DataPoint] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }

        guard !lines.isEmpty else { throw ImportError.emptyFile }

        // Detect delimiter
        let delimiter = detectDelimiter(in: lines)

        var points: [DataPoint] = []
        var skipped = 0

        for line in lines {
            // Split on runs of whitespace when no explicit delimiter was found,
            // so "1.0  2.0" and "1.0\t2.0" both produce exactly two parts.
            let parts: [String]
            if delimiter == DataImporter.whitespaceDelimiter {
                parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            } else {
                parts = line
                    .components(separatedBy: delimiter)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }

            guard parts.count >= 2 else { skipped += 1; continue }

            // Try to parse as numbers; skip header rows.
            // parseDouble handles uppercase E, locale separators, and
            // scientific notation produced by reformat().
            guard let x = parseDouble(parts[0]), let y = parseDouble(parts[1]) else {
                skipped += 1; continue
            }

            let weight: Double = parts.count >= 3 ? parseDouble(parts[2]) ?? 1.0 : 1.0
            points.append(DataPoint(x: x, y: y, weight: weight))
        }

        guard !points.isEmpty else { throw ImportError.noValidRows }
        return points.sorted { $0.x < $1.x }
    }

    // Sentinel value meaning "split on runs of whitespace"
    static let whitespaceDelimiter = "__WHITESPACE__"

    private static func detectDelimiter(in lines: [String]) -> String {
        // Sample the first few lines and count explicit delimiters.
        // Require a delimiter to appear in EVERY sampled line so that
        // a number like "1,234" in space-delimited data doesn't look like CSV.
        let sample = Array(lines.prefix(5))
        let tabLines   = sample.filter { $0.contains("\t") }.count
        let semiLines  = sample.filter { $0.contains(";")  }.count
        let commaLines = sample.filter { $0.contains(",")  }.count

        if tabLines   == sample.count { return "\t" }
        if semiLines  == sample.count { return ";" }
        if commaLines == sample.count { return "," }
        // Default: split on runs of whitespace (handles single space, multiple
        // spaces, and mixed spacing that slipped through the tab check above)
        return whitespaceDelimiter
    }

    // MARK: Format summary

    static func summary(_ points: [DataPoint]) -> String {
        guard !points.isEmpty else { return "No data" }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let xMin = xs.min()!; let xMax = xs.max()!
        let yMin = ys.min()!; let yMax = ys.max()!
        return "\(points.count) points · X: [\(fmt(xMin)), \(fmt(xMax))] · Y: [\(fmt(yMin)), \(fmt(yMax))]"
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.4g", v) }
}

// MARK: - Document Picker Wrapper

struct DocumentPickerView: UIViewControllerRepresentable {
    let completion: (String) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [
            .commaSeparatedText,
            .tabSeparatedText,
            .plainText,
            UTType("public.data")!
        ], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (String) -> Void
        init(completion: @escaping (String) -> Void) { self.completion = completion }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                             didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            completion(text)
        }
    }
}
