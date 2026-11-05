import Foundation
// Compile-time stand-in for CodeArchitecture (see diagram-tests.sh): DiagramAI.plainMermaid hands the sequence kind to it.
enum CodeArchitecture {
    static func sequenceMermaid(_ spec: DiagramSpec) -> String { "sequenceDiagram" }
}
