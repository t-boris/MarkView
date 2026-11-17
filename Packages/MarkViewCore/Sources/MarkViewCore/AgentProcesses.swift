import Foundation
import os

/// The assistant CLI processes of headless runs and remote-workspace commands that are running now.
/// They are children of the app but not of its terminal tabs, so quitting the app left them running with no
/// one to take their answer (a prototype build kept spending tokens for half an hour). The app stops them on quit.
public enum AgentProcesses {
    private struct State: Sendable {
        var running: [ObjectIdentifier: SubprocessChild] = [:]
        var stopHandlers: [ObjectIdentifier: @Sendable () -> Void] = [:]
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    public static func add(_ child: SubprocessChild, stop: (@Sendable () -> Void)? = nil) {
        state.withLock {
            $0.running[ObjectIdentifier(child)] = child
            $0.stopHandlers[ObjectIdentifier(child)] = stop
        }
    }

    public static func remove(_ child: SubprocessChild) {
        state.withLock {
            $0.running[ObjectIdentifier(child)] = nil
            $0.stopHandlers[ObjectIdentifier(child)] = nil
        }
    }

    public static var count: Int { state.withLock { $0.running.count } }

    /// Asks every running assistant to stop, and kills those still running after `grace` seconds. Blocks, so
    /// it is for quitting only.
    public static func terminateAll(grace: TimeInterval = 1.0) {
        let (children, handlers) = state.withLock { (Array($0.running.values), $0.stopHandlers) }
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
