import AppKit
import SwiftUI

// End-to-End QA (feature end-to-end-qa, REQ-003, DEC-008, DEC-017): what the system must allow before a native macOS check can start. MarkView
// reads and operates the application through Accessibility and takes its pictures through Screen Recording; the person grants both in System
// Settings, so this row says which one is missing and goes there. The panel owns the status and re-reads it when MarkView becomes active again.

struct QANativePermissionsView: View {
    @Environment(\.palette) private var palette
    let status: QANativePermissions.Status
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("A native check needs two permissions").uiFont(size: 11.5, weight: .semibold)
            row(.accessibility, title: "Accessibility", detail: "lets MarkView read and operate the application")
            row(.screenRecording, title: "Screen Recording", detail: "lets MarkView take pictures of the application's window for the feed and the video")
            if status != .granted {
                Text("Screen Recording counts after MarkView is restarted. A build that is not signed with a Developer ID loses both permissions each time it is rebuilt.")
                    .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func row(_ permission: QANativePermission, title: String, detail: String) -> some View {
        let missing = status.missing.contains(permission)
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: missing ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundColor(missing ? palette.red : palette.green).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).uiFont(size: 11)
                Text(detail).uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if missing {
                Button("Allow…") { allow(permission) }.controlSize(.small)
                Button("Open System Settings") { NSWorkspace.shared.open(QANativePermissions.systemSettingsURL(for: permission)) }.controlSize(.small)
            }
        }
    }

    private func allow(_ permission: QANativePermission) {
        switch permission {
        case .accessibility: QANativePermissions.requestAccessibility()
        case .screenRecording: QANativePermissions.requestScreenRecording()
        }
        refresh()
    }
}
