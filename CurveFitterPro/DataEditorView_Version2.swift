import SwiftUI
import Charts
import XYPlot
import NumericTextField
import Utilities

struct DataEditorView: View {
    @Bindable var project: Project
    @Binding var showImport: Bool

    // Focus tracking: which row id and which field is focused
    struct FocusKey: Equatable {
        let id: UUID
        let field: RowField
    }
    enum RowField { case x, y, w }
    @State private var focusKey: FocusKey? = nil

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
                            focusKey: $focusKey,
                            onSort: { sortAfterEdit(editedId: point.id, field: focusKey?.field ?? .x) }
                        )
                        .id(point.id)
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
            .onChange(of: focusKey) { _, newFocus in
                if let fk = newFocus {
                    withAnimation { proxy.scrollTo(fk.id, anchor: .center) }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            focusKey = FocusKey(id: newPoint.id, field: .x)
        }
    }

    private func sortData() {
        var pts = project.dataPoints
        pts.sort { $0.x < $1.x }
        project.dataPoints = pts
    }

    private func sortAfterEdit(editedId: UUID, field: RowField) {
        // Sort and restore focus to the just-edited row and field (if it still exists)
        var pts = project.dataPoints
        pts.sort { $0.x < $1.x }
        project.dataPoints = pts
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let exists = project.dataPoints.first(where: { $0.id == editedId }) {
                focusKey = FocusKey(id: exists.id, field: field)
            }
        }
    }
}

// MARK: - Data Point Row

struct DataPointRow: View {
	@Bindable var project: Project
	let point: DataPoint
	let index: Int
	@Binding var focusKey: DataEditorView.FocusKey?
	let onSort: () -> Void
	
	@State private var xStr: String = ""
	@State private var yStr: String = ""
	@State private var wStr: String = ""
	@State private var xFocused = false
	@State private var yFocused = false
	@State private var wFocused = false
	
	private var positiveStyle: NumericStringStyle {
		NumericStringStyle(decimalSeparator: true, negatives: false, exponent: true)
	}
	
	private func commit() {
		var pts = project.dataPoints
		guard index < pts.count else { return }
		if let v = Double(xStr), v.isFinite { pts[index].x = v }
		if let v = Double(yStr), v.isFinite { pts[index].y = v }
		if let v = Double(wStr), v.isFinite, v > 0 { pts[index].weight = v }
		project.dataPoints = pts
	}
	
	private var xField: some View {
		NumericTextField("x", numericText: $xStr,
						 onEditingChanged: { editing in
			if !editing { commit() }
			if editing {
				focusKey = .init(id: point.id, field: .x)
				xFocused = true; yFocused = false; wFocused = false
			}
		},
						 onNext: {
			commit()
			focusKey = .init(id: point.id, field: .y)
			xFocused = false; yFocused = true; wFocused = false
		}
		)
		//.isFocused($xFocused)
		.frame(maxWidth: .infinity)
	}
	
	private var yField: some View {
		NumericTextField("y", numericText: $yStr,
						 onEditingChanged: { editing in
			if !editing { commit() }
			if editing {
				focusKey = .init(id: point.id, field: .y)
				yFocused = true; xFocused = false; wFocused = false
			}
		},
						 onNext: {
			commit()
			focusKey = .init(id: point.id, field: .w)
			yFocused = false; xFocused = false; wFocused = true
		}
		)
		//.isFocused($yFocused)
		.frame(maxWidth: .infinity)
	}
	
	private var wField: some View {
		NumericTextField("w", numericText: $wStr,
						 style: positiveStyle,
						 onEditingChanged: { editing in
			if !editing {
				commit()
				onSort()
			}
			if editing {
				focusKey = .init(id: point.id, field: .w)
				wFocused = true; xFocused = false; yFocused = false
			}
		},
						 onCommit: {
			commit()
			onSort()
		}
		)
		//.isFocused($wFocused)
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
		.onAppear {
			xStr = point.x.isNaN ? "" : String(format: "%g", point.x)
			yStr = point.y.isNaN ? "" : String(format: "%g", point.y)
			wStr = String(format: "%g", point.weight)
			xFocused = focusKey == .init(id: point.id, field: .x)
			yFocused = focusKey == .init(id: point.id, field: .y)
			wFocused = focusKey == .init(id: point.id, field: .w)
		}
		.onChange(of: focusKey) { _, newFocus in
			xFocused = newFocus == .init(id: point.id, field: .x)
			yFocused = newFocus == .init(id: point.id, field: .y)
			wFocused = newFocus == .init(id: point.id, field: .w)
		}
		.onChange(of: point.x)      { _, v in xStr = String(format: "%g", v) }
		.onChange(of: point.y)      { _, v in yStr = String(format: "%g", v) }
		.onChange(of: point.weight) { _, v in wStr = String(format: "%g", v) }
	}
}
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
