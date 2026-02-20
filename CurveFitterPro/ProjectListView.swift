import SwiftUI
import SwiftData

struct ProjectListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.modifiedAt, order: .reverse) private var projects: [Project]
    @State private var showNewProject = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(projects) { project in
                            NavigationLink(destination: ProjectDetailView(project: project)) {
                                ProjectRow(project: project)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Curve Fitter Pro")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewProject = true } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
            }
            .alert("New Project", isPresented: $showNewProject) {
                TextField("Project name", text: $newName)
                Button("Create") { createProject() }
                Button("Cancel", role: .cancel) { newName = "" }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 64))
                .foregroundStyle(.indigo.opacity(0.4))
            Text("No Projects Yet")
                .font(.title2.bold())
            Text("Tap + to create your first curve fitting project.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
            Button("Create Project") { showNewProject = true }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
        }
    }

    private func createProject() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let p = Project(name: name.isEmpty ? "Untitled Project" : name)
        modelContext.insert(p)
        newName = ""
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets { modelContext.delete(projects[i]) }
    }
}

// MARK: - Project Row

struct ProjectRow: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name)
                .font(.headline)
            HStack {
                if !project.modelName.isEmpty {
                    Label(project.modelName, systemImage: "function")
                        .font(.caption)
                        .foregroundStyle(.indigo)
                }
                Spacer()
                Text(project.modifiedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let result = project.fitResult {
                HStack(spacing: 12) {
                    StatBadge(label: "R²", value: String(format: "%.4f", result.rSquared))
                    StatBadge(label: "pts", value: "\(project.dataPoints.count)")
                    if result.converged {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatBadge: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
    }
}
