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
            let parts = line
                .components(separatedBy: delimiter)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard parts.count >= 2 else { skipped += 1; continue }

            // Try to parse as numbers; skip header rows
            guard let x = Double(parts[0]), let y = Double(parts[1]) else {
                skipped += 1; continue
            }

            let weight: Double = parts.count >= 3 ? Double(parts[2]) ?? 1.0 : 1.0
            points.append(DataPoint(x: x, y: y, weight: weight))
        }

        guard !points.isEmpty else { throw ImportError.noValidRows }
        return points.sorted { $0.x < $1.x }
    }

    private static func detectDelimiter(in lines: [String]) -> Character {
        let sample = lines.prefix(5).joined()
        let commas = sample.filter { $0 == "," }.count
        let tabs = sample.filter { $0 == "\t" }.count
        let semis = sample.filter { $0 == ";" }.count
        if tabs >= commas && tabs >= semis { return "\t" }
        if semis > commas { return ";" }
        if commas > 0 { return "," }
        return " "
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
