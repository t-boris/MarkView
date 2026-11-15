import ApplicationServices
import CoreGraphics
import Foundation

// End-to-End QA (feature end-to-end-qa, DEC-008, DEC-012, DEC-017, DEC-023): makes the native player of every actor, and tells what the
// system still has to allow before a native check can run. A native check needs Accessibility (to read and operate the application) and
// Screen Recording (to take its pictures). Debug builds lose both grants whenever they are rebuilt (DEC-017).

/// Makes one native player for every actor (and one for the session that prepares data).
@MainActor
final class QANativeDriverFactory: QADriverFactory {
    private let config: QANativeActor.Config

    init(config: QANativeActor.Config = QANativeActor.Config()) {
        self.config = config
    }

    /// The request's address is the bundle identifier of the application (or `app://<bundle identifier>`).
    func makeDriver(_ request: QADriverRequest) async throws -> QAActorDriver {
        var credentials = QACredentials(username: request.login?.username, password: nil)
        if request.startupPolicy != .attach, let login = request.login {
            // The Keychain answers over a system service and may wait for the person: never on the main thread.
            credentials.password = await Task.detached(priority: .userInitiated) {
                BrowserPasswordStore.shared.password(host: login.host, username: login.username)
            }.value
        }
        return QANativeActor(request: request, credentials: credentials, config: config)
    }
}

/// A permission of the system that a native check needs.
enum QANativePermission {
    case accessibility
    case screenRecording
}

enum QANativePermissions {
    enum Status: Equatable {
        case granted
        case accessibilityMissing
        case screenRecordingMissing
        case both

        var missing: [QANativePermission] {
            switch self {
            case .granted: return []
            case .accessibilityMissing: return [.accessibility]
            case .screenRecordingMissing: return [.screenRecording]
            case .both: return [.accessibility, .screenRecording]
            }
        }

        /// What stops a check from starting; nil when nothing does. Accessibility is named first, as it is the one that is asked for first.
        var error: QANativeError? {
            switch self {
            case .granted: return nil
            case .accessibilityMissing, .both: return .accessibilityNotGranted
            case .screenRecordingMissing: return .screenRecordingNotGranted
            }
        }
    }

    static func status(accessibility: Bool, screenRecording: Bool) -> Status {
        switch (accessibility, screenRecording) {
        case (true, true): return .granted
        case (false, true): return .accessibilityMissing
        case (true, false): return .screenRecordingMissing
        case (false, false): return .both
        }
    }

    /// What the system allows this process now. Asks nothing and shows nothing.
    static var current: Status {
        status(accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess())
    }

    /// Shows the system's request for Accessibility (once per build; after that the person changes it in System Settings). True when granted.
    @discardableResult
    static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Shows the system's request for Screen Recording. True when it is granted already; a new grant counts after MarkView is restarted.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// The page of System Settings where the person allows the permission.
    static func systemSettingsURL(for permission: QANativePermission) -> URL {
        switch permission {
        case .accessibility: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .screenRecording: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}
