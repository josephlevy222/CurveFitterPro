import SwiftUI
import SwiftData
import XYPlot

struct ProjectDetailView: View {
	@Bindable var project: Project
	@StateObject private var engine = FittingEngine()
	@State private var selectedTab = 0
	@State private var showModelPicker = false
	@State private var showImport = false
	@State private var importError: String?
	@State private var showImportError = false
	@State private var modelToEdit: BuiltinModel? = nil
	@State private var isCreatingNewModel = false
	@State private var isEditingOldModel = false
	@State private var newModelFromOld = false
	
	/// Lifted here so FitRunView and PlotView share the same result, bypassing SwiftData's unreliable observation of Data blob properties.
	@State private var fitResult: FitResult? = nil
	@State private var plotData: PlotData = PlotData(settings: PlotSettings(savePoints: false))
	@State private var residualData: PlotData = PlotData(settings: PlotSettings(savePoints: false))
	
	// Holding containers to transfer models cleanly without triggering layout engine sheet collisions
	@State private var pendingCloneToEdit: BuiltinModel? = nil
	@State private var pendingModelToEdit: BuiltinModel? = nil
	
	var body: some View {
		VStack(spacing: 0) {
			Picker("Section", selection: $selectedTab) {
				Text("Data").tag(0)
				Text("Model").tag(1)
				Text("Fit").tag(2)
				Text("Plot").tag(3)
			}
			.pickerStyle(.segmented)
			.padding(.horizontal)
			.padding(.vertical, 8)
			
			Divider()
			
			/// if-based switcher — inactive views are destroyed, saving memory. Keyboard avoidance works correctly unlike .page TabView.
			Group {
				if selectedTab == 0 {
					DataEditorView(project: project, showImport: $showImport)
				} else if selectedTab == 1 {
					ModelSetupView(project: project,
								   showModelPicker: $showModelPicker,
								   showClonedModel: $newModelFromOld,
								   showCustomModel: $isCreatingNewModel,
								   isEditingOldModel: $isEditingOldModel)
				} else if selectedTab == 2 {
					FitRunView(project: project, engine: engine, fitResult: $fitResult)
				} else {
					PlotView(project: project, engine: engine, fitResult: $fitResult,
							 plotData: $plotData, residualData: $residualData)
				}
			}
		}
		.navigationTitle(project.name)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .automatic) {
				ExportMenu(provider: PlotExportLayout(plotData: plotData, residualData: residualData,
													  fitResults: fitResult != nil && project.showResiduals))
				.padding(.horizontal)
			}
		}
		.onAppear {
			/// Always restore from project — ensures switching projects doesn't carry over the previous project's fit result
			fitResult = project.fitResult
		}
		.sheet(isPresented: $showModelPicker) {
			ModelPickerSheet { model in
				applyModel(model)
				showModelPicker = false
			}
		}
		.sheet(isPresented: $isCreatingNewModel) {
			CustomModelSheet { model in
				applyModel(model)
				isCreatingNewModel = false
			}
		}
		// ── COPY FLOW: Create isolated detached instance -> queue for display ──
		.sheet(isPresented: $newModelFromOld, onDismiss: {
			if let model = pendingCloneToEdit {
				let clonedModel = BuiltinModel(
					name: "\(model.name) (Copy)",
					category: "Custom Models",
					equation: "",
					expression: model.expression,
					parameterNames: model.parameterNames,
					defaultValues: model.defaultValues,
					description: model.description,
					typicalUseCase: model.typicalUseCase
				)
				DispatchQueue.main.async {
					self.modelToEdit = clonedModel
					self.pendingCloneToEdit = nil
				}
			}
		}) {
			ModelPickerSheet { model in
				pendingCloneToEdit = model
				newModelFromOld = false
			}
		}
		// ── EDIT FLOW: Select target custom model -> stage for entry display ──
		.sheet(isPresented: $isEditingOldModel, onDismiss: {
			if let model = pendingModelToEdit {
				DispatchQueue.main.async {
					self.modelToEdit = model
					self.pendingModelToEdit = nil
				}
			}
		}) {
			ModelPickerSheet(customOnly: true) { model in
				pendingModelToEdit = model
				isEditingOldModel = false
			}
		}
		// ── VISUAL SCREEN PRESENTATION (Handles both saved edits and new clones) ──
		.sheet(item: $modelToEdit) { model in
			CustomModelSheet(editingModel: model) { editedModel in
				applyModel(editedModel)
				modelToEdit = nil
			}
		}
		.sheet(isPresented: $showImport) {
			ImportSheet { text in
				handleImport(text: text)
				showImport = false
			}
		}
		.alert("Import Error", isPresented: $showImportError) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(importError ?? "Unknown error")
		}
	}
	
	private func applyModel(_ model: BuiltinModel) {
		project.modelName = model.name
		project.modelExpression = model.expression
		project.modelEquation = model.equation
		project.parameters = model.makeParameters()
		project.fitResult = nil
		fitResult = nil
	}
	
	private func handleImport(text: String) {
		do {
			let points = try DataImporter.parse(text: text)
			project.dataPoints = points
			project.fitResult = nil
			fitResult = nil
		} catch {
			importError = error.localizedDescription
			showImportError = true
		}
	}
}
