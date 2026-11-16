import AppKit
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The feature packages exported from a session (CAP-05, CAP-06): the packages on disk, the export through the feature store, and the check
/// that marks a package whose files changed since. Owns the packages the Evidence panel lists.
@MainActor
final class StudioPackages: ObservableObject {
    /// Unowned: the session owns this part. A task of this part starts through `session.startPartTask`, which holds the session until it ends.
    unowned let session: StudioSession

    @Published private(set) var packages: [StudioPackage] = []

    init(session: StudioSession) {
        self.session = session
        packages = StudioStore.loadPackages(session.root)
    }

    // MARK: - Feature packages

    /// The operations a feature package can be made of: applied code changes and the context changes that made a scenario.
    var exportableOperations: [StudioOperation] {
        session.history.filter { [.applied, .kept].contains($0.status)
            && ($0.kind == .edit ? !$0.files.isEmpty : $0.kind == .context && $0.context?.scenarioId.isEmpty == false) }
    }

    /// Exports the chosen operations as a feature (CAP-05) through the feature store, with a package in
    /// `.markview/studio/packages/` that is revalidated when its files change later (CAP-06).
    func exportFeature(title: String, summary: String, operations ids: [String]) {
        let chosen = exportableOperations.filter { ids.contains($0.id) }
        guard !chosen.isEmpty, let store = session.featureStore() else { return }
        session.runWork("Exporting the feature") { session in
            guard let baseline = chosen.first?.baseRevision, let final = chosen.last?.finalRevision ?? chosen.last?.baseRevision else { return }
            let paths = Array(Set(chosen.flatMap { $0.files.map(\.path) })).sorted()
            let root = session.root
            let hashes = await Task.detached { StudioRevisionProbe.currentHashes(paths, root: root) }.value
            var pictures: [StudioPackage.Picture] = []
            let pictureIDs = [chosen.first?.beforeCapture, chosen.last?.afterCapture].compactMap { $0 }
            for id in pictureIDs {
                guard let capture = session.captures.first(where: { $0.id == id }) else { continue }
                let size = (try? FileManager.default.attributesOfItem(atPath: session.url(of: capture).path)[.size] as? Int) ?? 0
                pictures.append(StudioPackage.Picture(label: capture.label, captureId: capture.id, file: capture.file,
                                                      inFeature: size <= StudioPackage.inFeatureLimit, bytes: size))
            }
            let checks = chosen.flatMap(\.checks)
            let rendering = pictureIDs.compactMap { id in session.captures.first { $0.id == id }?.rendering }.last
            var package = StudioPackage(id: StudioStore.safeID(title) + "-" + String(UUID().uuidString.prefix(4)).lowercased(),
                                        featureSlug: "", title: title, summary: summary,
                                        requests: chosen.map(\.request), operations: chosen.map(\.id), scenario: session.scenario,
                                        baselineRevision: baseline, finalRevision: final, files: hashes,
                                        patch: chosen.map(\.patch).joined(), rendering: rendering, pictures: pictures, checks: checks)
            do {
                let created = try await StudioFeatureWriter.write(package, operations: chosen, root: root, redactor: session.redactor, into: store)
                package.featureSlug = created
                try StudioStore.savePackage(package, root: root)
                self.packages = StudioStore.loadPackages(root)
                session.notice = "Exported feature \(created)."
                session.featureExportDelegate?.studioDidExportFeature(created)
            } catch {
                session.notice = error.localizedDescription
            }
        }
    }

    /// Marks packages whose files changed since they were exported (CAP-06); their captures stay as history.
    func revalidatePackages() async {
        let current = packages, root = session.root
        let next = await Task.detached { current.map { $0.revalidated(root: root) } }.value
        packages = next
        let changed = zip(current, next).filter { $0.0.status != $0.1.status || $0.0.changedSince != $0.1.changedSince }.map(\.1)
        guard !changed.isEmpty else { return }
        session.io.async { for package in changed { try? StudioStore.savePackage(package, root: root) } }
    }
}
