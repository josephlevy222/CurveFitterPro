import SwiftUI
import Charts
import XYPlot
import NumericTextField
import Utilities

struct SettingsView: View {
    @AppStorage("significantFigures") private var sigFigs = 6
    @AppStorage("defaultXLabel") private var xLabel = "X"
    @AppStorage("defaultYLabel") private var yLabel = "Y"
    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    Stepper("Significant Figures: \(sigFigs)", value: $sigFigs, in: 3...10)
                }
                Section("Default Axis Labels") {
                    LabeledContent("X Axis") {
                        TextField("X", text: $xLabel)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Y Axis") {
                        TextField("Y", text: $yLabel)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Solver", value: "Levenberg-Marquardt (pure Swift)")
                    LabeledContent("Expression Engine", value: "Built-in recursive descent parser")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
