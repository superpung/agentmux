// The shared Ghostty terminal runtime: font, cursor and key settings, and a
// light/dark theme built on Apple Terminal's standard 16-color ANSI palette.
import AppKit
import Foundation
import GhosttyTerminal
import SwiftUI

/// The one Ghostty app object every surface shares. The theme carries both
/// palettes; Ghostty switches with the view's effective appearance.
@MainActor
enum GhosttyRuntime {
    static let controller = TerminalController(
        configuration: TerminalConfiguration(startingFrom: .default) { builder in
            builder.withFontFamily("SF Mono")
            builder.withFontSize(12.5)
            builder.withFontThicken(false)
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(true)
            // No padding inside the surface: the view is sized to exactly the
            // remote pane's grid, and SwiftUI adds the margins.
            builder.withWindowPaddingX(0)
            builder.withWindowPaddingY(0)
            // ⌘V is handled by PasteInterceptingTerminalView (paste through tmux).
            builder.withCustom("keybind", "super+v=unbind")
            // Option as Meta, for readline chords in shells and agent TUIs.
            builder.withCustom("macos-option-as-alt", "true")
            builder.withCustom("copy-on-select", "clipboard")
            // Shift always selects locally, even when the remote app captures the mouse.
            builder.withCustom("mouse-shift-capture", "never")
        },
        theme: theme
    )

    static let darkBackground = "#101012"
    static let lightBackground = "#FFFFFF"

    /// The terminal background, for the detail pane behind a centred surface so
    /// the letterbox margins read as terminal padding.
    static var terminalBackgroundColor: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? NSColor(srgbRed: 0x10 / 255, green: 0x10 / 255, blue: 0x12 / 255, alpha: 1)
                : NSColor.white
        })
    }

    /// Apple Terminal's 16-color ANSI palette.
    static let darkPalette: [(Int, Int, Int)] = [
        (0, 0, 0), (194, 54, 33), (37, 188, 36), (173, 173, 39),
        (73, 46, 225), (211, 56, 211), (51, 187, 200), (203, 204, 205),
        (129, 131, 131), (252, 57, 31), (49, 231, 34), (234, 236, 35),
        (88, 51, 255), (249, 53, 248), (20, 240, 240), (233, 235, 235),
    ]

    /// Per entry, whichever of the original and its luminance flip reads
    /// better on white: flips rescue colors made for dark backgrounds, while
    /// already-dark red/blue/magenta stay as they are.
    static let lightPalette: [(Int, Int, Int)] = darkPalette.map { color in
        let flipped = flip(color)
        return contrastOnWhite(color) >= contrastOnWhite(flipped) ? color : flipped
    }

    private static var theme: TerminalTheme {
        let dark = TerminalConfiguration { builder in
            builder.withBackground(darkBackground)
            builder.withForeground("#D6D6D6")
            for (index, color) in darkPalette.enumerated() {
                builder.withPalette(index, color: hex(color))
            }
        }
        let light = TerminalConfiguration { builder in
            builder.withBackground(lightBackground)
            builder.withForeground("#3A3A3A")
            for (index, color) in lightPalette.enumerated() {
                builder.withPalette(index, color: hex(color))
            }
        }
        return TerminalTheme(light: light, dark: dark)
    }

    private static func flip(_ color: (Int, Int, Int)) -> (Int, Int, Int) {
        let luminance = 0.2126 * Double(color.0) + 0.7152 * Double(color.1) + 0.0722 * Double(color.2)
        let offset = 255 - 2 * luminance
        func clamp(_ value: Double) -> Int { Int(min(255, max(0, value.rounded()))) }
        return (clamp(Double(color.0) + offset), clamp(Double(color.1) + offset), clamp(Double(color.2) + offset))
    }

    /// WCAG contrast ratio against white.
    private static func contrastOnWhite(_ color: (Int, Int, Int)) -> Double {
        func linear(_ value: Int) -> Double {
            let channel = Double(value) / 255
            return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(color.0) + 0.7152 * linear(color.1) + 0.0722 * linear(color.2)
        return 1.05 / (luminance + 0.05)
    }

    private static func hex(_ color: (Int, Int, Int)) -> String {
        String(format: "#%02X%02X%02X", color.0, color.1, color.2)
    }

    /// The terminal background for a given theme preference, used behind the
    /// surface so the letterbox margins match the forced palette.
    static func terminalBackground(for preference: TerminalThemePreference) -> Color {
        switch preference {
        case .system: terminalBackgroundColor
        case .light: Color(nsColor: .white)
        case .dark: Color(nsColor: NSColor(srgbRed: 0x10 / 255, green: 0x10 / 255, blue: 0x12 / 255, alpha: 1))
        }
    }
}

/// How an embedded terminal picks its light/dark palette. `.system` follows the
/// Mac; `.light`/`.dark` pin it — which matters because an agent's TUI renders
/// for the terminal it was started in (usually dark), so a mirror shown under a
/// mismatched appearance looks wrong (e.g. Codex's dark input box on a white
/// surface).
enum TerminalThemePreference: String, CaseIterable, Sendable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The AppKit appearance to force on a terminal surface; nil follows the
    /// inherited (system) appearance, which is what Ghostty reads to pick a
    /// light vs dark palette.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
