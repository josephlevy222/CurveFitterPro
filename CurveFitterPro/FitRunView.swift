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
                          systemImage: fitResult?.converged == true ? "checkmark.circle" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(fitResult?.converged == true ? .green : .orange)
                }
            }

            if let result = fitResult {
                Section("Goodness of Fit") {
                    LabeledContent("R²", value: String(format: "%.6f", result.rSquared))
                    LabeledContent("Adjusted R²", value: String(format: "%.6f", result.adjustedRSquared))
                    LabeledContent("RSS", value: String(format: "%.4g", result.residualSumOfSquares))
                    LabeledContent("Reduced χ²", value: String(format: "%.4g", result.reducedChiSquared))
                    LabeledContent("Iterations", value: "\(result.iterations)")
                    LabeledContent("Converged", value: result.converged ? "Yes" : "No")
                }

                Section("Parameters") {
                    ForEach(result.parameters) { p in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.name).font(.headline)
                            HStack(spacing: 20) {
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
                        .padding(.vertical, 4)
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

