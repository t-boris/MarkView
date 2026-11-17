import Foundation
import XCTest
@testable import MarkView

/// Reads the shipping feature files afresh for UI Studio's export and tracking assertions.
@MainActor
extension FeatureStore {
    struct Written {
        let slug: String
        let object: FeatureObject
        var id: String { object.id }
        var kind: FeatureObjectKind { object.kind }
        var title: String { object.title }
        var front: FrontMatter { object.front }
        var body: String { object.body }
    }

    private var inspectedFeatures: [Feature] {
        guard let folder = featuresFolder else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { Feature.load(folder: $0) }
    }

    var objects: [Written] {
        inspectedFeatures.flatMap { feature in
            feature.objects.values.flatMap { items in items.map { Written(slug: feature.slug, object: $0) } }
        }
    }

    var overviews: [String: (front: FrontMatter, body: String)] {
        Dictionary(uniqueKeysWithValues: inspectedFeatures.map { ($0.slug, (front: $0.front, body: $0.overviewBody)) })
    }

    var bugFiles: [URL] {
        guard let folder = bugsFolder else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var testTransitions: [TransitionRecord] {
        guard let root else { return [] }
        return (try? FileTransitionStorage(projectRoot: root).load()) ?? []
    }
}

final class UIStudioFeatureInspectionTests: XCTestCase {
    @MainActor func testReadsRealFeatureFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-studio-feature-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FeatureStore()
        store.setup(root: root)
        defer { store.reset() }
        let slug = try XCTUnwrap(store.createFeature(title: "Fixture feature", idea: "Example"))
        let item = try XCTUnwrap(store.create(.requirement, in: slug, title: "Fixture requirement", body: "Real file body", provenance: "Test"))
        XCTAssertEqual(store.overviews[slug]?.front.string("title"), "Fixture feature")
        XCTAssertTrue(store.objects.contains { $0.slug == slug && $0.id == item.id && $0.kind == .requirement && $0.body.contains("Real file body") })
        XCTAssertTrue(store.bugFiles.isEmpty)
    }
}
