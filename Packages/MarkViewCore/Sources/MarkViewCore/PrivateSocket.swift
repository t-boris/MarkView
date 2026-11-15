import Darwin
import Foundation
import Security

/// The protection every MarkView local socket server shares (`AR-40`, `DEC-009`).
///
/// A Unix socket that other users can never reach, not even for an instant, plus a per-socket secret and the
/// kernel's word on who connected. The browser control socket, the Cockpit host socket and the Remote tool
/// bridge all listen through `open(at:backlog:)`, judge each accepted connection with `peer(of:)` and
/// `Listener.accepts(token:)`, and their clients read the secret with `readToken(forSocket:)`.
public enum PrivateSocket {
    /// Why a socket could not be opened.
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    /// Kernel-verified identity of the process on the other end of an accepted connection.
    public struct Peer: Sendable {
        public let pid: Int32?
        public let uid: uid_t?

        public init(pid: Int32?, uid: uid_t?) {
            self.pid = pid
            self.uid = uid
        }

        /// Only a peer the kernel identified as this user passes; an unknown peer never does.
        public var isCurrentUser: Bool { uid == getuid() }
    }

    /// A listening socket and the secret its clients must present. Created only by `open(at:backlog:)`, so a
    /// server cannot listen without a token.
    public struct Listener: Sendable {
        public let fd: Int32
        public let path: String
        private let token: String

        fileprivate init(fd: Int32, path: String, token: String) {
            self.fd = fd
            self.path = path
            self.token = token
        }

        /// Whether `provided` is this socket's token (fails closed, constant time).
        public func accepts(token provided: String?) -> Bool {
            PrivateSocket.verify(provided, expected: token)
        }

        /// Wakes the accept loop, closes the descriptor and removes the socket and token files. Call once.
        public func stop() {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            PrivateSocket.remove(socketAt: path)
        }
    }

    // MARK: - Listening

    /// Binds and listens at `path` with a fresh 256-bit token written to the `0600` file next to it.
    ///
    /// The socket is bound inside a private (`0700`) staging folder, set to `0600` and only then renamed to
    /// `path`, so it is never visible to other users with the permissions a plain `bind` leaves (`umask` is
    /// process-wide and cannot be used from a multi-threaded app). The token file exists before the socket
    /// does, so a client that finds the socket always finds its token.
    public static func open(at path: String, backlog: Int32 = 16) throws -> Listener {
        guard address(path) != nil else { throw Failure(description: "The socket path is too long.") }
        guard let token = issueToken(forSocket: path) else { throw Failure(description: "The socket token could not be written.") }
        do {
            return Listener(fd: try bindPrivately(at: path, backlog: backlog), path: path, token: token)
        } catch {
            unlink(tokenPath(forSocket: path))
            throw error
        }
    }

    private static func bindPrivately(at path: String, backlog: Int32) throws -> Int32 {
        var template = Array(((path as NSString).deletingLastPathComponent + "/.mvs-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw failure("create a private folder") }
        let staging = String(cString: template)
        let staged = staging + "/s"
        defer { rmdir(staging) }
        guard var stagedAddress = address(staged) else { throw Failure(description: "The socket path is too long.") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure("create the socket") }
        let bound = withUnsafePointer(to: &stagedAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(staged, 0o600) == 0, Darwin.listen(fd, backlog) == 0, rename(staged, path) == 0 else {
            let failed = failure("bind the socket")
            Darwin.close(fd)
            unlink(staged)
            throw failed
        }
        return fd
    }

    private static func failure(_ action: String) -> Failure {
        Failure(description: "Could not \(action): \(String(cString: strerror(errno))).")
    }

    /// Removes a socket and its token file (also those a MarkView that is gone left behind).
    public static func remove(socketAt path: String) {
        unlink(path)
        unlink(tokenPath(forSocket: path))
    }

    /// The `sockaddr_un` for `path`; nil when the path does not fit.
    public static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        return address
    }

    // MARK: - Token

    /// Where the token of the socket at `socketPath` lives: `x.sock` -> `x.token`.
    public static func tokenPath(forSocket socketPath: String) -> String {
        if socketPath.hasSuffix(".sock") {
            return String(socketPath.dropLast(".sock".count)) + ".token"
        }
        return socketPath + ".token"
    }

    private static func issueToken(forSocket socketPath: String) -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let path = tokenPath(forSocket: socketPath)
        unlink(path)
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        _ = fchmod(fd, 0o600)
        var offset = 0
        let body = Array(token.utf8)
        while offset < body.count {
            let written = body.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, body.count - offset) }
            if written <= 0 {
                unlink(path)
                return nil
            }
            offset += written
        }
        return token
    }

    /// The token of the socket at `socketPath`, read from its token file; nil unless that is a regular `0600`
    /// file of this user (no environment fallback: a client without the file has no way in).
    public static func readToken(forSocket socketPath: String) -> String? {
        let fd = Darwin.open(tokenPath(forSocket: socketPath), O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o077) == 0,
              info.st_uid == getuid() else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
            if data.count > 8192 { return nil }
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// Whether `provided` equals `expected`: false when either is missing or empty, constant time otherwise.
    public static func verify(_ provided: String?, expected: String?) -> Bool {
        guard let expected, !expected.isEmpty, let provided, !provided.isEmpty else { return false }
        let a = Array(expected.utf8)
        let b = Array(provided.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<a.count { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    // MARK: - Peer

    /// The kernel's account of who is on the other end of `clientFD`: process (`LOCAL_PEERPID`) and user (`LOCAL_PEERCRED`).
    public static func peer(of clientFD: Int32) -> Peer {
        var peerPID: pid_t = 0
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        let gotPID = getsockopt(clientFD, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &pidLength) == 0 && peerPID > 0
        var credentials = xucred()
        var credentialsLength = socklen_t(MemoryLayout<xucred>.size)
        let gotCredentials = getsockopt(clientFD, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &credentialsLength) == 0
            && credentials.cr_version == XUCRED_VERSION
        return Peer(pid: gotPID ? peerPID : nil, uid: gotCredentials ? credentials.cr_uid : nil)
    }
}
