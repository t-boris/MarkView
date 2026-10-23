import SwiftUI

/// Discussions: ideas thought through before they are features. A question is answered as an Insight page; the
/// decisions and open questions it brings are kept beside the conversation and can be edited.
struct DiscussionsView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @ObservedObject var store: DiscussionStore
    @State private var creating = false
    @State private var newTitle = ""
    @State private var question = ""
    @State private var newItem = ""
    @State private var newKind: DiscussionItem.Kind = .question
    @State private var confirmDelete: Discussion?

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 214)
            Divider().background(VSDark.border)
            Group {
                if let discussion = store.selected {
                    detail(discussion).id(discussion.slug)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VSDark.bg)
        .alert("Delete this discussion?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let d = confirmDelete { store.delete(d.slug) }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("\"\(confirmDelete?.title ?? "")\" and its answers are removed from .dde/discussions.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("DISCUSSIONS").uiFont(size: 10, weight: .semibold).foregroundColor(VSDark.textDim)
                Spacer()
                Button { creating.toggle() } label: { Image(systemName: "plus") }.help("Start a discussion")
            }
            .buttonStyle(.plain).foregroundColor(VSDark.textDim).padding(.horizontal, 10).padding(.vertical, 8)
            if creating {
                HStack(spacing: 6) {
                    TextField("What do you want to think through?", text: $newTitle)
                        .textFieldStyle(.roundedBorder).uiFont(size: 11)
                        .onSubmit(create)
                    Button("Start", action: create).controlSize(.small).disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }.padding(.horizontal, 10).padding(.bottom, 8)
            }
            Divider().background(VSDark.border)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.discussions) { discussion in
                        Button { store.selectedSlug = discussion.slug } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(discussion.title).uiFont(size: 12, weight: .medium).foregroundColor(VSDark.text).lineLimit(2)
                                Text("\(discussion.turns.count) questions · \(discussion.items(.question).count) open")
                                    .uiFont(size: 10).foregroundColor(VSDark.textDim)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(store.selectedSlug == discussion.slug ? VSDark.bgActive : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { Button("Delete…", role: .destructive) { confirmDelete = discussion } }
                    }
                }
            }
        }
        .background(VSDark.bgSidebar)
    }

    private func create() {
        if store.create(title: newTitle) != nil { newTitle = ""; creating = false }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 34)).foregroundColor(VSDark.textDim)
            Text("Think an idea through before it is a feature").uiFont(size: 15, weight: .semibold).foregroundColor(VSDark.text)
            Text("Start a discussion, ask questions about the project, and get each answer as a page you can dig into. Decisions and open questions are kept, so the idea can later become a feature or a list of tasks.")
                .uiFont(size: 12).foregroundColor(VSDark.textDim).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Start a discussion") { creating = true }.buttonStyle(.borderedProminent)
        }.padding(30)
    }

    // MARK: Detail

    private func detail(_ discussion: Discussion) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Text(discussion.title).uiFont(size: 15, weight: .semibold).foregroundColor(VSDark.text)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 10)
                Divider().background(VSDark.border)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if discussion.turns.isEmpty {
                            Text("Ask the first question below. The assistant reads the project, then answers as a page.")
                                .uiFont(size: 12).foregroundColor(VSDark.textDim)
                        }
                        ForEach(discussion.turns) { turn in turnCard(discussion, turn) }
                    }.padding(16)
                }
                Divider().background(VSDark.border)
                composer(discussion)
            }
            .frame(maxWidth: .infinity)
            Divider().background(VSDark.border)
            itemsPane(discussion).frame(width: 290)
        }
    }

    private func turnCard(_ discussion: Discussion, _ turn: DiscussionTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Q\(turn.id) · \(turn.question)").uiFont(size: 12, weight: .semibold).foregroundColor(VSDark.text)
            Text(String(turn.answer.prefix(320)) + (turn.answer.count > 320 ? "…" : ""))
                .uiFont(size: 11).foregroundColor(VSDark.textDim)
            HStack(spacing: 8) {
                Button { workspaceManager.openDiscussionAnswer(discussion.slug, turn: turn.id, asNote: false) } label: {
                    Label("Open as page", systemImage: "doc.richtext")
                }
                Button { workspaceManager.openDiscussionAnswer(discussion.slug, turn: turn.id, asNote: true) } label: {
                    Label("Open note", systemImage: "doc.text")
                }
            }.buttonStyle(.bordered).controlSize(.small)
            if !turn.followUps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ASK NEXT").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
                    ForEach(turn.followUps, id: \.self) { follow in
                        Button { question = follow } label: {
                            Text("↳ \(follow)").uiFont(size: 11).foregroundColor(VSDark.blue).multilineTextAlignment(.leading)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(VSDark.bgBanner))
    }

    private func composer(_ discussion: Discussion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = store.lastError {
                Text(error).uiFont(size: 11).foregroundColor(.red).textSelection(.enabled)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $question)
                    .uiFont(size: 12).frame(height: 62)
                    .scrollContentBackground(.hidden).background(VSDark.bgInput).cornerRadius(6)
                    .disabled(store.asking != nil)
                if store.asking == discussion.slug {
                    VStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Reading the project…").uiFont(size: 10).foregroundColor(VSDark.textDim)
                    }.frame(width: 110)
                } else {
                    Button {
                        let text = question
                        question = ""
                        workspaceManager.askDiscussion(discussion.slug, question: text)
                    } label: { Label("Ask", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.asking != nil)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help("Ask (⌘↩)")
                }
            }
        }.padding(12)
    }

    // MARK: Decisions and open questions

    private func itemsPane(_ discussion: Discussion) -> some View {
        VStack(spacing: 0) {
            Text("WHERE THIS STANDS").uiFont(size: 10, weight: .semibold).foregroundColor(VSDark.textDim)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
            Divider().background(VSDark.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach([DiscussionItem.Kind.decision, .question, .rejected], id: \.self) { kind in
                        let items = discussion.items(kind)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(kind.title.uppercased()) (\(items.count))").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
                            if items.isEmpty { Text("Nothing yet").uiFont(size: 11).foregroundColor(VSDark.textDim) }
                            ForEach(items) { item in itemRow(discussion, item) }
                        }
                    }
                }.padding(12)
            }
            Divider().background(VSDark.border)
            HStack(spacing: 6) {
                Picker("", selection: $newKind) {
                    ForEach(DiscussionItem.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 104).controlSize(.small)
                TextField("Add by hand", text: $newItem).textFieldStyle(.roundedBorder).uiFont(size: 11).onSubmit { addItem(discussion) }
            }.padding(10)
        }
        .background(VSDark.bgSidebar)
    }

    private func itemRow(_ discussion: Discussion, _ item: DiscussionItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: item.kind == .decision ? "checkmark.circle.fill" : item.kind == .question ? "questionmark.circle" : "xmark.circle")
                .foregroundColor(item.kind == .decision ? VSDark.green : item.kind == .question ? VSDark.yellow : VSDark.textDim)
                .font(.system(size: 12))
            Text(item.text).uiFont(size: 11).foregroundColor(VSDark.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                ForEach(DiscussionItem.Kind.allCases.filter { $0 != item.kind }, id: \.self) { kind in
                    Button("Mark as \(kind.title.lowercased())") { store.move(discussion.slug, item: item.id, to: kind) }
                }
                Divider()
                Button("Remove", role: .destructive) { store.remove(discussion.slug, item: item.id) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
        }
    }

    private func addItem(_ discussion: Discussion) {
        store.addItem(discussion.slug, kind: newKind, text: newItem)
        newItem = ""
    }
}
