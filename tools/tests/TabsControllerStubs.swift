import Foundation

// Collaborators of `OpenTab` and `TabsController` that the tab checks do not exercise: the sessions a tab can carry. They stand in for the
// app's own types, which belong to features of their own (Insight, the browser, Prototype Studio, UI Studio, the Cockpit).
struct InsightSession {
    let id = UUID()
    func cancel() async {}
}
struct SemanticBlock {}
struct BlockCompilationState {}
struct BrowserSession {
    var url: URL?
    func close() {}
}
struct PrototypeSession { let slug: String }
struct StudioSession { func close() async {} }
struct CockpitSession { func cancel() {} }
enum Archive { static func isArchive(_ url: URL) -> Bool { false } }
