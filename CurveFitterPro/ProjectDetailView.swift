import SwiftUI
import SwiftData

struct ProjectDetailView: View {
    @Bindable var project: Project
    @StateObject private var engine = FittingEngine()
    @State private var selectedTab = 0
    @State private var showModelPicker = false
    @State private var showImport = false
    @State private var importError: String?
    @State private var showImportError = false
    @State private var showCustomModel = false
    // Lifted here so FitRunView and PlotView share the same result,
    // bypassing SwiftData's unreliable observation of Data blob properties.
    @State private var fitResult: FitResult? = nil

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

            TabView(selection: $selectedTab) {
                DataEditorView(project: project, showImport: $showImport)
                    .tag(0)
                ModelSetupView(project: project,
                               showModelPicker: $showModelPicker,
                               showCustomModel: $showCustomModel)
                    .tag(1)
                FitRunView(project: project, engine: engine, fitResult: $fitResult)
                    .tag(2)
                PlotView(project: project, engine: engine, fitResult: $fitResult)
                    .tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Restore persisted result on load
            if fitResult == nil {
                fitResult = project.fitResult
            }
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet { model in
                applyModel(model)
                showModelPicker = false
            }
        }
        .sheet(isPresented: $showCustomModel) {
            CustomModelSheet { expr, paramNames, defaults in
                project.modelName = "Custom"
                project.modelExpression = expr
                project.parameters = zip(paramNames, defaults).map {
                    FitParameter(name: $0.0, initialValue: $0.1)
                }
                fitResult = nil
                showCustomModel = false
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
