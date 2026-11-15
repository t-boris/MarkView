import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The assistant CLI processes of headless runs and remote-workspace commands that are running now.
/// They are children of the app but not of its terminal tabs, so quitting the app left them running with no
/// one to take their answer (a prototype build kept spending tokens for half an hour). The app stops them on quit.
enum AgentProcesses {
    private static let lock = NSLock()
    private static var running: [ObjectIdentifier: SubprocessChild] = [:]
    private static var stopHandlers: [ObjectIdentifier: () -> Void] = [:]

    static func add(_ child: SubprocessChild, stop: (() -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        running[ObjectIdentifier(child)] = child
        stopHandlers[ObjectIdentifier(child)] = stop
    }

    static func remove(_ child: SubprocessChild) {
        lock.lock(); defer { lock.unlock() }
        running[ObjectIdentifier(child)] = nil
        stopHandlers[ObjectIdentifier(child)] = nil
    }

    static var count: Int {
        lock.lock(); defer { lock.unlock() }
        return running.count
    }

    /// Asks every running assistant to stop, and kills those still running after `grace` seconds. Blocks, so
    /// it is for quitting only.
    static func terminateAll(grace: TimeInterval = 1.0) {
        lock.lock()
        let children = Array(running.values)
        let handlers = stopHandlers
        lock.unlock()
        let live = children.filter { $0.isRunning }
        live.forEach { child in
            if let stop = handlers[ObjectIdentifier(child)] { stop() }
            else { child.terminate(grace: grace) }
        }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, live.contains(where: { $0.isRunning }) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for child in live where child.isRunning { child.kill() }
    }
}
