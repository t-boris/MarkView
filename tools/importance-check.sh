#!/bin/bash
# Test cases for the Importance overlay: rate the sections of the fixture documents in
# Tests/Fixtures/importance with each AI CLI and compare with expected.json.
#   tools/importance-check.sh            # both CLIs
#   tools/importance-check.sh claude     # one CLI
#   tools/importance-check.sh codex gpt-5.5   # one CLI with a specific model
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# FileType and the CLI tool helpers come from app sources; SemanticDatabase is stubbed.
python3 - "$WORK" <<'PY'
import sys
work = sys.argv[1]
src = open('MarkView/Models/DocumentState.swift').read()
i = src.index('/// Supported file types for viewing/editing'); j = src.index('/// Represents a table of contents heading entry')
open(f'{work}/FileType.swift', 'w').write('import Foundation\n' + src[i:j])
eng = open('MarkView/Models/AIConsoleEngine.swift').read()
open(f'{work}/Tools.swift', 'w').write('import Foundation\nimport AppKit\n' + eng[eng.index('// MARK: - CLI Tool Discovery'):])
open(f'{work}/Stub.swift', 'w').write('import Foundation\n@MainActor final class SemanticDatabase { func addUsage(inputTokens: Int, outputTokens: Int, costCents: Double) {} }\n')
PY
cat > "$WORK/check.swift" <<'SWIFT'
import Foundation
@main struct Check { static func main() async {
    let fixtures = URL(fileURLWithPath: "Tests/Fixtures/importance")
    let expected = try! JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("expected.json"))) as! [String: [String: [String]]]
    let tools: [CLITool] = CommandLine.arguments.count > 1 ? [CLITool(rawValue: CommandLine.arguments[1])!] : [.claude, .codex]
    var failures = 0
    for tool in tools {
        for (file, want) in expected.sorted(by: { $0.key < $1.key }) {
            let text = try! String(contentsOf: fixtures.appendingPathComponent(file), encoding: .utf8)
            let sections = ArchitectureScanner.sections(of: text).filter { $0.line > 1 }
            let items = sections.map { ImportanceRater.Item(key: "s\($0.line)", label: $0.title,
                                                            detail: ImportanceRater.sectionText(text, fromLine: $0.line)) }
            var request = ImportanceRater.request(subject: .documentation, context: "Document: \(file)", items: items, readableFolder: nil)
            request.tool = tool
            if CommandLine.arguments.count > 2 { request.model = CommandLine.arguments[2] }
            do {
                let result = try await CLICompletion.run(request)
                let ratings = ImportanceRater.parse(result.structured, keys: Set(items.map(\.key)))
                for (item, section) in zip(items, sections) {
                    let got = ratings[item.key]?.level ?? "missing"
                    let ok = want[section.title]?.contains(got) ?? false
                    if !ok { failures += 1 }
                    print("\(ok ? "PASS" : "FAIL") [\(tool.rawValue)] \(file) › \(section.title): \(got) (want \(want[section.title] ?? []))")
                }
            } catch {
                failures += 1
                print("FAIL [\(tool.rawValue)] \(file): \(error.localizedDescription)")
            }
        }
    }
    // A user-defined filter (template: Importance) on the same document.
    let payments = ImportanceRater.customFilter(name: "Payment safety",
        criterion: "How much is this about preventing duplicate or unauthorized payments?")
    let wantCustom: [String: [String]] = [
        "Authentication and key rotation": ["strong", "moderate"],
        "Idempotency": ["strong"],
        "History of the API": ["none", "weak"],
        "TODO": ["none", "weak"],
    ]
    for tool in tools {
        let text = try! String(contentsOf: fixtures.appendingPathComponent("api-design.md"), encoding: .utf8)
        let sections = ArchitectureScanner.sections(of: text).filter { $0.line > 1 }
        let items = sections.map { ImportanceRater.Item(key: "s\($0.line)", label: $0.title,
                                                        detail: ImportanceRater.sectionText(text, fromLine: $0.line)) }
        var request = ImportanceRater.request(subject: .documentation, filter: payments, context: "Document: api-design.md",
                                              items: items, readableFolder: nil)
        request.tool = tool
        if CommandLine.arguments.count > 2 { request.model = CommandLine.arguments[2] }
        do {
            let result = try await CLICompletion.run(request)
            let ratings = ImportanceRater.parse(result.structured, keys: Set(items.map(\.key)), filter: payments)
            for (item, section) in zip(items, sections) {
                guard let want = wantCustom[section.title] else { continue }
                let got = ratings[item.key]?.level ?? "missing"
                let ok = want.contains(got)
                if !ok { failures += 1 }
                print("\(ok ? "PASS" : "FAIL") [\(tool.rawValue)] filter \"\(payments.name)\" › \(section.title): \(got) (want \(want))")
            }
        } catch {
            failures += 1
            print("FAIL [\(tool.rawValue)] custom filter: \(error.localizedDescription)")
        }
    }
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}}
SWIFT
swiftc -O -parse-as-library -o "$WORK/check" "$WORK/FileType.swift" "$WORK/Tools.swift" "$WORK/Stub.swift" \
    MarkView/Models/CLICompletion.swift MarkView/Models/ArchitectureModel.swift MarkView/Models/ArchitectureScanner.swift \
    MarkView/Models/ImportanceRater.swift "$WORK/check.swift"
"$WORK/check" "$@"
