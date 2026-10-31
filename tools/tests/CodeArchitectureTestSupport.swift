import Foundation

// Only unrelated model dependencies are replaced; architecture and diagram models
// and builders in this harness are the shipping implementations.
enum ImportanceRater { struct Rating: Codable { var level: String; var reason: String } }
enum ArchitectureScanner { static let maxParseBytes = 512 * 1024 }
