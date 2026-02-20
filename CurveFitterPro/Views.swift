import SwiftUI
import Charts

// MARK: - Data Editor View

struct DataEditorView: View {
    @Bindable var project: Project
    @Binding var showImport: Bool
    @State private var newX = ""
    @State private var newY = ""

    var body: some View {
        List {
            Section {
                HStack {
                    Button { showImport = true } label: {
                        Label("Import File", systemImage: "doc.badge.plus")
                    }
                    Spacer()
                    Button {
                        if let text = UIPasteboard.general.string {
                            if let points = try? DataImporter.parse(text: text) {
                                project.dataPoints = points
                            }
                        }
                    } label: {
                        Label("Paste", systemImage: "clipboard")
                    }
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Import Data")
            } footer: {
                Text(DataImporter.summary(project.dataPoints))
                    .font(.caption)
            }

            Section("Add Point") {
                HStack {
                    TextField("X", text: $newX)
                        .keyboardType(.decimalPad)
                    TextField("Y", text: $newY)
                        .keyboardType(.decimalPad)
                    Button("Add") {
                        guard let x = Double(newX), let y = Double(newY) else { return }
                        var pts = project.dataPoints
                        pts.append(DataPoint(x: x, y: y))
                        project.dataPoints = pts.sorted { $0.x < $1.x }
                        newX = ""; newY = ""
                    }
                    .disabled(Double(newX) == nil || Double(newY) == nil)
                }
            }

            Section("Data Points (\(project.dataPoints.count))") {
                HStack {
                    Text("X").bold().frame(maxWidth: .infinity, alignment: .leading)
                    Text("Y").bold().frame(maxWidth: .infinity, alignment: .leading)
                    Text("Weight").bold().frame(width: 70)
                    Text("Outlier").bold().frame(width: 60)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(project.dataPoints) { point in
                    DataPointRow(project: project, point: point)
                }
                .onDelete { offsets in
                    var pts = project.dataPoints
                    pts.remove(atOffsets: offsets)
                    project.dataPoints = pts
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct DataPointRow: View {
    @Bindable var project: Project
    let point: DataPoint

    var body: some View {
        HStack {
            Text(String(format: "%.4g", point.x)).frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%.4g", point.y)).frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%.2g", point.weight)).frame(width: 70)
            Toggle("", isOn: Binding(
                get: { point.isOutlier },
                set: { val in
                    var pts = project.dataPoints
                    if let i = pts.firstIndex(where: { $0.id == point.id }) {
                        pts[i].isOutlier = val
                        project.dataPoints = pts
                    }
                }
            ))
            .frame(width: 60)
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(point.isOutlier ? .secondary : .primary)
    }
}

// MARK: - Import Sheet

struct ImportSheet: View {
    let completion: (String) -> Void
    @State private var text = ""
    @State private var showFilePicker = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste CSV, TSV, or space-delimited data below.\nFirst two columns are X and Y. Optional third column is weight.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal)

                Button {
                    showFilePicker = true
                } label: {
                    Label("Import from Files…", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
            }
            .padding(.top)
            .navigationTitle("Import Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import") {
                        completion(text)
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .bold()
                }
            }
            .sheet(isPresented: $showFilePicker) {
                DocumentPickerView { fileText in
                    text = fileText
                    showFilePicker = false
                }
            }
        }
    }
}

// MARK: - Model Setup View

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
                    ForEach($project.parameters) { $param in
                        ParameterRow(param: $param)
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
                        TextField("value", value: $param.initialValue, format: .number)
                            .keyboardType(.decimalPad)
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

// MARK: - Fit Run View

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
                    .chartYAxisLabel("Residual")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Plot View

struct PlotView: View {
    @Bindable var project: Project
    @ObservedObject var engine: FittingEngine
    @Binding var fitResult: FitResult?
    @State private var showConfidenceBand = true
    @State private var showResiduals = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if project.dataPoints.isEmpty {
                    ContentUnavailableView("No Data", systemImage: "chart.xyaxis.line",
                                           description: Text("Import or enter data first."))
                } else {
                    mainPlot
                        .padding(.horizontal)

                    Toggle("Show Confidence Band", isOn: $showConfidenceBand)
                        .padding(.horizontal)

                    if fitResult != nil {
                        Toggle("Show Residuals", isOn: $showResiduals)
                            .padding(.horizontal)

                        if showResiduals {
                            residualPlot
                                .padding(.horizontal)
                        }
                    }
                }
            }
            .padding(.vertical)
        }
    }

    private var mainPlot: some View {
        let dataPoints = project.dataPoints
        let result = fitResult
        let xs = dataPoints.map(\.x)
        let xMin = xs.min() ?? 0
        let xMax = xs.max() ?? 1

        return Chart {
            // Data points
            ForEach(dataPoints.filter { !$0.isOutlier }) { pt in
                PointMark(x: .value("X", pt.x), y: .value("Y", pt.y))
                    .foregroundStyle(.indigo)
                    .symbolSize(40)
            }
            ForEach(dataPoints.filter(\.isOutlier)) { pt in
                PointMark(x: .value("X", pt.x), y: .value("Y", pt.y))
                    .foregroundStyle(.orange.opacity(0.5))
                    .symbolSize(40)
            }

            // Fitted curve
            if let result = result,
               let expr = try? CompiledExpression(source: project.modelExpression) {
                let params = result.parameters.compactMap { p -> (String, Double)? in
                    guard let v = p.fittedValue else { return nil }
                    return (p.name, v)
                }
                let paramDict = Dictionary(uniqueKeysWithValues: params)
                let curve = engine.smoothCurve(xMin: xMin, xMax: xMax, params: Array(paramDict.values),
                                               paramNames: Array(paramDict.keys), expression: expr)
                ForEach(Array(curve.enumerated()), id: \.offset) { _, pt in
                    LineMark(x: .value("X", pt.x), y: .value("Y", pt.y))
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
        }
        .chartXAxisLabel(project.xLabel)
        .chartYAxisLabel(project.yLabel)
        .frame(height: 300)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4)
    }

    private var residualPlot: some View {
        guard let result = fitResult else { return AnyView(EmptyView()) }
        let pairs = Array(zip(project.dataPoints.filter { !$0.isOutlier }, result.residuals))

        return AnyView(
            Chart {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    PointMark(x: .value("X", pair.0.x), y: .value("Residual", pair.1))
                        .foregroundStyle(.indigo)
                }
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(dash: [4]))
            }
            .frame(height: 150)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 4)
        )
    }
}

// MARK: - Model Picker Sheet

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
                                TextField("1.0", text: Binding(
                                    get: { i < defaultValues.count ? defaultValues[i] : "1.0" },
                                    set: { if i < defaultValues.count { defaultValues[i] = $0 } }
                                ))
                                .keyboardType(.decimalPad)
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

// MARK: - Settings View

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
