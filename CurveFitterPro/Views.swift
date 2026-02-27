import SwiftUI
import Charts
import XYPlot
import NumericTextField
import Utilities

// MARK: - Data Editor View

struct DataEditorView: View {
    @Bindable var project: Project
    @Binding var showImport: Bool
    @State private var newX = ""
    @State private var newY = ""
    @FocusState private var focusedRow: Int?

    var body: some View {
        ScrollViewReader { proxy in
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
                    NumericTextField("X", numericText: $newX)
                    NumericTextField("Y", numericText: $newY)
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

                ForEach(Array(project.dataPoints.enumerated()), id: \.offset) { index, point in
                    DataPointRow(project: project, point: point, index: index,
                                 focusedRow: $focusedRow)
                }
                .onDelete { offsets in
                    var pts = project.dataPoints
                    pts.remove(atOffsets: offsets)
                    project.dataPoints = pts
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: focusedRow) { _, newRow in
            guard let row = newRow else { return }
            withAnimation { proxy.scrollTo("row-\(row)", anchor: .center) }
        }
        } // ScrollViewReader
    }
}

struct DataPointRow: View {
    @Bindable var project: Project
    let point: DataPoint
    let index: Int
    var focusedRow: FocusState<Int?>.Binding

    // Local string state for editing — initialised from point values
    @State private var xStr: String = ""
    @State private var yStr: String = ""
    @State private var wStr: String = ""

    // Write edited strings back to the project data store
    private func commit() {
        var pts = project.dataPoints
        guard index < pts.count else { return }
        if let v = Double(xStr), v.isFinite { pts[index].x = v }
        if let v = Double(yStr), v.isFinite { pts[index].y = v }
        if let v = Double(wStr), v.isFinite && v > 0 { pts[index].weight = v }
        project.dataPoints = pts
    }

    var body: some View {
        HStack {
            NumericTextField("x", numericText: $xStr,
                             onEditingChanged: { editing in
                                 if editing { focusedRow.wrappedValue = index }
                                 else { commit() }
                             },
                             onCommit: commit)
                .frame(maxWidth: .infinity)
            NumericTextField("y", numericText: $yStr,
                             onEditingChanged: { editing in
                                 if editing { focusedRow.wrappedValue = index }
                                 else { commit() }
                             },
                             onCommit: commit)
                .frame(maxWidth: .infinity)
            NumericTextField("w", numericText: $wStr,
                             style: NumericStringStyle(decimalSeparator: true, negatives: false, exponent: true),
                             onEditingChanged: { editing in
                                 if editing { focusedRow.wrappedValue = index }
                                 else { commit() }
                             },
                             onCommit: commit)
                .frame(width: 70)
            Toggle("", isOn: Binding(
                get: { point.isOutlier },
                set: { val in
                    var pts = project.dataPoints
                    guard index < pts.count else { return }
                    pts[index].isOutlier = val
                    project.dataPoints = pts
                }
            ))
            .frame(width: 60)
        }
        .id("row-\(index)")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(point.isOutlier ? .secondary : .primary)
        .onAppear {
            xStr = String(format: "%g", point.x)
            yStr = String(format: "%g", point.y)
            wStr = String(format: "%g", point.weight)
        }
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
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Plot View

struct PlotView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var project: Project
    @ObservedObject var engine: FittingEngine
    @Binding var fitResult: FitResult?
    // Cached computed data — only rebuilt when fitResult or confidenceLevel changes
    @State private var curvePoints: [(x: Double, y: Double)] = []
    @State private var bandPoints:  [(x: Double, lower: Double, upper: Double)] = []
    // Annotation box corner — cycles on tap
    // XYPlot data — rebuilt from curvePoints/bandPoints/dataPoints
    @State private var plotData: PlotData = PlotData(settings: PlotSettings(savePoints: false))
    @State private var residualData: PlotData = PlotData(settings: PlotSettings(savePoints: false))

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
                if project.dataPoints.isEmpty {
                    ContentUnavailableView("No Data", systemImage: "chart.xyaxis.line",
                                           description: Text("Import or enter data first."))
                } else {
                    mainPlot
                        .padding(.horizontal)

                    HStack(spacing: 0) {
                        Text("Show")
                        Picker("", selection: Binding(
                            get: { project.confidenceLevel },
                            set: { project.confidenceLevel = $0 }
                        )) {
                            Text("90%").tag(90)
                            Text("95%").tag(95)
                            Text("99%").tag(99)
                        }
                        Toggle("Confidence Band", isOn: Binding(get: { project.showConfidenceBand }, set: { project.showConfidenceBand = $0 }))
                    }
                    .padding(.horizontal)

                    if fitResult != nil {
                        Toggle("Show Residuals", isOn: Binding(get: { project.showResiduals }, set: { project.showResiduals = $0 }))
                            .padding(.horizontal)

                        if project.showResiduals {
                            residualPlot
                                .padding(.horizontal)
                        }
                    }
                }
            }
        .padding(.vertical)
        .onChange(of: fitResult?.residualSumOfSquares) { _, _ in recomputePlotData() }
        .onChange(of: project.confidenceLevel) { _, _ in recomputePlotData() }
        .onChange(of: project.showConfidenceBand) { _, _ in buildPlotData() }
        .onChange(of: plotData.plotLines.count > 1 ? plotData.plotLines[1].lineColor.sARGB : 0) { _, _ in
            // Band legend line color changed via PlotLineDialog — sync fill color
            guard plotData.plotLines.count > 1 && !bandPoints.isEmpty else { return }
            let newFill = plotData.plotLines[1].lineColor.opacity(colorScheme == .dark ? 0.35 : 0.15)
            plotData.plotBands = [PlotBand(
                upper: bandPoints.map { PlotPoint($0.x, $0.upper) },
                lower: bandPoints.map { PlotPoint($0.x, $0.lower) },
                color: newFill
            )]
        }
        .onAppear { recomputePlotData() }
    }


    // Recompute curve and band whenever the fit result changes.
    // Parameters are taken directly from result.parameters in order —
    // never via a Dictionary — so name/value correspondence is always correct.
    private func recomputePlotData() {
        // When no fit result, still build plot data so raw data points are shown
        guard let result = fitResult else {
            curvePoints = []
            bandPoints  = []
            buildPlotData()
            return
        }

        // Capture all values needed off-main-actor before entering Task
        let dataPoints    = project.dataPoints
        let finiteXs      = dataPoints.map(\.x).filter(\.isFinite)
        let xMin          = finiteXs.min() ?? 0
        let xMax          = finiteXs.max() ?? 1
        let expression    = project.modelExpression
        let confidenceLevel = project.confidenceLevel
        let showBand      = project.showConfidenceBand
        let covMatrix     = result.covarianceMatrix
        let fittedParams  = result.parameters.filter { $0.fittedValue != nil }
        let paramNames    = fittedParams.map(\.name)
        let paramValues   = fittedParams.compactMap(\.fittedValue)
        let dof           = max(1, dataPoints.count - fittedParams.count)
        let engineRef     = engine

        Task.detached(priority: .userInitiated) {
            guard let expr = try? await CompiledExpression(source: expression) else {
                await MainActor.run { curvePoints = []; bandPoints = [] }
                return
            }

            let curve = await engineRef.smoothCurve(xMin: xMin, xMax: xMax,
                                                    params: paramValues,
                                                    paramNames: paramNames,
                                                    expression: expr)

            var computedBand: [(x: Double, lower: Double, upper: Double)] = []
            if showBand && !covMatrix.isEmpty {
                let b = await engineRef.confidenceBand(
                    xValues:         curve.map(\.x),
                    fittedParams:    paramValues,
                    paramNames:      paramNames,
                    covMatrix:       covMatrix,
                    expression:      expr,
                    dof:             dof,
                    confidenceLevel: confidenceLevel
                )
                computedBand = zip(curve, b).compactMap { pt, bv in
                    guard bv.lower.isFinite && bv.upper.isFinite else { return nil }
                    return (x: pt.x, lower: bv.lower, upper: bv.upper)
                }
            }

            let finalBand = computedBand
            await MainActor.run {
                curvePoints = curve
                bandPoints  = finalBand
                buildPlotData()
            }
        }
    }

    /// Builds XYPlot PlotData from computed curve, band, and raw data points.
    /// Called whenever curvePoints or bandPoints are updated.
    private func buildPlotData() {
        let dataPoints = project.dataPoints.filter { $0.x.isFinite && $0.y.isFinite }
        let inliers  = dataPoints.filter { !$0.isOutlier }
        let outliers = dataPoints.filter(  \.isOutlier )

        // ── Helper: read existing PlotLine from plotData or probe UserDefaults,
        //    falling back to a default. This preserves user style/color edits.
        let plotKey = "xyplot-main-\(project.id)"
        func existingLine(at index: Int, default defaultLine: PlotLine) -> PlotLine {
            if plotData.plotLines.count > index { return plotData.plotLines[index] }
            var probe = PlotData(plotLines: [], settings: PlotSettings(savePoints: false), plotName: plotKey)
            probe.readFromUserDefaults()
            if probe.plotLines.count > index { return probe.plotLines[index] }
            return defaultLine
        }

        // ── Curve line (index 0) ──────────────────────────────────────────
        var curveLine = existingLine(at: 0, default: PlotLine(
            lineColor: Color.accentColor,
            lineStyle: StrokeStyle(lineWidth: 2),
            pointColor: .clear,
            pointShape: PointShape(Circle().path, color: .clear),
            legend: "Fit"
        ))
        curveLine.values = curvePoints
            .filter { $0.x.isFinite && $0.y.isFinite }
            .map { PlotPoint($0.x, $0.y) }

        // ── Inlier data points (indices 2 & 3) ───────────────────────────
        // Double-draw trick: white disc underneath, colored disc on top
        // Default inlier color matches the fit line color
        let defaultInlierColor = curveLine.lineColor
        var inlierWhite = existingLine(at: 2, default: PlotLine(
            lineColor: .clear,
            pointColor: .white,
            pointShape: PointShape(Circle().path, fill: true, color: .white, size: 1.4),
            legend: nil
        ))
        var inlierDark = existingLine(at: 3, default: PlotLine(
            lineColor: .clear,
            pointColor: defaultInlierColor,
            pointShape: PointShape(Circle().path, fill: true, color: defaultInlierColor, size: 1.0),
            legend: project.yLabel.isEmpty ? "Data" : project.yLabel
        ))
        let inlierPts = inliers.map { PlotPoint($0.x, $0.y) }
        inlierWhite.values = inlierPts
        inlierDark.values  = inlierPts

        // ── Outlier data points (indices 4 & 5) ──────────────────────────
        var outlierWhite = existingLine(at: 4, default: PlotLine(
            lineColor: .clear,
            pointColor: .white,
            pointShape: PointShape(Polygon(sides: 4).path, fill: true, color: .white, size: 1.4),
            legend: nil
        ))
        var outlierLine = existingLine(at: 5, default: PlotLine(
            lineColor: .clear,
            pointColor: .orange,
            pointShape: PointShape(Polygon(sides: 4).path, fill: true, color: .orange, size: 1.0),
            legend: outliers.isEmpty ? nil : "Outlier"
        ))
        let outlierPts = outliers.map { PlotPoint($0.x, $0.y) }
        outlierWhite.values = outlierPts
        outlierLine.values  = outlierPts

        // ── Axis titles as AttributedStrings ──────────────────────────────
        let xAttr = AttributedString(project.xLabel)
        let yAttr = AttributedString(project.yLabel)

        // ── Band color — index 1 in plotLines is always the band legend entry.
        let bandLineColor: Color = existingLine(at: 1, default: PlotLine(
            lineColor: Color.accentColor,
            lineStyle: StrokeStyle(lineWidth: 8),
            pointColor: .clear,
            pointShape: PointShape(Circle().path, color: .clear),
            legend: nil
        )).lineColor
        let bandFillColor = bandLineColor.opacity(colorScheme == .dark ? 0.35 : 0.15)

        // ── Confidence band fill ───────────────────────────────────────────
        var bands: [PlotBand] = []
        if project.showConfidenceBand && !bandPoints.isEmpty {
            let upper = bandPoints.map { PlotPoint($0.x, $0.upper) }
            let lower = bandPoints.map { PlotPoint($0.x, $0.lower) }
            bands = [PlotBand(upper: upper, lower: lower, color: bandFillColor)]
        }

        // ── Band legend entry — no points, just color + label for legend/editing ──
        let bandLegendLine = PlotLine(
            lineColor: bandLineColor,
            lineStyle: StrokeStyle(lineWidth: 8),
            pointColor: .clear,
            pointShape: PointShape(Circle().path, color: .clear),
            legend: project.showConfidenceBand && !bandPoints.isEmpty
                ? "\(project.confidenceLevel)% CI" : nil
        )
        // No points — appears only in legend for color editing

        var lines: [PlotLine] = [curveLine, bandLegendLine, inlierWhite, inlierDark]
        if !outliers.isEmpty { lines += [outlierWhite, outlierLine] }

        // ── Annotation text (R², model name, fitted equation) ───────────────
        let annotationText: String? = {
            guard let result = fitResult else { return nil }
            let r2    = String(format: "R² = %.4f", result.rSquared)
            let model = project.modelName.isEmpty ? "" : project.modelName + "\n"
            let eq    = fittedEquation(result: result)
            return model + r2 + (eq.isEmpty ? "" : "\n" + eq)
        }()

        if plotData.plotName == plotKey {
            // Already initialised — mutate a local copy then assign once
            // to avoid "onChange tried to update multiple times per frame"
            var updated = plotData
            updated.plotLines = lines
            updated.plotBands = bands
            updated.scaleAxes()
            updated.plotBands = bands
            updated.settings.annotation = annotationText
            plotData = updated
        } else {
            // First time for this project — build with defaults then restore
            // persisted settings (legend/annotation positions, axis ranges, etc.)
            var baseSettings = PlotSettings(
                title: AttributedString(project.name),
                xAxis: AxisParameters(title: xAttr),
                yAxis: AxisParameters(title: yAttr),
                legend: false,
                savePoints: false
            )
            // Probe UserDefaults to restore positions and other persisted settings
            var probe = PlotData(plotLines: [], settings: baseSettings, plotName: plotKey)
            probe.readFromUserDefaults()
            // Take persisted settings but always refresh titles, savePoints, annotation
            // Only restore legend from UserDefaults if real data was previously saved;
            // otherwise default to hidden (legend:false)
            let hadSavedData = probe.settings != baseSettings
            baseSettings = probe.settings
            baseSettings.title = probe.settings.title.characters.isEmpty
                ? AttributedString(project.name) : probe.settings.title
            baseSettings.xAxis?.title = xAttr
            baseSettings.yAxis?.title = yAttr
            baseSettings.savePoints = false
            baseSettings.annotation = annotationText
            if !hadSavedData { baseSettings.legend = false }
            var newPlot = PlotData(plotLines: lines, settings: baseSettings, plotName: plotKey)
            newPlot.plotBands = bands
            newPlot.scaleAxes()
            newPlot.plotBands = bands
            plotData = newPlot
        }

        // ── Residuals ─────────────────────────────────────────────────────
        guard let result = fitResult else { return }
        let pts   = dataPoints.filter { !$0.isOutlier }
        let pairs = zip(pts, result.residuals).filter { $0.1.isFinite }

        var posLine = PlotLine(
            lineColor: .clear,
            pointColor: Color.accentColor,
            pointShape: PointShape(Circle().path, fill: true, color: Color.accentColor, size: 1.0),
            legend: nil
        )
        var negLine = PlotLine(
            lineColor: .clear,
            pointColor: .orange,
            pointShape: PointShape(Circle().path, fill: true, color: .orange, size: 1.0),
            legend: nil
        )
        // Stems as thin vertical lines from zero — one PlotLine per point
        // XYPlot doesn't have RuleMark, so we approximate with short line segments
        var stemLines: [PlotLine] = []
        for (pt, res) in pairs {
            var stem = PlotLine(lineColor: Color(.systemGray4), lineStyle: StrokeStyle(lineWidth: 1),
                                pointShape: PointShape(Circle().path, color: .clear), legend: nil)
            stem.append(PlotPoint(pt.x, 0))
            stem.append(PlotPoint(pt.x, res))
            stemLines.append(stem)
            if res >= 0 { posLine.append(PlotPoint(pt.x, res)) }
            else        { negLine.append(PlotPoint(pt.x, res)) }
        }
        // Zero rule line
        var zeroLine = PlotLine(
            lineColor: Color(.systemGray3),
            lineStyle: StrokeStyle(lineWidth: 1, dash: [4, 3]),
            pointShape: PointShape(Circle().path, color: .clear),
            legend: nil
        )
        if let xFirst = pts.first?.x, let xLast = pts.last?.x {
            zeroLine.append(PlotPoint(xFirst, 0))
            zeroLine.append(PlotPoint(xLast,  0))
        }

        let resLines = stemLines + [zeroLine, posLine, negLine]
        let residualKey = "xyplot-residual-\(project.id)"
        let resAttr = AttributedString("Residuals")
        let resTitleStr = project.name.isEmpty ? "Residuals" : project.name + " — Residuals"
        var baseResSettings = PlotSettings(
            title: AttributedString(resTitleStr),
            xAxis: AxisParameters(title: xAttr),
            yAxis: AxisParameters(title: resAttr),
            legend: false,
            savePoints: false
        )
        var resProbe = PlotData(plotLines: [], settings: baseResSettings, plotName: residualKey)
        resProbe.readFromUserDefaults()
        baseResSettings = resProbe.settings
        baseResSettings.title = resProbe.settings.title.characters.isEmpty
            ? AttributedString(resTitleStr) : resProbe.settings.title
        baseResSettings.xAxis?.title = xAttr
        baseResSettings.yAxis?.title = resAttr
        baseResSettings.legend = false
        baseResSettings.savePoints = false
        var newResidual = PlotData(plotLines: resLines, settings: baseResSettings, plotName: residualKey)
        newResidual.scaleAxes()
        residualData = newResidual
    }

    // MARK: - Publication-quality main plot (XYPlot)

    private var mainPlot: some View {
        XYPlot(data: $plotData)
            .frame(maxHeight: .infinity)
    }


    /// Substitutes fitted values into the mathematical equation template.
    /// Falls back to substituting into the expression if no equation template stored.
    private func fittedEquation(result: FitResult) -> String {
        let params = result.parameters.filter { $0.fittedValue != nil }
        guard !params.isEmpty else { return "" }

        // Format a single parameter value concisely
        func fmt(_ v: Double) -> String {
            if abs(v) >= 1000 || (abs(v) < 0.01 && v != 0) {
                return String(format: "%.3g", v)
            }
            // Strip trailing zeros after decimal
            let s = String(format: "%.4g", v)
            return s
        }

        // Prefer the stored mathematical equation (e.g. "y = a·x² + b·x + c")
        // Replace each parameter name with its fitted value
        var eq = project.modelEquation.isEmpty ? project.modelExpression : project.modelEquation

        // Sort by length descending so "Vmax" is replaced before "V"
        let sorted = params.sorted { $0.name.count > $1.name.count }
        for p in sorted {
            guard let v = p.fittedValue else { continue }
            let formatted = fmt(v)
            // In math equation: replace bare parameter names
            eq = eq.replacingOccurrences(of: p.name, with: formatted)
        }

        // Clean up C-style operators to math notation
        eq = eq.replacingOccurrences(of: "* x * x * x", with: "x³")
        eq = eq.replacingOccurrences(of: "* x * x",     with: "x²")
        eq = eq.replacingOccurrences(of: " * x",        with: "x")
        eq = eq.replacingOccurrences(of: "* x",         with: "x")
        eq = eq.replacingOccurrences(of: " * ",         with: "·")
        eq = eq.replacingOccurrences(of: "pow(x, ",     with: "x^")
            .replacingOccurrences(of: "pow(x,",         with: "x^")
        // Remove trailing ) from pow replacements
        eq = eq.replacingOccurrences(of: #"x\^([\d.]+)\)"#, with: "x^$1",
                                     options: .regularExpression)
        eq = eq.replacingOccurrences(of: "exp(",        with: "e^(")
        eq = eq.replacingOccurrences(of: "log(",        with: "ln(")
        eq = eq.replacingOccurrences(of: "sqrt(",       with: "√(")

        return eq
    }

    private func yLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .default, weight: .regular))
            .foregroundStyle(.secondary)
            .fixedSize()
            .rotationEffect(.degrees(-90))
            .frame(width: 16)
    }

    // MARK: - Residuals plot (XYPlot)

    private var residualPlot: some View {
        XYPlot(data: $residualData)
            .frame(height: 200)
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
