//
// ModelLibraryViews.swift
// CurveFitterPro
//
import SwiftUI
import Charts
import XYPlot
import NumericTextField
import Utilities

// MARK: - Model Picker Sheet

struct ModelPickerSheet: View {
	let customOnly: Bool
	let onSelect: (BuiltinModel) -> Void
	init(customOnly: Bool = false, onSelect: @escaping (BuiltinModel) -> Void) {
		self.customOnly = customOnly
		self.onSelect = onSelect
	}
	@State private var searchText = ""
	@State private var showCustomSheet = false
	@State private var libraryToggle = false
	@Environment(\.dismiss) private var dismiss
	
	var filtered: [BuiltinModel] {
		_ = libraryToggle
		return ModelLibrary.search(searchText)
	}
	
	var body: some View {
		NavigationStack {
			List {
				ForEach(ModelLibrary.categories, id: \.self) { cat in
					let models = filtered.filter { $0.category == cat }
					if !models.isEmpty && (!customOnly || cat == "Custom Models")  {
						Section(cat) {
							ForEach(models) { model in
								Button {
									onSelect(model)
								} label: {
									VStack(alignment: .leading, spacing: 4) {
										Text(model.name).foregroundStyle(.primary).bold()
										// True baseline-shifted rendering for custom or built-in json records
										Text(EquationFormatter.formatToAttributedString(model.expression, fontSize: 13))
										Text(model.typicalUseCase)
											.font(.caption)
											.foregroundStyle(.secondary)
									}
									.padding(.vertical, 2)
								}
							}
							.onDelete { offsets in
								if cat == "Custom Models" {
									deleteCustomModel(at: offsets, from: models)
								}
							}
						}
					}
				}
				
#if DEBUG
				Section {
					Button(action: {
						ModelLibrary.resetToFactoryDefaults()
						libraryToggle.toggle()
					}) {
						HStack {
							Image(systemName: "trash.triangle.fill")
							Text("Reset Cache to Factory Defaults")
						}
						.font(.caption)
						.foregroundStyle(.red)
					}
					.buttonStyle(.borderedProminent)
					.tint(.red.opacity(0.1))
					.padding(.top, 8)
				}
#endif
			} // 🎯 The List ends here
			// ✅ FIX: Modifiers are now properly attached to the List itself
			.searchable(text: $searchText, prompt: "Search models…")
			.navigationTitle("Model Library")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .topBarTrailing) {
					Button { showCustomSheet = true } label: { Image(systemName: "plus") }
				}
			}
			.sheet(isPresented: $showCustomSheet) {
				CustomModelSheet { newModel in
					libraryToggle.toggle()
					onSelect(newModel)
				}
			}
		}
	}
	
	private func deleteCustomModel(at offsets: IndexSet, from sectionModels: [BuiltinModel]) {
		for index in offsets {
			let modelToDelete = sectionModels[index]
			if let masterIndex = ModelLibrary.all.firstIndex(where: { $0.id == modelToDelete.id }) {
				ModelLibrary.all.remove(at: masterIndex)
			}
		}
		let data = try? JSONEncoder().encode(ModelLibrary.all)
		let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
		if let fileURL = paths.first?.appendingPathComponent("models.json") {
			try? data?.write(to: fileURL, options: .atomic)
		}
		libraryToggle.toggle()
	}
}

// MARK: - Custom Model Sheet (Supports Creation & Editing)

struct CustomModelSheet: View {
	let editingModel: BuiltinModel?
	let onSave: (BuiltinModel) -> Void
	@State private var name : String = ""
	@State private var description : String = ""
	@State private var typicalUseCase: String  = ""
	@State private var expression: String = ""
	@State private var parseError: String = ""
	@State private var detectedParams: [String] = []
	@State private var defaultValues: [String] = []
	@Environment(\.dismiss) private var dismiss
	
	init(editingModel: BuiltinModel? = nil, onSave: @escaping (BuiltinModel) -> Void) {
		self.editingModel = editingModel
		self.onSave = onSave
		
		if let model = editingModel {
			self._name = State(initialValue: model.name)
			self._description = State(initialValue: model.description)
			self._typicalUseCase = State(initialValue: model.typicalUseCase)
			self._expression = State(initialValue: model.expression)
			self._detectedParams = State(initialValue: model.parameterNames)
			self._defaultValues = State(initialValue: model.defaultValues.map { String($0) })
		}
	}
	
	var body: some View {
		NavigationStack {
			Form {
				Section("Model Information") {
					TextField("Model Name (e.g., My Growth Law)", text: $name)
					TextField("Description", text: $description)
					TextField("Typical Use Case", text: $typicalUseCase)
				}
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
			.navigationTitle(editingModel == nil ? "Custom Model" : "Edit Model")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .topBarTrailing) {
					Button("Save") {
						if let editingModel {
							// 1. 💡 FIX: Construct an updated model instance incorporating all modified @State values
							var updatedModel = editingModel
							updatedModel.name = name
							updatedModel.description = description
							updatedModel.typicalUseCase = typicalUseCase
							updatedModel.expression = expression
							updatedModel.equation = EquationFormatter.formatToPlainString(expression)
							updatedModel.parameterNames = detectedParams
							updatedModel.defaultValues = defaultValues.map { Double($0) ?? 1.0 }
							
							// 2. 💡 FIX: Look up by ID. If it's a traditional edit, replace it.
							// If it's a clone/copy, it won't be found — so append it as a new custom model!
							if let index = ModelLibrary.all.firstIndex(where: { $0.id == editingModel.id }) {
								ModelLibrary.all[index] = updatedModel
							} else {
								ModelLibrary.all.append(updatedModel)
							}
							
							// 3. Persist the updated array to disk and notify the parent presentation handler
							ModelLibrary.save(models: ModelLibrary.all)
							onSave(updatedModel)
							dismiss() // Ensure the sheet closes out fully
						} else {
							saveAndForwardModel()
						}
					}
					.bold()
					.disabled(detectedParams.isEmpty || !parseError.isEmpty)
				}
			}.interactiveDismissDisabled()
		}
	}
	
	private func parseExpression() {
		guard !expression.isEmpty else { parseError = ""; detectedParams = []; return }
		do {
			// 🎯 THE APPROACH 2 FIX: Strip out double quotes so the math compiler
			// only sees clean variable/parameter names (e.g., slope, bottom)
			let cleanExpression = expression.replacingOccurrences(of: "\"", with: "")
			
			let compiled = try CompiledExpression(source: cleanExpression)
			detectedParams = compiled.parameterNames
			parseError = ""
			while defaultValues.count < detectedParams.count { defaultValues.append("1.0") }
			if defaultValues.count > detectedParams.count { defaultValues = Array(defaultValues.prefix(detectedParams.count)) }
		} catch {
			parseError = error.localizedDescription
			detectedParams = []
		}
	}
	
	private func saveAndForwardModel() {
		let numericDefaults = defaultValues.map { Double($0) ?? 1.0 }
		
		let newModel = BuiltinModel(
			name: name,
			category: "Custom Models",
			// 🎯 Formats plain string output cleanly for json document architecture
			equation: EquationFormatter.formatToPlainString(expression),
			expression: expression,
			parameterNames: detectedParams,
			defaultValues: numericDefaults,
			description: description.isEmpty ? "User defined model equation." : description,
			typicalUseCase: typicalUseCase.isEmpty ? "Custom analysis" : typicalUseCase
		)
		
		ModelLibrary.all.append(newModel)
		let encoder = JSONEncoder()
		if let data = try? encoder.encode(ModelLibrary.all) {
			let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
			if let fileURL = paths.first?.appendingPathComponent("models.json") {
				try? data.write(to: fileURL, options: .atomic)
			}
		}
		onSave(newModel)
		dismiss()
	}
}

// MARK: - Model Library View (Tab)

struct ModelLibraryView: View {
	@State private var searchText = ""
	@State private var showCustomSheet = false
	@State private var libraryToggle = false
	
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
										// 🎯 Rich text layout replacements instead of mono plain-text
										Text(EquationFormatter.formatToAttributedString(model.expression, fontSize: 13))
									}
								}
							}
							.onDelete { offsets in
								if cat == "Custom Models" {
									deleteCustomModel(at: offsets, from: models)
								}
							}
						}
					}
				}
			}
			.searchable(text: $searchText, prompt: "Search…")
			.navigationTitle("Model Library")
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button { showCustomSheet = true } label: { Image(systemName: "plus") }
				}
			}
			.sheet(isPresented: $showCustomSheet) {
				CustomModelSheet { _ in libraryToggle.toggle() }
			}
			.id(libraryToggle)
		}
	}
	
	private func deleteCustomModel(at offsets: IndexSet, from sectionModels: [BuiltinModel]) {
		for index in offsets {
			let modelToDelete = sectionModels[index]
			if let masterIndex = ModelLibrary.all.firstIndex(where: { $0.id == modelToDelete.id }) {
				ModelLibrary.all.remove(at: masterIndex)
			}
		}
		let data = try? JSONEncoder().encode(ModelLibrary.all)
		let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
		if let fileURL = paths.first?.appendingPathComponent("models.json") {
			try? data?.write(to: fileURL, options: .atomic)
		}
		libraryToggle.toggle()
	}
}

// MARK: - Model Detail View

struct ModelDetailView: View {
	let model: BuiltinModel
	
	var body: some View {
		List {
			Section("Equation") {
				// 🎯 Upgraded presentation view layout
				Text(EquationFormatter.formatToAttributedString(model.expression, fontSize: 15))
			}
			Section("Expression (for custom use)") {
				Text(model.expression)
					.font(.system(.caption, design: .monospaced))
					.textSelection(.enabled)
			}
			Section("Description") { Text(model.description) }
			Section("Typical Use Case") { Text(model.typicalUseCase) }
			Section("Default Parameter Values") {
				ForEach(Array(zip(model.parameterNames.map { $0.replacingOccurrences(of: "\"", with: "")}, model.defaultValues)), id: \.0) { name, val in
					LabeledContent(name, value: String(format: "%.4g", val))
				}
			}
		}
		.navigationTitle(model.name)
		.navigationBarTitleDisplayMode(.inline)
	}
}
