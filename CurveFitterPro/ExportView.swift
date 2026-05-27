//
//  ExportView.swift
//  CurveFitterPro
//
//  Created by Joseph Levy on 5/25/26.
//

import SwiftUI
import XYPlot
import Utilities

struct ExportPlotView:  View {
	let plotData: PlotData
	let residualData: PlotData
	let fitResults: Bool
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			XYPlot(data: .constant(plotData))
				.padding(.horizontal)
			
			if fitResults {
				XYPlot(data: .constant(residualData))
					.frame(height: 200)
					.padding(.horizontal)
			}
		}
		.padding()
		.allowsHitTesting(false) // Not an interactive view, This and below
		.disabled(true)          // prevent focus state warnings
	}
}


struct PlotExportLayout: ExportableLayout {
	let plotData: PlotData
	let residualData: PlotData
	let fitResults: Bool
	var jobName: String { "Main Data Report" }
	
	func makeView(isLandscape: Bool) -> some View {
		// Return your specific view, passing down the orientation
		ExportPlotView(plotData: plotData, residualData: residualData, fitResults: fitResults)
			.frame(
				width:  (isLandscape ? 11.0 : 8.5) * 72,
				height: (isLandscape ? 8.5 : 11.0) * 72
			)
	}
}
