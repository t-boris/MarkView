import Foundation
import Darwin

@main
enum TerminalChildProcessTests {
    static func main() async throws {
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
        print("Terminal children: escalation, exited-child reaping and invalid-PID checks passed.")
    }
}
