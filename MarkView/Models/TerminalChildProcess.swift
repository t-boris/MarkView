import Foundation
import Darwin

/// Takes ownership of a stopped PTY child after its exit source has been detached. Keep the
/// child unreaped through the grace period so its PID cannot be reused before group escalation.
enum TerminalChildProcess {
    /// Called only between forkpty and exec. The bound is obtained in the parent; the child
    /// uses only close(2), with no allocation, Foundation or Swift runtime synchronization.
    @inline(__always) static func closeInheritedDescriptors(upTo limit: Int32) {
        var fd: Int32 = 3
        while fd < limit { _ = close(fd); fd += 1 }
    }

    static func stopAndReap(_ pid: pid_t, graceNanoseconds: UInt64 = 2_000_000_000) -> Task<Void, Never>? {
        guard pid > 0 else { return nil }
        _ = kill(-pid, SIGHUP)
        _ = kill(pid, SIGHUP)
        return Task.detached {
            try? await Task.sleep(nanoseconds: graceNanoseconds)
            _ = kill(-pid, SIGKILL)
            _ = kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
    }
}
