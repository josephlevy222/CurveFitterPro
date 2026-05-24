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
				ForEach(project.dataPoints) { point in
					DataPointRow(
						point: point,
						focusedField: $focusedField,
						onUpdate: { updatedPoint in
							updatePoint(updatedPoint)
						},
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
			}
			.listStyle(.plain) // Cleaner "Excel" look than insetGrouped
		}
	
	}
	
	// MARK: - Logic
	
	private func updatePoint(_ updatedPoint: DataPoint) {
		if let index = project.dataPoints.firstIndex(where: { $0.id == updatedPoint.id }) {
			project.dataPoints[index] = updatedPoint
		}
	}
	
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
	let point: DataPoint
	@FocusState.Binding var focusedField: DataEditorView.Field?
	var onUpdate: (DataPoint) -> Void
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
			
			Toggle("", isOn: Binding(
				get: { point.isOutlier },
				set: { val in
					var p = point
					p.isOutlier = val
					onUpdate(p)
				}
			)).labelsHidden().frame(width: 40)
			
			Button(action: onDelete) {
				Image(systemName: "minus.circle.fill").foregroundStyle(.red)
			}
			.frame(width: 30)
		}
		.padding(.horizontal)
		.frame(height: 34)
		// Ensure the whole row doesn't trigger List selection focus loss
		.listRowBackground(isFocused ? Color.accentColor.opacity(0.1) : Color.clear)
		.onAppear { syncFromModel() }
		.onChange(of: point) { print("Never runs"); syncFromModel() }
	}
	
	private var isFocused: Bool {
		if case .row(let id, _) = focusedField { return id == point.id }
		return false
	}
	
	private func cell(text: Binding<String>, col: DataEditorView.Field.Column, width: CGFloat? = nil) -> some View {
		NumericTextField("", numericText: text ,onCommit: {
			commitChanges()
			
			// LOGIC: Dismiss if empty, otherwise advance
			if pStr.x.isEmpty && pStr.y.isEmpty {
				focusedField = nil
			} else {
				// Moving the focus immediately prevents the "flicker"
				onCommit(col)
			}
		})
		.focused($focusedField, equals: .row(id: point.id, column: col))
		.textFieldStyle(.plain)
		.monospaced()
		.padding(4)
		.background( focusedField == .row(id: point.id, column: col) ? Color(uiColor: .systemBackground) : Color.clear)
		.frame(maxWidth: width ?? .infinity)
		// Direct tap gesture ensures focus shifts before List can intercept
		.contentShape(Rectangle())
		.onTapGesture {
			focusedField = .row(id: point.id, column: col)
		}
		.onSubmit { commitChanges() }
	}
	
	private func syncFromModel() { print("syncing", terminator: " ")
		pStr.x = String(format: "%g", point.x)
		pStr.y = String(format: "%g", point.y)
		pStr.w = String(format: "%g", point.weight)
	}
	
	private var updatedPoint: DataPoint {
		var p = point
		if let vx = Double(pStr.x) { p.x = vx }
		if let vy = Double(pStr.y) { p.y = vy }
		if let vw = Double(pStr.w) { p.weight = vw }
		return p
	}

	private func commitChanges() {
		onUpdate(updatedPoint)
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

#if false
struct NewDataPointRow: View {
	@FocusState.Binding var focusedField: DataEditorView.Field?
	var onAdd: (DataPoint) -> Void
	
	@State private var xStr = ""
	@State private var yStr = ""
	
	var body: some View {
		HStack(spacing: 0) {
			NumericTextField("New X", numericText: $xStr, onCommit: {
				focusedField = .newRow(column: .y)
			})
			.focused($focusedField, equals: .newRow(column: .x))
			
			NumericTextField("New Y", numericText: $yStr, onCommit: {
				if let x = Double(xStr), let y = Double(yStr) {
					onAdd(DataPoint(x: x, y: y))
					xStr = ""; yStr = ""
				}
			})
			.focused($focusedField, equals: .newRow(column: .y))
			
			Spacer().frame(width: 140)
		}
		.monospaced()
		.padding(.horizontal)
		.frame(height: 34)
		.background(Color.accentColor.opacity(0.05))
	}
}


import SwiftUI
import XYPlot
import NumericTextField

struct DataEditorView: View {
	@Bindable var project: Project
	@Binding var showImport: Bool
	
	@FocusState private var focusedField: Field?
	@State private var autoSort = false
	@State private var showPasteError = false
	@State private var pasteError: String?
	
	enum Field: Hashable {
		case row(id: UUID, column: Column)
		case newRow(column: Column)
		
		enum Column { case x, y, w }
	}
	
	var body: some View {
		VStack(spacing: 0) {
			// MARK: - Toolbar
			headerToolbar
			
			// MARK: - Spreadsheet Header
			columnHeaderLabels
			
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(spacing: 0) {
						// Data Rows
						ForEach($project.dataPoints) { $point in
							DataPointRow(
								point: $point,
								focusedField: $focusedField,
								onCommit: { advanceFocus(from: point, col: $0) },
								onDelete: { deletePoint(point) }
							)
							.id(point.id)
							Divider()
						}
						
						// The "Ghost" Row for quick manual entry
						NewDataPointRow(
							focusedField: $focusedField,
							onAdd: { newPoint in
								project.dataPoints.append(newPoint)
								if autoSort { sortData() }
								// Focus the X field of the next ghost row
								focusedField = .newRow(column: .x)
								proxy.scrollTo(newPoint.id, anchor: .bottom)
							}
						)
					}
				}
			}
		}
		.background(Color(.systemGroupedBackground))
		.alert("Paste Error", isPresented: $showPasteError) {
			Button("OK", role: .cancel) {}
		} message: { Text(pasteError ?? "") }
	}
	
	// MARK: - Helper Views
	
	private var headerToolbar: some View {
		HStack {
			Button { showImport = true } label: { Image(systemName: "doc.badge.plus") }
			Button { pasteFromClipboard() } label: { Image(systemName: "clipboard") }
			
			Spacer()
			
			Toggle("Auto-Sort", isOn: $autoSort)
				.font(.caption)
				.fixedSize()
			
			Button("Sort Now") { sortData() }
				.buttonStyle(.bordered)
				.controlSize(.small)
		}
		.padding()
		.background(.ultraThinMaterial)
	}
	
	private var columnHeaderLabels: some View {
		HStack(spacing: 0) {
			Text("X Value").frame(maxWidth: .infinity, alignment: .leading)
			Text("Y Value").frame(maxWidth: .infinity, alignment: .leading)
			Text("Weight").frame(width: 70, alignment: .leading)
			Text("Out").frame(width: 40)
			Spacer().frame(width: 30) // Delete button spacer
		}
		.font(.caption2.bold())
		.foregroundStyle(.secondary)
		.padding(.horizontal)
		.padding(.vertical, 8)
		.background(Color(.secondarySystemGroupedBackground))
	}
	
	// MARK: - Logic
	
	private func advanceFocus(from point: DataPoint, col: Field.Column) {
		switch col {
		case .x: focusedField = .row(id: point.id, column: .y)
		case .y: focusedField = .row(id: point.id, column: .w)
		case .w:
			// Find next row
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
	
	private func deletePoint(_ point: DataPoint) {
		project.dataPoints.removeAll(where: { $0.id == point.id })
	}
	
	private func pasteFromClipboard() {
		guard let text = UIPasteboard.general.string else { return }
		do {
			let points = try DataImporter.parse(text: text)
			project.dataPoints.append(contentsOf: points)
			if autoSort { sortData() }
		} catch {
			pasteError = error.localizedDescription
			showPasteError = true
		}
	}
}

// MARK: - Specialized Row Component
func stringBinding(_ x: Binding<Double>) -> Binding<String> {
	Binding(get: {String(x.wrappedValue)}, set: { xString in x.wrappedValue = Double(xString) ?? 0.0 })
}
struct DataPointRow: View {
	@Binding var point: DataPoint
	@FocusState.Binding var focusedField: DataEditorView.Field?
	var onCommit: (DataEditorView.Field.Column) -> Void
	var onDelete: () -> Void
	
	var body: some View {
		HStack(spacing: 0) {
			numericCell(value: $point.x, col: .x)
			numericCell(value: $point.y, col: .y)
			numericCell(value: $point.weight, col: .w, width: 70)
			
			Toggle("", isOn: $point.isOutlier)
				.labelsHidden()
				.frame(width: 40)
			
			Button(action: onDelete) {
				Image(systemName: "minus.circle.fill").foregroundStyle(.red)
			}
			.frame(width: 30)
		}
		.padding(.horizontal)
		.frame(height: 44)
		.background(isFocused ? Color.accentColor.opacity(0.1) : Color(.secondarySystemGroupedBackground))
	}
	
	private var isFocused: Bool {
		if case .row(let id, _) = focusedField { return id == point.id }
		return false
	}
	
	@ViewBuilder
	private func numericCell(value: Binding<Double>, col: DataEditorView.Field.Column, width: CGFloat? = nil) -> some View {
		// We use a local string proxy to prevent the "disappearing text" issue while typing
		NumericTextField("", numericText: stringBinding(value))//  reformatter: NumberFormatter.plain)
			.focused($focusedField, equals: .row(id: point.id, column: col))
			.onSubmit { onCommit(col) }
			.textFieldStyle(.plain)
			.padding(4)
			.background(focusedField == .row(id: point.id, column: col) ? Color.white : Color.clear)
			.cornerRadius(4)
			.frame(maxWidth: width == nil ? .infinity : width!)
	}
}

// MARK: - New Point "Ghost" Row

struct NewDataPointRow: View {
	@FocusState.Binding var focusedField: DataEditorView.Field?
	var onAdd: (DataPoint) -> Void
	
	@State private var x: Double?
	@State private var y: Double?
	
	var body: some View {
		HStack(spacing: 0) {
			TextField("New X", value: $x, format: .number)
				.focused($focusedField, equals: .newRow(column: .x))
			TextField("New Y", value: $y, format: .number)
				.focused($focusedField, equals: .newRow(column: .y))
				.onSubmit {
					if let xVal = x, let yVal = y {
						onAdd(DataPoint(x: xVal, y: yVal))
						x = nil; y = nil
					}
				}
			Spacer().frame(width: 140)
		}
		.padding(.horizontal)
		.frame(height: 44)
		.background(Color(.secondarySystemGroupedBackground).opacity(0.5))
		.italic()
	}
}

// MARK: - Formatter Helper
extension NumberFormatter {
	static var plain: NumberFormatter {
		let f = NumberFormatter()
		f.numberStyle = .decimal
		f.maximumFractionDigits = 8
		return f
	}
}


import SwiftUI
import Charts
import XYPlot
import NumericTextField
import Utilities

// MARK: - DataEditorView with Improved Focus Management

struct DataEditorView: View {
    @Bindable var project: Project
    @Binding var showImport: Bool
    
    // MARK: - Configuration
    
    /// Delay before auto-sorting after editing stops
    /// Set to 0 for immediate sorting, or increase for more delay
    private let autoSortDelay: Duration = .seconds(1.5)

    // Focus tracking with FocusState for proper SwiftUI focus management
    enum Field: Hashable {
        case row(id: UUID, column: Column)
        
        enum Column {
            case x, y, w
        }
    }
    
    @FocusState private var focusedField: Field?
    
    // Track if we're in the middle of editing to prevent sort interruptions
    @State private var isEditing = false
    @State private var pendingSort = false
    @State private var sortTask: Task<Void, Never>? = nil
    @State private var pasteError: String? = nil
    @State private var showPasteError = false

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
                            guard let text = UIPasteboard.general.string,
                                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                pasteError = "No text found on the clipboard."
                                showPasteError = true
                                return
                            }
                            do {
                                let points = try DataImporter.parse(text: text)
                                project.dataPoints = points
                                focusedField = nil
                            } catch {
                                pasteError = error.localizedDescription
                                showPasteError = true
                            }
                        } label: {
                            Label("Paste", systemImage: "clipboard")
                        }
                        Spacer()
                        Button {
                            sortData()
                        } label: {
                            Label("Sort", systemImage: "arrow.down")
                        }
                        Spacer()
                        Button {
                            addRow()
                        } label: {
                            Label("Add", systemImage: "plus.circle")
                        }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Import Data")
                } footer: {
                    Text(DataImporter.summary(project.dataPoints))
                        .font(.caption)
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

                    ForEach(Array(project.dataPoints.enumerated()), id: \.element.id) { index, point in
                        DataPointRow(
                            project: project,
                            point: point,
                            index: index,
                            focusedField: $focusedField,
                            isEditing: $isEditing,
                            onEditComplete: { scheduleSort() }
                        )
                        .id(point.id)
                    }
                    .onDelete { offsets in
                        var pts = project.dataPoints
                        pts.remove(atOffsets: offsets)
                        project.dataPoints = pts
                        focusedField = nil
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .onDisappear {
                // Clean up pending sort task
                sortTask?.cancel()
                sortTask = nil
            }
            .alert("Paste Error", isPresented: $showPasteError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(pasteError ?? "Unknown error")
            }
            .onChange(of: focusedField) { oldValue, newValue in
                // Handle focus changes
                if let field = newValue, case .row(let id, _) = field {
                    // User started editing again - cancel pending sort
                    if pendingSort {
                        sortTask?.cancel()
                        sortTask = nil
                    }
                    
                    // Scroll to focused row with a slight delay to ensure layout is complete
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
                
                // If we lost focus completely (no field selected), execute pending sort
                if oldValue != nil && newValue == nil && pendingSort {
                    // Give a brief moment in case user is just switching to another row
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if focusedField == nil {
                            executePendingSort()
                        }
                    }
                }
            }
        }
    }

    private func addRow() {
        var pts = project.dataPoints
        let newPoint = DataPoint(x: 0, y: 0)
        pts.insert(newPoint, at: 0)
        project.dataPoints = pts
        
        // Set focus to new row's X field after the view updates
        DispatchQueue.main.asyncAfter(deadline: .now() /*+ 0.15*/) {
            focusedField = .row(id: newPoint.id, column: .x)
        }
    }

    private func sortData() {
        // If currently editing, schedule the sort for later
        if isEditing {
            pendingSort = true
            focusedField = nil // This will trigger the sort in onChange
        } else {
            performSort()
        }
    }
    
    private func scheduleSort() {
        // Called when user finishes editing a field
        // Only sort if data is out of order
        guard needsSorting() else { return }
        
        pendingSort = true
        
        // Cancel any existing sort task
        sortTask?.cancel()
        
        // Schedule sort with delay - if user starts editing again within
        // this window, the sort will be cancelled
        sortTask = Task { @MainActor in
            // Wait for configured delay before sorting
            try? await Task.sleep(for: autoSortDelay)
            
            guard !Task.isCancelled else { return }
            
            // Only sort if still not editing and sort is still pending
            if !isEditing && pendingSort {
                executePendingSort()
            }
        }
    }
    
    private func needsSorting() -> Bool {
        let points = project.dataPoints
        for i in 0..<(points.count - 1) {
            if points[i].x > points[i + 1].x {
                return true
            }
        }
        return false
    }
    
    private func executePendingSort() {
        guard pendingSort else { return }
        pendingSort = false
        sortTask?.cancel()
        sortTask = nil
        performSort()
    }

    private func performSort() {
        var pts = project.dataPoints
        pts.sort { $0.x < $1.x }
        project.dataPoints = pts
    }
}

// MARK: - Data Point Row with Improved Focus

struct DataPointRow: View {
    @Bindable var project: Project
    let point: DataPoint
    let index: Int
    @FocusState.Binding var focusedField: DataEditorView.Field?
    @Binding var isEditing: Bool
    let onEditComplete: () -> Void
    
    @State private var xStr: String = ""
    @State private var yStr: String = ""
    @State private var wStr: String = ""
    
    private var positiveStyle: NumericStringStyle {
        NumericStringStyle(decimalSeparator: true, negatives: false, exponent: true)
    }
    
    private func commit() {
        var pts = project.dataPoints
        guard index < pts.count else { return }
        
        var changed = false
        if let v = Double(xStr), v.isFinite, v != pts[index].x {
            pts[index].x = v
            changed = true
        }
        if let v = Double(yStr), v.isFinite, v != pts[index].y {
            pts[index].y = v
            changed = true
        }
        if let v = Double(wStr), v.isFinite, v > 0, v != pts[index].weight {
            pts[index].weight = v
            changed = true
        }
        
        if changed {
            project.dataPoints = pts
        }
    }
    
    // Computed property to check if this row has focus
    private var hasFocus: Bool {
        if case .row(let id, _) = focusedField, id == point.id {
            return true
        }
        return false
    }
    
    private var xField: some View {
        NumericTextField("x", numericText: $xStr,
                         onEditingChanged: { editing in
            isEditing = editing
            if !editing { 
                commit()
                onEditComplete()
            }
        },
                         onCommit: {
            commit()
            // Move to Y field after Done is pressed
            focusedField = .row(id: point.id, column: .y)
        })
        .focused($focusedField, equals: .row(id: point.id, column: .x))
        .frame(maxWidth: .infinity)
    }
    
    private var yField: some View {
        NumericTextField("y", numericText: $yStr,
                         onEditingChanged: { editing in
            isEditing = editing
            if !editing {
                commit()
                onEditComplete()
            }
        },
                         onCommit: {
            commit()
            // Move to Weight field after Done is pressed
            focusedField = .row(id: point.id, column: .w)
        })
        .focused($focusedField, equals: .row(id: point.id, column: .y))
        .frame(maxWidth: .infinity)
    }
    
    private var wField: some View {
        NumericTextField("w", numericText: $wStr,
                         style: positiveStyle,
                         onEditingChanged: { editing in
            isEditing = editing
            if !editing {
                commit()
                onEditComplete()
            }
        },
                         onCommit: {
            commit()
            onEditComplete()
            // Done button on Weight field dismisses keyboard
            focusedField = nil
        })
        .focused($focusedField, equals: .row(id: point.id, column: .w))
        .frame(width: 70)
    }
    
    private var outlierToggle: some View {
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
    
    var body: some View {
        HStack {
            xField
            yField
            wField
            outlierToggle
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(point.isOutlier ? .secondary : .primary)
        .background(hasFocus ? Color.accentColor.opacity(0.08) : Color.clear)
        .onAppear {
            updateStrings()
        }
        .onChange(of: point.x) { _, _ in
            // Only update if we're not currently editing this field
            if case .row(let id, let col) = focusedField, 
               id == point.id, col == .x {
                return
            }
            updateStrings()
        }
        .onChange(of: point.y) { _, _ in
            if case .row(let id, let col) = focusedField,
               id == point.id, col == .y {
                return
            }
            updateStrings()
        }
        .onChange(of: point.weight) { _, _ in
            if case .row(let id, let col) = focusedField,
               id == point.id, col == .w {
                return
            }
            updateStrings()
        }
    }
    
    private func updateStrings() {
        xStr = point.x.isNaN ? "" : String(format: "%g", point.x)
        yStr = point.y.isNaN ? "" : String(format: "%g", point.y)
        wStr = String(format: "%g", point.weight)
    }
}
#endif
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

