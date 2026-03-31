import Foundation

/// Reads and manages .dde/overlays/ configuration files:
/// glossary.yaml, suppressions.yaml, policies.yaml
@MainActor
class OverlayManager: ObservableObject {
    @Published var glossaryEntries: [GlossaryEntry] = []
    @Published var suppressionRules: [SuppressionRule] = []
    @Published var privacyMode: PrivacyMode = .trustedRemote
    @Published var redactPatterns: [String] = []

    private let overlaysDir: URL
    private var fileWatcher: DispatchSourceFileSystemObject?

    init(workspacePath: URL) {
        self.overlaysDir = workspacePath.appendingPathComponent(".dde").appendingPathComponent("overlays")
        loadAll()
        startWatching()
    }

    // MARK: - Load

    func loadAll() {
        loadGlossary()
        loadSuppressions()
        loadPolicies()
    }

    private func loadGlossary() {
        let file = overlaysDir.appendingPathComponent("glossary.yaml")
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }
        // Simple YAML-like parsing (term: canonical_name)
        glossaryEntries = content.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let term = parts[0].trimmingCharacters(in: .whitespaces)
            let canonical = parts[1].trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, !canonical.isEmpty else { return nil }
            return GlossaryEntry(term: term, canonicalName: canonical, aliases: nil, entityType: nil)
        }
        NSLog("[OverlayManager] Loaded \(glossaryEntries.count) glossary entries")
    }

    private func loadSuppressions() {
        let file = overlaysDir.appendingPathComponent("suppressions.yaml")
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }
        suppressionRules = content.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let diagType = parts[0].trimmingCharacters(in: .whitespaces)
            let reason = parts[1].trimmingCharacters(in: .whitespaces)
            return SuppressionRule(diagnosticType: diagType, entityPattern: nil, reason: reason)
        }
    }

    private func loadPolicies() {
        let file = overlaysDir.appendingPathComponent("policies.yaml")
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }
        for line in content.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if key == "privacy_mode" {
                privacyMode = PrivacyMode(rawValue: value) ?? .trustedRemote
            }
        }
    }

    // MARK: - Glossary Application

    /// Apply glossary overrides to an entity name → canonical name
    func canonicalize(_ name: String) -> String {
        for entry in glossaryEntries {
            if name.lowercased() == entry.term.lowercased() {
                return entry.canonicalName
            }
        }
        return name
    }

    /// Check if a diagnostic should be suppressed
    func shouldSuppress(diagnosticType: String, entityName: String?) -> Bool {
        suppressionRules.contains { rule in
            if rule.diagnosticType != diagnosticType { return false }
            if let pattern = rule.entityPattern, let name = entityName {
                // Simple glob: "Legacy*" matches "LegacyService"
                if pattern.hasSuffix("*") {
                    return name.hasPrefix(String(pattern.dropLast()))
                }
                return name == pattern
            }
            return true // No entity pattern = suppress all of this type
        }
    }

    // MARK: - File Watching

    private func startWatching() {
        let fd = open(overlaysDir.path, O_EVTONLY)
        guard fd != -1 else { return }

        fileWatcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .all, queue: .main
        )
        fileWatcher?.setEventHandler { [weak self] in
            self?.loadAll()
        }
        fileWatcher?.setCancelHandler { close(fd) }
        fileWatcher?.resume()
    }
}

// MARK: - Overlay Data Types

struct GlossaryEntry: Codable {
    let term: String
    let canonicalName: String
    let aliases: [String]?
    let entityType: String?
}

struct SuppressionRule: Codable {
    let diagnosticType: String
    let entityPattern: String?
    let reason: String
}
