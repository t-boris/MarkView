import Foundation

/// What a tool's own object needs to bring a tool's tab forward.
@MainActor
protocol ToolOpening: AnyObject {
    func open(_ id: ToolID)
}

/// What opening a tool does beyond showing its tab: wiring the tool's own store to the project, or building the tab of a tool that
/// carries a session. A tool that needs neither has no entry in the router's table; `ToolRegistry` describes the rest of it.
struct ToolOpener {
    /// Runs on every open, also when the tool's tab exists already.
    var prepare: (URL) -> Void = { _ in }
    /// The tab of a tool that carries a session; every other tool gets a plain `.tool` tab.
    var makeTab: ((URL, ToolDescriptor) -> OpenTab)?
    /// Runs once, after a tab built by `makeTab` was added.
    var opened: (OpenTab) -> Void = { _ in }
}
