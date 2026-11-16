import AppKit
import Foundation

// Compile-time stand-ins for what the tools' hosts and the router hold but the checks do not exercise: the sessions a tab can carry
// (they replace TabsControllerStubs.swift, with the classes the hosts build), the QA model and Feature store the router wires, the
// Cockpit's window contract, the assistant and its usage record, and Prototype Studio's files. The shipping router, hosts, tabs
// controller, panels, deployment store and discussion store run unchanged beside them.
struct InsightSession {
    let id = UUID()
    func cancel() async {}
}
struct BrowserSession {
    var url: URL?
    func close() {}
}

@MainActor
final class PrototypeSession {
    let id = UUID()
    let slug: String
    let folder: URL
    let manifest: PrototypeFiles.Manifest
    var codeScope = PrototypeAI.CodeScope()
    var record: PrototypeAI.Record = { _ in }
    var languageNote = ""
    init(root: URL, title: String, brief: String, sources: [String], mode: PrototypeFiles.Mode = .requirements) {
        slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
        folder = PrototypeFiles.folder(root: root, slug: slug)
        manifest = PrototypeFiles.Manifest(title: title, slug: slug, brief: brief, sources: sources, mode: mode)
    }
    init?(root: URL, slug: String) {
        guard let manifest = PrototypeFiles.loadManifest(PrototypeFiles.folder(root: root, slug: slug)) else { return nil }
        self.slug = slug
        folder = PrototypeFiles.folder(root: root, slug: slug)
        self.manifest = manifest
    }
}
enum PrototypeAI {
    typealias Record = @MainActor @Sendable (CLICompletion.Result) -> Void
    struct CodeScope: Sendable, Equatable { var apps: [String] = [] }
}

@MainActor protocol StudioWindowServices: AnyObject, Sendable {
    func studioEditorBuffers(root: URL) -> [String: String]
    func studioRecordUsage(_ input: Int, _ output: Int, _ cost: Double)
    func studioOpenFile(_ url: URL)
    func studioFeatureStore() -> FeatureStore?
    func studioDidExportFeature(_ slug: String)
}

@MainActor
final class StudioSession {
    let id = UUID()
    let root: URL
    weak var windowServices: (any StudioWindowServices)?
    func editorBuffers() -> [String: String] { windowServices?.studioEditorBuffers(root: root) ?? [:] }
    func recordUsage(_ input: Int, _ output: Int, _ cost: Double) { windowServices?.studioRecordUsage(input, output, cost) }
    func openFile(_ url: URL) { windowServices?.studioOpenFile(url) }
    func featureStore() -> FeatureStore? { windowServices?.studioFeatureStore() }
    private(set) var started = false
    init(root: URL) { self.root = root }
    func start() { started = true }
    func close() async {}
}

@MainActor
final class CockpitExecution { var isActive = false }

@MainActor
final class CockpitSession {
    let root: URL
    var execution: CockpitExecution?
    private(set) var runsLoaded = 0
    private(set) var projectClosed = false
    init(root: URL, workspace: any CockpitWindow) { self.root = root }
    func loadRuns() { runsLoaded += 1 }
    func closeProject() { projectClosed = true }
    func cancel() {}
}

@MainActor
protocol CockpitQAWindow: AnyObject {
    var qa: QAModel { get }
    func showQATool()
}

@MainActor
protocol CockpitWindow: CockpitQAWindow {
    var hostWindow: NSWindow? { get }
    func showAIConsole()
    var assistants: any AssistantProviding { get }
    var features: FeatureStore { get }
    var cockpitTabIsActive: Bool { get }
    func showCockpitTool()
    func openFile(_ url: URL)
}

@MainActor
final class FeatureStore {}

protocol QABugSink {}
struct QAFeatureStoreBugSink: QABugSink { init(store: FeatureStore) {} }
final class QABugFiler { init(sink: any QABugSink) {} }

protocol QARunLinks: Sendable {}
struct CockpitRunLinks: QARunLinks {}

@MainActor
final class QARunSlot { var bugFiler: QABugFiler?; var runLinks: (any QARunLinks)? }

@MainActor
final class QAModel {
    weak var assistants: (any AssistantProviding)?
    let run = QARunSlot()
    let archive = QARunSlot()
    private(set) var attachedRoot: URL?
    func attach(root: URL?) { attachedRoot = root }
}

@MainActor
final class WorkflowEditorModel {}

@MainActor
final class WindowRequests {
    var showPrototypeCreator = false
    var prototypeCreatorMode: PrototypeFiles.Mode = .requirements
}

actor SemanticDatabase {
    private(set) var usage: [(input: Int, output: Int, cents: Double)] = []
    func addUsage(inputTokens: Int, outputTokens: Int, costCents: Double) {
        usage.append((inputTokens, outputTokens, costCents))
    }
}

@MainActor
final class TerminalSession: Identifiable {
    let id = UUID()
}
enum TerminalProfile { case shell }

enum CompletionActivity: Sendable {
    case read(String), search(String), run(String), webSearch(String), webFetch(String), thinking, writing(Int), answerDelta(String)
}

enum CLICompletion {
    struct Assistant {}

    struct Request {
        let project: URL?
        var prompt: String
        var systemPrompt: String? = nil
        var readableFolder: URL? = nil
        var extraReadableFolders: [URL] = []
        var effort: String? = nil
        var timeout: TimeInterval? = 180
        var label = ""
    }

    struct Result {
        var text = ""
        var structured: Any?
        var costUSD: Double?
        func record(in db: SemanticDatabase?) {}
    }

    typealias Activity = CompletionActivity

    static func run(_ request: Request, onDelta: (@Sendable (String) -> Void)? = nil,
                    onActivity: (@Sendable (Activity) -> Void)? = nil) async throws -> Result {
        fatalError("These checks inject their own runner")
    }
}
