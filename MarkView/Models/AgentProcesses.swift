import Foundation

/// The assistant CLI processes of headless runs and remote-workspace commands that are running now.
/// They are children of the app but not of its terminal tabs, so quitting the app left them running with no
/// one to take their answer (a prototype build kept spending tokens for half an hour). The app stops them on quit.
enum AgentProcesses {
    private static let lock = NSLock()
    private static var running: [ObjectIdentifier: Process] = [:]
    private static var stopHandlers: [ObjectIdentifier: () -> Void] = [:]

    static func add(_ process: Process, stop: (() -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        running[ObjectIdentifier(process)] = process
        stopHandlers[ObjectIdentifier(process)] = stop
    }

    static func remove(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        running[ObjectIdentifier(process)] = nil
        stopHandlers[ObjectIdentifier(process)] = nil
    }

    static var count: Int {
        lock.lock(); defer { lock.unlock() }
        return running.count
    }

    /// Asks every running assistant to stop, and kills those still running after `grace` seconds. Blocks, so
    /// it is for quitting only.
    static func terminateAll(grace: TimeInterval = 1.0) {
        lock.lock()
        let processes = Array(running.values)
        let handlers = stopHandlers
        lock.unlock()
        let live = processes.filter { $0.isRunning }
        live.forEach { process in
            if let stop = handlers[ObjectIdentifier(process)] { stop() }
            else { process.terminate() }
        }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, live.contains(where: { $0.isRunning }) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for process in live where process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
