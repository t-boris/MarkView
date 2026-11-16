import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Sources of a feature: adding a file, a link, an issue or a note, and the source cards.

/// Source material and the facts extracted from it (spec §9–10).
struct SourcesSection: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var assistant: FeatureAssistant
    @ObservedObject var store: FeatureStore
    let feature: Feature
    @ObservedObject private var whisper: WhisperClient
    @State private var prompt: SourcePrompt?

    init(store: FeatureStore, feature: Feature) {
        self.store = store
        self.feature = feature
        self.whisper = store.assistant.voice
    }
    @State private var dropping = false

    enum SourcePrompt: String, Identifiable { case url, issue, text; var id: String { rawValue } }


    var body: some View {
        PanelSection(title: "Sources", trailing: AnyView(addMenu)) {
            if assistant.running.contains(where: { $0.hasPrefix("ingest:") }) || assistant.isRunning("add-source") {
                Working(text: "Reading the source…")
            }
            if feature.list(.source).isEmpty {
                Text("Drop files here (docs, PDFs, screenshots, audio) or add a URL, a GitHub issue, notes or a voice note. The AI proposes facts; you accept them.")
                    .uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(feature.list(.source).reversed()) { source in SourceCard(store: store, feature: feature, source: source) }
        }
        .padding(4)
        .background(dropping ? palette.selection.opacity(0.25) : Color.clear)
        .cornerRadius(4)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in addFile(url) }
                }
            }
            return true
        }
        .sheet(item: $prompt) { kind in
            SourceInputSheet(kind: kind) { title, value in
                assistant.start("ingest:" + UUID().uuidString) { assistant in
                    switch kind {
                    case .url:
                        if let url = URL(string: value.trimmingCharacters(in: .whitespaces)) { await assistant.ingest(.url(url), into: feature.slug) }
                    case .issue:
                        let digits = value.filter(\.isNumber)
                        if let number = Int(digits) { await assistant.ingest(.gitHubIssue(number), into: feature.slug) }
                    case .text:
                        await assistant.ingest(.text(title: title, text: value, kind: "notes"), into: feature.slug)
                    }
                }
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Files…") { chooseFiles() }
            Button("URL…") { prompt = .url }
            Button("GitHub Issue…") { prompt = .issue }
            Button("Notes / Conversation…") { prompt = .text }
            Divider()
            if whisper.isRecording {
                Button("Stop Voice Note") {
                    assistant.start("ingest:" + UUID().uuidString) { assistant in
                        if let text = await whisper.stopRecording(), !text.isEmpty {
                            await assistant.ingest(.voice(text: text), into: feature.slug)
                        }
                    }
                }
            } else {
                Button("Record Voice Note") { whisper.startRecording() }
            }
        } label: {
            HStack(spacing: 2) {
                if whisper.isRecording { Circle().fill(palette.red).frame(width: 6, height: 6) }
                Image(systemName: "plus").uiFont(size: 9)
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Add sources to \(feature.title)"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addFile(url) }
    }

    private func addFile(_ url: URL) {
        assistant.start("ingest:" + url.path) { await $0.ingest(.file(url), into: feature.slug) }
    }
}

struct SourceInputSheet: View {
    @Environment(\.palette) private var palette
    let kind: SourcesSection.SourcePrompt
    let onDone: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kind == .url ? "Add a web page" : kind == .issue ? "Add a GitHub issue" : "Add notes or a conversation").uiFont(.headline)
            if kind == .text {
                TextField("Title (e.g. Call with support, 12 Sep)", text: $title).textFieldStyle(.roundedBorder)
                TextEditor(text: $value).uiFont(size: 12).frame(minWidth: 420, minHeight: 180)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.border))
            } else {
                TextField(kind == .url ? "https://…" : "Issue number or link", text: $value).textFieldStyle(.roundedBorder).frame(minWidth: 380)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { onDone(title, value); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }
}

/// A source with its role and candidate facts: Accept / Reject / Edit / Discuss.
struct SourceCard: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var assistant: FeatureAssistant
    @ObservedObject var store: FeatureStore
    let feature: Feature
    let source: FeatureObject
    @EnvironmentObject private var flow: FeatureFlowCoordinator
    @State private var editing: Int?
    @State private var draft = ""

    var body: some View {
        FeatureCard {
            HStack(spacing: 4) {
                Image(systemName: "paperclip").uiFont(size: 9).foregroundColor(palette.textDim)
                Text(source.title).uiFont(size: 10, weight: .semibold).foregroundColor(palette.textBright).lineLimit(1)
                Spacer()
                let role = source.front.string("role")
                if !role.isEmpty { Text(FeatureVocabulary.label(role)).uiFont(size: 8).foregroundColor(palette.cyan) }
                Button(action: { flow.open(source.url) }) {
                    Image(systemName: "doc.text").uiFont(size: 9).foregroundColor(palette.textDim)
                }.buttonStyle(.plain)
            }
            let facts = source.front["facts"]?.list ?? []
            let pending = facts.filter { $0["status"]?.string == "pending" }.count
            if !facts.isEmpty {
                Text("\(facts.count) facts extracted\(pending > 0 ? " · \(pending) to confirm" : "")")
                    .uiFont(size: 9).foregroundColor(palette.textDim)
            }
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                let status = fact["status"]?.string ?? "pending"
                let text = fact["text"]?.string ?? ""
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 4) {
                        Text(status == "accepted" ? "✓" : status == "rejected" ? "✗" : "?")
                            .uiFont(size: 10, weight: .bold, design: .monospaced)
                            .foregroundColor(status == "accepted" ? palette.green : status == "rejected" ? palette.textDim : palette.yellow)
                        if editing == index {
                            TextField("", text: $draft).textFieldStyle(.plain).uiFont(size: 10)
                                .onSubmit {
                                    assistant.setFact(feature.slug, source: source.id, index: index, status: "accepted", text: draft)
                                    editing = nil
                                }
                        } else {
                            Text(text).uiFont(size: 10).foregroundColor(status == "rejected" ? palette.textDim : palette.text)
                                .strikethrough(status == "rejected").fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if status == "pending" {
                        HStack(spacing: 4) {
                            SmallButton(title: "Accept") { assistant.setFact(feature.slug, source: source.id, index: index, status: "accepted") }
                            SmallButton(title: "Reject") { assistant.setFact(feature.slug, source: source.id, index: index, status: "rejected") }
                            SmallButton(title: "Edit") { draft = text; editing = index }
                            SmallButton(title: "Discuss") {
                                assistant.start("chat:" + feature.slug) {
                                    await $0.chat(feature.slug, message: "About this fact from \(source.id): \"\(text)\" — is it right, and what does it mean for the feature?")
                                }
                            }
                        }
                        .padding(.leading, 14)
                    }
                }
            }
        }
    }
}
