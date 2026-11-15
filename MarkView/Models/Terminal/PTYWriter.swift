import Darwin
import Foundation

/// Input to a non-blocking PTY master, delivered completely and in order.
///
/// The terminal driver takes only about 1 KB of input at a time; a longer write stops
/// with EAGAIN until the program on the other side reads. Unsent bytes wait here and go
/// out as the PTY drains (a write source wakes on the queue), so a long paste keeps its
/// closing ESC[201~ and an Enter queued after it always lands after it. The caller never
/// blocks.
final class PTYWriter {
    private let fd: Int32
    private let queue: DispatchQueue
    private var pending = Data()
    private var source: DispatchSourceWrite?
    private var sourceActive = false
    private var closed = false

    /// `queue` is where `write` and `cancel` are called; the write source runs on it too.
    init(fd: Int32, queue: DispatchQueue = .main) {
        self.fd = fd
        self.queue = queue
    }

    /// Bytes still waiting for the program to read.
    var pendingCount: Int { pending.count }

    func write(_ data: Data) {
        guard !closed, !data.isEmpty else { return }
        pending.append(data)
        // Already waiting for the PTY: the write source sends these after the earlier bytes.
        guard !sourceActive else { return }
        flush()
    }

    /// Stop writing (the PTY is being closed); unsent input is dropped.
    func cancel() {
        closed = true
        pending.removeAll()
        if let source {
            // A suspended source must be resumed before it can be cancelled.
            if !sourceActive { source.resume() }
            source.cancel()
        }
        source = nil
        sourceActive = false
    }

    private func flush() {
        while !pending.isEmpty {
            let written = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                pending.removeFirst(written)
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN {
                waitForWritable()
                return
            }
            // The PTY is gone (EIO, EBADF): nothing more can be delivered.
            pending.removeAll()
            break
        }
        if sourceActive {
            source?.suspend()
            sourceActive = false
        }
    }

    private func waitForWritable() {
        guard !sourceActive else { return }
        if source == nil {
            let made = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            made.setEventHandler { [weak self] in self?.flush() }
            source = made
        }
        sourceActive = true
        source?.resume()
    }

    deinit {
        cancel()
    }
}
