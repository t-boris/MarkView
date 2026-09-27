import SwiftUI
import AppKit

// New Research (feature new-research-repository-grounded-analysis): the intake fields, the
// bar under the editor with running jobs and "Continue / deepen", and the follow-up sheet.

/// Research-only fields of the intake sheet: target documents (DEC-009), output path (DEC-006)
/// and the repository's web search opt-out (DEC-011).
struct ResearchIntakeOptions: View {
    let root: URL
    @Binding var targets: [URL]
    @Binding var outputPath: String
    @Binding var outputPathEdited: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Documents / folders:").font(.caption)
                ForEach(targets, id: \.self) { url in
                    HStack(spacing: 2) {
                        Text(ResearchJobs.relative(url, to: root) ?? url.lastPathComponent).font(.caption).lineLimit(1)
                        Button(action: { targets.removeAll { $0 == url } }) { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2).background(VSDark.bgInput).cornerRadius(4)
                }
                if targets.isEmpty { Text("the whole repository").font(.caption).foregroundColor(.secondary) }
                Button("Add…") { chooseTargets() }.font(.caption)
                Spacer()
            }
            HStack(spacing: 6) {
                Text("Save as:").font(.caption)
                TextField("docs/research/<date>-<name>.md", text: Binding(
                    get: { outputPath },
                    set: { outputPath = $0; outputPathEdited = true }
                ))
                .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
            }
            WebSearchToggle(root: root)
        }
    }

    /// Repository files only: targets are cited by their workspace paths.
    private func chooseTargets() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.directoryURL = root
        panel.message = "Choose documents or folders to analyse first; folders include their subfolders"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where (url.standardizedFileURL == root.standardizedFileURL || ResearchJobs.relative(url, to: root) != nil) && !targets.contains(url) {
            targets.append(url)
        }
    }
}

/// "Disable web search for this repository" (DEC-011), stored per folder.
struct WebSearchToggle: View {
    @AppStorage private var disabled: Bool

    init(root: URL) {
        _disabled = AppStorage(wrappedValue: false, ResearchSettings.webDisabledKey(root))
    }

    var body: some View {
        Toggle("Disable web search for this repository", isOn: $disabled)
            .font(.caption)
            .help("Research then uses only the repository, and the report says so. Otherwise the AI may search the web with generic queries, each listed in the report.")
    }
}

/// Under the editor: running research jobs (elapsed time, current step, Cancel) and, for an
/// open research document, its status and "Continue / deepen" (DEC-005, DEC-012).
struct ResearchBar: View {
    @ObservedObject var research: ResearchJobs
    let root: URL?
    /// The open document, when it is file-backed.
    let activeFile: URL?
    let activeContent: String

    var body: some View {
        let front = activeFile != nil ? FrontMatter.split(activeContent).0 : FrontMatter()
        let isResearch = front.string("type") == "research"
        if !research.jobs.isEmpty || research.message != nil || isResearch {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(research.jobs) { job in
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).scaleEffect(0.7)
                        TimelineView(.periodic(from: job.started, by: 1)) { context in
                            let seconds = max(0, Int(context.date.timeIntervalSince(job.started)))
                            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                                .font(.system(size: 10, design: .monospaced)).foregroundColor(VSDark.text)
                        }
                        Text(job.title).font(.system(size: 10, weight: .semibold)).foregroundColor(VSDark.textBright).lineLimit(1)
                        Text("· " + job.step).font(.system(size: 10)).foregroundColor(VSDark.textDim)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        SmallButton(title: "Cancel", icon: "stop.circle") { research.cancel(job.id) }
                            .help("Stop the job; what it produced so far is saved and marked incomplete")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 3)
                }
                if let message = research.message {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 9)).foregroundColor(VSDark.yellow)
                        Text(message).font(.system(size: 10)).foregroundColor(VSDark.text).lineLimit(2).textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button(action: { research.message = nil }) { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.plain).foregroundColor(VSDark.textDim).help("Dismiss")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 3)
                }
                if isResearch, let file = activeFile {
                    let complete = front.string("status") != "incomplete"
                    HStack(spacing: 6) {
                        Image(systemName: "books.vertical").font(.system(size: 9)).foregroundColor(VSDark.blue)
                        Text("Research").font(.system(size: 10, weight: .semibold)).foregroundColor(VSDark.text)
                        Text(complete ? "complete" : "incomplete")
                            .font(.system(size: 10)).foregroundColor(complete ? VSDark.green : VSDark.yellow)
                        Text("· select text and use ✦ › Revise With Comment to have the AI rework a passage")
                            .font(.system(size: 10)).foregroundColor(VSDark.textDim).lineLimit(1)
                        Spacer(minLength: 4)
                        SmallButton(title: "Continue / Deepen…", icon: "arrow.down.doc", prominent: true) {
                            research.requestFollowUp(for: file)
                        }
                        .disabled(research.isRunning(on: file))
                        .help("Ask a follow-up question or retry an incomplete part; the answer is appended to this document")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 3)
                }
            }
            .background(VSDark.bgSidebar)
            .overlay(Divider().background(VSDark.border), alignment: .top)
            // Presented here: this view observes the jobs, the window's root view does not.
            .sheet(item: $research.followUp) { request in
                if let root {
                    ResearchFollowUpSheet(file: request.file, root: root, research: research)
                }
            }
        }
    }
}

/// "Continue / deepen": a follow-up question, or a retry of the latest incomplete part,
/// which is pre-selected when the latest section is incomplete (DEC-013).
struct ResearchFollowUpSheet: View {
    let file: URL
    let root: URL
    @ObservedObject var research: ResearchJobs
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var retry: Bool
    private let retryTarget: ResearchDocument.Section?

    init(file: URL, root: URL, research: ResearchJobs) {
        self.file = file
        self.root = root
        self.research = research
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let sections = ResearchDocument.sections(text)
        let target = ResearchDocument.unresolved(sections).last
        retryTarget = target
        _retry = State(initialValue: target != nil && sections.last?.incomplete == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "books.vertical").foregroundColor(VSDark.blue)
                Text("Continue / Deepen Research").font(.headline)
            }
            Text(file.lastPathComponent).font(.caption).foregroundColor(.secondary)
            if let target = retryTarget {
                Picker("", selection: $retry) {
                    Text("Ask a follow-up question").tag(false)
                    Text("Retry incomplete part (\(target.name))").tag(true)
                }
                .pickerStyle(.radioGroup).labelsHidden()
            }
            if retry, let target = retryTarget {
                Text("Runs this question again with the partial answer as context and appends the result; the incomplete part stays as it is.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(target.question.isEmpty ? "(no question recorded)" : target.question)
                    .font(.system(size: 12)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(VSDark.bgInput).cornerRadius(4)
            } else {
                Text("The AI reads the document as it is saved (with your edits) and appends its answer as a new dated section.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $question)
                    .font(.system(size: 13))
                    .frame(minWidth: 520, minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(VSDark.border, lineWidth: 1))
            }
            WebSearchToggle(root: root)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(retry ? "Retry" : "Continue") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!retry && question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 560)
    }

    private func submit() {
        dismiss()
        if retry, let target = retryTarget {
            research.followUp(file, question: target.question, retry: target)
        } else {
            research.followUp(file, question: question.trimmingCharacters(in: .whitespacesAndNewlines), retry: nil)
        }
    }
}
