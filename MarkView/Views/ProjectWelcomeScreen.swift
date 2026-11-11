import SwiftUI

/// The project store already watches bug/feature changes. Observe it here so the background reacts without polling or AI calls.
struct ProjectWelcomeScreen<Below: View>: View {
    let root: URL?
    let isGitRepo: Bool
    @ObservedObject var store: FeatureStore
    @Binding var backdrop: WelcomeBackdrop
    let perform: (WelcomeActionID) -> Void
    @ViewBuilder let below: () -> Below
    @State private var signals = ProjectBackdropSignals()
    @State private var scannedRoot: URL?

    private var context: ProjectBackdropContext? {
        guard let root else { return nil }
        let workflow = store.lifecycle.workflow
        let issuesKnown = store.hasLoaded && store.root?.standardizedFileURL == root.standardizedFileURL
        let bugs = issuesKnown ? store.bugs.filter { !(workflow.role(.bug, $0.status)?.isFinished ?? false) } : []
        let features = issuesKnown ? store.features.filter { workflow.role(.feature, $0.status) != .cancelled } : []
        return ProjectBackdropContext(identity: root.standardizedFileURL.path,
                                      signals: scannedRoot == root ? signals : ProjectBackdropSignals(),
                                      openBugs: bugs.count,
                                      criticalBugs: bugs.filter { ["critical", "blocker"].contains($0.severity.lowercased()) }.count,
                                      features: features.count,
                                      completedFeatures: features.filter { workflow.isCompleted(.feature, $0.status) }.count,
                                      issuesKnown: issuesKnown)
    }

    var body: some View {
        WelcomeScreen(projectName: root.map { WindowTitle.folderName(of: $0) }, isGitRepo: isGitRepo,
                      backdrop: $backdrop, projectContext: context, perform: perform, below: below)
            .task(id: backdrop == .project ? root : nil) {
                guard backdrop == .project, let root else { return }
                let work = Task.detached(priority: .utility) { ProjectBackdropScanner.scan(root) }
                let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
                guard !Task.isCancelled else { return }
                signals = result
                scannedRoot = root
            }
    }
}
