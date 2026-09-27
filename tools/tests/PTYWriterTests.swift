import Darwin
import Foundation

// Checks PTYWriter (MarkView/Models/PTYWriter.swift) against a real PTY whose reader is slower
// than the writer: long pastes arrive whole and in order (BUG-002).

var failures = 0
func check(_ condition: Bool, _ message: String) {
    print((condition ? "PASS " : "FAIL ") + message)
    if !condition { failures += 1 }
}

/// A raw-mode child that starts reading after `delay` seconds and copies its input to `file`.
func spawnReader(delay: Double, file: String) -> (fd: Int32, pid: pid_t) {
    var master: Int32 = -1
    var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    let script = "stty raw -echo; sleep \(delay); exec cat > '\(file)'"
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(script), nil]
    let pid = forkpty(&master, nil, nil, &size)
    if pid == 0 { _ = execv("/bin/sh", argv); _exit(127) }
    _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
    // Let stty switch the line discipline before anything is written.
    usleep(300_000)
    return (master, pid)
}

/// Runs the main queue until `done` or the timeout; drains the child's output meanwhile.
func run(until done: () -> Bool, timeout: Double, fd: Int32) {
    let end = Date().addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !done() && Date() < end {
        _ = Darwin.read(fd, &buffer, buffer.count)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

func received(_ file: String, expected count: Int, timeout: Double = 3) -> Data {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: file)), data.count >= count { return data }
        usleep(50_000)
    }
    return (try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data()
}

let folder = NSTemporaryDirectory() + "pty-writer-tests-\(getpid())"
try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: folder) }

let body = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 450) + "END-OF-PROMPT"
let paste = "\u{1b}[200~" + body + "\u{1b}[201~"

// 1. A 20 KB paste followed by Enter: everything arrives, the terminator and Enter last.
do {
    let file = folder + "/paste.txt"
    let child = spawnReader(delay: 1, file: file)
    let writer = PTYWriter(fd: child.fd)
    let started = Date()
    writer.write(Data(paste.utf8))
    let elapsed = Date().timeIntervalSince(started)
    check(elapsed < 0.1, "write returns at once while the reader is busy (\(String(format: "%.3f", elapsed)) s)")
    check(writer.pendingCount > 0, "the part the PTY could not take waits (\(writer.pendingCount) bytes)")
    writer.write(Data("\r".utf8))
    run(until: { writer.pendingCount == 0 }, timeout: 10, fd: child.fd)
    let expected = Data((paste + "\r").utf8)
    let got = received(file, expected: expected.count)
    check(got == expected, "reader got all \(expected.count) bytes in order (got \(got.count))")
    check(got.suffix(7) == Data("\u{1b}[201~\r".utf8), "the paste is closed with ESC[201~ before Enter")
    kill(child.pid, SIGKILL); waitpid(child.pid, nil, 0); close(child.fd)
}

// 2. Many small writes while the PTY is full keep their order.
do {
    let file = folder + "/order.txt"
    let child = spawnReader(delay: 0.5, file: file)
    let writer = PTYWriter(fd: child.fd)
    var expected = ""
    for index in 0..<2000 {
        let piece = "<\(index)>"
        expected += piece
        writer.write(Data(piece.utf8))
    }
    run(until: { writer.pendingCount == 0 }, timeout: 10, fd: child.fd)
    let got = received(file, expected: expected.utf8.count)
    check(String(decoding: got, as: UTF8.self) == expected, "2000 small writes arrive in order (\(got.count) of \(expected.utf8.count) bytes)")
    kill(child.pid, SIGKILL); waitpid(child.pid, nil, 0); close(child.fd)
}

// 3. Cancel with input still waiting: dropped, nothing more written, no crash.
do {
    let file = folder + "/cancel.txt"
    let child = spawnReader(delay: 1, file: file)
    let writer = PTYWriter(fd: child.fd)
    writer.write(Data(paste.utf8))
    let before = writer.pendingCount
    writer.cancel()
    writer.write(Data("after".utf8))
    check(before > 0 && writer.pendingCount == 0, "cancel drops waiting input and ignores later writes")
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    let got = received(file, expected: paste.utf8.count, timeout: 0.5)
    check(got.count < paste.utf8.count, "nothing is written after cancel (\(got.count) bytes reached the reader)")
    kill(child.pid, SIGKILL); waitpid(child.pid, nil, 0); close(child.fd)
}

// 4. The program exits with input waiting: the writer gives up instead of spinning.
do {
    let file = folder + "/exit.txt"
    let child = spawnReader(delay: 5, file: file)
    let writer = PTYWriter(fd: child.fd)
    writer.write(Data(paste.utf8))
    kill(child.pid, SIGKILL); waitpid(child.pid, nil, 0)
    run(until: { writer.pendingCount == 0 }, timeout: 3, fd: child.fd)
    check(writer.pendingCount == 0, "input for an exited program is dropped")
    writer.cancel()
    close(child.fd)
}

print(failures == 0 ? "All PTYWriter tests passed" : "\(failures) PTYWriter test(s) failed")
exit(failures == 0 ? 0 : 1)
