import SwiftUI

/// Adaptive color palette — VS Code Dark+ in dark mode, VS Code Light+ in light mode
enum VSDark {
    private static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // Backgrounds
    static var bg: Color { isDark ? Color(hex: 0x1e1e1e) : Color(hex: 0xffffff) }
    static var bgSidebar: Color { isDark ? Color(hex: 0x252526) : Color(hex: 0xf3f3f3) }
    static var bgInput: Color { isDark ? Color(hex: 0x3c3c3c) : Color(hex: 0xe8e8e8) }
    static var bgHover: Color { isDark ? Color(hex: 0x2a2d2e) : Color(hex: 0xe8e8e8) }
    static var bgActive: Color { isDark ? Color(hex: 0x37373d) : Color(hex: 0xdcdcdc) }
    static var bgBanner: Color { isDark ? Color(hex: 0x1b1b1f) : Color(hex: 0xf0f0f0) }

    // Text
    static var text: Color { isDark ? Color(hex: 0xd4d4d4) : Color(hex: 0x1e1e1e) }
    static var textDim: Color { isDark ? Color(hex: 0x808080) : Color(hex: 0x6e7681) }
    static var textBright: Color { isDark ? Color(hex: 0xffffff) : Color(hex: 0x000000) }

    // Accent colors (same in both themes — they're designed to work on both)
    static let blue = Color(hex: 0x569cd6)
    static let green = Color(hex: 0x4ec9b0)
    static let orange = Color(hex: 0xce9178)
    static let yellow = Color(hex: 0xdcdcaa)
    static let purple = Color(hex: 0xc586c0)
    static let red = Color(hex: 0xf44747)
    static var cyan: Color { isDark ? Color(hex: 0x9cdcfe) : Color(hex: 0x0070c1) }

    // UI elements
    static var border: Color { isDark ? Color(hex: 0x3c3c3c) : Color(hex: 0xd4d4d4) }
    static var selection: Color { isDark ? Color(hex: 0x264f78) : Color(hex: 0xadd6ff) }
    static let badge = Color(hex: 0x007acc)

    // Entity type colors
    static func entityColor(_ type: String) -> Color {
        switch type {
        case "System": return cyan
        case "Service": return green
        case "Component": return Color(hex: 0x4ec9b0)
        case "API": return blue
        case "Event": return yellow
        case "Database": return purple
        case "Queue": return orange
        case "Team": return Color(hex: 0xd7ba7d)
        case "Environment": return Color(hex: 0x608b4e)
        case "Phase": return Color(hex: 0xb5cea8)
        default: return textDim
        }
    }

    // Claim type colors
    static func claimColor(_ type: String) -> Color {
        switch type {
        case "Definition": return blue
        case "Decision": return green
        case "Constraint": return red
        case "Requirement": return purple
        case "Assumption": return orange
        case "Risk": return red
        case "OwnershipClaim": return cyan
        case "CurrentState": return textDim
        case "TargetState": return yellow
        default: return textDim
        }
    }

    // Severity colors
    static func severityColor(_ severity: DiagnosticSeverity) -> Color {
        switch severity {
        case .error: return red
        case .warning: return orange
        case .info: return blue
        case .hint: return textDim
        }
    }
}

// Keep Matrix as alias for backward compatibility during migration
typealias Matrix = VSDark

// MARK: - Color hex init

extension Color {
    init(hex: Int) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

// MARK: - Reusable components

struct VSDarkHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(VSDark.text)
                .textCase(.uppercase)
            Spacer()
            if let count = count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(VSDark.textBright)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(VSDark.badge)
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(VSDark.bgSidebar)
    }
}

// Backward compat
typealias MatrixHeader = VSDarkHeader
typealias MatrixRow = VSDarkRow

struct VSDarkRow: View {
    let icon: String
    let text: String
    var detail: String? = nil
    var iconColor: Color = VSDark.blue
    var isActive: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        Button(action: { action?() }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(iconColor)
                    .frame(width: 16)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(isActive ? VSDark.textBright : VSDark.text)
                    .lineLimit(1)
                Spacer()
                if let detail = detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(VSDark.textDim)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isActive ? VSDark.bgActive : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
