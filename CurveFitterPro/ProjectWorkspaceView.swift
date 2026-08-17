//
//  ProjectWorkspaceView.swift
//  CurveFitterPro
//
//  Created by Joseph Levy on 6/4/26.
//
import SwiftUI
import XYPlot
import Utilities

struct ProjectWorkspaceView: View {
	// 💡 Lifted states from ProjectDetailView to bypass SwiftData observation lag
	@Environment(\.colorScheme) private var colorScheme
	@Bindable var project: Project
	@ObservedObject var engine: FittingEngine
	@Binding var fitResult: FitResult?
	@Binding var plotData: PlotData
	@Binding var residualData: PlotData
	
	
	@State private var autoFitTask: Task<Void, Never>? = nil
	@State private var showImport = false
	@State private var viewPortSize: CGSize = .zero
	
	// 📐 Enforce minimum structural thresholds for clear multi-pane layout presentation
	private let minWorkspaceWidth: CGFloat = 950
	private let minWorkspaceHeight: CGFloat = 650
#if os(macOS)
    let scale = 0.8
#else
    let scale = 1.0
#endif
	var body: some View {
		ZStack {
			GeometryReader { g in
				Color.clear
					.onAppear { viewPortSize = g.size }
					.onChange(of: g.size) { //_,newSize in
						DispatchQueue.main.async {
							viewPortSize = g.size
						}
					}
			}.ignoresSafeArea(.keyboard)
			
			let portrait = viewPortSize.width <= viewPortSize.height * 1.4
			let height = viewPortSize.height
			ScalingStackPair(portrait: portrait, height: height , scale: scale) {
				PlotView(
					project: project,
					engine: engine,
					fitResult: $fitResult,
					plotData: $plotData,
					residualData: $residualData
				).scaleToFitAvailableSize(minSize: CGSize(
					width:  (portrait ? 5.5 : 8.5) * 72,
					height: (portrait ? 8.5 : 5.5) * 72
				))
				
			} content2: {
				ScalingStackPair(portrait: !portrait, height: height, scale: 1.0) {
					VStack(spacing: 0) {
						DataEditorView(project: project, showImport: .constant(false))
							.frame(maxWidth: .infinity)
						Divider()
					}
				} content2: {
					VStack(spacing: 0) {
						Text("Model Configuration & Analytics")
							.font(.subheadline.bold())
							.frame(maxWidth: .infinity, alignment: .leading)
							.padding()
							.background(Color(.secondarySystemGroupedBackground))
						Button("Choose Model") {}
						Divider()
						
						// Shares the same fitResult binding as the PlotView above
						//FitRunView(project: project, engine: engine, fitResult: $fitResult)
						if let result = fitResult {
							ForEach(result.parameters.indices, id: \.self) { i in
								let p = result.parameters[i]
								HStack(alignment: .top) {
									Text(p.name)
										.font(.headline)
										.frame(width: 80, alignment: .leading)
									
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
						}
					}
				}
			}
			.background(Color(.systemGroupedBackground))
			.onAppear {
				// Sync initial state on view presentation to prevent crossover artifacts
				fitResult = project.fitResult
			}
			.onChange(of: project.dataPoints) { _, _ in runDebouncedFit() }
			.onChange(of: project.modelExpression) { _, _ in runDebouncedFit() }
			
		}
	}
	
	
	private func runDebouncedFit() {
		autoFitTask?.cancel()
		autoFitTask = Task {
			try? await Task.sleep(for: .milliseconds(350))
			guard !Task.isCancelled else { return }
			guard !project.dataPoints.isEmpty && !project.modelExpression.isEmpty else { return }
			
			if let result = await engine.fit(project: project) {
				await MainActor.run {
					project.fitResult = result
					project.parameters = result.parameters
					self.fitResult = result
				}
			}
		}
	}
}

/* The Core Layout Trick:
 Forces the workspace to match window dimensions *unless* the window drops below the minimum boundaries.
 When it drops lower, the frame locks at the minimum constants, triggering the parent ScrollView.
 */
//			.frame(
//				width: max(geometry.size.width, minWorkspaceWidth),
//				height: max(geometry.size.height, minWorkspaceHeight)
//			)
