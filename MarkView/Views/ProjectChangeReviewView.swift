import SwiftUI

struct ProjectChangeReviewBar: View {
    @ObservedObject var review: ProjectChangeReview
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var showingReview = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass").foregroundColor(VSDark.blue)
            if review.changes.isEmpty {
                Text("File changes: none observed").foregroundColor(VSDark.textDim)
            } else {
                Text("\(review.changes.count) observed file change\(review.changes.count == 1 ? "" : "s")")
                    .foregroundColor(VSDark.text)
            }
            Spacer(minLength: 0)
            if review.isScanning { ProgressView().controlSize(.mini) }
            Button { Task { await review.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh observed file changes")
                .accessibilityLabel("Refresh observed file changes")
            if !review.changes.isEmpty {
                Button("Review") { showingReview = true }
            }
        }
        .uiFont(size: 10)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(VSDark.bgSidebar)
        .sheet(isPresented: $showingReview) {
            ProjectChangeReviewSheet(review: review)
                .environmentObject(workspaceManager)
        }
    }
}

private struct ProjectChangeReviewSheet: View {
    @ObservedObject var review: ProjectChangeReview
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPath: String?

    private var selected: ProjectChange? {
        review.changes.first { $0.path == selectedPath } ?? review.changes.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Observed file changes").uiFont(.title3, weight: .semibold)
                Spacer()
                Button { Task { await review.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button("Done") { dismiss() }
            }.padding(12)
            Text("Changes since this project opened. MarkView observes disk files; the source of each change is unknown.")
                .uiFont(size: 10).foregroundColor(VSDark.textDim)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            Divider()
            HStack(spacing: 0) {
                List(review.changes, selection: $selectedPath) { change in
                    HStack(spacing: 6) {
                        Image(systemName: change.kind == .added ? "plus.circle" :
                              change.kind == .deleted ? "minus.circle" : "pencil.circle")
                        Text(change.path).lineLimit(1)
                        Spacer()
                        Text(change.kind.rawValue.capitalized).foregroundColor(VSDark.textDim)
                    }
                    .uiFont(size: 10)
                    .tag(change.path)
                }
                .frame(minWidth: 210, idealWidth: 260)
                Divider()
                if let selected {
                    VStack(spacing: 0) {
                        HStack {
                            Text(selected.path).uiFont(size: 11, weight: .semibold).lineLimit(1)
                            Spacer()
                            if selected.kind != .deleted, let root = workspaceManager.rootNode?.url {
                                Button("Open in Files") {
                                    workspaceManager.openFile(root.appendingPathComponent(selected.path))
                                    dismiss()
                                }
                            }
                        }.padding(8)
                        Divider()
                        HStack(spacing: 0) {
                            version("Before", text: selected.before)
                            Divider()
                            version("Current", text: selected.current)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("Original files remain on disk. Reviewing does not apply or revert changes.")
                    .uiFont(size: 10).foregroundColor(VSDark.textDim)
                Spacer()
                Button("Mark reviewed") {
                    Task { await review.acknowledge(); dismiss() }
                }
            }.padding(10)
        }
        .frame(minWidth: 680, minHeight: 440)
        .onAppear { selectedPath = review.changes.first?.path }
    }

    private func version(_ title: String, text: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).uiFont(size: 11, weight: .semibold).padding(8)
            Divider()
            ScrollView {
                Text(text ?? "No readable text is available for this version.")
                    .uiFont(size: 10, design: .monospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
