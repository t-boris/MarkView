import AppKit
import SwiftUI

// End-to-End QA (feature end-to-end-qa, REQ-015): looking closer at a run and deciding what to do about what it found. The viewer shows a
// player's picture or a screenshot at the size of the screen; the finding bar marks a finding (bug confirmed, not a bug, workaround, seen);
// the runs list and the run report bring a finished run back after the app was restarted.

// MARK: - The viewer

struct QAViewerSlide: Identifiable {
    let id: String
    var title: String
    var caption: String = ""
    /// The picture file when there is one; "Open in Preview" opens it, else a copy of the picture.
    var file: URL? = nil
    var image: () -> NSImage?
}

/// Shows a view in a window of its own that can be resized, made full screen and closed with Esc. One viewer window is kept: asking again
/// replaces what it shows. The window keeps the size the person gave it: only the hosted view changes, never the window's content controller
/// (AppKit resizes a window to a new content controller's initial size, which collapsed the viewer to a few points).
@MainActor
enum QAViewer {
    private static var window: NSWindow?
    private static var host: NSHostingController<AnyView>?

    static func show<Content: View>(title: String, palette: AppPalette, @ViewBuilder content: () -> Content) {
        // A new identity for every request: the viewer then starts on the picture that was asked for instead of keeping the earlier selection.
        let root = AnyView(content().environment(\.palette, palette).foregroundStyle(palette.text).background(palette.bg).id(UUID()))
        if let window, let host, window.isVisible || window.isMiniaturized {
            host.rootView = root
            window.title = title
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1280, screen.width * 0.9), height: min(860, screen.height * 0.9))
        let created = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        created.contentViewController = host
        created.setContentSize(size)
        created.title = title
        created.minSize = NSSize(width: 640, height: 420)
        created.collectionBehavior = [.fullScreenPrimary]
        created.isReleasedWhenClosed = false
        created.center()
        self.host = host
        window = created
        created.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }
}

/// A picture that fits its space (or shows at 100%, scrolling), centred.
struct QAZoomableImage: View {
    let image: NSImage
    let actualSize: Bool

    var body: some View {
        GeometryReader { geometry in
            let size = image.size
            let fit = size.width > 0 && size.height > 0 ? min(geometry.size.width / size.width, geometry.size.height / size.height) : 1
            let scale = actualSize ? 1 : max(fit, 0.05)
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width * scale, height: size.height * scale)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
        }
    }
}

/// The pictures of a run one at a time, with ← and → to go through them.
struct QAViewerBody: View {
    @Environment(\.palette) private var palette
    let slides: [QAViewerSlide]
    @State private var selection: String
    @State private var actualSize = false

    init(slides: [QAViewerSlide], start: String) {
        self.slides = slides
        _selection = State(initialValue: start)
    }

    private var index: Int { slides.firstIndex { $0.id == selection } ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if slides.indices.contains(index), let image = slides[index].image() {
                QAZoomableImage(image: image, actualSize: actualSize)
                    .background(Color.black.opacity(0.25))
            } else {
                Text("There is no picture yet.").uiFont(size: 12).foregroundColor(palette.textDim).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if slides.indices.contains(index), !slides[index].caption.isEmpty {
                Divider()
                ScrollView {
                    Text(slides[index].caption).uiFont(size: 12).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(maxHeight: 120)
            }
        }
        .onExitCommand { QAViewer.close() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: []).disabled(index == 0).help("Previous picture (←)")
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: []).disabled(index >= slides.count - 1).help("Next picture (→)")
            Text(slides.indices.contains(index) ? slides[index].title : "").uiFont(size: 12, weight: .semibold).lineLimit(1)
            Spacer(minLength: 0)
            if slides.count > 1 { Text("\(index + 1) of \(slides.count)").uiFont(size: 11).foregroundColor(palette.textDim) }
            Picker("", selection: $actualSize) {
                Text("Fit").tag(false)
                Text("100%").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 110)
            Button("Open in Preview") { openInPreview() }.disabled(!slides.indices.contains(index))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func step(_ delta: Int) {
        let next = min(max(index + delta, 0), slides.count - 1)
        if slides.indices.contains(next) { selection = slides[next].id }
    }

    private func openInPreview() {
        guard slides.indices.contains(index) else { return }
        let slide = slides[index]
        if let file = slide.file { NSWorkspace.shared.open(file); return }
        guard let image = slide.image(), let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("QA-\(UUID().uuidString.prefix(8)).png")
        guard (try? png.write(to: url)) != nil else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The viewer of the run in progress or just ended: each player's picture now (it follows the page) and every screen the feed shows.
struct QALiveViewer: View {
    @ObservedObject var run: QARunModel
    let start: String

    var body: some View { QAViewerBody(slides: run.viewerSlides(), start: start) }
}

extension QARunModel {
    func viewerSlides() -> [QAViewerSlide] {
        var slides: [QAViewerSlide] = []
        for player in players where player.picture != nil {
            let id = player.id
            let page = player.title.isEmpty ? player.address : "\(player.title) — \(player.address)"
            slides.append(QAViewerSlide(id: "player:\(id)", title: "\(player.name), now", caption: page, image: { [weak self] in
                self?.screenshot(ofPlayer: id).flatMap { NSImage(data: $0) }
            }))
        }
        var seen = Set<Int>()
        for item in feed {
            guard let data = item.screenshot, item.screen != 0, seen.insert(item.screen).inserted else { continue }
            let finding = item.finding.flatMap { found in findings.first { $0.id == found.id } ?? found }
            let title = "\(clockText(item.time)) · \(item.text)"
            var caption = item.text
            if let finding {
                caption = [finding.title, finding.detail, finding.proposal.isEmpty ? "" : "Better: " + finding.proposal].filter { !$0.isEmpty }.joined(separator: "\n")
            }
            slides.append(QAViewerSlide(id: "screen:\(item.screen)", title: title, caption: caption, image: { NSImage(data: data) }))
        }
        return slides
    }

    private func clockText(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

// MARK: - Marking a finding

extension QATriageState: Identifiable {
    public var id: String { rawValue }
}

/// The marks of a finding: the buttons it offers, or the mark it has with a way to take it back. A workaround is asked for in a small box.
struct QAFindingTriageBar: View {
    @Environment(\.palette) private var palette
    let finding: QAFinding
    let mark: (QATriageState?, String) -> Void
    @State private var asking: QATriageState?
    @State private var note = ""

    var body: some View {
        HStack(spacing: 6) {
            if let state = finding.triage {
                Label(state.title, systemImage: icon(state)).uiFont(size: 10.5, weight: .semibold).foregroundColor(color(state))
                if let words = finding.triageNote {
                    Text(words).uiFont(size: 10.5).foregroundColor(palette.textDim).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Button("Undo") { mark(nil, "") }.buttonStyle(.link).uiFont(size: 10.5)
            } else {
                ForEach(QATriage.states(for: finding)) { state in
                    Button(state.action) { choose(state) }.controlSize(.small).uiFont(size: 10.5)
                }
            }
            Spacer(minLength: 0)
        }
        .popover(item: $asking, arrowEdge: .bottom) { state in form(state) }
    }

    private func choose(_ state: QATriageState) {
        if state.needsNote {
            note = ""
            asking = state
        } else {
            mark(state, "")
        }
    }

    private func form(_ state: QATriageState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.notePrompt).uiFont(size: 11.5, weight: .semibold)
            TextField("", text: $note).frame(width: 320).onSubmit { save(state) }
            HStack {
                Spacer()
                Button("Cancel") { asking = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { save(state) }.keyboardShortcut(.defaultAction)
                    .disabled(state.needsNote && QATriage.clean(note).isEmpty)
            }
        }
        .padding(12)
    }

    private func save(_ state: QATriageState) {
        guard !(state.needsNote && QATriage.clean(note).isEmpty) else { return }
        asking = nil
        mark(state, note)
    }

    private func icon(_ state: QATriageState) -> String {
        switch state {
        case .confirmed: return "checkmark.seal.fill"
        case .notABug: return "xmark.circle.fill"
        case .workaround: return "arrow.triangle.branch"
        case .seen: return "eye.fill"
        case .dismissed: return "minus.circle.fill"
        }
    }

    private func color(_ state: QATriageState) -> Color {
        switch state {
        case .confirmed: return palette.red
        case .workaround: return palette.orange
        case .notABug, .seen, .dismissed: return palette.textDim
        }
    }
}

// MARK: - The runs of a scenario

/// A scenario's earlier runs on the Run tab: when, how each branch ended, how many findings are still unmarked.
struct QARunsList: View {
    @Environment(\.palette) private var palette
    @ObservedObject var archive: QARunArchive
    let scenarioID: String
    let phase: QARunModel.Phase

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Earlier runs").uiFont(size: 11.5, weight: .semibold)
            if archive.runs.isEmpty {
                Text("None yet. A finished run is kept here with its findings.").uiFont(size: 10.5).foregroundColor(palette.textDim)
            }
            ForEach(archive.runs.prefix(30), id: \.id) { run in
                Button { archive.open(run.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(run.startedAt.formatted(date: .abbreviated, time: .shortened)).uiFont(size: 11, weight: .medium)
                            Text(summary(run)).uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(2).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").uiFont(size: 10).foregroundColor(palette.textDim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { archive.reload(scenarioID: scenarioID) }
        .onChange(of: scenarioID) { archive.reload(scenarioID: $0) }
        .onChange(of: phase) { if $0 == .finished { archive.reload(scenarioID: scenarioID) } }
    }

    private func summary(_ run: QARunRecord) -> String {
        let counts = Dictionary(grouping: run.results, by: { $0.verdict.outcome }).mapValues(\.count)
        let parts = [QAOutcome.passed, .failed, .blocked, .interrupted, .uncovered].compactMap { outcome in counts[outcome].map { "\($0) \(outcome.label.lowercased())" } }
        var text = parts.isEmpty ? (run.finishedAt == nil ? "Not finished" : "No result") : parts.joined(separator: " · ")
        if let findings = QATriage.summary(run.findings) { text += " · " + findings }
        return text
    }
}

// MARK: - A run opened from the list

struct QARunReportView: View {
    @Environment(\.palette) private var palette
    @ObservedObject var archive: QARunArchive
    let scenario: QAScenario
    let record: QARunRecord
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { onClose() } label: { Label("Back to the scenario", systemImage: "chevron.left") }.uiFont(size: 11)
                Spacer()
                Text("Run of \(record.startedAt.formatted(date: .abbreviated, time: .shortened))").uiFont(size: 11.5, weight: .medium)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let notice = archive.notice { Text(notice).uiFont(size: 10.5).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true) }
                    results
                    findings
                    timeline
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(palette.bg)
    }

    // MARK: Branches

    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Branches").uiFont(size: 11.5, weight: .semibold)
            ForEach(record.lines, id: \.branch) { line in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(line.outcome?.label ?? "Not run").uiFont(size: 10.5, weight: .semibold).foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(tint(line.outcome)))
                        Text(label(line.branch)).uiFont(size: 11.5, weight: .medium).lineLimit(2)
                        Spacer(minLength: 0)
                        if let video = archive.video(of: line.branch, in: record) {
                            Button { NSWorkspace.shared.open(video) } label: { Label("Video", systemImage: "play.rectangle") }
                                .buttonStyle(.borderless).uiFont(size: 10.5)
                        }
                    }
                    if let reason = line.reason, !reason.isEmpty {
                        Text(reason).uiFont(size: 10.5).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func label(_ branch: String) -> String {
        scenario.enumerateBranches().branches.first { $0.id == branch }.map { scenario.label(of: $0) } ?? branch
    }

    private func tint(_ outcome: QAOutcome?) -> Color {
        switch outcome {
        case .passed?: return palette.green
        case .failed?: return palette.red
        case .blocked?, .interrupted?: return palette.orange
        case .uncovered?, nil: return palette.textDim
        }
    }

    // MARK: Findings

    private var findings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(record.findings.isEmpty ? "Findings" : "Findings (\(record.findings.count))").uiFont(size: 11.5, weight: .semibold)
            if record.findings.isEmpty {
                Text("The review found nothing to report in this run.").uiFont(size: 10.5).foregroundColor(palette.textDim)
            }
            ForEach(record.findings) { finding in
                HStack(alignment: .top, spacing: 10) {
                    if let url = archive.frame(of: finding, in: record) {
                        Button { openViewer(at: finding.id) } label: { QAFileThumbnail(url: url) }
                            .buttonStyle(.plain).accessibilityLabel("Enlarge the screenshot").help("Click to enlarge")
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(finding.title).uiFont(size: 11.5, weight: .semibold).fixedSize(horizontal: false, vertical: true)
                        Text("\(finding.severity.rawValue) · \(finding.isDefect ? "defect" : "suggestion")").uiFont(size: 10).foregroundColor(palette.textDim)
                        if !finding.detail.isEmpty { Text(finding.detail).uiFont(size: 10.5).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true) }
                        if !finding.proposal.isEmpty { Text("Better: " + finding.proposal).uiFont(size: 10.5).fixedSize(horizontal: false, vertical: true) }
                        QAFindingTriageBar(finding: finding) { state, note in archive.mark(finding.id, state, note: note) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func openViewer(at id: String) {
        let slides = record.findings.compactMap { finding -> QAViewerSlide? in
            guard let url = archive.frame(of: finding, in: record) else { return nil }
            let words = [finding.title, finding.detail, finding.proposal.isEmpty ? "" : "Better: " + finding.proposal].filter { !$0.isEmpty }.joined(separator: "\n")
            return QAViewerSlide(id: finding.id, title: finding.title, caption: words, file: url, image: { NSImage(contentsOf: url) })
        }
        QAViewer.show(title: "Run of \(record.startedAt.formatted(date: .abbreviated, time: .shortened))", palette: palette) { QAViewerBody(slides: slides, start: id) }
    }

    // MARK: What happened

    private var timeline: some View {
        DisclosureGroup("What happened (\(record.timeline.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(record.timeline, id: \.id) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(clock(entry.time)).uiFont(size: 10).foregroundColor(palette.textDim).monospacedDigit().frame(width: 38, alignment: .trailing)
                        Text(entry.text).uiFont(size: 10.5).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 4)
        }
        .uiFont(size: 11.5, weight: .semibold)
    }

    private func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// A small picture of a file, read off the main thread.
struct QAFileThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(Color.black.opacity(0.2))
            }
        }
        .frame(width: 120, height: 75)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.3)))
        .task(id: url) {
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return QAFrameComposer.thumbnail(from: data, width: 240)
            }.value
        }
    }
}
