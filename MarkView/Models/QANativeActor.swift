import AppKit
import Foundation

// End-to-End QA (feature end-to-end-qa, DEC-008, DEC-012, DEC-017, DEC-023): one player of a scenario in a native macOS application. MarkView
// attaches to an already-running application, or launches a separate instance when needed. It reads and operates the selected
// process through Accessibility, and takes pictures with ScreenCaptureKit. Cleanup ends only an instance started by QA, never an attached
// user process. The player's password is typed by the player, never shown to the assistant, and a
// secure field's value is never read.

enum QANativeError: Error, LocalizedError {
    case accessibilityNotGranted
    case screenRecordingNotGranted
    case notInstalled(String)
    case launchFailed(String)
    case noSecondInstance(String)
    case notOpen
    case notAvailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "MarkView is not allowed to control other applications. Allow MarkView in System Settings > Privacy & Security > Accessibility, then run the check again."
        case .screenRecordingNotGranted:
            return "MarkView is not allowed to record the screen. Allow MarkView in System Settings > Privacy & Security > Screen & System Audio Recording, then run the check again."
        case .notInstalled(let identifier): return "No installed application has the identifier \(identifier)."
        case .launchFailed(let message): return "The application could not be launched: \(message)"
        case .noSecondInstance(let name):
            return "\(name) does not allow a second instance of itself and one is running already, so a copy of its own cannot be started for this player."
        case .notOpen: return "The application is not open."
        case .notAvailable(let what): return "\(what) is not available for a native application."
        case .failed(let message): return message
        }
    }
}

@MainActor
final class QANativeActor: QAActorDriver {
    struct Config {
        /// Brings the player's application to the front before every look and every action of this player: SwiftUI ignores clicks and keys
        /// that are sent to it in the background. A check that must not take the focus (the live check of the player itself) turns it off.
        var bringToFront = true
        /// How long a launched application may take to show a window.
        var launchTimeout: TimeInterval = 20
        /// How long a closing application is given to quit before it is made to.
        var terminationGrace: TimeInterval = 3
    }

    /// The application reacts to an action for a moment before the next look.
    private static let settle: UInt64 = 200_000_000
    /// One native process cannot represent two independent players at once.
    private static var claimedProcesses: Set<pid_t> = []

    let request: QADriverRequest
    private let credentials: QACredentials
    private let config: Config
    private var process: NSRunningApplication?
    private var ownsProcess = false
    private var accessibility: QANativeAccessibility?
    private var capture: QANativeCapture?
    private var bundleIdentifier = ""
    private var applicationName = ""
    private var last: QANativeAccessibility.Reading?
    private var closed = false

    /// `credentials` are read by the factory off the main thread (a Keychain read can wait for the system), and go no further than this
    /// player: the assistant writes {{password}} and the real value goes straight into the field.
    init(request: QADriverRequest, credentials: QACredentials, config: Config = Config()) {
        self.request = request
        self.credentials = credentials
        self.config = config
    }

    // MARK: QAActorDriver

    /// Launches the application named by `address`: its bundle identifier, or `app://<bundle identifier>`. Checks the permissions first, so
    /// nothing is launched that could not be driven.
    func open(_ address: String) async throws {
        guard !closed, process == nil else { throw QANativeError.failed("The player's application is open already.") }
        if let missing = QANativePermissions.current.error { throw missing }
        let identifier = Self.bundleIdentifier(from: address)
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { throw QANativeError.notInstalled(identifier) }
        let bundle = Bundle(url: url)
        bundleIdentifier = identifier
        applicationName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { !$0.isTerminated }
        let launched: NSRunningApplication
        switch request.startupPolicy {
        case .attach:
            guard !running.isEmpty else { throw QANativeError.failed("Open \(applicationName) before attaching, or choose Launch a new instance in Setup.") }
            guard running.count == 1 else { throw QANativeError.failed("More than one \(applicationName) process is running. Close the extra instances before attaching.") }
            launched = running[0]
            ownsProcess = false
        case .launch:
            if !running.isEmpty, bundle?.object(forInfoDictionaryKey: "LSMultipleInstancesProhibited") as? Bool == true {
                throw QANativeError.noSecondInstance(applicationName)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = false
            configuration.addsToRecentItems = false
            do { launched = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration) } catch {
                throw QANativeError.launchFailed(error.localizedDescription)
            }
            guard !running.contains(where: { $0.processIdentifier == launched.processIdentifier }) else {
                throw QANativeError.noSecondInstance(applicationName)
            }
            ownsProcess = true
        }
        guard !Self.claimedProcesses.contains(launched.processIdentifier) else {
            ownsProcess = false
            throw QANativeError.failed("\(applicationName) is already in use by another QA player. A separate instance is required for each player.")
        }
        Self.claimedProcesses.insert(launched.processIdentifier)
        process = launched

        do {
            let driver = QANativeAccessibility(pid: launched.processIdentifier)
            accessibility = driver
            capture = QANativeCapture(pid: launched.processIdentifier)
            await driver.prepare()
            let deadline = Date().addingTimeInterval(config.launchTimeout)
            while !(await driver.hasWindow()) {
                if launched.isTerminated {
                    throw QANativeError.launchFailed("\(applicationName) quit right after it was opened. It may allow only one instance at a time.")
                }
                if Date() > deadline { throw QANativeError.launchFailed("\(applicationName) showed no window within \(Int(config.launchTimeout)) seconds.") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            await close()
            throw error
        }
    }

    func observe() async throws -> QAObservation {
        let driver = try live()
        await front()
        let reading = try await driver.read()
        let snapshot = QANativeSnapshot.render(app: "\(applicationName) (\(bundleIdentifier))", windowTitle: reading.windowTitle, elements: reading.elements,
                                               menus: reading.menus, omitted: reading.omitted)
        await driver.publish(snapshot.refs)
        last = reading
        let path = reading.windowTitle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        return QAObservation(address: scrub("app://\(bundleIdentifier)/\(path)"), title: scrub(reading.windowTitle), snapshot: scrub(snapshot.text))
    }

    func perform(_ action: QAAction) async throws -> String {
        let driver = try live()
        switch action.kind {
        case .navigate: throw QANativeError.notAvailable("Opening an address (navigate)")
        case .http: throw QANativeError.notAvailable("A request to an address (http)")
        case .wait:
            try await Task.sleep(nanoseconds: UInt64(max(action.amount, 0)) * 1_000_000)
            return "Waited \(action.amount) ms"
        case .click, .fill, .select, .scroll, .key: break
        }
        await front()
        let done: String
        do {
            switch action.kind {
            case .click:
                done = try await driver.click(try reference(action))
            case .fill:
                let value = credentials.fill(action.text)
                if let missing = credentials.unfilled(action.text).first {
                    throw QANativeError.failed("This player has no saved sign-in, so \(missing) cannot be filled in. Type what the step itself says, or answer blocked: the person has to choose a login for this player in Setup.")
                }
                done = try await driver.fill(try reference(action), text: value)
            case .select:
                done = try await driver.select(try reference(action), option: action.text)
            case .scroll:
                done = try await driver.scroll(up: action.direction.lowercased() == "up")
            case .key:
                guard let key = QANativeKeys.parse(action.text) else {
                    throw QANativeError.failed("\"\(action.text)\" is not a key. Use a name such as Enter, Escape, Tab, Down or a letter, with modifiers: cmd+shift+n.")
                }
                try await driver.press(key)
                done = "Pressed \(action.text)"
            case .wait, .navigate, .http:
                return ""
            }
        } catch let error as QANativeError {
            // What an element is called can hold the password; no error may carry it to the assistant.
            throw QANativeError.failed(scrub(error.errorDescription ?? "The action failed."))
        }
        try? await Task.sleep(nanoseconds: Self.settle)
        return scrub(done)
    }

    /// The latest picture of the player's window; nil when it has none.
    func inputMark(for action: QAAction) async -> QAInputMark {
        var mark = QAInputMark(kind: action.kind, direction: action.direction)
        if let driver = accessibility, let (frame, viewport) = await driver.inputFrame(ref: action.ref, kind: action.kind) {
            mark.target = QAInputMark.normalized(frame, in: viewport)
        }
        return mark
    }

    func screenshot() async -> Data? {
        guard !closed, let capture else { return nil }
        return await capture.latestPNG(preferring: last?.windowFrame)
    }

    /// A native application has no requests to disturb.
    func arm(_ fault: QAFault) async throws {
        throw QANativeError.notAvailable("A network fault")
    }

    func faultHits() async -> Int { 0 }

    /// The window as the last look read it, measured for the review.
    func measure() async -> QAPageEvidence? {
        guard !closed, let last, let frame = last.windowFrame else { return nil }
        return QANativeEvidence.make(from: last.elements, windowFrame: frame)
    }

    func sessionIdentity() async -> String? {
        guard let process, !closed, !process.isTerminated else { return nil }
        let mode = ownsProcess ? "Launched" : "Attached to"
        return "\(mode) \(applicationName) (PID \(process.processIdentifier))."
    }

    /// Stops the pictures and ends only a process this player launched; an attached process stays open.
    func close() async {
        guard !closed else { return }
        closed = true
        accessibility = nil
        let recording = capture
        capture = nil
        await recording?.stop()
        guard let process else { return }
        defer { Self.claimedProcesses.remove(process.processIdentifier) }
        guard ownsProcess, !process.isTerminated else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(config.terminationGrace)
        while !process.isTerminated, Date() < deadline { await Self.pause(0.1) }
        if !process.isTerminated { process.forceTerminate() }
    }

    // MARK: Helpers

    private func live() throws -> QANativeAccessibility {
        guard !closed, let accessibility, process?.isTerminated == false else {
            throw closed || process == nil ? QANativeError.notOpen : QANativeError.failed("\(applicationName) has quit.")
        }
        return accessibility
    }

    private func front() async {
        guard config.bringToFront, let accessibility else { return }
        if await accessibility.bringToFront() { await Self.pause(0.25) }
    }

    /// A wait that goes on when the task was cancelled: closing has to run to the end.
    private static func pause(_ seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }

    /// Nothing that comes back from the application may carry the password to the assistant, the run record or a log.
    private func scrub(_ text: String) -> String { credentials.scrub(text) }

    private func reference(_ action: QAAction) throws -> String {
        // A reference is `e` and a number; anything else is not an element of the last look.
        guard action.ref.range(of: "^e[0-9]{1,6}$", options: .regularExpression) != nil else {
            throw QANativeError.failed("\"\(action.ref)\" is not an element of the window.")
        }
        return action.ref
    }

    /// `com.example.App` from `com.example.App` or `app://com.example.App/Window title`.
    static func bundleIdentifier(from address: String) -> String {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("app://") { text = String(text.dropFirst("app://".count)) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        return text
    }
}
