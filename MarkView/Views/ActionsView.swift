import SwiftUI

/// AI panel → Actions: analyse the open document once, then run the actions the AI
/// suggested for it or the standard ones. Each result opens in a new unsaved tab.
struct ActionsView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @ObservedObject var store: DocumentActionsStore
    @State private var customInstruction = ""

    var body: some View {
        let document = workspaceManager.actionsDocument
        VStack(spacing: 0) {
            header(document)
            Divider().background(VSDark.border)

            if let document {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let error = store.errors[document.url.path] {
                            banner(error, symbol: "exclamationmark.triangle", color: VSDark.red)
                        }
                        suggestions(for: document)
                        section("Always available") {
                            ForEach(DocumentAction.base) { actionRow($0, document: document.url) }
                        }
                        customAction
                    }
                    .padding(8)
                }
            } else {
                VStack {
                    Spacer()
                    Text("Open a document to see actions for it")
                        .font(.system(size: 11)).foregroundColor(VSDark.textDim)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(VSDark.bgSidebar)
        .task(id: document?.url) {
            if let url = document?.url {
                store.load(for: url, storeDirectory: workspaceManager.actionsStoreDirectory(for: url))
            }
        }
    }

    // MARK: - Header

    private func header(_ document: (url: URL, content: String)?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text").font(.system(size: 10)).foregroundColor(VSDark.textDim)
            Text(document?.url.lastPathComponent ?? "No document")
                .font(.system(size: 10, weight: .semibold)).foregroundColor(VSDark.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)

            if let document {
                let hasAnalysis = store.analyses[document.url.path] != nil
                Button(hasAnalysis ? "Reanalyze" : "Analyze") { workspaceManager.analyzeActiveDocument() }
                    .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundColor(VSDark.textBright)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(VSDark.blue.opacity(0.3)).cornerRadius(3)
                    .disabled(store.isAnalyzing(document.url))
                    .help("Analyse this document and suggest actions for it")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(VSDark.bg)
    }

    // MARK: - Sections

    @ViewBuilder
    private func suggestions(for document: (url: URL, content: String)) -> some View {
        let analyzing = store.isAnalyzing(document.url)
        if let analysis = store.analyses[document.url.path] {
            section("For this document") {
                VStack(alignment: .leading, spacing: 3) {
                    Text(analysis.documentType.isEmpty ? "Document" : analysis.documentType)
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(VSDark.text)
                    if !analysis.summary.isEmpty {
                        Text(analysis.summary)
                            .font(.system(size: 10)).foregroundColor(VSDark.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Analysed \(analysis.analyzedAt.formatted(date: .abbreviated, time: .shortened)) · \(analysis.assistant)")
                        .font(.system(size: 8)).foregroundColor(VSDark.textDim)
                }
                if analyzing {
                    progress("Reanalysing…")
                } else if DocumentActionsStore.contentHash(document.content) != analysis.contentHash {
                    banner("The document changed since this analysis. Reanalyze to refresh the suggestions.",
                           symbol: "clock.arrow.circlepath", color: VSDark.orange)
                }
                ForEach(analysis.actions) { actionRow($0, document: document.url) }
            }
        } else if analyzing {
            section("For this document") { progress("Analysing the document…") }
        } else {
            section("For this document") {
                Text("Analyse the document to get actions tailored to it — specific flows, diagrams, tables and briefs.")
                    .font(.system(size: 10)).foregroundColor(VSDark.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Analyze document") { workspaceManager.analyzeActiveDocument() }
                    .font(.system(size: 10))
            }
        }
    }

    private var customAction: some View {
        section("Custom") {
            HStack(spacing: 6) {
                TextField("Describe what to create from this document…", text: $customInstruction)
                    .textFieldStyle(.plain).font(.system(size: 11)).foregroundColor(VSDark.text)
                    .padding(5).background(VSDark.bg).cornerRadius(4)
                    .onSubmit(runCustom)
                Button("Run", action: runCustom)
                    .font(.system(size: 10))
                    .disabled(customInstruction.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func runCustom() {
        let instruction = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        workspaceManager.runDocumentAction(DocumentAction(
            id: "custom", title: "Custom", detail: instruction, kind: .other, instruction: instruction))
        customInstruction = ""
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold)).foregroundColor(VSDark.textDim)
            content()
        }
    }

    private func actionRow(_ action: DocumentAction, document: URL) -> some View {
        let running = store.isRunning(action, for: document)
        return Button(action: { workspaceManager.runDocumentAction(action) }) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: action.kind.symbol)
                    .font(.system(size: 10)).foregroundColor(VSDark.blue)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.system(size: 11, weight: .medium)).foregroundColor(VSDark.textBright)
                    Text(action.detail)
                        .font(.system(size: 9)).foregroundColor(VSDark.textDim)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if running {
                    ProgressView().scaleEffect(0.4).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 9)).foregroundColor(VSDark.textDim)
                }
            }
            .padding(6)
            .background(VSDark.bgActive.opacity(0.6))
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(running)
        .help(action.instruction)
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
            Text(text).font(.system(size: 10)).foregroundColor(VSDark.blue)
        }
    }

    private func banner(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9)).foregroundColor(color)
            Text(text).font(.system(size: 9)).foregroundColor(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(color.opacity(0.1))
        .cornerRadius(4)
    }
}
