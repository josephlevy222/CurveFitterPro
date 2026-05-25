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
				}
				
				// Always-present row for new data
				NewDataPointRow(focusedField: $focusedField) { newPoint in
					project.dataPoints.append(newPoint)
					if autoSort { sortData() }
					focusedField = .newRow(column: .x)
				}
				.listRowInsets(EdgeInsets())
				.listRowSeparator(.hidden)
			}//}
			.listStyle(.plain) // Cleaner "Excel" look than insetGrouped
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
		// Cross-platform pasteboard support
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
	
	@State private var pStr = PointStrings()
	
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
		.onAppear { syncFromModel() }
		// This will run when you paste data or auto-sort!
		.onChange(of: point) { syncFromModel() }
	}
	
	private var isFocused: Bool {
		if case .row(let id, _) = focusedField { return id == point.id }
		return false
	}
	
	private func cell(text: Binding<String>, col: DataEditorView.Field.Column, width: CGFloat? = nil) -> some View {
		NumericTextField("", numericText: text,
						 onEditingChanged: { editing in if !editing { commitChanges() } },
						 onCommit: {
							commitChanges()
							if pStr.x.isEmpty && pStr.y.isEmpty {
								focusedField = nil
								} else {
									onCommit(col)
								}
							})
		.focused($focusedField, equals: .row(id: point.id, column: col))
		.textFieldStyle(.plain)
		.monospaced()
		.background(focusedField == .row(id: point.id, column: col) ? Color(uiColor: .systemBackground) : Color.clear)
		.padding(8)
		.frame(maxWidth: width ?? .infinity)
	}
	
	private func syncFromModel() {
		pStr.x = String(format: "%g", point.x)
		pStr.y = String(format: "%g", point.y)
		pStr.w = String(format: "%g", point.weight)
	}
	
	private func commitChanges() {
		// Mutate the binding directly. This updates the model without destroying the view.
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
			NumericTextField("New X", numericText: $xStr, onCommit: {
				if xStr.isEmpty && yStr.isEmpty {
					focusedField = nil // Dismiss on empty
				} else {
					focusedField = .newRow(column: .y) // Move to Y
				}
			})
			.focused($focusedField, equals: .newRow(column: .x))
			.contentShape(Rectangle())
			.onTapGesture { focusedField = .newRow(column: .x) }
			
			// Y Field
			NumericTextField("New Y", numericText: $yStr, onCommit: {
				if let x = Double(xStr), let y = Double(yStr) {
					onAdd(DataPoint(x: x, y: y))
					xStr = ""
					yStr = ""
					// Stay in "Excel mode" - return to X of the next empty row
					focusedField = .newRow(column: .x)
				} else if xStr.isEmpty && yStr.isEmpty {
					focusedField = nil // Dismiss on empty
				} else {
					focusedField = .newRow(column: .x)
				}
			})
			.focused($focusedField, equals: .newRow(column: .y))
			.contentShape(Rectangle())
			.onTapGesture { focusedField = .newRow(column: .y) }
			
			Spacer().frame(width: 140)
		}
		.monospaced()
		.padding(.horizontal)
		.frame(height: 34)
		.background(Color.accentColor.opacity(0.05))
		// Save a complete entry when the user moves focus away from the ghost row entirely
		.onChange(of: focusedField) { oldFocus, newFocus in
			guard case .newRow(_) = oldFocus else { return }  // we were in this row
			if case .newRow(_)? = newFocus { return }         // still in this row, wait
			// Focus left the ghost row — commit if both fields are valid
			if let x = Double(xStr), let y = Double(yStr) {
				onAdd(DataPoint(x: x, y: y))
				xStr = ""
				yStr = ""
			}
		}
	}
	
	private func handleXCommit() {
		if xStr.isEmpty && yStr.isEmpty {
			// Line is empty: Dismiss keyboard
			focusedField = nil
		} else {
			// Entry exists: Move to Y field, keep keyboard
			focusedField = .newRow(column: .y)
		}
	}
	
	private func handleYCommit() {
		if let x = Double(xStr), let y = Double(yStr) {
			// Data exists: Add the point
			onAdd(DataPoint(x: x, y: y))
			
			// Clear local buffers for the next entry
			xStr = ""
			yStr = ""
			
			// Keep keyboard showing and return to X of the "new" ghost row
			focusedField = .newRow(column: .x)
		} else if xStr.isEmpty && yStr.isEmpty {
			// Both empty: Dismiss
			focusedField = nil
		} else {
			// Partial data or invalid: Just stay here or move back to X
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
