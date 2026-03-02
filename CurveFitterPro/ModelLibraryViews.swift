import SwiftUI
import Charts
import XYPlot
import NumericTextField
import Utilities

struct ModelPickerSheet: View {
    let onSelect: (BuiltinModel) -> Void
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    var filtered: [BuiltinModel] { ModelLibrary.search(searchText) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(ModelLibrary.categories, id: \.self) { cat in
                    let models = filtered.filter { $0.category == cat }
                    if !models.isEmpty {
                        Section(cat) {
                            ForEach(models) { model in
                                Button {
                                    onSelect(model)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(model.name).foregroundStyle(.primary).bold()
                                        Text(model.equation)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.indigo)
                                        Text(model.typicalUseCase)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search models…")
            .navigationTitle("Model Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Custom Model Sheet

struct CustomModelSheet: View {
    let onSave: (String, [String], [Double]) -> Void
    @State private var expression = ""
    @State private var parseError = ""
    @State private var detectedParams: [String] = []
    @State private var defaultValues: [String] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. a * exp(-b * x) + c", text: $expression)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: expression) { _, _ in parseExpression() }
                } header: {
                    Text("Expression (use x as independent variable)")
                } footer: {
                    if !parseError.isEmpty {
                        Text(parseError).foregroundStyle(.red)
                    } else if !detectedParams.isEmpty {
                        Text("Detected parameters: \(detectedParams.joined(separator: ", "))")
                            .foregroundStyle(.green)
                    }
                }

                if !detectedParams.isEmpty {
                    Section("Initial Parameter Values") {
                        ForEach(Array(detectedParams.enumerated()), id: \.offset) { i, name in
                            HStack {
                                Text(name).bold().frame(width: 60)
                                NumericTextField("1.0", numericText: Binding(
                                    get: { i < defaultValues.count ? defaultValues[i] : "1.0" },
                                    set: { if i < defaultValues.count { defaultValues[i] = $0 } }
                                ))
                            }
                        }
                    }
                }

                Section("Available Functions") {
                    Text("exp, log, log10, sqrt, abs, sin, cos, tan, asin, acos, atan, pow, sign")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Constants: pi, e")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Custom Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use Model") {
                        let values = defaultValues.map { Double($0) ?? 1.0 }
                        onSave(expression, detectedParams, values)
                    }
                    .bold()
                    .disabled(detectedParams.isEmpty || !parseError.isEmpty)
                }
            }
        }
    }

    private func parseExpression() {
        guard !expression.isEmpty else { parseError = ""; detectedParams = []; return }
        do {
            let compiled = try CompiledExpression(source: expression)
            detectedParams = compiled.parameterNames
            parseError = ""
            // Pad or trim defaultValues
            while defaultValues.count < detectedParams.count { defaultValues.append("1.0") }
            if defaultValues.count > detectedParams.count { defaultValues = Array(defaultValues.prefix(detectedParams.count)) }
        } catch {
            parseError = error.localizedDescription
            detectedParams = []
        }
    }
}

// MARK: - Model Library View (Tab)

struct ModelLibraryView: View {
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(ModelLibrary.categories, id: \.self) { cat in
                    let models = ModelLibrary.search(searchText).filter { $0.category == cat }
                    if !models.isEmpty {
                        Section(cat) {
                            ForEach(models) { model in
                                NavigationLink(destination: ModelDetailView(model: model)) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(model.name).bold()
                                        Text(model.equation)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.indigo)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search…")
            .navigationTitle("Model Library")
        }
    }
}

struct ModelDetailView: View {
    let model: BuiltinModel

    var body: some View {
        List {
            Section("Equation") {
                Text(model.equation)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.indigo)
            }
            Section("Expression (for custom use)") {
                Text(model.expression)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section("Description") {
                Text(model.description)
            }
            Section("Typical Use Case") {
                Text(model.typicalUseCase)
            }
            Section("Default Parameter Values") {
                ForEach(Array(zip(model.parameterNames, model.defaultValues)), id: \.0) { name, val in
                    LabeledContent(name, value: String(format: "%.4g", val))
                }
            }
        }
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

