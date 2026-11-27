import Foundation

// What an assistant driven over the Agent Client Protocol (`<cli> --acp`, `ACPAssistant`) brings besides its provider:
// how it is started and what its probe checks (its account's models: `ACPModelListing`). Foundation only.

/// How one ACP assistant is started and what it needs around the protocol.
struct ACPLaunchProfile: Sendable {
    var arguments: [String]
    /// Session mode that keeps the assistant read-only, set after `session/new`.
    var readOnlyMode: String?
    /// A chunk the CLI puts into the answer that is not part of it.
    var noticePrefix: String?
}

/// What the Settings probe checks for an ACP assistant.
struct ACPProbeProfile: Sendable {
    /// Older majors are refused with `installCommand` as the way to update.
    let minimumMajorVersion: Int
    let installCommand: String
    /// Said when the CLI exits quietly with no output (Cline: macOS kills its binary when the signature is broken).
    let silentExitMessage: String?
    /// The account lists its models only when signed in, so a non-empty list proves it.
    let modelListImpliesSignedIn: Bool
}

protocol AssistantACPSupport: Sendable {
    /// How the assistant starts `--acp`; `effort` is the reasoning level of the request, if any.
    func launchProfile(effort: String?) -> ACPLaunchProfile
    var probe: ACPProbeProfile { get }
    /// What to tell the user when macOS kills the process with SIGKILL right after the start, or nil.
    var killedMessage: String? { get }
}

extension AssistantACPSupport {
    var killedMessage: String? { nil }
}
