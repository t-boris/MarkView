import Foundation
import Combine

/// One of the eight project colors (feature-2, DEC-009). Values are sRGB, readable on the light and
/// the dark window chrome. No UI frameworks, so tools/tests/project-color-tests.sh compiles it alone.
struct ProjectColor: Equatable, Identifiable {
    let id: String
    let name: String
    let red: Double
    let green: Double
    let blue: Double

    static let palette: [ProjectColor] = [
        ProjectColor(id: "red", name: "Red", hex: 0xE5484D),
        ProjectColor(id: "orange", name: "Orange", hex: 0xF76B15),
        ProjectColor(id: "yellow", name: "Yellow", hex: 0xF5C518),
        ProjectColor(id: "green", name: "Green", hex: 0x30A46C),
        ProjectColor(id: "teal", name: "Teal", hex: 0x12A594),
        ProjectColor(id: "blue", name: "Blue", hex: 0x3E63DD),
        ProjectColor(id: "purple", name: "Purple", hex: 0x8E4EC6),
        ProjectColor(id: "pink", name: "Pink", hex: 0xD6409F),
    ]

    private init(id: String, name: String, hex: UInt32) {
        self.id = id
        self.name = name
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    static func withID(_ id: String) -> ProjectColor? { palette.first { $0.id == id } }

    /// A project is its folder's standardized path after resolving symbolic links (DEC-008):
    /// same-named folders stay different projects; a moved or renamed folder is a new one.
    static func projectKey(for folder: URL) -> String {
        folder.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The automatic color: a stable hash (FNV-1a 64 over the key's UTF-8, unlike `hashValue`,
    /// which changes every launch) into the palette. Different projects may share a color.
    static func automatic(forKey key: String) -> ProjectColor {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// Every project's color, shared by all windows so a change shows in each window of that project
/// at once (DEC-010). Kept in local MarkView settings, never in the project folder (DEC-008).
@MainActor
final class ProjectColorStore: ObservableObject {
    static let shared = ProjectColorStore()
    static let defaultsKey = "project.colors"

    /// Project key → palette id, for automatic assignments and user choices alike.
    @Published private(set) var assignments: [String: String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        assignments = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    /// The saved color, else the automatic one. Reading never writes, so views may call it.
    func color(forKey key: String) -> ProjectColor {
        assignments[key].flatMap(ProjectColor.withID) ?? ProjectColor.automatic(forKey: key)
    }

    /// Saves the automatic color the first time a project is shown, so it stays fixed (DEC-009).
    func assignIfNeeded(key: String) {
        guard assignments[key].flatMap(ProjectColor.withID) == nil else { return }
        set(ProjectColor.automatic(forKey: key), forKey: key)
    }

    func set(_ color: ProjectColor, forKey key: String) {
        guard assignments[key] != color.id else { return }
        assignments[key] = color.id
        defaults.set(assignments, forKey: Self.defaultsKey)
    }
}
