import SwiftUI

/// The definition of done: what the assistant must have done before an Implement with AI goal counts as
/// finished. Opened before a run (Start hands the goal over) and from Settings (just edit and save).
struct DefinitionOfDoneSheet: View {
    @Environment(\.palette) private var palette
    let root: URL?
    /// The feature about to be implemented; nil when opened from Settings.
    var feature: URL?
    /// What MarkView knows of the feature to recommend a mode; nil when it is not a feature folder (only the direct mode is offered).
    var launch: ImplementationLaunchOptions? = nil
    /// Called with the checklist when the person hands the feature to the assistant terminal.
    var onStart: ((DefinitionOfDone) -> Void)?
    /// Called with the checklist when the person chooses a managed Cockpit run (REQ-001).
    var onPrepareCockpit: ((DefinitionOfDone) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var done = DefinitionOfDone.standard
    @State private var saveAsDefault = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(feature == nil ? "Definition of Done" : "Implement with AI").uiFont(size: 14, weight: .semibold)
            Text(feature == nil
                 ? "What the assistant has to do before an implementation goal counts as finished. Applies to this project. It guides the work: what a status change needs comes from the project workflow, and changing this list does not change it."
                 : "What “done” means for \(feature?.lastPathComponent ?? "this feature"). The assistant gets this with the goal and has to show evidence for each required item.")
                .uiFont(size: 11).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach($done.items) { $item in row($item) }
                    Button { addItem() } label: { Label("Add your own item", systemImage: "plus") }
                        .buttonStyle(.plain).foregroundColor(palette.blue).uiFont(size: 11)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
            }
            .frame(height: 380)
            HStack(spacing: 14) {
                Text("Require: must be true and shown. Ask me: asked first. Skip: not part of this goal.")
                    .uiFont(size: 10).foregroundColor(palette.textDim)
                Spacer()
                Button("Reset to Standard") { done = .standard }.controlSize(.small)
            }
            if feature != nil, let launch, onPrepareCockpit != nil { launchAdvice(launch) }
            if let error { Text(error).uiFont(size: 11).foregroundColor(palette.red) }
            HStack {
                if feature != nil {
                    Toggle("Save as this project's default", isOn: $saveAsDefault).toggleStyle(.checkbox).uiFont(size: 11)
                        .disabled(root == nil)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if feature != nil, let launch, onPrepareCockpit != nil {
                    let recommended = ImplementationLaunchAdvice.recommend(launch.specification, done: done).recommended
                    modeButton(.direct, recommended: recommended) { start() }
                    modeButton(.cockpit, recommended: recommended) { prepareCockpit() }
                } else if feature != nil {
                    Button("Start") { start() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Save") { if save() { dismiss() } }.keyboardShortcut(.defaultAction).disabled(root == nil)
                }
            }
        }
        .padding(18)
        .frame(width: 620)
        .onAppear { done = DefinitionOfDone.load(root: root) }
    }

    /// The recommended mode and why, from the feature's specification and this checklist, and where the checklist leaves out what the
    /// project's rules require (REQ-001, REQ-004). Either mode can be chosen.
    private func launchAdvice(_ launch: ImplementationLaunchOptions) -> some View {
        let advice = ImplementationLaunchAdvice.recommend(launch.specification, done: done)
        let conflicts = ImplementationDeliveryRules.conflicts(done: done, rules: launch.rules)
        return VStack(alignment: .leading, spacing: 4) {
            Label("Recommended: \(advice.recommended.title)", systemImage: advice.recommended == .cockpit ? "gauge.with.dots.needle.67percent" : "terminal")
                .uiFont(size: 12, weight: .semibold)
            ForEach(advice.reasons, id: \.self) { Text("• " + $0).uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true) }
            ForEach(conflicts) { conflict in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(palette.orange)
                    Text(conflict.message).uiFont(size: 10).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Require it") { setMode(.require, for: conflict.itemID) }.controlSize(.small)
                }
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bg))
    }

    @ViewBuilder private func modeButton(_ mode: ImplementationLaunchMode, recommended: ImplementationLaunchMode, action: @escaping () -> Void) -> some View {
        if mode == recommended {
            Button(mode.title, action: action).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        } else {
            Button(mode.title, action: action)
        }
    }

    private func setMode(_ mode: DoneMode, for id: String) {
        guard let index = done.items.firstIndex(where: { $0.id == id }) else { return }
        done.items[index].mode = mode
    }

    private func row(_ item: Binding<DoneItem>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                if item.wrappedValue.custom {
                    TextField("Title", text: item.title).textFieldStyle(.plain).uiFont(size: 12, weight: .medium)
                } else {
                    Text(item.wrappedValue.title).uiFont(size: 12, weight: .medium)
                }
                Spacer(minLength: 8)
                Picker("", selection: item.mode) {
                    ForEach(DoneMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                if item.wrappedValue.custom {
                    Button { done.items.removeAll { $0.id == item.wrappedValue.id } } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).help("Remove this item")
                }
            }
            if item.wrappedValue.custom {
                TextField("What the assistant should do", text: item.instruction, axis: .vertical)
                    .textFieldStyle(.roundedBorder).uiFont(size: 11).lineLimit(1...3)
            } else {
                Text(item.wrappedValue.instruction).uiFont(size: 10).foregroundColor(palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bg))
        .opacity(item.wrappedValue.mode == .skip ? 0.6 : 1)
    }

    private func addItem() {
        done.items.append(DoneItem(id: "custom-" + UUID().uuidString.prefix(8).lowercased(), title: "",
                                   instruction: "", mode: .require, custom: true))
    }

    @discardableResult
    private func save() -> Bool {
        guard let root else { return false }
        do {
            try done.save(root: root)
            error = nil
            return true
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
            return false
        }
    }

    private func prepareCockpit() {
        if saveAsDefault, root != nil, !save() { return }
        onPrepareCockpit?(done)
        dismiss()
    }

    private func start() {
        if saveAsDefault, root != nil, !save() { return }
        // A custom item without a title still works; the text is what the assistant reads.
        onStart?(done)
        dismiss()
    }
}
