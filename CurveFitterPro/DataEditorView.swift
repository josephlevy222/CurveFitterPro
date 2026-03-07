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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
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
