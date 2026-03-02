import SwiftUI
import Charts
import XYPlot
import NumericTextField
import Utilities

struct DataEditorView: View {
    @Bindable var project: Project
    @Binding var showImport: Bool

    // Which row+field has focus: (rowIndex, field)
    enum RowField { case x, y, w }
    @FocusState private var focus: Int?          // row index; nil = none
    @State private var focusField: RowField = .x // which field within the focused row

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
                            if let text = UIPasteboard.general.string,
                               let points = try? DataImporter.parse(text: text) {
                                project.dataPoints = points
                            }
                        } label: {
                            Label("Paste", systemImage: "clipboard")
						}
						Spacer()
						Button {
							var pts = project.dataPoints
							pts.sort { $0.x < $1.x }
							project.dataPoints = pts
						} label: {
							Label( "Sort", systemImage: "arrow.down")
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

                    ForEach(Array(project.dataPoints.enumerated()), id: \.offset) { index, point in
                        DataPointRow(
                            project: project,
                            point: point,
                            index: index,
                            focus: $focus,
                            focusField: $focusField,
                            onNext: { advanceFocus(from: index) },
                            onLoseFocus: { sortData() }
                        )
                        .id("row-\(index)")
                    }
                    .onDelete { offsets in
                        var pts = project.dataPoints
                        pts.remove(atOffsets: offsets)
                        project.dataPoints = pts
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: focus) { _, newRow in
                guard let row = newRow else { return }
                withAnimation { proxy.scrollTo("row-\(row)", anchor: .center) }
            }
        }
    }

    private func addRow() {
        var pts = project.dataPoints
        // Insert at the beginning instead of appending
        pts.insert(DataPoint(x: 0, y: 0), at: 0)
        project.dataPoints = pts
        
        focusField = .x
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focus = 0  // Focus on the new first row
        }
    }

    /// Sort data points by X value
    private func sortData() {
        var pts = project.dataPoints
        pts.sort { $0.x < $1.x }
        project.dataPoints = pts
    }

    /// Move focus to next field, then next row, then dismiss
    private func advanceFocus(from index: Int) {
        switch focusField {
        case .x:
            focusField = .y
            focus = index
        case .y:
            focusField = .w
            focus = index
        case .w:
            // Last field of this row — move to x of next row
            let nextIndex = index + 1
            if nextIndex < project.dataPoints.count {
                focusField = .x
                focus = nextIndex
            } else {
                // When we reach the last field, sort the data
                focus = nil
                sortData()
            }
        }
    }
}

// MARK: - Data Point Row

struct DataPointRow: View {
    @Bindable var project: Project
    let point: DataPoint
    let index: Int
    var focus: FocusState<Int?>.Binding
    @Binding var focusField: DataEditorView.RowField
    let onNext: () -> Void
    let onLoseFocus: () -> Void

    @State private var xStr: String = ""
    @State private var yStr: String = ""
    @State private var wStr: String = ""

    private var isRowFocused: Bool { focus.wrappedValue == index }

    private func commit() {
        var pts = project.dataPoints
        guard index < pts.count else { return }
        if let v = Double(xStr), v.isFinite { pts[index].x = v }
        if let v = Double(yStr), v.isFinite { pts[index].y = v }
        if let v = Double(wStr), v.isFinite, v > 0 { pts[index].weight = v }
        project.dataPoints = pts
    }

    // Pre-compute opacities to avoid complex inline expressions
    private func opacity(for field: DataEditorView.RowField, str: String) -> Double {
        if isRowFocused && focusField == field { return 1.0 }
        return str.isEmpty ? 0.4 : 1.0
    }

    private var positiveStyle: NumericStringStyle {
        NumericStringStyle(decimalSeparator: true, negatives: false, exponent: true)
    }

    var body: some View {
        HStack {
            NumericTextField("x", numericText: $xStr,
                             onEditingChanged: { editing in if !editing { commit() } },
                             onNext: { commit(); focusField = .y; focus.wrappedValue = index })
                .opacity(opacity(for: .x, str: xStr))
                .frame(maxWidth: .infinity)

            NumericTextField("y", numericText: $yStr,
                             onEditingChanged: { editing in if !editing { commit() } },
                             onNext: { commit(); focusField = .w; focus.wrappedValue = index })
                .opacity(opacity(for: .y, str: yStr))
                .frame(maxWidth: .infinity)

            NumericTextField("w", numericText: $wStr,
                             style: positiveStyle,
                             onEditingChanged: { editing in if !editing { commit() } },
                             onCommit: { commit(); onNext() })
                .opacity(opacity(for: .w, str: wStr))
                .frame(width: 70)

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
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(point.isOutlier ? .secondary : .primary)
		.onAppear {
			xStr = point.x.isNaN ? "" : String(format: "%g", point.x)
			yStr = point.y.isNaN ? "" : String(format: "%g", point.y)
			wStr = String(format: "%g", point.weight)
		}
        .onChange(of: focus.wrappedValue) { oldRow, newRow in
            // When leaving this row, trigger the sort
            if oldRow == index && newRow != index { 
                onLoseFocus()
            }
        }
        .onChange(of: point.x)      { _, v in xStr = String(format: "%g", v) }
        .onChange(of: point.y)      { _, v in yStr = String(format: "%g", v) }
        .onChange(of: point.weight) { _, v in wStr = String(format: "%g", v) }
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
