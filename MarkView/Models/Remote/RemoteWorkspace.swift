import Foundation

/// Owns the selected work-computer folder and its command sessions. No provider or network code
/// belongs here. File tools reject traversal and symlink escapes; shell commands deliberately have
/// the same user permissions as an ordinary local agent terminal.
actor RemoteWorkspace {
    private static let persistentDeviceID: String = {
        let defaults = UserDefaults.standard, key = "remote.deviceID"
        if let value = defaults.string(forKey: key), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString
        defaults.set(value, forKey: key)
        return value
    }()
    let root: URL
    private let deviceID: String
    private var commands: [String: RemoteCommand] = [:]
    private var results: [UUID: RemoteJSON] = [:]
    private var resultSizes: [UUID: Int] = [:]
    private var resultOrder: [UUID] = []
    private var resultHead = 0
    private var resultBytes = 0
    private let resultCacheBytes: Int
    private var seen: Set<UUID> = []
    private var inFlight: [UUID: Task<RemoteJSON, Never>] = [:]
    private var closed = false
    private let browserCall: (@Sendable (String, RemoteJSON) async -> RemoteJSON)?

    init(root: URL, deviceID: String? = nil, resultCacheBytes: Int = 32 * 1024 * 1024,
         browserCall: (@Sendable (String, RemoteJSON) async -> RemoteJSON)? = nil) async throws {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
            throw RemoteFailure.invalid("Choose an existing project folder.")
        }
        self.browserCall = browserCall
        self.root = root
        self.deviceID = deviceID ?? Self.persistentDeviceID
        self.resultCacheBytes = max(0, resultCacheBytes)
    }

    func describe() -> RemoteJSON {
        var instructions: [String] = []
        for name in ["AGENTS.md", "CLAUDE.md"] {
            if let path = try? resolve(name), let data = try? Data(contentsOf: path), data.count <= 32_768,
               let text = String(data: data, encoding: .utf8) { instructions.append("\(name):\n\(text)") }
        }
        return .object([
            "computer": .string("work"),
            "file_tools": .object(["scope": .string("workspace"),
                "root_writable": .bool(FileManager.default.isWritableFile(atPath: root.path)),
                "write_operations": .array([.string("write_file"), .string("edit_file")]),
                "permissions_source": .string("Work-computer OS permissions; the home CLI sandbox does not apply.")]),
            "cwd": .string(root.path), "hostname": .string(ProcessInfo.processInfo.hostName),
            "deviceID": .string(deviceID),
            "os": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "shell": .string(ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"),
            "home": .string(NSHomeDirectory()), "instructions": .string(instructions.joined(separator: "\n\n")),
        ])
    }

    /// Duplicate delivery returns the original result, including command IDs, without replaying a write.
    func call(id: UUID, name: String, arguments: RemoteJSON) async -> RemoteJSON {
        if let result = results[id] { return result }
        if let operation = inFlight[id] { return await operation.value }
        guard !seen.contains(id) else { return .textResult("This request already completed, but its cached result expired. Reconnect before continuing.", error: true) }
        guard !closed else { return .textResult("The workspace was disconnected.", error: true) }
        guard seen.count < 100000 else { return .textResult("Reconnect to continue this workspace session.", error: true) }
        seen.insert(id)
        let operation = Task { () -> RemoteJSON in
            do {
                let result = try await perform(name, arguments)
                guard try JSONEncoder().encode(RemoteMessage("toolResult", result, id: id)).count <= RemoteMessage.maxBytes else {
                    throw RemoteFailure.invalid("Tool result exceeds 4 MB. Read a smaller portion or limit command output.")
                }
                return result
            }
            catch { return .textResult(error.localizedDescription, error: true) }
        }
        inFlight[id] = operation
        let result = await operation.value
        inFlight.removeValue(forKey: id)
        cache(result, id: id)
        return result
    }

    /// Bound retained file/command contents while preserving every completed ID. Evicting a result
    /// can refuse a very old retry, but can never execute an already completed write a second time.
    private func cache(_ result: RemoteJSON, id: UUID) {
        let bytes = (try? JSONEncoder().encode(result).count) ?? RemoteMessage.maxBytes
        guard bytes <= resultCacheBytes else { return }
        while resultBytes + bytes > resultCacheBytes, resultHead < resultOrder.count {
            let previous = resultOrder[resultHead]; resultHead += 1
            results.removeValue(forKey: previous)
            resultBytes -= resultSizes.removeValue(forKey: previous) ?? 0
        }
        if resultHead > 1024, resultHead * 2 >= resultOrder.count {
            resultOrder.removeFirst(resultHead); resultHead = 0
        }
        results[id] = result; resultSizes[id] = bytes
        resultBytes += bytes; resultOrder.append(id)
    }

    private func perform(_ name: String, _ args: RemoteJSON) async throws -> RemoteJSON {
        guard !closed else { throw RemoteFailure.disconnected }
        if RemoteWorkspaceTools.browserNames.contains(name) {
            guard let browserCall else { throw RemoteFailure.invalid("This remote session has no connected browser window. Reconnect from MarkView.") }
            return await browserCall(name, args)
        }
        switch name {
        case "workspace_info":
            return .textResult(String(data: try JSONEncoder().encode(describe()), encoding: .utf8)!)
        case "list_directory":
            let url = try resolve(args["path"].string ?? ".")
            let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            return .textResult(entries.prefix(5000).map {
                $0.lastPathComponent + (((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) ? "/" : "")
            }.joined(separator: "\n"))
        case "read_file":
            let url = try resolve(args.requiredString("path", limit: 8192))
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2 * 1024 * 1024 else { throw RemoteFailure.invalid("File exceeds 2 MB. Use exec_command to read a selected portion.") }
            let data = try Data(contentsOf: url)
            let mime: String? = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"][url.pathExtension.lowercased()]
            if let mime {
                return .object(["content": .array([.object(["type": .string("image"), "data": .string(data.base64EncodedString()), "mimeType": .string(mime)])])])
            }
            guard let text = String(data: data, encoding: .utf8) else { throw RemoteFailure.invalid("This file is not UTF-8 text or a supported image.") }
            let lines = text.components(separatedBy: "\n")
            let offset = max(0, args["offset"].integer ?? 0)
            let limit = min(10000, max(1, args["limit"].integer ?? 2000))
            return .textResult(lines.dropFirst(offset).prefix(limit).enumerated().map { "\($0.offset + offset + 1):\($0.element)" }.joined(separator: "\n"))
        case "write_file":
            let url = try resolve(args.requiredString("path", limit: 8192))
            let content = try args.requiredString("content", limit: 2 * 1024 * 1024)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .atomic)
            return .textResult("Wrote \(url.path).")
        case "edit_file":
            let url = try resolve(args.requiredString("path", limit: 8192))
            let old = try args.requiredString("old_text"), new = try args.requiredString("new_text")
            guard !old.isEmpty else { throw RemoteFailure.invalid("old_text must not be empty.") }
            let data = try Data(contentsOf: url)
            guard data.count <= 2 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw RemoteFailure.invalid("File is too large or is not UTF-8.") }
            let parts = text.components(separatedBy: old)
            guard parts.count > 1 else { throw RemoteFailure.invalid("old_text does not match the current file. Read it again.") }
            guard args["replace_all"].bool == true || parts.count == 2 else { throw RemoteFailure.invalid("old_text has several matches. Include more context or set replace_all.") }
            try Data(parts.joined(separator: new).utf8).write(to: url, options: .atomic)
            return .textResult("Updated \(url.path).")
        case "exec_command":
            guard commands.count < 64 else { throw RemoteFailure.invalid("Too many command sessions. Finish an existing command first.") }
            let cwd = try resolve(args["workdir"].string ?? ".")
            let command = try RemoteCommand(command: args.requiredString("cmd"), directory: cwd)
            let id = UUID().uuidString
            commands[id] = command
            return await poll(command, id: id, wait: args["yield_time_ms"].integer ?? 1000)
        case "write_stdin":
            let id = try args.requiredString("session_id", limit: 128)
            guard let command = commands[id] else { throw RemoteFailure.invalid("This command session no longer exists.") }
            if args["terminate"].bool == true { command.stop() }
            else if let chars = args["chars"].string { try command.write(chars) }
            if args["close_stdin"].bool == true { command.closeInput() }
            return await poll(command, id: id, wait: args["yield_time_ms"].integer ?? 1000)
        default: throw RemoteFailure.invalid("Unknown workspace tool: \(name).")
        }
    }

    private func poll(_ command: RemoteCommand, id: String, wait: Int) async -> RemoteJSON {
        await command.wait(milliseconds: min(30000, max(0, wait)))
        let snapshot = command.takeOutput()
        if snapshot.exitCode != nil { commands.removeValue(forKey: id) }
        return .textResult("\(snapshot.output)\n" + (snapshot.exitCode.map { "Exit code: \($0)" } ?? "Running. session_id: \(id)"))
    }

    func close() {
        closed = true
        commands.values.forEach { $0.stop() }; commands.removeAll()
    }

    func resolve(_ path: String) throws -> URL {
        guard !path.contains("\0"), path.utf8.count <= 8192 else { throw RemoteFailure.invalid("Invalid workspace path.") }
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard url.path == root.path || url.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else {
            throw RemoteFailure.invalid("Path is outside the selected workspace: \(path). Select that folder in MarkView to work there.")
        }
        return url
    }
}
