import Darwin
import Foundation
import XCTest
@testable import MarkViewCore

final class PrivateSocketTests: XCTestCase {
    func testSocketSecurityAndLifecycle() async throws {
        func check(_ condition: Bool, _ message: String, line: Int = #line) {
            XCTAssertTrue(condition, message, line: UInt(line))
        }
        func mode(_ path: String) -> Int? {
            var info = stat()
            return lstat(path, &info) == 0 ? Int(info.st_mode & 0o7777) : nil
        }
        func isSocket(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
        }
        func connect(to path: String) -> Int32? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0, var address = PrivateSocket.address(path) else { return nil }
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            if result != 0 { close(fd); return nil }
            return fd
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mv-private-socket-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func sockPath(_ name: String) -> String { folder.appendingPathComponent(name + ".sock").path }
        func entries() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }

        // MARK: - Opening

        let path = sockPath("one")
        let listener = try PrivateSocket.open(at: path, backlog: 4)
        let tokenFile = PrivateSocket.tokenPath(forSocket: path)
        check(tokenFile == folder.appendingPathComponent("one.token").path && PrivateSocket.tokenPath(forSocket: "/x/y") == "/x/y.token",
              "the token file sits next to the socket: x.sock -> x.token")
        check(isSocket(path) && mode(path) == 0o600, "the socket is a 0600 socket")
        check(mode(tokenFile) == 0o600, "the token file is 0600")
        check(entries() == ["one.sock", "one.token"], "no staging folder is left next to the socket", line: #line)
        let token = PrivateSocket.readToken(forSocket: path) ?? ""
        check(token.count == 64 && token.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "the token is 256 bits of lower-case hex")
        check(listener.accepts(token: token), "the listener accepts the token its file holds")
        check(!listener.accepts(token: nil) && !listener.accepts(token: "") && !listener.accepts(token: "wrong")
              && !listener.accepts(token: String(token.dropLast())) && !listener.accepts(token: token + "0"),
              "the listener refuses a missing, empty, wrong, shorter or longer token")

        // MARK: - A real connection and the kernel's account of its peer

        let client = try XCTUnwrap(connect(to: path))
        let accepted = accept(listener.fd, nil, nil)
        check(accepted >= 0, "a client connects and the listener accepts it")
        let peer = PrivateSocket.peer(of: accepted)
        check(peer.uid == getuid() && peer.pid == getpid() && peer.isCurrentUser, "the peer of a local connection is this process and this user")
        check(!PrivateSocket.Peer(pid: 1, uid: getuid() &+ 1).isCurrentUser, "a peer of another user is not the current user")
        check(!PrivateSocket.Peer(pid: 1, uid: nil).isCurrentUser, "a peer whose user the kernel could not tell is not the current user")
        check(PrivateSocket.peer(of: -1).uid == nil && !PrivateSocket.peer(of: -1).isCurrentUser, "no peer is known for a descriptor that is not a connection")
        close(accepted)
        close(client)

        // MARK: - Verifying

        let other = String(repeating: "a", count: 64)
        check(!PrivateSocket.verify(nil, expected: nil) && !PrivateSocket.verify("", expected: "") && !PrivateSocket.verify("anything", expected: ""),
              "verify fails closed when the expected token is missing or empty")
        check(!PrivateSocket.verify(nil, expected: token) && !PrivateSocket.verify("", expected: token) && !PrivateSocket.verify(other, expected: token),
              "verify refuses a missing, empty or different token")
        check(PrivateSocket.verify(token, expected: token), "verify accepts the matching token")

        // MARK: - Reading the token (the clients' side)

        setenv("MARKVIEW_CONTROL_TOKEN", other, 1)
        defer { unsetenv("MARKVIEW_CONTROL_TOKEN") }
        chmod(tokenFile, 0o644)
        check(PrivateSocket.readToken(forSocket: path) == nil, "a token file readable by the group or others is not trusted")
        chmod(tokenFile, 0o640)
        check(PrivateSocket.readToken(forSocket: path) == nil, "a group-readable token file is not trusted")
        chmod(tokenFile, 0o600)
        check(PrivateSocket.readToken(forSocket: path) == token, "a 0600 token file is read back")
        let real = folder.appendingPathComponent("real.token").path
        try FileManager.default.moveItem(atPath: tokenFile, toPath: real)
        try FileManager.default.createSymbolicLink(atPath: tokenFile, withDestinationPath: real)
        check(PrivateSocket.readToken(forSocket: path) == nil, "a symbolic link in place of the token file is not followed")
        try FileManager.default.removeItem(atPath: tokenFile)
        try FileManager.default.moveItem(atPath: real, toPath: tokenFile)
        try Data("   \n".utf8).write(to: URL(fileURLWithPath: folder.appendingPathComponent("blank.token").path))
        chmod(folder.appendingPathComponent("blank.token").path, 0o600)
        check(PrivateSocket.readToken(forSocket: sockPath("blank")) == nil, "an empty token file gives no token")
        try Data(repeating: 65, count: 9000).write(to: URL(fileURLWithPath: folder.appendingPathComponent("huge.token").path))
        chmod(folder.appendingPathComponent("huge.token").path, 0o600)
        check(PrivateSocket.readToken(forSocket: sockPath("huge")) == nil, "an oversized token file gives no token")
        try FileManager.default.removeItem(atPath: tokenFile)
        check(PrivateSocket.readToken(forSocket: path) == nil, "a missing token file gives no token, whatever the environment says")
        try FileManager.default.removeItem(atPath: folder.appendingPathComponent("blank.token").path)
        try FileManager.default.removeItem(atPath: folder.appendingPathComponent("huge.token").path)

        // MARK: - Stopping and reopening

        listener.stop()
        check(!FileManager.default.fileExists(atPath: path) && !FileManager.default.fileExists(atPath: tokenFile) && entries().isEmpty,
              "stopping removes the socket and its token file")
        check(connect(to: path) == nil, "nobody connects after the listener stopped")

        // A MarkView that is gone leaves its socket and token behind; opening the same path takes it over with a new token.
        try Data("old-socket".utf8).write(to: URL(fileURLWithPath: path))
        try Data("old-token".utf8).write(to: URL(fileURLWithPath: tokenFile))
        let reopened = try PrivateSocket.open(at: path)
        let freshToken = PrivateSocket.readToken(forSocket: path) ?? ""
        check(isSocket(path) && mode(path) == 0o600 && freshToken.count == 64 && freshToken != "old-token" && reopened.accepts(token: freshToken),
              "opening over a stale socket and token replaces both")
        PrivateSocket.remove(socketAt: path)
        check(entries().isEmpty, "remove(socketAt:) clears a socket and its token even when its listener is gone")
        close(reopened.fd)

        var refused = 0
        do { _ = try PrivateSocket.open(at: folder.path + "/" + String(repeating: "x", count: 120) + ".sock") } catch { refused += 1 }
        do { _ = try PrivateSocket.open(at: folder.path + "/missing-folder/s.sock") } catch { refused += 1 }
        check(refused == 2 && entries().isEmpty, "a path that is too long or in a missing folder is refused and leaves no token or staging folder behind")

        // MARK: - The socket is never visible with another mode

        // A poller watches the final path while sockets are opened and stopped on it: whatever it ever sees there must be
        // 0600 already (the socket is bound in a private staging folder and only renamed into place once it is).
        let watched = sockPath("watched")
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let poller = Task.detached {
            var seen = 0
            var wrongMode = 0
            startedContinuation.yield(())
            startedContinuation.finish()
            while !Task.isCancelled {
                var info = stat()
                if lstat(watched, &info) == 0 {
                    seen += 1
                    if info.st_mode & 0o7777 != 0o600 { wrongMode += 1 }
                }
            }
            return (seen, wrongMode)
        }
        defer { poller.cancel() }
        for await _ in started { break }
        for _ in 0..<300 {
            let l = try PrivateSocket.open(at: watched)
            l.stop()
        }
        poller.cancel()
        let (seen, wrongMode) = await poller.value
        check(wrongMode == 0 && seen > 0, "a socket is never seen at its path with a mode other than 0600 (seen \(seen) times)")
    }
}
