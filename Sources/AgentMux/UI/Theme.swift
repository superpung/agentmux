// Light/dark design tokens for the app: Apple's semantic system colors for the
// neutral text ramp, status and device tints, plus a small set of explicit
// brand-accent and surface values.
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

    // Neutral text ramp: Apple's semantic label colors.
    static let text = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    static let textGhost = Color(nsColor: .quaternaryLabelColor)

    // Brand accent (ours); status colors map to the system palette.
    static let accent = dynamic(hex(0xC65A3E), hex(0xE07D5E))
    static let working = Color(nsColor: .systemBlue)
    static let success = Color(nsColor: .systemGreen)
    /// Finished while no one was looking. Green means only this in agent
    /// status; idle is neutral.
    static let done = success
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)

    // Surfaces: neutral washes and hairlines over the content.
    static let itemWash = dynamic(hex(0x141414, alpha: 0.06), hex(0xF0F0F0, alpha: 0.06))
    static let itemWashSelected = dynamic(hex(0x141414, alpha: 0.07), hex(0xF0F0F0, alpha: 0.07))
    static let contentBackground = dynamic(hex(0xF6F6F6), hex(0x181818))
    static let terminalBackground = dynamic(hex(0xFFFFFF), hex(0x101012))
    static let sidebarBorder = Color(nsColor: .separatorColor)
    static let hairline = dynamic(hex(0x000000, alpha: 0.08), hex(0xFFFFFF, alpha: 0.06))

    /// Distinct tints for device chips, from the system accent palette
    /// (deliberately kept clear of the status colors above).
    static let devicePalette: [Color] = [
        Color(nsColor: .systemPurple),
        Color(nsColor: .systemTeal),
        Color(nsColor: .systemPink),
        Color(nsColor: .systemIndigo),
        Color(nsColor: .systemBrown),
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
        case .idle: textSecondary
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

/// Spinner while working, a mark when the agent needs you or finished
/// unseen, nothing otherwise.
struct AgentStatusGlyph: View {
    let activity: AgentActivity
    /// Why an idle agent stopped short, shown in place of nothing.
    var fault: AgentFault? = nil
    /// Working, but waiting out an API retry: the spinner turns the warning tint.
    var retrying = false
    /// Finished while no one was looking.
    var done = false
    /// On a highlighted (accent) row: the mark in the row's text color, as
    /// menus draw their icons there, since status colors don't read on it.
    var plain = false

    /// One box for every mark, so marks of different shapes line up. With
    /// no mark there is no box.
    static let width: CGFloat = 14

    var body: some View {
        Group {
            if activity != .working, !activity.needsAttention, let fault {
                Image(systemName: fault.kind == .usageLimit ? "hourglass" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint(fault.kind == .usageLimit ? Color(nsColor: .systemPurple) : Theme.danger))
                    .help(fault.summary)
            } else {
                activityGlyph
            }
        }
        .frame(width: Self.width, height: Self.width)
        // One mark gives way to the next (a spinner to a check) with a fade.
        .animation(Motion.quick, value: "\(activity)\(done)\(retrying)\(fault?.kind == nil)")
    }

    private func tint(_ color: some ShapeStyle) -> AnyShapeStyle {
        plain ? AnyShapeStyle(.primary) : AnyShapeStyle(color)
    }

    @ViewBuilder private var activityGlyph: some View {
        switch activity {
        case .working:
            if retrying {
                SpinnerView(color: tint(Theme.warning))
                    .frame(width: 12, height: 12)
                    .help("Retrying")
            } else {
                // Same weight as the adjacent last-active time (.tertiary).
                SpinnerView(color: tint(.tertiary))
                    .frame(width: 12, height: 12)
            }
        case .waitingInput, .waitingApproval:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint(Theme.warning))
        case .idle, .exited, .unknown:
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint(Theme.done))
                    .help("Done")
            }
        }
    }
}

/// How long an agent has been working, or how long ago it was last active.
struct ActivityTime: View {
    let entry: AgentEntry
    /// At the end of a one-line row after a status chip: room for the
    /// widest time ("23h"), right-aligned, so the chips before it line up.
    var fixedWidth = false

    var body: some View {
        Group {
            if entry.activity == .working {
                if let since = entry.since {
                    TimelineView(.periodic(from: since, by: 60)) { context in
                        Text(RelativeTime.elapsed(Int(context.date.timeIntervalSince(since))))
                    }
                }
            } else if let active = RelativeTime.short(entry.lastActiveSeconds) {
                Text(active)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
        .frame(minWidth: fixedWidth ? 24 : nil, alignment: .trailing)
    }
}

/// A ring that fills up until an automatic continue is sent.
struct NudgeRing: View {
    let start: Date
    let fireAt: Date
    var size: CGFloat = 11

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { context in
            let total = max(1, fireAt.timeIntervalSince(start))
            let progress = min(1, max(0, context.date.timeIntervalSince(start) / total))
            ZStack {
                Circle().stroke(Color(nsColor: .systemBlue).opacity(0.2), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color(nsColor: .systemBlue), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size, height: size)
        }
        .help("Continues automatically")
    }
}

struct SpinnerView<S: ShapeStyle>: View {
    let color: S

    /// Seconds per revolution.
    private static var period: Double { 0.9 }

    var body: some View {
        // The angle is derived from wall-clock time, not an animated @State
        // flag with `.onAppear`. An implicit rotation animation that starts as
        // the view is inserted gets captured by whatever ambient transaction is
        // live at that moment (e.g. the detail view's selection-change
        // easeInOut), which distorted the spin on appearance — the "fly". A
        // time-driven angle is correct from the first frame and immune to that.
        // 360° ≡ 0°, so the per-period wrap is seamless with no implicit tween.
        TimelineView(.animation) { context in
            let angle = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.period) / Self.period * 360
            Circle()
                .trim(from: 0.12, to: 1)
                .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(angle))
        }
    }
}

extension View {
    /// Rolls a numeric Text digit-by-digit when `value` changes, for live
    /// figures (metrics, counts, percentages). Not for relative-time strings,
    /// whose format shifts ("59m" → "1h") and reads worse animated.
    func rollingNumber(_ value: some Equatable) -> some View {
        contentTransition(.numericText())
            .animation(.easeOut(duration: 0.25), value: value)
    }
}
