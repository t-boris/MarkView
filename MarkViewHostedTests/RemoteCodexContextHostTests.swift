import Foundation
import XCTest
@testable import MarkView

private enum RemoteCodexContextChecks {
    static let threadID = "11111111-1111-4111-8111-111111111111"

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-codex-context-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executableURL = root.appendingPathComponent("fixture-server")
        let server = #"""
        #!/usr/bin/python3
        import json, os, sys
        with open("fixture.json", encoding="utf-8") as f:
            mode = f.read()
        with open("audit.jsonl", "a", encoding="utf-8") as audit:
            for line in sys.stdin:
                audit.write(line)
                audit.flush()
                request = json.loads(line)
                if "id" not in request:
                    continue
                if mode == "exit":
                    break
                if mode == "malformed":
                    print("not-json", flush=True)
                    break
                result = {}
                if request.get("method") == "thread/list":
                    data = [] if mode == "empty" else [{"id": "11111111-1111-4111-8111-111111111111", "cwd": "/unrelated-project" if mode == "wrong-cwd" else os.getcwd()}]
                    result = {"data": data}
                response = {"id": request["id"], "error": {"message": "SENSITIVE provider details"}} if mode == "error" else {"id": request["id"], "result": result}
                encoded = json.dumps(response, ensure_ascii=False).encode("utf-8")
                sys.stdout.buffer.write(b'{"method":"notice"}\n')
                sys.stdout.buffer.write(encoded[:5]); sys.stdout.buffer.flush()
                sys.stdout.buffer.write(encoded[5:] + b'\n'); sys.stdout.buffer.flush()
        """#
        try server.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
        let executable = executableURL.path
        let audit = root.appendingPathComponent("audit.jsonl")
        let fixture = root.appendingPathComponent("fixture.json")
        func mode(_ text: String) throws { try Data(text.utf8).write(to: fixture) }
        func calls() throws -> [RemoteJSON] {
            guard FileManager.default.fileExists(atPath: audit.path) else { return [] }
            return try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map {
                try JSONDecoder().decode(RemoteJSON.self, from: Data($0.utf8))
            }
        }
        let context: RemoteJSON = .object(["cwd": .string("/work/project"), "hostname": .string("work-mac")])
        try mode("empty")
        let empty = try await RemoteCodexContext.prepare(executable: executable, directory: root, context: context)
        XCTAssertTrue(empty == nil, "No saved thread must start a fresh conversation.")
        try mode("normal")
        let resumed = try await RemoteCodexContext.prepare(executable: executable, directory: root, context: context)
        XCTAssertTrue(resumed == threadID)
        var events = try calls()
        let injection = events.first { $0["method"].string == "thread/inject_items" }!
        XCTAssertTrue(injection["params"]["threadId"].string == threadID)
        let message = injection["params"]["items"].array!.first!
        XCTAssertTrue(message["role"].string == "developer")
        let instructions = try RemoteProviderConfiguration.instructions(context: context)
        XCTAssertTrue(message["content"].array!.first!["text"].string == instructions)
        XCTAssertTrue(events.allSatisfy { $0["method"].string != "turn/start" }, "Context refresh must never generate a model turn.")
        let resume = events.first { $0["method"].string == "thread/resume" }!
        XCTAssertTrue(resume["params"]["sandbox"].string == "read-only" && resume["params"]["approvalPolicy"].string == "never")
        let stamp = root.appendingPathComponent("codex-context.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: stamp.path)
        XCTAssertTrue((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        _ = try await RemoteCodexContext.prepare(executable: executable, directory: root, context: context)
        events = try calls()
        XCTAssertTrue(events.filter { $0["method"].string == "thread/inject_items" }.count == 1,
                     "Reconnects must not repeatedly append identical instructions.")
        _ = try await RemoteCodexContext.prepare(executable: executable, directory: root, context: .object(["cwd": .string("/work/changed")]))
        events = try calls()
        XCTAssertTrue(events.filter { $0["method"].string == "thread/inject_items" }.count == 2)
        _ = try await RemoteCodexContext.prepare(executable: executable, directory: root,
            context: .object(["instructions": .string(String(repeating: "policy é\n", count: 12000))]))
        events = try calls()
        XCTAssertTrue(events.filter { $0["method"].string == "thread/inject_items" }.count == 3)
        for bad in ["error", "malformed", "exit", "wrong-cwd"] {
            try mode(bad)
            do {
                _ = try await RemoteCodexContext.prepare(executable: executable, directory: root, context: .null)
                XCTFail("Invalid app-server responses must fail before terminal startup.")
            } catch {
                XCTAssertTrue(!error.localizedDescription.contains("SENSITIVE"), "Provider errors must not leak previews or credentials.")
            }
        }
    }

}

extension EditorHostTests {
    func testRemoteCodexContextProtocol() async throws { try await RemoteCodexContextChecks.run() }
}
