import Foundation

@main enum RemoteCodexContextTests {
    static let threadID = "11111111-1111-4111-8111-111111111111"

    static func main() async throws {
        if CommandLine.arguments.contains("app-server") { try serve(); return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-codex-context-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
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
        precondition(empty == nil, "No saved thread must start a fresh conversation.")
        try mode("normal")
        let resumed = try await RemoteCodexContext.prepare(executable: executable, directory: root, context: context)
        precondition(resumed == threadID)
        var events = try calls()
        let injection = events.first { $0["method"].string == "thread/inject_items" }!
        precondition(injection["params"]["threadId"].string == threadID)
        let message = injection["params"]["items"].array!.first!
        precondition(message["role"].string == "developer")
        let instructions = try RemoteProviderConfiguration.instructions(context: context)
        precondition(message["content"].array!.first!["text"].string == instructions)
        precondition(events.allSatisfy { $0["method"].string != "turn/start" }, "Context refresh must never generate a model turn.")
        let resume = events.first { $0["method"].string == "thread/resume" }!
        precondition(resume["params"]["sandbox"].string == "read-only" && resume["params"]["approvalPolicy"].string == "never")
        let stamp = root.appendingPathComponent("codex-context.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: stamp.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        _ = try await RemoteCodexContext.prepare(executable: executable, directory: root, context: context)
        events = try calls()
        precondition(events.filter { $0["method"].string == "thread/inject_items" }.count == 1,
                     "Reconnects must not repeatedly append identical instructions.")
        _ = try await RemoteCodexContext.prepare(executable: executable, directory: root, context: .object(["cwd": .string("/work/changed")]))
        events = try calls()
        precondition(events.filter { $0["method"].string == "thread/inject_items" }.count == 2)
        _ = try await RemoteCodexContext.prepare(executable: executable, directory: root,
            context: .object(["instructions": .string(String(repeating: "policy é\n", count: 12000))]))
        events = try calls()
        precondition(events.filter { $0["method"].string == "thread/inject_items" }.count == 3)
        for bad in ["error", "malformed", "exit", "wrong-cwd"] {
            try mode(bad)
            do {
                _ = try await RemoteCodexContext.prepare(executable: executable, directory: root, context: .null)
                preconditionFailure("Invalid app-server responses must fail before terminal startup.")
            } catch {
                precondition(!error.localizedDescription.contains("SENSITIVE"), "Provider errors must not leak previews or credentials.")
            }
        }
        print("Remote Codex context: new/saved threads, injection, deduplication, changes, native isolation and protocol failures passed.")
    }

    /// Act as a fragmented stdio app-server, including notifications between responses.
    private static func serve() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let mode = try String(contentsOf: root.appendingPathComponent("fixture.json"), encoding: .utf8)
        let audit = root.appendingPathComponent("audit.jsonl")
        if !FileManager.default.fileExists(atPath: audit.path) { FileManager.default.createFile(atPath: audit.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: audit)
        defer { try? handle.close() }
        while let line = readLine() {
            try handle.seekToEnd(); try handle.write(contentsOf: Data((line + "\n").utf8))
            let request = try JSONDecoder().decode(RemoteJSON.self, from: Data(line.utf8))
            guard let id = request["id"].integer else { continue }
            if mode == "exit" { return }
            if mode == "malformed" { print("not-json"); fflush(stdout); return }
            let result: RemoteJSON
            switch request["method"].string {
            case "thread/list": result = .object(["data": .array(mode == "empty" ? [] : [.object([
                "id": .string(threadID), "cwd": .string(mode == "wrong-cwd" ? "/unrelated-project" : root.path)])])])
            default: result = .object([:])
            }
            let response: RemoteJSON = mode == "error"
                ? .object(["id": .int(id), "error": .object(["message": .string("SENSITIVE provider details")])])
                : .object(["id": .int(id), "result": result])
            let data = try JSONEncoder().encode(response)
            FileHandle.standardOutput.write(Data("{\"method\":\"notice\"}\n".utf8))
            FileHandle.standardOutput.write(data.prefix(5))
            FileHandle.standardOutput.write(data.dropFirst(5) + Data([10]))
        }
    }
}
