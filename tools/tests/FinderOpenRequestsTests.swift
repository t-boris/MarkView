import Foundation

/// The Finder Quick Action request poll (`AR-19`) on real files: what a request file may be, that it is consumed once, that one poll
/// serves the app, and that stopping it ends it.
@main
enum FinderOpenRequestsChecks {
    nonisolated(unsafe) static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        }
    }

    static func write(_ text: String, to path: String) { try? text.write(toFile: path, atomically: true, encoding: .utf8) }
    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Waits until `condition` holds, for at most two seconds.
    @MainActor
    static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    @MainActor
    static func main() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("finder-requests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("first.txt").path, second = dir.appendingPathComponent("second.txt").path

        // --- The request file.
        check(await FinderOpenRequests.takeRequest(from: [first, second]) == nil, "no request file, no request")
        write("/Users/someone/My Notes/plan.md\n", to: first)
        let taken = await FinderOpenRequests.takeRequest(from: [first, second])
        check(taken == URL(fileURLWithPath: "/Users/someone/My Notes/plan.md"), "a request is the path in the file, trimmed (\(String(describing: taken)))")
        check(!exists(first), "a request is deleted as it is read")
        check(await FinderOpenRequests.takeRequest(from: [first, second]) == nil, "a request is taken once")

        write("  \n", to: first)
        check(await FinderOpenRequests.takeRequest(from: [first, second]) == nil && !exists(first), "an empty request is dropped and its file removed")

        write("/tmp/a", to: first)
        write("/tmp/b", to: second)
        let one = await FinderOpenRequests.takeRequest(from: [first, second])
        let two = await FinderOpenRequests.takeRequest(from: [first, second])
        check(one?.path == "/tmp/a" && two?.path == "/tmp/b", "the first file is read first, the second one on the next call (\(String(describing: one)), \(String(describing: two)))")

        // A symbolic link is not followed; a folder is not a request; both stay where they are.
        let target = dir.appendingPathComponent("target.txt").path
        write("/etc/passwd", to: target)
        try? FileManager.default.createSymbolicLink(atPath: first, withDestinationPath: target)
        check(await FinderOpenRequests.takeRequest(from: [first]) == nil && exists(target), "a request file that is a symbolic link is ignored and its target kept")
        try? FileManager.default.removeItem(atPath: first)
        try? FileManager.default.createDirectory(atPath: second, withIntermediateDirectories: true)
        check(await FinderOpenRequests.takeRequest(from: [second]) == nil && exists(second), "a folder is not a request file")
        try? FileManager.default.removeItem(atPath: second)

        // Only the first 64 KB is read.
        write("/tmp/" + String(repeating: "x", count: 70_000), to: first)
        let large = await FinderOpenRequests.takeRequest(from: [first])
        check((large?.path.count ?? 0) <= 65_540 && (large?.path.count ?? 0) > 60_000, "a request is read up to 64 KB (\(large?.path.count ?? 0))")

        // --- The poll.
        let polled = FinderOpenRequests(candidates: [first], interval: 20_000_000)
        var received: [[URL]] = []
        var ignored = 0
        check(!polled.isPolling, "a new poll is not running")
        polled.start { received.append($0); check(Thread.isMainThread, "the handler runs on the main thread") }
        polled.start { _ in ignored += 1 }
        check(polled.isPolling, "start begins the poll")
        write("/tmp/polled-one", to: first)
        check(await eventually { received.count == 1 }, "a request written while the poll runs reaches the handler")
        check(received.first == [URL(fileURLWithPath: "/tmp/polled-one")] && !exists(first), "the handler gets the URL and the file is gone")
        write("/tmp/polled-two", to: first)
        check(await eventually { received.count == 2 }, "the next request is taken too")
        check(ignored == 0, "a second start does not stack a second poll or replace the handler")

        polled.stop()
        check(!polled.isPolling, "stop ends the poll")
        write("/tmp/after-stop", to: first)
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(received.count == 2 && exists(first), "a stopped poll leaves a request in its file for the next window")

        polled.start { received.append($0) }
        check(await eventually { received.count == 3 } && !exists(first), "a poll started again takes the request that waited")
        polled.stop()

        if failures > 0 {
            FileHandle.standardError.write(Data("\(failures) check(s) failed\n".utf8))
            exit(1)
        }
        print("FinderOpenRequests: request files, one poll, stop and restart passed")
    }
}
