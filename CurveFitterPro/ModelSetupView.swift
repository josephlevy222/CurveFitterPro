import SwiftUI
import Charts
import XYPlot
import NumericTextField
import Utilities

struct ModelSetupView: View {
    @Bindable var project: Project
    @Binding var showModelPicker: Bool
    @Binding var showCustomModel: Bool

    var body: some View {
        List {
            Section("Current Model") {
                if project.modelName.isEmpty {
                    Text("No model selected")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Name", value: project.modelName)
                    LabeledContent("Expression", value: project.modelExpression)
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Button("Choose Built-in…") { showModelPicker = true }
                    Spacer()
                    Button("Custom…") { showCustomModel = true }
                }
                .buttonStyle(.borderless)
            }

            if !project.parameters.isEmpty {
                Section("Parameters") {
                    ForEach(project.parameters.indices, id: \.self) { i in
                        ParameterRow(param: Binding(
                            get: {
                                let params = project.parameters
                                return i < params.count ? params[i] : FitParameter(name: "", initialValue: 0)
                            },
                            set: { newVal in
                                var params = project.parameters
                                if i < params.count { params[i] = newVal }
                                project.parameters = params
                            }
                        ))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct ParameterRow: View {
    @Binding var param: FitParameter
    @State private var initialStr: String = ""
    @State private var editingInitial = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(param.name)
                    .font(.headline)
                    .frame(width: 40, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    // Initial value — always editable
                    HStack(spacing: 6) {
                        Text("Initial:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        NumericTextField("value", numericText: $initialStr,
                                         onEditingChanged: { editing in
                                             if !editing {
                                                 param.initialValue = Double(initialStr) ?? param.initialValue
                                             }
                                         })
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)

                        // If there's a non-converged fitted value, offer to use it as initial
                        if let fitted = param.fittedValue, param.fittedValue != nil {
                            Button {
                                param.initialValue = fitted
                                initialStr = String(format: "%g", fitted)
                            } label: {
                                Image(systemName: "arrow.uturn.left.circle")
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.borderless)
                            .help("Use fitted value as initial value")
                        }
                    }

                    // Fitted result — shown when available
                    if let v = param.fittedValue {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Fitted")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.6g", v))
                                    .font(.system(.subheadline, design: .monospaced))
                            }
                            if let se = param.standardError {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("±SE")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(String(format: "%.4g", se))
                                        .font(.system(.caption, design: .monospaced))
                                }
                            }
                            if let lo = param.confidenceIntervalLow,
                               let hi = param.confidenceIntervalHigh {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("95% CI")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("[\(String(format: "%.4g", lo)), \(String(format: "%.4g", hi))]")
                                        .font(.system(.caption2, design: .monospaced))
                                }
                            }
                        }
                    }
                }

                Spacer()
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            initialStr = String(format: "%g", param.initialValue)
        }
        .onChange(of: param.initialValue) { _, v in
            // Keep field in sync if initialValue changed externally (e.g. "use fitted" button)
            let s = String(format: "%g", v)
            if initialStr != s { initialStr = s }
        }
    }
}
