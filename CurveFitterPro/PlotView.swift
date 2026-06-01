//
// PlotView.swift
// CurveFitterPro
//
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
	@State private var curvePoints: [(x: Double, y: Double)] = []
	@State private var bandPoints:  [(x: Double, lower: Double, upper: Double)] = []
	@State private var computeTask: Task<Void, Never>? = nil
	@State private var mainPlotHeight: CGFloat = 500
	@State private var pendingScrollAnchor: String? = nil
	@Binding var plotData: PlotData
	@Binding var residualData: PlotData
	
	init(project: Project, engine: FittingEngine, fitResult: Binding<FitResult?>,
		 plotData: Binding<PlotData> = .constant(PlotData(settings: PlotSettings(savePoints: false))),
		 residualData: Binding<PlotData> = .constant(PlotData(settings: PlotSettings(savePoints: false)))) {
		self.project = project
		self.engine = engine
		self._fitResult = fitResult
		self._plotData = plotData
		self._residualData = residualData
	}
	
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Color.clear.frame(height: 0).id("plotTop")
			if project.dataPoints.isEmpty {
				ContentUnavailableView("No Data", systemImage: "chart.xyaxis.line",
									   description: Text("Import or enter data first."))
			} else {
				XYPlot(data: $plotData)
					.padding(.horizontal)
				VStack(spacing: 0) {
					HStack(spacing: 0) {
						Text(project.showConfidenceBand ? "Show" : "Not Showing")
						if project.showConfidenceBand {
							Picker("", selection: Binding(
								get: { project.confidenceLevel },
								set: { project.confidenceLevel = $0 }
							)) {
								Text("90%").tag(90)
								Text("95%").tag(95)
								Text("99%").tag(99)
							}
						} else { Text(" ").padding(.bottom)}
						Toggle("Confidence Band", isOn: Binding(get: { project.showConfidenceBand },
																set: { project.showConfidenceBand = $0 }))
					}
					.padding(.horizontal)
					
					Color.clear.frame(height: 0).id("plotBottom")
					if fitResult != nil {
						Toggle("Show Residuals", isOn: Binding(get: { project.showResiduals },
															   set: { project.showResiduals = $0 }))
						.padding(.horizontal)
						
						if project.showResiduals {
							XYPlot(data: $residualData)
								.frame(height: 200)
								.padding(.horizontal)
						}
					}
				}
				.padding(.vertical)
			}
		}
		.padding(.horizontal)
		.scrollsWithKeyboard()
		
		.onChange(of: fitResult?.residualSumOfSquares) { _, _ in recomputePlotData() }
		.onChange(of: project.confidenceLevel) { _, _ in recomputePlotData() }
		.onChange(of: project.showConfidenceBand) { _, newValue in
			if newValue { recomputePlotData() } else { buildPlotData() }
		}
		.onChange(of: plotData.plotLines.count > 1 ? plotData.plotLines[1].lineColor.sARGB : 0) { _, _ in
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
			computeTask?.cancel()
			computeTask = nil
			curvePoints = []
			bandPoints  = []
			plotData    = PlotData(settings: PlotSettings(savePoints: false))
			residualData = PlotData(settings: PlotSettings(savePoints: false))
			recomputePlotData()
		}
	}
	
	private func recomputePlotData() {
		guard let result = fitResult else {
			curvePoints = []
			if !project.showConfidenceBand { bandPoints = [] }
			buildPlotData()
			return
		}
		
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
		
		computeTask?.cancel()
		computeTask = Task.detached(priority: .userInitiated) {
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
			guard !Task.isCancelled else { return }
			await MainActor.run {
				curvePoints = curve
				bandPoints  = finalBand
				buildPlotData()
			}
		}
	}
	
	private func buildPlotData() {
		let dataPoints = project.dataPoints.filter { $0.x.isFinite && $0.y.isFinite }
		let inliers  = dataPoints.filter { !$0.isOutlier }
		let outliers = dataPoints.filter(  \.isOutlier )
		
		let plotKey = "xyplot-main-\(project.id)"
		func existingLine(at index: Int, default defaultLine: PlotLine) -> PlotLine {
			if plotData.plotLines.count > index { return plotData.plotLines[index] }
			var probe = PlotData(plotLines: [], settings: PlotSettings(savePoints: false), plotName: plotKey)
			probe.readFromUserDefaults()
			if probe.plotLines.count > index { return probe.plotLines[index] }
			return defaultLine
		}
		
		var curveLine = existingLine(at: 0, default: PlotLine(
			lineColor: Color.accentColor, lineStyle: StrokeStyle(lineWidth: 2),
			pointColor: .clear, pointShape: PointShape(Circle().path, color: .clear), legend: "Fit"
		))
		curveLine.values = curvePoints.filter { $0.x.isFinite && $0.y.isFinite }.map { PlotPoint($0.x, $0.y) }
		
		let defaultInlierColor = curveLine.lineColor
		var inlierWhite = existingLine(at: 2, default: PlotLine(
			lineColor: .clear, pointColor: .white,
			pointShape: PointShape(Circle().path, fill: true, color: .white, size: 1.4), legend: nil
		))
		var inlierDark = existingLine(at: 3, default: PlotLine(
			lineColor: .clear, pointColor: defaultInlierColor,
			pointShape: PointShape(Circle().path, fill: true, color: defaultInlierColor, size: 1.0),
			legend: project.yLabel.isEmpty ? "Data" : project.yLabel
		))
		let inlierPts = inliers.map { PlotPoint($0.x, $0.y) }
		inlierWhite.values = inlierPts
		inlierDark.values  = inlierPts
		
		var outlierWhite = existingLine(at: 4, default: PlotLine(
			lineColor: .clear, pointColor: .white,
			pointShape: PointShape(Polygon(sides: 4).path, fill: true, color: .white, size: 1.4), legend: nil
		))
		var outlierLine = existingLine(at: 5, default: PlotLine(
			lineColor: .clear, pointColor: .orange,
			pointShape: PointShape(Polygon(sides: 4).path, fill: true, color: .orange, size: 1.0),
			legend: outliers.isEmpty ? nil : "Outlier"
		))
		let outlierPts = outliers.map { PlotPoint($0.x, $0.y) }
		outlierWhite.values = outlierPts
		outlierLine.values  = outlierPts
		
		let xAttr = AttributedString(project.xLabel)
		let yAttr = AttributedString(project.yLabel)
		
		let bandLineColor: Color = existingLine(at: 1, default: PlotLine(
			lineColor: Color.accentColor, lineStyle: StrokeStyle(lineWidth: 8),
			pointColor: .clear, pointShape: PointShape(Circle().path, color: .clear), legend: nil
		)).lineColor
		let bandFillColor = bandLineColor.opacity(colorScheme == .dark ? 0.35 : 0.15)
		
		var bands: [PlotBand] = []
		if project.showConfidenceBand && !bandPoints.isEmpty {
			let upper = bandPoints.map { PlotPoint($0.x, $0.upper) }
			let lower = bandPoints.map { PlotPoint($0.x, $0.lower) }
			bands = [PlotBand(upper: upper, lower: lower, color: bandFillColor)]
		}
		
		let bandLegendLine = PlotLine(
			lineColor: bandLineColor, lineStyle: StrokeStyle(lineWidth: 8), pointColor: .clear,
			pointShape: PointShape(Circle().path, color: .clear),
			legend: project.showConfidenceBand && !bandPoints.isEmpty ? "\(project.confidenceLevel)% CI" : nil
		)
		
		var lines: [PlotLine] = [curveLine, bandLegendLine, inlierWhite, inlierDark]
		if !outliers.isEmpty { lines += [outlierWhite, outlierLine] }
		
		// ── 🎯 Upgraded Dynamic AttributedString Generation ─────────────────────
		let annotationText: AttributedString? = {
			guard let result = fitResult else { return nil }
			
			let fontSize: CGFloat = 12
			var baseContainer = AttributeContainer()
			baseContainer.font = UIFont.systemFont(ofSize: fontSize, weight: .regular)
			
			var finalAttr = AttributedString()
			
			if !project.modelName.isEmpty {
				var modelAttr = AttributedString(project.modelName + "\n")
				modelAttr.font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
				finalAttr.append(modelAttr)
			}
			
			let r2Str = String(format: "R² = %.4f", result.rSquared)
			finalAttr.append(AttributedString(r2Str, attributes: baseContainer))
			
			let parameterSubstitution = fittedEquation(result: result)
			if !parameterSubstitution.isEmpty {
				finalAttr.append(AttributedString("\n"))
				// Resolves all complex structural exponents through unified parser
				let mathExpr = EquationFormatter.formatToAttributedString(parameterSubstitution, fontSize: fontSize, includeLHS: true)
				finalAttr.append(mathExpr)
			}
			
			if project.showConfidenceBand {
				finalAttr.append(AttributedString("\n\(project.confidenceLevel)% Confidence Band", attributes: baseContainer))
			}
			return finalAttr
		}()
		
		if plotData.plotName == plotKey {
			var updated = plotData
			updated.plotLines = lines
			updated.plotBands = bands
			updated.settings.annotation = annotationText
			plotData = updated
		} else {
			var baseSettings = PlotSettings(
				title: AttributedString(project.name), xAxis: AxisParameters(title: xAttr),
				yAxis: AxisParameters(title: yAttr), legend: false, savePoints: false
			)
			var probe = PlotData(plotLines: [], settings: baseSettings, plotName: plotKey)
			probe.readFromUserDefaults()
			let hadSavedData = probe.settings != baseSettings
			baseSettings = probe.settings
			baseSettings.title = probe.settings.title.characters.isEmpty ? AttributedString(project.name) : probe.settings.title
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
			lineColor: .clear, pointColor: Color.accentColor,
			pointShape: PointShape(Circle().path, fill: true, color: Color.accentColor, size: 1.0), legend: nil
		)
		var negLine = PlotLine(
			lineColor: .clear, pointColor: .orange,
			pointShape: PointShape(Circle().path, fill: true, color: .orange, size: 1.0), legend: nil
		)
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
		var zeroLine = PlotLine(
			lineColor: Color(.systemGray3), lineStyle: StrokeStyle(lineWidth: 1, dash: [4, 3]),
			pointShape: PointShape(Circle().path, color: .clear), legend: nil
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
			title: AttributedString(resTitleStr), xAxis: AxisParameters(title: xAttr),
			yAxis: AxisParameters(title: resAttr), legend: false, savePoints: false
		)
		var resProbe = PlotData(plotLines: [], settings: baseResSettings, plotName: residualKey)
		resProbe.readFromUserDefaults()
		baseResSettings = resProbe.settings
		baseResSettings.title = resProbe.settings.title.characters.isEmpty ? AttributedString(resTitleStr) : resProbe.settings.title
		baseResSettings.xAxis?.title = xAttr
		baseResSettings.yAxis?.title = resAttr
		baseResSettings.legend = false
		baseResSettings.savePoints = false
		var newResidual = PlotData(plotLines: resLines, settings: baseResSettings, plotName: residualKey)
		newResidual.scaleAxes()
		residualData = newResidual
	}
	
	/// Performs raw parameter value placement. Cleanup and structural formatting are entirely handled by EquationFormatter.
	/// Performs raw parameter value placement. Cleanup and structural formatting are entirely handled by EquationFormatter.
	private func fittedEquation(result: FitResult) -> String {
		let params = result.parameters.filter { $0.fittedValue != nil }
		guard !params.isEmpty else { return "" }
		
		func fmt(_ v: Double) -> String {
			if abs(v) >= 1000 || (abs(v) < 0.01 && v != 0) {
				return String(format: "%.3g", v)
			}
			return String(format: "%.4g", v)
		}
		
		var eq = project.modelEquation.isEmpty ? project.modelExpression : project.modelEquation
		let sorted = params.sorted { $0.name.count > $1.name.count }
		
		for p in sorted {
			guard let v = p.fittedValue else { continue }
			let formatted = fmt(v)
			
			// 1. Replace the original clean name (e.g., "V50")
			eq = eq.replacingOccurrences(of: p.name, with: formatted)
			
			// 2. 🎯 NEW: Replace potential subscript variations generated by EquationFormatter
			if p.name.count > 1 {
				let firstLetter = p.name.prefix(1)
				let remainingPart = p.name.dropFirst()
				
				let plainSubscript = "\(firstLetter)_\(remainingPart)"          // e.g., "V_50"
				let bracketedSubscript = "\(firstLetter)_[\(remainingPart)]"    // e.g., "V_[50]"
				
				eq = eq.replacingOccurrences(of: plainSubscript, with: formatted)
				eq = eq.replacingOccurrences(of: bracketedSubscript, with: formatted)
			}
		}
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
}
