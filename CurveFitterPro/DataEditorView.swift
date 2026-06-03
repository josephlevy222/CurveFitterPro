//
//  DataEditorView.swift
//  CurveFitterPro
//
//  Created by Joseph Levy on 5/24/26.
//

import SwiftUI
import XYPlot
import NumericTextField
import Utilities

struct DataEditorView: View {
	@Bindable var project: Project
	@Binding var showImport: Bool
	
	@FocusState private var focusedField: Field?
	@State private var autoSort = false
	@State private var refreshID = UUID()
	enum Field: Hashable {
		case row(id: UUID, column: Column)
		case newRow(column: Column)
		enum Column { case x, y, w }
	}
	
	var body: some View {
		VStack(spacing: 0) {
			// MARK: - Toolbar
			HStack {
				Button { showImport = true } label: { Image(systemName: "doc.badge.plus") }
				Button { pasteFromClipboard() } label: { Image(systemName: "clipboard") }
				Spacer()
				Toggle("Auto-Sort", isOn: $autoSort).font(.caption).fixedSize()
				Button("Sort") { sortData() }.buttonStyle(.bordered).controlSize(.small)
			}
			.padding()
			.background(.ultraThinMaterial)
			
			// MARK: - Spreadsheet Headers
			HStack(spacing: 0) {
				Text("X Value").frame(maxWidth: .infinity, alignment: .leading)
				Text("Y Value").frame(maxWidth: .infinity, alignment: .leading)
				Text("Weight").frame(width: 70, alignment: .leading)
				Text("Out").frame(width: 40)
				Spacer().frame(width: 30)
			}
			.font(.caption2.bold().monospaced())
			.padding(.horizontal).padding(.vertical, 8)
			.background(Color(.secondarySystemGroupedBackground))
			
			// MARK: - Data List
			List {
				ForEach($project.dataPoints) { $point in
					DataPointRow(
						point: $point,
						focusedField: $focusedField,
						onCommit: { col in
							advanceFocus(from: point, col: col)
						},
						onDelete: {
							project.dataPoints.removeAll(where: { $0.id == point.id })
						}
					)
					.listRowInsets(EdgeInsets())
					.listRowSeparator(.hidden)
				}.id(refreshID)
				
				// Always-present row for new data
				NewDataPointRow(focusedField: $focusedField) { newPoint in
					project.dataPoints.append(newPoint)
					if autoSort { sortData() }
					focusedField = .newRow(column: .x)
				}
				.listRowInsets(EdgeInsets())
				.listRowSeparator(.hidden)
			}
			.listStyle(.plain)
			.scrollDismissesKeyboard(.never)
		}
	}
	
	// MARK: - Logic
	
	private func advanceFocus(from point: DataPoint, col: Field.Column) {
		switch col {
		case .x: focusedField = .row(id: point.id, column: .y)
		case .y: focusedField = .row(id: point.id, column: .w)
		case .w:
			if let index = project.dataPoints.firstIndex(where: { $0.id == point.id }),
			   index + 1 < project.dataPoints.count {
				focusedField = .row(id: project.dataPoints[index+1].id, column: .x)
			} else {
				focusedField = .newRow(column: .x)
			}
			if autoSort { sortData() }
		}
	}
	
	private func sortData() {
		withAnimation {
			project.dataPoints.sort { $0.x < $1.x }
		}
	}
	
	private func pasteFromClipboard() {
#if os(iOS)
		let clipboardText = UIPasteboard.general.string
#elseif os(macOS)
		let clipboardText = NSPasteboard.general.string(forType: .string)
#endif
		
		guard let text = clipboardText else { return }
		if let points = try? DataImporter.parse(text: text) {
			project.dataPoints.append(contentsOf: points)
			if autoSort { sortData() }
		}
	}
}

// MARK: - Row with Local String Buffer

struct DataPointRow: View {
	@Binding var point: DataPoint
	@FocusState.Binding var focusedField: DataEditorView.Field?
	var onCommit: (DataEditorView.Field.Column) -> Void
	var onDelete: () -> Void
	
	struct PointStrings : Equatable {
		var x: String = ""
		var y: String = ""
		var w: String = ""
	}
	
	@State private var pStr: PointStrings
	
	// FIX: Explicitly seed the state buffer during initialization
	init(point: Binding<DataPoint>,
		 focusedField: FocusState<DataEditorView.Field?>.Binding,
		 onCommit: @escaping (DataEditorView.Field.Column) -> Void,
		 onDelete: @escaping () -> Void) {
		self._point = point
		self._focusedField = focusedField
		self.onCommit = onCommit
		self.onDelete = onDelete
		
		// Map the numeric values to strings immediately on creation
		self._pStr = State(initialValue: PointStrings(
			x: String(format: "%g", point.wrappedValue.x),
			y: String(format: "%g", point.wrappedValue.y),
			w: String(format: "%g", point.wrappedValue.weight)
		))
	}
	
	var body: some View {
		HStack(spacing: 0) {
			cell(text: $pStr.x, col: .x)
			cell(text: $pStr.y, col: .y)
			cell(text: $pStr.w, col: .w, width: 70)
			
			Toggle("", isOn: $point.isOutlier)
				.labelsHidden()
				.frame(width: 40)
			
			Button(action: onDelete) {
				Image(systemName: "minus.circle.fill").foregroundStyle(.red)
			}
			.frame(width: 30)
		}
		.padding(.horizontal)
		.frame(height: 34)
		.listRowBackground(isFocused ? Color.accentColor.opacity(0.1) : Color.clear)
		// Leave this here so that pasting data or auto-sorting still updates the text fields!
		.onChange(of: point) { syncFromModel() }
	
		// ✅ FIX: Ties the hardware Return/Enter key into your custom horizontal focus advancement flow
		.onSubmit {
			commitChanges()
			if case .row(let id, let col) = focusedField, id == point.id {
				if pStr.x.isEmpty && pStr.y.isEmpty {
					focusedField = nil
				} else {
					onCommit(col)
				}
			}
		}
	}
	
	private var isFocused: Bool {
		if case .row(let id, _) = focusedField { return id == point.id }
		return false
	}
	
	private func cell(text: Binding<String>, col: DataEditorView.Field.Column, width: CGFloat? = nil) -> some View {
		let isCurrentCell = focusedField == .row(id: point.id, column: col)
		
		return NumericTextField("", numericText: text,
								onEditingChanged: { editing in if !editing { commitChanges() } },
								onCommit: { commitChanges() })
		.focused($focusedField, equals: .row(id: point.id, column: col))
		.textFieldStyle(.plain)
		.monospaced()
		.padding(.horizontal, 8)
		.padding(.vertical, 6)
		.frame(maxWidth: width ?? .infinity, alignment: .leading)
		// UI FIX: Padding before background makes the entire column cell highly responsive to mouse clicks
		.background(isCurrentCell ? Color(uiColor: .systemBackground) : Color.clear)
		.contentShape(Rectangle())
		.onTapGesture {
			focusedField = .row(id: point.id, column: col)
		}
	}
	
	private func syncFromModel() {
		pStr.x = String(format: "%g", point.x)
		pStr.y = String(format: "%g", point.y)
		pStr.w = String(format: "%g", point.weight)
	}
	
	private func commitChanges() {
		if let vx = Double(pStr.x), vx != point.x { point.x = vx }
		if let vy = Double(pStr.y), vy != point.y { point.y = vy }
		if let vw = Double(pStr.w), vw != point.weight { point.weight = vw }
	}
}

// MARK: - Ghost Row for New Entry

struct NewDataPointRow: View {
	@FocusState.Binding var focusedField: DataEditorView.Field?
	var onAdd: (DataPoint) -> Void
	
	@State private var xStr = ""
	@State private var yStr = ""
	
	var body: some View {
		HStack(spacing: 0) {
			// X Field
			NumericTextField("New X", numericText: $xStr, onCommit: { })
				.focused($focusedField, equals: .newRow(column: .x))
				.textFieldStyle(.plain)
				.padding(.horizontal, 8)
				.padding(.vertical, 6)
				.frame(maxWidth: .infinity, alignment: .leading) // UI FIX: Matching layouts prevent horizontal alignment shifting
				.background(focusedField == .newRow(column: .x) ? Color(uiColor: .systemBackground) : Color.clear)
				.contentShape(Rectangle())
				.onTapGesture { focusedField = .newRow(column: .x) }
			
			// Y Field
			NumericTextField("New Y", numericText: $yStr, onCommit: { })
				.focused($focusedField, equals: .newRow(column: .y))
				.textFieldStyle(.plain)
				.padding(.horizontal, 8)
				.padding(.vertical, 6)
				.frame(maxWidth: .infinity, alignment: .leading) // UI FIX: Matching layouts prevent horizontal alignment shifting
				.background(focusedField == .newRow(column: .y) ? Color(uiColor: .systemBackground) : Color.clear)
				.contentShape(Rectangle())
				.onTapGesture { focusedField = .newRow(column: .y) }
			
			Spacer().frame(width: 140)
		}
		.monospaced()
		.padding(.horizontal)
		.frame(height: 34)
		.background(Color.accentColor.opacity(0.05))
		.onChange(of: focusedField) { oldFocus, newFocus in
			guard case .newRow(_) = oldFocus else { return }
			if case .newRow(_)? = newFocus { return }
			
			if let x = Double(xStr), let y = Double(yStr) {
				onAdd(DataPoint(x: x, y: y))
				xStr = ""
				yStr = ""
			}
		}
		// ✅ FIX: Maps the Return key to advance from New X -> New Y -> Submit row on the input fields
		.onSubmit {
			if case .newRow(let col) = focusedField {
				if col == .x {
					handleXCommit()
				} else {
					handleYCommit()
				}
			}
		}
	}
	
	private func handleXCommit() {
		if xStr.isEmpty && yStr.isEmpty {
			focusedField = nil
		} else {
			focusedField = .newRow(column: .y)
		}
	}
	
	private func handleYCommit() {
		if let x = Double(xStr), let y = Double(yStr) {
			onAdd(DataPoint(x: x, y: y))
			xStr = ""
			yStr = ""
			focusedField = .newRow(column: .x)
		} else if xStr.isEmpty && yStr.isEmpty {
			focusedField = nil
		} else {
			focusedField = .newRow(column: .x)
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
					Button("Import") { completion(text) }
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
//import SwiftUI
//import XYPlot
//import NumericTextField
//import Utilities
//
//struct DataEditorView: View {
//	@Bindable var project: Project
//	@Binding var showImport: Bool
//	
//	@FocusState private var focusedField: Field?
//	@State private var autoSort = false
//	
//	enum Field: Hashable {
//		case row(id: UUID, column: Column)
//		case newRow(column: Column)
//		enum Column { case x, y, w }
//	}
//	
//	var body: some View {
//		VStack(spacing: 0) {
//			// MARK: - Toolbar
//			HStack {
//				Button { showImport = true } label: { Image(systemName: "doc.badge.plus") }
//				Button { pasteFromClipboard() } label: { Image(systemName: "clipboard") }
//				Spacer()
//				Toggle("Auto-Sort", isOn: $autoSort).font(.caption).fixedSize()
//				Button("Sort") { sortData() }.buttonStyle(.bordered).controlSize(.small)
//			}
//			.padding()
//			.background(.ultraThinMaterial)
//			
//			// MARK: - Spreadsheet Headers
//			HStack(spacing: 0) {
//				Text("X Value").frame(maxWidth: .infinity, alignment: .leading)
//				Text("Y Value").frame(maxWidth: .infinity, alignment: .leading)
//				Text("Weight").frame(width: 70, alignment: .leading)
//				Text("Out").frame(width: 40)
//				Spacer().frame(width: 30)
//			}
//			.font(.caption2.bold().monospaced())
//			.padding(.horizontal).padding(.vertical, 8)
//			.background(Color(.secondarySystemGroupedBackground))
//			
//			// MARK: - Data List
//			List {
//				ForEach($project.dataPoints) { $point in
//					DataPointRow(
//						point: $point,
//						focusedField: $focusedField,
//						onCommit: { col in
//							advanceFocus(from: point, col: col)
//						},
//						onDelete: {
//							project.dataPoints.removeAll(where: { $0.id == point.id })
//						}
//					)
//					.listRowInsets(EdgeInsets())
//					.listRowSeparator(.hidden)
//				}
//				
//				// Always-present row for new data
//				NewDataPointRow(focusedField: $focusedField) { newPoint in
//					project.dataPoints.append(newPoint)
//					if autoSort { sortData() }
//					focusedField = .newRow(column: .x)
//				}
//				.listRowInsets(EdgeInsets())
//				.listRowSeparator(.hidden)
//			}
//			.listStyle(.plain)
//			.scrollDismissesKeyboard(.never)
//		}
//	}
//	
//	// MARK: - Logic
//	
//	private func advanceFocus(from point: DataPoint, col: Field.Column) {
//		switch col {
//		case .x: focusedField = .row(id: point.id, column: .y)
//		case .y: focusedField = .row(id: point.id, column: .w)
//		case .w:
//			if let index = project.dataPoints.firstIndex(where: { $0.id == point.id }),
//			   index + 1 < project.dataPoints.count {
//				focusedField = .row(id: project.dataPoints[index+1].id, column: .x)
//			} else {
//				focusedField = .newRow(column: .x)
//			}
//			if autoSort { sortData() }
//		}
//	}
//	
//	private func sortData() {
//		withAnimation {
//			project.dataPoints.sort { $0.x < $1.x }
//		}
//	}
//	
//	private func pasteFromClipboard() {
//#if os(iOS)
//		let clipboardText = UIPasteboard.general.string
//#elseif os(macOS)
//		let clipboardText = NSPasteboard.general.string(forType: .string)
//#endif
//		
//		guard let text = clipboardText else { return }
//		if let points = try? DataImporter.parse(text: text) {
//			project.dataPoints.append(contentsOf: points)
//			if autoSort { sortData() }
//		}
//	}
//}
//
//// MARK: - Row with Local String Buffer
//
//struct DataPointRow: View {
//	@Binding var point: DataPoint
//	@FocusState.Binding var focusedField: DataEditorView.Field?
//	var onCommit: (DataEditorView.Field.Column) -> Void
//	var onDelete: () -> Void
//	
//	struct PointStrings : Equatable {
//		var x: String = ""
//		var y: String = ""
//		var w: String = ""
//	}
//	
//	@State private var pStr = PointStrings()
//	@State private var isHovered = false // Desktop hover enhancement
//	
//	var body: some View {
//		HStack(spacing: 0) {
//			cell(text: $pStr.x, col: .x)
//			cell(text: $pStr.y, col: .y)
//			cell(text: $pStr.w, col: .w, width: 70)
//			
//			Toggle("", isOn: $point.isOutlier)
//				.labelsHidden()
//				.frame(width: 40)
//			
//			Button(action: onDelete) {
//				Image(systemName: "minus.circle.fill").foregroundStyle(.red)
//			}
//			.frame(width: 30)
//			.buttonStyle(.plain)
//		}
//		.padding(.horizontal)
//		.frame(height: 34)
//		// Combined focused and hover backdrop responses
//		.background(isFocused ? Color.accentColor.opacity(0.12) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
//		.onHover { hovering in isHovered = hovering }
//		.onAppear { syncFromModel() }
//		.onChange(of: point) { syncFromModel() }
//	}
//	
//	private var isFocused: Bool {
//		if case .row(let id, _) = focusedField { return id == point.id }
//		return false
//	}
//	
//	private func cell(text: Binding<String>, col: DataEditorView.Field.Column, width: CGFloat? = nil) -> some View {
//		let isCurrentCell = focusedField == .row(id: point.id, column: col)
//		
//		return NumericTextField("", numericText: text,
//								onEditingChanged: { editing in if !editing { commitChanges() } },
//								onCommit: {
//			commitChanges()
//			if pStr.x.isEmpty && pStr.y.isEmpty {
//				focusedField = nil
//			} else {
//				onCommit(col)
//			}
//		})
//		.focused($focusedField, equals: .row(id: point.id, column: col))
//		.textFieldStyle(.plain)
//		.monospaced()
//		.padding(.horizontal, 8)
//		.padding(.vertical, 6)
//		.frame(maxWidth: width ?? .infinity, alignment: .leading)
//		// Background attached to the layout frame to ensure full cell click target
//		.background(isCurrentCell ? Color(uiColor: .systemBackground) : Color.clear)
//		.contentShape(Rectangle())
//		.onTapGesture {
//			focusedField = .row(id: point.id, column: col)
//		}
//	}
//	
//	private func syncFromModel() {
//		pStr.x = String(format: "%g", point.x)
//		pStr.y = String(format: "%g", point.y)
//		pStr.w = String(format: "%g", point.weight)
//	}
//	
//	private func commitChanges() {
//		if let vx = Double(pStr.x), vx != point.x { point.x = vx }
//		if let vy = Double(pStr.y), vy != point.y { point.y = vy }
//		if let vw = Double(pStr.w), vw != point.weight { point.weight = vw }
//	}
//}
//
//// MARK: - Ghost Row for New Entry
//
//struct NewDataPointRow: View {
//	@FocusState.Binding var focusedField: DataEditorView.Field?
//	var onAdd: (DataPoint) -> Void
//	
//	@State private var xStr = ""
//	@State private var yStr = ""
//	@State private var isHovered = false
//	
//	var body: some View {
//		HStack(spacing: 0) {
//			// X Field
//			NumericTextField("New X", numericText: $xStr, onCommit: {
//				handleXCommit()
//			})
//			.focused($focusedField, equals: .newRow(column: .x))
//			.textFieldStyle(.plain)
//			.padding(.horizontal, 8)
//			.padding(.vertical, 6)
//			.frame(maxWidth: .infinity, alignment: .leading) // Aligns with upper infinite rows
//			.background(focusedField == .newRow(column: .x) ? Color(uiColor: .systemBackground) : Color.clear)
//			.contentShape(Rectangle())
//			.onTapGesture { focusedField = .newRow(column: .x) }
//			
//			// Y Field
//			NumericTextField("New Y", numericText: $yStr, onCommit: {
//				handleYCommit()
//			})
//			.focused($focusedField, equals: .newRow(column: .y))
//			.textFieldStyle(.plain)
//			.padding(.horizontal, 8)
//			.padding(.vertical, 6)
//			.frame(maxWidth: .infinity, alignment: .leading) // Aligns with upper infinite rows
//			.background(focusedField == .newRow(column: .y) ? Color(uiColor: .systemBackground) : Color.clear)
//			.contentShape(Rectangle())
//			.onTapGesture { focusedField = .newRow(column: .y) }
//			
//			// Accounts perfectly for Weight (70) + Outlier (40) + Button (30)
//			Spacer().frame(width: 140)
//		}
//		.monospaced()
//		.padding(.horizontal)
//		.frame(height: 34)
//		.background(focusedField == .newRow(column: .x) || focusedField == .newRow(column: .y) ? Color.accentColor.opacity(0.08) : (isHovered ? Color.primary.opacity(0.02) : Color.accentColor.opacity(0.03)))
//		.onHover { hovering in isHovered = hovering }
//		.onChange(of: focusedField) { oldFocus, newFocus in
//			guard case .newRow(_) = oldFocus else { return }
//			if case .newRow(_)? = newFocus { return }
//			
//			if let x = Double(xStr), let y = Double(yStr) {
//				onAdd(DataPoint(x: x, y: y))
//				xStr = ""
//				yStr = ""
//			}
//		}
//	}
//	
//	private func handleXCommit() {
//		if xStr.isEmpty && yStr.isEmpty {
//			focusedField = nil
//		} else {
//			focusedField = .newRow(column: .y)
//		}
//	}
//	
//	private func handleYCommit() {
//		if let x = Double(xStr), let y = Double(yStr) {
//			onAdd(DataPoint(x: x, y: y))
//			xStr = ""
//			yStr = ""
//			focusedField = .newRow(column: .x)
//		} else if xStr.isEmpty && yStr.isEmpty {
//			focusedField = nil
//		} else {
//			focusedField = .newRow(column: .x)
//		}
//	}
//}
//
//// MARK: - Import Sheet
//
//struct ImportSheet: View {
//	let completion: (String) -> Void
//	@State private var text = ""
//	@State private var showFilePicker = false
//	@Environment(\.dismiss) private var dismiss
//	
//	var body: some View {
//		NavigationStack {
//			VStack(alignment: .leading, spacing: 12) {
//				Text("Paste CSV, TSV, or space-delimited data below.\nFirst two columns are X and Y. Optional third column is weight.")
//					.font(.footnote)
//					.foregroundStyle(.secondary)
//					.padding(.horizontal)
//				TextEditor(text: $text)
//					.font(.system(.body, design: .monospaced))
//					.frame(maxWidth: .infinity, maxHeight: .infinity)
//					.padding(.horizontal)
//				Button {
//					showFilePicker = true
//				} label: {
//					Label("Import from Files…", systemImage: "folder")
//						.frame(maxWidth: .infinity)
//				}
//				.buttonStyle(.bordered)
//				.padding(.horizontal)
//			}
//			.padding(.top)
//			.navigationTitle("Import Data")
//			.navigationBarTitleDisplayMode(.inline)
//			.toolbar {
//				ToolbarItem(placement: .topBarLeading) {
//					Button("Cancel") { dismiss() }
//				}
//				ToolbarItem(placement: .topBarTrailing) {
//					Button("Import") { completion(text) }
//						.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
//						.bold()
//						.keyboardShortcut(.return, modifiers: []) // Desktop confirmation enhancement
//				}
//			}
//			.sheet(isPresented: $showFilePicker) {
//				DocumentPickerView { fileText in
//					text = fileText
//					showFilePicker = false
//				}
//			}
//		}
//	}
//}
