import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Bug investigation: a bug report's open questions, the discussion box and the attachments.

/// A bug report's investigation: the questions still open, what was answered, and the fix.
struct BugPanelView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var assistant: FeatureAssistant
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @ObservedObject var store: FeatureStore
    let bug: BugReport
    @State private var showAnswered = false

    private var checking: Bool { assistant.isRunning("validity:bug:" + bug.key) }
    private var busy: Bool { assistant.isRunning("bug:" + bug.key) || checking }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "ladybug").uiFont(size: 10)
                        .foregroundColor(["critical", "high"].contains(bug.severity) ? palette.red : palette.orange)
                    Text(bug.key).uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim)
                    if !bug.severity.isEmpty {
                        Text(bug.severity.uppercased()).uiFont(size: 8, weight: .bold).foregroundColor(palette.textDim)
                    }
                    IssueLinks(numbers: bug.issueNumbers)
                    Spacer()
                    Menu {
                        ForEach(store.lifecycle.workflow.bug.statuses) { status in
                            Button((status.id == IssueStatus.normalize(bug.status) ? "✓ " : "") + status.title) {
                                Task { await LifecycleStatusChange.perform(store: store, kind: .bug, issue: bug.key, to: status.id) }
                            }
                        }
                    } label: {
                        Text(bug.status.capitalized).uiFont(size: 10, weight: .semibold)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Bug status")
                }
                Text(bug.title).uiFont(size: 11, weight: .semibold).foregroundColor(palette.textBright)
                    .fixedSize(horizontal: false, vertical: true)
            }
            IssueLifecycleSection(store: store, kind: .bug, issue: bug.key, status: bug.status)
                .id("lifecycle-bug-\(bug.key)")
            CycleTimeLink(kind: .bug, issue: bug.key)
            PanelSection(title: "Investigation") {
                if busy {
                    Working(text: checking ? "Checking whether the bug still exists on main…"
                                           : "Investigating — reading the code and refining the report…")
                }
                ForEach(bug.openQuestions) { question in
                    BugQuestionCard(bug: bug, question: question, busy: busy)
                }
                if bug.openQuestions.isEmpty && !busy {
                    Text(bug.answeredQuestions.isEmpty
                         ? "No questions yet. Investigate: the AI checks the code and asks what is missing to reproduce the bug."
                         : "Nothing more to ask — the report is ready to fix.")
                        .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                }
                FlowButtons {
                    if bug.readyToFix && bug.status == "open" {
                        SmallButton(title: "Confirm handoff", icon: "checkmark.circle", prominent: true) {
                            workspaceManager.flow.fixBugWithAI(bug.url)
                        }
                        .help("Confirm the AI's readiness proposal and hand this bug to implementation")
                    }
                    SmallButton(title: "Fix with AI", icon: "hammer", prominent: true) { workspaceManager.flow.fixBugWithAI(bug.url) }
                        .help("The report goes to the assistant in the Terminal tab: reproduce, find the root cause, fix, verify. Status becomes Fixing.")
                    SmallButton(title: "Investigate", icon: "magnifyingglass") { Task { await assistant.investigateBug(bug.url) } }
                        .disabled(busy)
                        .help("First checks whether the bug still exists on main (an already fixed bug is closed). Otherwise the AI reads the code again with the answers so far, rewrites the report and asks what is still missing")
                }
            }
            if !bug.validity.isEmpty {
                PanelSection(title: "Validity check") {
                    Text(panelMarkdown(bug.validity)).uiFont(size: 10)
                        .foregroundColor(palette.text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !bug.discussion.isEmpty {
                PanelSection(title: "Discussion") {
                    Text(panelMarkdown(bug.discussion)).uiFont(size: 10)
                        .foregroundColor(palette.text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !bug.answeredQuestions.isEmpty {
                Button(action: { showAnswered.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: showAnswered ? "chevron.down" : "chevron.right").uiFont(size: 8)
                        Text("ANSWERED (\(bug.answeredQuestions.count))").uiFont(size: 9, weight: .bold)
                    }.foregroundColor(palette.textDim)
                }.buttonStyle(.plain)
                if showAnswered {
                    ForEach(bug.answeredQuestions) { question in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(question.id)  \(question.text)").uiFont(size: 10).foregroundColor(palette.text)
                            Text("→ " + question.answer).uiFont(size: 10)
                                .foregroundColor(question.status == "skipped" ? palette.textDim : palette.green)
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

struct BugDiscussionInput: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var assistant: FeatureAssistant
    let bug: BugReport
    @State private var text = ""
    @State private var attachments: [URL] = []
    @State private var focused = false
    @State private var failed: String?

    var body: some View {
        DictationInput(text: $text, isFocused: { focused }, resetOn: bug.url) { voice in
        VStack(alignment: .leading, spacing: 5) {
            IntakeTextEditor(text: $text, focused: $focused, attach: { add($0) }, failed: { failed = $0 })
                .frame(height: 72)
            BugAttachmentControls(attachments: $attachments, failed: $failed)
            HStack {
                Text("Discuss this bug; paste a screenshot with ⌘V")
                    .uiFont(size: 10).foregroundColor(palette.textDim)
                Spacer()
                voice.mic()
                if assistant.isRunning("discuss:bug:" + bug.key) || assistant.isRunning("validity:bug:" + bug.key) {
                    ProgressView().scaleEffect(0.45).frame(width: 14, height: 14)
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").uiFont(size: 15).foregroundColor(palette.blue) }
                        .buttonStyle(.plain)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                }
            }
            voice.status
            if let failed { Text(failed).uiFont(size: 10).foregroundColor(.red) }
        }
        .padding(8).background(palette.bgInput)
        .onChange(of: bug.url) { _ in text = ""; attachments = []; failed = nil }
        }
    }

    private func add(_ urls: [URL]) { attachments += urls.filter { !attachments.contains($0) } }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !attachments.isEmpty else { return }
        let files = attachments
        text = ""
        attachments = []
        Task { await assistant.discussBug(bug.url, message: message, attachments: files) }
    }
}

struct BugAttachmentControls: View {
    @Binding var attachments: [URL]
    @Binding var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Add Files…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                if panel.runModal() == .OK {
                    attachments += panel.urls.filter { !attachments.contains($0) }
                }
            }
            .uiFont(size: 10)
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(attachments, id: \.self) { url in
                            HStack(spacing: 3) {
                                IntakeAttachmentThumbnail(url: url)
                                Text(url.lastPathComponent).uiFont(size: 10).lineLimit(1)
                                Button { attachments.removeAll { $0 == url } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// An open question about a bug: choose an option, answer in your own words, or "I don't know".
struct BugQuestionCard: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var assistant: FeatureAssistant
    let bug: BugReport
    let question: BugQuestion
    let busy: Bool
    @State private var answer = ""
    @State private var attachments: [URL] = []
    @State private var focused = false
    @State private var failed: String?

    var body: some View {
        FeatureCard {
            Text(question.id).uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim)
            Text(question.text).uiFont(size: 11, weight: .semibold).foregroundColor(palette.textBright)
                .fixedSize(horizontal: false, vertical: true)
            if !question.why.isEmpty {
                Text(question.why).uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(question.options, id: \.self) { option in
                HStack(alignment: .top, spacing: 5) {
                    Text(option.label).uiFont(size: 10, weight: .bold, design: .monospaced).foregroundColor(palette.blue)
                    Text(option.text).uiFont(size: 10).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !busy {
                FlowButtons {
                    ForEach(question.options, id: \.self) { option in
                        SmallButton(title: "Choose \(option.label)", prominent: true) { send("\(option.label). \(option.text)") }
                    }
                    SmallButton(title: "I don't know") { send("") }
                }
                DictationInput(text: $answer, isFocused: { focused }, resetOn: question.id) { voice in
                    VStack(alignment: .leading, spacing: 4) {
                        IntakeTextEditor(text: $answer, focused: $focused,
                                         attach: { urls in attachments += urls.filter { !attachments.contains($0) } },
                                         failed: { failed = $0 })
                            .frame(height: 64)
                            .overlay(alignment: .bottomTrailing) { voice.mic().padding(4) }
                        voice.status
                    }
                }
                BugAttachmentControls(attachments: $attachments, failed: $failed)
                if let failed { Text(failed).uiFont(size: 10).foregroundColor(.red) }
                SmallButton(title: "Answer", action: submit)
            }
        }
    }

    private func submit() {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        answer = ""
        send(text)
    }

    private func send(_ text: String) {
        let files = attachments
        attachments = []
        Task { await assistant.answerBug(bug.url, question: question.id, answer: text, attachments: files) }
    }
}
