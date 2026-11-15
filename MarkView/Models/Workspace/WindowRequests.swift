import Foundation

/// What one window was asked to show in a sheet, a popover or an alert (`AR-14` step 6): the intake sheet, the new-project flow, the
/// definition of done, the operations console and the like. A request belongs to the window the person acted in and is never saved
/// with its session. The window view observes it; whoever makes the request only writes it.
@MainActor
final class WindowRequests: ObservableObject {
    /// The "New" intake sheet (New Feature / New Bug / I Need to Understand).
    @Published var intake: IntakeRequest?
    /// Start a Project from Scratch: a new idea, or an unfinished draft.
    @Published var newProject: NewProjectRequest?
    /// "Publish to GitHub…" for the open folder.
    @Published var gitHubPublishRequested = false
    /// The item ("feature:slug", "bug:BUG-001") whose cycle time the window should open at; the window clears it when it closes.
    @Published var cycleTimeItem: String?
    /// The definition of done to confirm before "Implement with AI" starts on this document.
    @Published var doneRequest: URL?
    /// The creator sheet of Prototype Studio, and what it makes.
    @Published var showPrototypeCreator = false
    @Published var prototypeCreatorMode = PrototypeFiles.Mode.requirements
    /// The kind of diagram the graph creator sheet opens with; nil while it is closed.
    @Published var pendingGraphCreatorType: String?
    /// A file the file tree should show ("Reveal in File Tree"); the tree browses its folder, highlights it and clears the request.
    @Published var fileTreeRevealRequest: URL?
    /// The documents the PDF book sheet offers.
    @Published var pdfBookSelection: BookPDFSelection?
    /// The specification hand-off the window offers to resume.
    @Published var handoffResume: HandoffResume?
    /// The project operations console: whether it is open and which run it selects. The store is shared by every window on the folder; these are not.
    @Published var operationConsoleVisible = false
    @Published var operationSelectedRunID: String?
    @Published var operationEditRequest: ProjectOperationEditRequest?
}
