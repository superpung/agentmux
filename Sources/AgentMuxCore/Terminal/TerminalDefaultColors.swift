import Foundation

/// The terminal's default colors, also used by TUIs to choose their own fills.
/// A tmux control client has no tty from which tmux can discover these colors.
public struct TerminalDefaultColors: Sendable, Equatable {
    public let foreground: UInt32
    public let background: UInt32

    public init(foreground: UInt32, background: UInt32) {
        precondition(foreground <= 0xFFFFFF && background <= 0xFFFFFF)
        self.foreground = foreground
        self.background = background
    }

    public var foregroundHex: String { String(format: "#%06X", foreground) }
    public var backgroundHex: String { String(format: "#%06X", background) }

    /// Reports colors to tmux, rather than typing terminal replies into a TUI.
    /// tmux accepts one complete OSC response per `refresh-client -r`.
    public func reportCommands(paneID: String) -> [String] {
        guard paneID.hasPrefix("%"), TmuxQuote.id(paneID) != nil else { return [] }
        return [(10, foreground), (11, background)].map { slot, color in
            let components = [16, 8, 0].map { shift in
                String(format: "%04x", ((color >> shift) & 0xFF) * 257)
            }.joined(separator: "/")
            let report = "\u{1B}]\(slot);rgb:\(components)\u{07}"
            return "refresh-client -r \(TmuxQuote.word(paneID + ":" + report))"
        }
    }

    /// A newly created pane needs its colors before the agent's startup probe,
    /// which runs before the app has discovered and opened its control client.
    var paneStyle: String {
        "fg=\(foregroundHex.lowercased()),bg=\(backgroundHex.lowercased())"
    }
}
