import SwiftUI
import Charts
import XYPlot
import NumericTextField
import Utilities

struct FitRunView: View {
    @Bindable var project: Project
    @ObservedObject var engine: FittingEngine
    @Binding var fitResult: FitResult?

    var body: some View {
        List {
            Section {
                Button {
                    Task {
                        if let result = await engine.fit(project: project) {
                            project.fitResult  = result
                            project.parameters = result.parameters
                            fitResult = result
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if engine.isFitting {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Fitting…")
                        } else {
                            Image(systemName: "play.fill")
                            Text("Run Fit")
                        }
                        Spacer()
                    }
                }
                .disabled(engine.isFitting || project.dataPoints.isEmpty || project.modelExpression.isEmpty)
                .bold()

                if !engine.statusMessage.isEmpty {
                    Label(engine.statusMessage,
                          systemImage: fitResult?.converged == true ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(fitResult?.converged == true ? .green : .orange)
                }
            }

            if let result = fitResult {
                Section("Goodness of Fit") {
                    LabeledContent("R²",          value: String(format: "%.6f", result.rSquared))
                    LabeledContent("Adjusted R²", value: String(format: "%.6f", result.adjustedRSquared))
                    LabeledContent("RSS",          value: String(format: "%.4g", result.residualSumOfSquares))
                    LabeledContent("Reduced χ²",  value: String(format: "%.4g", result.reducedChiSquared))
                    LabeledContent("Iterations",  value: "\(result.iterations)")
                    LabeledContent("Converged",   value: result.converged ? "Yes" : "No")
                }

                Section {
                    ForEach(result.parameters.indices, id: \.self) { i in
                        let p = result.parameters[i]
                        HStack(alignment: .top) {
                            Text(p.name)
                                .font(.headline)
                                .frame(width: 40, alignment: .leading)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 16) {
                                    VStack(alignment: .leading) {
                                        Text("Value").font(.caption2).foregroundStyle(.secondary)
                                        Text(p.displayValue).font(.system(.body, design: .monospaced))
                                    }
                                    VStack(alignment: .leading) {
                                        Text("±SE").font(.caption2).foregroundStyle(.secondary)
                                        Text(p.displaySE).font(.system(.body, design: .monospaced))
                                    }
                                    VStack(alignment: .leading) {
                                        Text("95% CI").font(.caption2).foregroundStyle(.secondary)
                                        Text(p.displayCI).font(.system(.caption, design: .monospaced))
                                    }
                                }
                            }

                            Spacer()

                            // Always offer to seed the initial value from the fitted value.
                            // Especially useful when fit didn't converge.
                            if let fitted = p.fittedValue {
                                Button {
                                    var params = project.parameters
                                    if i < params.count {
                                        params[i].initialValue = fitted
                                        project.parameters = params
                                    }
                                } label: {
                                    VStack(spacing: 2) {
                                        Image(systemName: "arrow.uturn.left.circle")
                                        Text("Use as\ninitial")
                                            .font(.caption2)
                                            .multilineTextAlignment(.center)
                                    }
                                    .foregroundStyle(result.converged ? .blue : .orange)
                                }
                                .buttonStyle(.borderless)
                                .help("Copy this value to the initial value for the next fit")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    HStack {
                        Text("Parameters")
                        if !result.converged {
                            Spacer()
                            Button("Use All as Initials") {
                                var params = project.parameters
                                for i in result.parameters.indices where i < params.count {
                                    if let v = result.parameters[i].fittedValue {
                                        params[i].initialValue = v
                                    }
                                }
                                project.parameters = params
                            }
                            .font(.caption)
                        }
                    }
                }

                Section("Residuals") {
                    Chart {
                        ForEach(Array(zip(project.dataPoints, result.residuals).enumerated()), id: \.offset) { _, pair in
                            PointMark(x: .value("X", pair.0.x),
                                      y: .value("Residual", pair.1))
                            .foregroundStyle(.indigo)
                        }
                        RuleMark(y: .value("Zero", 0))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(dash: [4]))
                    }
                    .frame(height: 150)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
