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
    @State private var showBounds = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(param.name)
                    .font(.headline)
                    .frame(width: 60, alignment: .leading)

                if let v = param.fittedValue {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fitted: \(String(format: "%.6g", v))")
                            .font(.subheadline)
                        if let se = param.standardError {
                            Text("SE: \(String(format: "%.4g", se))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack {
                        Text("Initial:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        NumericTextField("value", numericText: Binding(
                            get: { String(format: "%g", param.initialValue) },
                            set: { param.initialValue = Double($0) ?? param.initialValue }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    }
                }

                Spacer()
                if let lo = param.confidenceIntervalLow, let hi = param.confidenceIntervalHigh {
                    Text("95% CI\n[\(String(format: "%.4g", lo)), \(String(format: "%.4g", hi))]")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

