import Foundation

// Only unrelated model dependencies of SemanticDatabase.swift are replaced; the database, its schema, its migrations and
// the architecture models it stores are the shipping implementations.
enum ImportanceRater {
    struct Rating: Codable, Equatable { var level: String; var reason: String }
    static func isTemporary(_ id: String) -> Bool { id.hasPrefix("tmp-") }
}
enum ArchitectureScanner { static let maxParseBytes = 512 * 1024 }
