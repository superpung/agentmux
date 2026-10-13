// Design tokens and status marks adapted from a Mac agent console
// (a Mac agent console, an upstream reference, a noncommercial license;
// reused for personal, non-distributed use).
import AgentMuxCore
import AppKit
import SwiftUI

/// Light/dark adaptive design tokens.
enum Theme {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    // text ramp
    static let text = dynamic(hex(0x242424), hex(0xE2E2E2))
    static let textSecondary = dynamic(hex(0x666666), hex(0xA3A3A3))
    static let textTertiary = dynamic(hex(0x858585), hex(0x7D7D7D))
    static let textGhost = dynamic(hex(0xA4A4A4), hex(0x575757))

    // accent + status
    static let accent = dynamic(hex(0xC85F44), hex(0xE2795B))
    static let working = dynamic(hex(0x2563EB), hex(0x3B82F6))
    static let success = dynamic(hex(0x2FA35F), hex(0x62C987))
    static let warning = dynamic(hex(0xB8862E), hex(0xE0B36A))
    static let danger = dynamic(hex(0xC94F44), hex(0xE2726A))

    // surfaces
    static let itemWash = dynamic(hex(0x141414, alpha: 0.06), hex(0xF0F0F0, alpha: 0.06))
    static let itemWashSelected = dynamic(hex(0x141414, alpha: 0.07), hex(0xF0F0F0, alpha: 0.07))
    static let contentBackground = dynamic(hex(0xF6F6F6), hex(0x181818))
    static let terminalBackground = dynamic(hex(0xFFFFFF), hex(0x101012))
    static let sidebarBorder = dynamic(hex(0xD9D9D9), hex(0x292929))
    static let hairline = dynamic(hex(0x000000, alpha: 0.08), hex(0xFFFFFF, alpha: 0.06))

    /// Distinct tints for device chips (deliberately avoids the status colors).
    static let devicePalette: [Color] = [
        dynamic(hex(0x7C3AED), hex(0x8B5CF6)), // violet
        dynamic(hex(0x0D9488), hex(0x14B8A6)), // teal
        dynamic(hex(0xBE185D), hex(0xEC4899)), // magenta
        dynamic(hex(0x4338CA), hex(0x818CF8)), // indigo
        dynamic(hex(0x92640C), hex(0xC9964A)), // bronze
    ]

    /// Stable per-target tint.
    static func deviceTint(_ targetID: String) -> Color {
        let sum = targetID.utf8.reduce(0) { $0 &+ Int($1) }
        return devicePalette[sum % devicePalette.count]
    }

    static func activityColor(_ activity: AgentActivity) -> Color {
        switch activity {
        case .working: working
        case .waitingInput, .waitingApproval: warning
        case .idle: success
        case .exited, .unknown: textGhost
        }
    }

    /// Short label for a status chip; nil when there is nothing worth asserting.
    static func activityLabel(_ activity: AgentActivity) -> String? {
        switch activity {
        case .working: "Working"
        case .waitingInput: "Needs input"
        case .waitingApproval: "Needs approval"
        case .idle: "Idle"
        case .exited: "Exited"
        case .unknown: nil
        }
    }

    /// A load / usage fraction (0…1) mapped to the shared semantic ramp.
    static func meterColor(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.7: success
        case ..<0.9: warning
        default: danger
        }
    }
}

/// Spinner while working, a mark when the agent needs you, nothing otherwise.
struct AgentStatusGlyph: View {
    let activity: AgentActivity

    var body: some View {
        switch activity {
        case .working:
            // Same weight as the adjacent last-active time (.tertiary).
            SpinnerView(color: .tertiary)
                .frame(width: 12, height: 12)
        case .waitingInput, .waitingApproval:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.warning)
        case .idle, .exited, .unknown:
            EmptyView()
        }
    }
}

struct SpinnerView<S: ShapeStyle>: View {
    let color: S
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1)
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
