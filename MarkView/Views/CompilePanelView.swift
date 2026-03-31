import SwiftUI

/// Matrix-style compile panel with full options, build status, section preview
struct CompilePanelView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var selectedProfileId = "high_level_architecture"
    @State private var audience = "Engineering"
    @State private var language = "English"
    @State private var strictness = "moderate"
    @State private var llmMode = "template_only"
    @State private var compileEngine: CompileEngine?

    private let matrixGreen = Color(red: 0.0, green: 0.85, blue: 0.3)
    private let matrixDim = Color(red: 0.0, green: 0.45, blue: 0.15)
    private let matrixBg = Color(red: 0.03, green: 0.08, blue: 0.03)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                Text("╔═ COMPILE ENGINE ═╗")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(matrixGreen)
                    .padding(.top, 8)

                // Profile selector
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TARGET PROFILE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(matrixDim)
                        Picker("", selection: $selectedProfileId) {
                            ForEach(CompileEngine.profiles) { p in
                                Text(p.name).tag(p.id)
                            }
                        }
                        .labelsHidden()
                    }
                }

                // Options
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("OPTIONS")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(matrixDim)

                        HStack {
                            Text("Audience:")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(matrixDim)
                                .frame(width: 75, alignment: .trailing)
                            Picker("", selection: $audience) {
                                Text("Engineering").tag("Engineering")
                                Text("Executive").tag("Executive")
                                Text("DevOps / SRE").tag("DevOps")
                                Text("Security").tag("Security")
                            }.labelsHidden()
                        }
                        HStack {
                            Text("Language:")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(matrixDim)
                                .frame(width: 75, alignment: .trailing)
                            Picker("", selection: $language) {
                                Text("English").tag("English")
                                Text("Russian").tag("Russian")
                            }.labelsHidden()
                        }
                        HStack {
                            Text("Strictness:")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(matrixDim)
                                .frame(width: 75, alignment: .trailing)
                            Picker("", selection: $strictness) {
                                Text("Lenient").tag("lenient")
                                Text("Moderate").tag("moderate")
                                Text("Strict").tag("strict")
                            }.labelsHidden()
                        }
                        HStack {
                            Text("LLM Mode:")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(matrixDim)
                                .frame(width: 75, alignment: .trailing)
                            Picker("", selection: $llmMode) {
                                Text("Template Only").tag("template_only")
                                Text("AI Assisted").tag("assisted")
                                Text("Review Only").tag("review_only")
                            }.labelsHidden()
                        }
                    }
                }

                // Precompile check
                if let tab = activeTab {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PRECOMPILE CHECK")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(matrixDim)

                            let blockCount = tab.blocks.count
                            let entityCount = workspaceManager.semanticDatabase?.entityCount() ?? 0
                            let claimCount = workspaceManager.semanticDatabase?.claimCount() ?? 0
                            let completeness = min(1.0, Double(claimCount) / max(1.0, Double(blockCount) * 0.5))

                            HStack {
                                Text("Completeness:")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(matrixDim)
                                ProgressView(value: completeness)
                                    .tint(completeness > 0.7 ? matrixGreen : .orange)
                                Text("\(Int(completeness * 100))%")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(completeness > 0.7 ? matrixGreen : .orange)
                            }

                            Text("  Blocks: \(blockCount) | Entities: \(entityCount) | Claims: \(claimCount)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(matrixDim)
                        }
                    }
                }

                // Compile button
                Button(action: compile) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("COMPILE")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(matrixGreen)
                .disabled(compileEngine?.isCompiling == true)

                // Build status + compiled sections
                if let engine = compileEngine {
                    if engine.isCompiling {
                        HStack {
                            ProgressView().scaleEffect(0.7)
                            Text("COMPILING...")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.orange)
                        }
                    } else if !engine.compiledSections.isEmpty {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 4) {
                                let covered = engine.compiledSections.filter { !$0.sourceBlockIds.isEmpty }.count
                                let total = engine.compiledSections.count

                                HStack {
                                    Text(covered == total ? "✓ BUILD SUCCESS" : "⚠ BUILD WITH GAPS")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(covered == total ? matrixGreen : .yellow)
                                    Spacer()
                                    Text("\(covered)/\(total) sections")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(matrixDim)
                                }

                                ForEach(engine.compiledSections) { artifact in
                                    HStack(spacing: 4) {
                                        Text(artifact.sourceBlockIds.isEmpty ? "○" : "●")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(artifact.sourceBlockIds.isEmpty ? .orange : matrixGreen)
                                        Text(artifact.sectionKey ?? "?")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(VSDark.text)
                                        Spacer()
                                        Text("\(artifact.sourceBlockIds.count)blk")
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundColor(matrixDim)
                                    }
                                }
                            }
                        }

                        Button(action: exportCompiled) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("EXPORT .MD")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }

                Text("╚═══════════════════╝")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(matrixDim.opacity(0.3))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private func compile() {
        guard let compiler = workspaceManager.incrementalCompiler,
              let tab = activeTab else { return }
        let engine = CompileEngine(database: compiler.database, orchestrator: compiler.orchestrator)
        self.compileEngine = engine
        Task {
            await engine.compile(profileId: selectedProfileId, blocks: tab.blocks, documentId: tab.url.lastPathComponent)
        }
    }

    private func exportCompiled() {
        guard let engine = compileEngine else { return }
        let profile = CompileEngine.profiles.first(where: { $0.id == selectedProfileId })
        let markdown = engine.exportAsMarkdown(title: profile?.name ?? "Compiled Document")
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "\(selectedProfileId).md"
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
        }
    }

    private var activeTab: OpenTab? {
        guard workspaceManager.activeTabIndex >= 0,
              workspaceManager.activeTabIndex < workspaceManager.openTabs.count else { return nil }
        return workspaceManager.openTabs[workspaceManager.activeTabIndex]
    }
}
