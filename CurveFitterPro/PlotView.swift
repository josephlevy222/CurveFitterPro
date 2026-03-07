import SwiftUI
import Charts
import XYPlot
import NumericTextField
import Utilities

struct PlotView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var project: Project
    @ObservedObject var engine: FittingEngine
    @Binding var fitResult: FitResult?
    // Cached computed data — only rebuilt when fitResult or confidenceLevel changes
    @State private var curvePoints: [(x: Double, y: Double)] = []
    @State private var bandPoints:  [(x: Double, lower: Double, upper: Double)] = []
    @State private var computeTask: Task<Void, Never>? = nil
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
						.fixedSize()
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
        .onChange(of: project.showConfidenceBand) { _, newValue in
            if newValue { recomputePlotData() } else { buildPlotData() }
        }
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
        .onDisappear { computeTask?.cancel(); computeTask = nil }
        .onAppear {
            // Cancel any in-flight task from previous project
            computeTask?.cancel()
            computeTask = nil
            // Clear stale data from previous project before recomputing
            curvePoints = []
            bandPoints  = []
            plotData    = PlotData(settings: PlotSettings(savePoints: false))
            residualData = PlotData(settings: PlotSettings(savePoints: false))
            recomputePlotData()
        }
    }


    // Recompute curve and band whenever the fit result changes.
    // Parameters are taken directly from result.parameters in order —
    // never via a Dictionary — so name/value correspondence is always correct.
    private func recomputePlotData() {
        // Capture all values needed off-main-actor before entering Task
        let dataPoints      = project.dataPoints
        let finiteXs        = dataPoints.map(\.x).filter(\.isFinite)
        let xMin            = finiteXs.min() ?? 0
        let xMax            = finiteXs.max() ?? 1
        let expression      = project.modelExpression
        let confidenceLevel = project.confidenceLevel
        let showBand        = project.showConfidenceBand
        let plotKey         = "xyplot-main-\(project.id)"
        let engineRef       = engine

        // Snapshot fit result data (nil is valid — means show raw data only)
        let covMatrix    = fitResult?.covarianceMatrix ?? []
        let fittedParams = fitResult?.parameters.filter { $0.fittedValue != nil } ?? []
        let paramNames   = fittedParams.map(\.name)
        let paramValues  = fittedParams.compactMap(\.fittedValue)
        let dof          = max(1, dataPoints.count - fittedParams.count)

        computeTask?.cancel()
        computeTask = Task.detached(priority: .userInitiated) {
            // ── Pre-read UserDefaults off the main actor ──────────────────
            // This is the primary source of the axes-before-curve flash:
            // doing it here means buildPlotData() on main does no I/O at all.
            var probe = PlotData(plotLines: [], settings: PlotSettings(savePoints: false), plotName: plotKey)
            probe.readFromUserDefaults()
            let preloadedProbe = probe

            let residualKey = "xyplot-residual-\(plotKey.dropFirst("xyplot-main-".count))"
            var resProbe = PlotData(plotLines: [], settings: PlotSettings(savePoints: false), plotName: residualKey)
            resProbe.readFromUserDefaults()
            let preloadedResidualProbe = resProbe

            // ── Curve and band computation ────────────────────────────────
            var curve: [(x: Double, y: Double)] = []
            var computedBand: [(x: Double, lower: Double, upper: Double)] = []

            if !expression.isEmpty && !paramValues.isEmpty,
			   let expr = try? await CompiledExpression(source: expression) {
                curve = await engineRef.smoothCurve(xMin: xMin, xMax: xMax,
                                                    params: paramValues,
                                                    paramNames: paramNames,
                                                    expression: expr)

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
            }

            guard !Task.isCancelled else { return }
			let finalCurve = curve
			let finalBand = computedBand
            await MainActor.run {
                curvePoints = finalCurve
                bandPoints  = showBand ? finalBand : []
                buildPlotData(preloadedProbe: preloadedProbe, residualProbe: preloadedResidualProbe)
            }
        }
    }

    /// Builds XYPlot PlotData from computed curve, band, and raw data points.
    /// Called whenever curvePoints or bandPoints are updated.
    /// `preloadedProbe`: a PlotData already populated via readFromUserDefaults(),
    /// read off the main actor in the detached task to avoid blocking the UI.
    /// Pass nil only when calling outside of a task context (e.g. band color sync).
    private func buildPlotData(preloadedProbe: PlotData? = nil, residualProbe: PlotData? = nil) {
        let dataPoints = project.dataPoints.filter { $0.x.isFinite && $0.y.isFinite }
        let inliers  = dataPoints.filter { !$0.isOutlier }
        let outliers = dataPoints.filter(  \.isOutlier )

        // ── Helper: restore existing PlotLine from in-memory plotData first,
        //    then from the pre-loaded probe (read off-main in the detached task),
        //    falling back to a default. No UserDefaults I/O on the main actor.
        let plotKey = "xyplot-main-\(project.id)"
        func existingLine(at index: Int, default defaultLine: PlotLine) -> PlotLine {
            if plotData.plotLines.count > index { return plotData.plotLines[index] }
            // Use the probe that was pre-read off the main actor
            let probe: PlotData = preloadedProbe ?? {
                var p = PlotData(plotLines: [], settings: PlotSettings(savePoints: false), plotName: plotKey)
                p.readFromUserDefaults()
                return p
            }()
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
            // Use pre-loaded probe (read off the main actor in the detached task)
            // to restore persisted settings without blocking the main actor.
            let probe: PlotData = preloadedProbe ?? {
                var p = PlotData(plotLines: [], settings: baseSettings, plotName: plotKey)
                p.readFromUserDefaults()
                return p
            }()
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
        let resProbe: PlotData = residualProbe ?? {
            var p = PlotData(plotLines: [], settings: baseResSettings, plotName: residualKey)
            p.readFromUserDefaults()
            return p
        }()
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

    // plotName is nil on the empty stub PlotData assigned in onAppear before the
    // detached task completes.  Suppress XYPlot entirely until buildPlotData() has
    // run at least once and stamped the real plotName — otherwise XYPlot renders
    // a first pass with default 0…1 axes before the data arrives.
    private var mainPlot: some View {
        Group {
            if plotData.plotName != nil {
                XYPlot(data: $plotData)
            } else {
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
        Group {
            if residualData.plotName != nil {
                XYPlot(data: $residualData)
            } else {
                Color.clear
            }
        }
        .frame(height: 200)
    }
}

