import Foundation
import ObjectiveC

// The welcome screen's backdrops as a registry (architecture review AR-34, DEC-001). A backdrop is one class, in the file that draws
// it, that conforms to `BackdropRegistration` and says what it is (`BackdropDescriptor`): its stored name, title, symbol, place in the
// picker, whether Shuffle may pick it and when By Project would. The picker, Shuffle, By Project and the layer builder all read this
// registry, so adding a backdrop is adding that one class: there is no enum case, title switch, symbol switch, list or dispatch to
// edit. Nothing is loaded from outside the app: the registry finds the registration classes that were compiled into the app (code
// that ships with it, not a plug-in).
//
// Foundation only. The registrations of the scenes are in `Views/Appearance/*BackdropLayers.swift` (they conform to `BackdropDrawing`
// there, which adds the drawing); the modes (By Project, Shuffle, Off) are registered in `WelcomeBackdrop.swift`. A program that
// compiles only some of those files sees only the backdrops in them.

/// What a backdrop is, for everything that lists or chooses backdrops.
struct BackdropDescriptor: Sendable {
    /// A scene is drawn; a mode chooses what is drawn (By Project, Shuffle) or draws nothing (Off).
    enum Category: Int, Sendable { case scene, mode }

    /// When By Project (`ProjectBackdropContext.scene`) draws this scene for a project.
    struct ProjectRule: Sendable {
        /// Rules are tried from the lowest number; the first one that matches draws its scene.
        let priority: Int
        /// nil: the scene a project gets when no other rule matches, and a window without a project (it has no evidence at all).
        let matches: (@Sendable (ProjectBackdropContext) -> Bool)?
        /// Why the scene was chosen, as the sentence the screen shows.
        let reason: @Sendable (ProjectBackdropContext) -> String
    }

    /// The name a window stores for its choice; it never changes once a build has shipped.
    let id: String
    let title: String
    let symbol: String
    /// Position in the picker and in Shuffle's pool: the scenes by this number, then the modes.
    let order: Int
    let category: Category
    /// Shuffle picks from the scenes that are animated.
    let animated: Bool
    let project: ProjectRule?

    static func scene(_ id: String, title: String, symbol: String, order: Int, animated: Bool = true, project: ProjectRule? = nil) -> BackdropDescriptor {
        BackdropDescriptor(id: id, title: title, symbol: symbol, order: order, category: .scene, animated: animated, project: project)
    }

    static func mode(_ id: String, title: String, symbol: String, order: Int) -> BackdropDescriptor {
        BackdropDescriptor(id: id, title: title, symbol: symbol, order: order, category: .mode, animated: false, project: nil)
    }
}

/// A class that registers a backdrop; the registry finds it. It must be a class, because the registry finds registrations through the
/// Objective-C runtime's list of the classes in the app.
protocol BackdropRegistration: Sendable {
    static var descriptor: BackdropDescriptor { get }
}

enum BackdropRegistry {
    struct Entry: Sendable {
        let descriptor: BackdropDescriptor
        let type: any BackdropRegistration.Type
    }

    /// Every registered backdrop in picker order: the scenes by `order`, then the modes by `order`.
    static let entries: [Entry] = discover()
        .map { Entry(descriptor: $0.descriptor, type: $0) }
        .sorted { ($0.descriptor.category.rawValue, $0.descriptor.order, $0.descriptor.id) < ($1.descriptor.category.rawValue, $1.descriptor.order, $1.descriptor.id) }

    static func entry(_ id: String) -> Entry? { entries.first { $0.descriptor.id == id } }

    /// The scenes Shuffle draws from.
    static var shufflePool: [Entry] { entries.filter { $0.descriptor.category == .scene && $0.descriptor.animated } }

    /// The scenes By Project can draw, in the order their rules are tried.
    static var projectRules: [Entry] {
        entries.filter { $0.descriptor.project != nil }
            .sorted { ($0.descriptor.project?.priority ?? 0, $0.descriptor.id) < ($1.descriptor.project?.priority ?? 0, $1.descriptor.id) }
    }

    /// The scene a project gets when no rule matches: the first one that states no condition.
    static var projectDefault: Entry? { projectRules.first { $0.descriptor.project?.matches == nil } }

    // MARK: Finding the registrations

    /// The registration classes compiled into the same image as this registry: the Objective-C runtime lists every class of an image,
    /// and those that conform to `BackdropRegistration` are the registrations. It runs once, when the first backdrop is asked for.
    private static func discover() -> [any BackdropRegistration.Type] {
        guard let image = class_getImageName(Anchor.self) else { return [] }
        var count: UInt32 = 0
        guard let names = objc_copyClassNamesForImage(image, &count) else { return [] }
        defer { free(names) }
        var found: [any BackdropRegistration.Type] = []
        for index in 0..<Int(count) {
            if let type = NSClassFromString(String(cString: names[index])) as? any BackdropRegistration.Type { found.append(type) }
        }
        return found
    }

    /// Names the image to list: any class of the app's code would do.
    private final class Anchor {}
}
