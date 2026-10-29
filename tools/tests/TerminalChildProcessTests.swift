import Foundation
import Darwin

@main
enum TerminalChildProcessTests {
    static func main() async throws {
        let pipe = Pipe()
        let inheritedFD = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_DUPFD, 512)
        precondition(inheritedFD >= 512)
        let limit = getdtablesize()
        var inheritedMaster: Int32 = -1
        let child = forkpty(&inheritedMaster, nil, nil, nil)
        if child == 0 {
            TerminalChildProcess.closeInheritedDescriptors(upTo: limit)
            _exit(fcntl(inheritedFD, F_GETFD) == -1 && fcntl(STDOUT_FILENO, F_GETFD) >= 0 ? 0 : 1)
        }
        precondition(child > 0)
        var childStatus: Int32 = 0
        while waitpid(child, &childStatus, 0) < 0 && errno == EINTR {}
        close(inheritedFD)
        close(inheritedMaster)
        precondition(childStatus == 0, "PTY children must close inherited pipes above fd 255 while retaining standard I/O.")
        for script in ["trap '' HUP; printf READY; exec sleep 30", "printf READY; exit 0"] {
            let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(script), nil]
            defer { argv.forEach { free($0) } }
            var master: Int32 = -1
            let pid = forkpty(&master, nil, nil, nil)
            if pid == 0 { _ = execv(argv[0]!, argv); _exit(127) }
            precondition(pid > 0, "The test must create its own PTY child.")
            defer { close(master) }
            _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
            var output = ""
            for _ in 0..<100 {
                var buffer = [UInt8](repeating: 0, count: 128)
                let count = read(master, &buffer, buffer.count)
                if count > 0 { output += String(decoding: buffer[..<count], as: UTF8.self) }
                if output.contains("READY") { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            precondition(output.contains("READY"), "The child must start before termination is tested.")
            await TerminalChildProcess.stopAndReap(pid, graceNanoseconds: 100_000_000)?.value
            var status: Int32 = 0
            precondition(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD, "Stopped PTY children must be reaped, including a child that ignores HUP and one that already exited.")
        }
        await TerminalChildProcess.stopAndReap(0, graceNanoseconds: 0)?.value
        print("Terminal children: descriptor isolation, escalation, exited-child reaping and invalid-PID checks passed.")
    }
}
