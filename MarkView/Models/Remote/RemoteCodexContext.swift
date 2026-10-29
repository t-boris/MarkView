import Foundation
import CryptoKit

/// Resuming a CLI thread does not replace its saved developer messages. Refresh the remote
/// boundary through Codex's app-server API before handing that same thread to the terminal.
/// No model turn runs here, and Codex's session files are never edited directly.
enum RemoteCodexContext {
    static func prepare(executable: String, directory: URL, context: RemoteJSON) async throws -> String? {
        let requestedPath = directory.path
        let directory = directory.resolvingSymlinksInPath()
        let client = try Client(executable: executable, directory: directory)
        do {
            _ = try await client.call("initialize", .object([
                "clientInfo": .object(["name": .string("markview_remote_context"), "version": .string("1")]),
                "capabilities": .object(["experimentalApi": .bool(true)])]))
            try client.notify("initialized", .object([:]))
            let list = try await client.call("thread/list", .object([
                "cwd": .array(Array(Set([directory.path, requestedPath])).sorted().map(RemoteJSON.string)),
                "limit": .int(1), "sortKey": .string("updated_at"), "sortDirection": .string("desc"),
                "modelProviders": .array([]),
                "sourceKinds": .array(["cli", "exec", "appServer"].map(RemoteJSON.string))]))
            guard let rows = list["data"].array else { throw failure() }
            guard let thread = rows.first else { await client.close(); return nil }
            guard let id = thread["id"].string, UUID(uuidString: id) != nil,
                  let cwd = thread["cwd"].string,
                  URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == directory else { throw failure() }
            let instructions = try RemoteProviderConfiguration.instructions(context: context)
            let signature = SHA256.hash(data: Data(instructions.utf8)).map { String(format: "%02x", $0) }.joined()
            let stamp = directory.appendingPathComponent("codex-context.json")
            let previous = (try? Data(contentsOf: stamp)).flatMap { try? JSONDecoder().decode(RemoteJSON.self, from: $0) }
            if previous?["thread"].string != id || previous?["signature"].string != signature {
                _ = try await client.call("thread/resume", .object([
                    "threadId": .string(id), "cwd": .string(directory.path), "excludeTurns": .bool(true),
                    "sandbox": .string("read-only"), "approvalPolicy": .string("never"),
                    "config": .object(["mcp_servers": .object([:])])]))
                _ = try await client.call("thread/inject_items", .object([
                    "threadId": .string(id), "items": .array([.object([
                        "type": .string("message"), "role": .string("developer"),
                        "content": .array([.object(["type": .string("input_text"), "text": .string(instructions)])])])])]))
                let data = try JSONEncoder().encode(RemoteJSON.object(["thread": .string(id), "signature": .string(signature)]))
                try data.write(to: stamp, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stamp.path)
            }
            await client.close()
            return id
        } catch {
            await client.close()
            if error is CancellationError { throw error }
            // Do not expose provider responses: they can contain document previews and login data.
            throw failure()
        }
    }

    private static func failure() -> RemoteFailure {
        .invalid("Could not refresh the saved Codex conversation. Update Codex on the home computer and reconnect.")
    }

    private final class Client {
        private let command: RemoteCommand
        private var nextID = 0
        private var pending = Data()

        init(executable: String, directory: URL) throws {
            let args = [executable, "-c", "mcp_servers={}", "-c", "features.plugins=false", "-c", "features.apps=false", "app-server", "--stdio"]
            command = try RemoteCommand(command: args.map(RemoteProviderConfiguration.quote).joined(separator: " ") + " 2>/dev/null", directory: directory)
        }

        func notify(_ method: String, _ params: RemoteJSON) throws {
            try send(.object(["method": .string(method), "params": params]))
        }

        private func send(_ request: RemoteJSON) throws {
            let data = try JSONEncoder().encode(request)
            var text = String(decoding: data, as: UTF8.self) + "\n"
            // WORK instructions can include two 32 KB project guides. Queue bounded UTF-8 chunks
            // without splitting a character or exceeding RemoteCommand's input limit.
            while !text.isEmpty {
                let chunk = String(text.prefix(8192))
                try command.write(chunk)
                text.removeFirst(chunk.count)
            }
        }

        func call(_ method: String, _ params: RemoteJSON) async throws -> RemoteJSON {
            nextID += 1
            let id = nextID
            try send(.object(["id": .int(id), "method": .string(method), "params": params]))
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                try Task.checkCancellation()
                let snapshot = command.takeOutput()
                pending.append(contentsOf: snapshot.output.utf8)
                guard pending.count < 2 * 1024 * 1024 else { throw failure() }
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending.prefix(upTo: newline)
                    let event = try JSONDecoder().decode(RemoteJSON.self, from: line)
                    pending.removeSubrange(...newline)
                    guard event["id"].integer == id else { continue }
                    guard event["error"] == .null, event["result"] != .null else { throw failure() }
                    return event["result"]
                }
                guard snapshot.exitCode == nil else { throw failure() }
                await command.wait(milliseconds: 20)
            }
            throw failure()
        }

        func close() async {
            command.closeInput()
            await command.wait(milliseconds: 1000)
            if command.takeOutput().exitCode == nil {
                command.stop()
                await command.wait(milliseconds: 2500)
            }
        }
    }
}
