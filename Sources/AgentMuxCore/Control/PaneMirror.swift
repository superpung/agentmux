import Foundation

/// Mirrors one existing tmux pane into a local terminal over control mode.
///
/// Nothing shared changes: no window or pane is selected, no size is set.
/// Input goes to this pane only (`send-keys -H -t %N`), and pastes go
/// through `paste-buffer -p`, so tmux adds bracketed-paste markers exactly
/// when the program in the pane asked for them.
///
/// Sync: one command line asks for the pane's size, cursor and modes and
/// captures its screen. tmux runs a line as one unit, so output that
/// arrives before its reply is already in the capture (and dropped), and
/// output after the reply follows the capture (and is applied).
public final class PaneMirror: @unchecked Sendable {
    public struct Geometry: Sendable, Equatable {
        public var columns: Int
        public var rows: Int
    }

    public let paneID: String
    private let client: ControlClient

    // Confined to client.queue.
    private var live = false
    private var ended = false
    private var geometry: Geometry?
    private var requestedSize: Geometry?
    private var pendingSize: Geometry?
    private var sizeGeneration = 0
    private var silenced = Set<String>()
    private var onTerminalBytes: (@Sendable (Data) -> Void)?
    private var onGeometry: (@Sendable (Geometry) -> Void)?
    private var onEnded: (@Sendable (String) -> Void)?

    public var clientTag: String { client.clientTag }

    public static let maxPasteBytes = 256 << 10

    public init(host: HostConfig, target: TargetConfig, session: String, paneID: String, options: SSHOptions = SSHOptions()) throws {
        guard TmuxQuote.id(paneID) != nil, paneID.hasPrefix("%") else {
            throw InvalidRemoteValue(field: "pane", value: paneID)
        }
        self.paneID = paneID
        client = try ControlClient(host: host, target: target, session: session, options: options)
    }

    /// `onGeometry` comes before the bytes that assume it. All callbacks run
    /// on the control client's queue.
    public func start(
        onTerminalBytes: @escaping @Sendable (Data) -> Void,
        onGeometry: @escaping @Sendable (Geometry) -> Void,
        onEnded: @escaping @Sendable (String) -> Void
    ) throws {
        client.queue.sync {
            self.onTerminalBytes = onTerminalBytes
            self.onGeometry = onGeometry
            self.onEnded = onEnded
        }
        try client.start { [weak self] event in self?.handle(event) }
        // The client is attached to its own grouped session: remove it when
        // the client leaves (or the app dies), and focus the agent's window
        // so `refresh-client -C` sizes that window and not another.
        client.send("set-option destroy-unattached on") { _ in }
        if let target = TmuxQuote.id(paneID) {
            client.send("select-window -t \(target)") { _ in }
        }
        resync()
    }

    /// Redraws the local terminal from the pane's current state.
    public func resync() {
        client.queue.async { [self] in
            guard !ended else { return }
            live = false
            client.send(syncCommands) { [weak self] result in self?.applySync(result) }
        }
    }

    /// Raw input bytes (keys, mouse reports) for this pane only.
    public func sendInput(_ data: Data) {
        guard !data.isEmpty, let target = TmuxQuote.id(paneID) else { return }
        var start = data.startIndex
        while start < data.endIndex {
            let end = data.index(start, offsetBy: 256, limitedBy: data.endIndex) ?? data.endIndex
            let hex = data[start ..< end].map { String(format: "%02x", $0) }.joined(separator: " ")
            client.send("send-keys -t \(target) -H \(hex)") { _ in }
            start = end
        }
    }

    /// Pastes text into this pane through a temporary named buffer, which
    /// `paste-buffer -d` deletes again.
    public func paste(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= Self.maxPasteBytes, let target = TmuxQuote.id(paneID) else { return false }
        let buffer = "agentmux-\(client.clientTag)"
        client.send([
            "set-buffer -b \(buffer) -- \(TmuxQuote.word(text))",
            "paste-buffer -p -d -b \(buffer) -t \(target)",
        ]) { _ in }
        return true
    }

    /// Drives the remote window to `columns`×`rows` so the pane fills the
    /// local view. `refresh-client -C` is only a soft request that other
    /// active clients override, so this forces the size with `resize-window`
    /// (which sets the window to `manual`); `close()` restores `latest`.
    /// Debounced, because a window drag produces a stream of sizes. tmux
    /// reflows the pane and sends a layout change, which triggers a resync.
    public func setViewportSize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        client.queue.async { [self] in
            guard !ended, requestedSize != Geometry(columns: columns, rows: rows) else { return }
            pendingSize = Geometry(columns: columns, rows: rows)
            sizeGeneration += 1
            let generation = sizeGeneration
            client.queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.flushSize(generation)
            }
        }
    }

    private func flushSize(_ generation: Int) {
        guard !ended, generation == sizeGeneration, let size = pendingSize, size != requestedSize else { return }
        requestedSize = size
        // Soft size: `refresh-client -C` sizes this client's current window
        // (the agent's window, in our grouped session) under `window-size
        // latest`. It is not forced, so it self-heals to the user's clients
        // when we leave — no restore needed.
        client.send("refresh-client -C \(size.columns)x\(size.rows)") { _ in }
        // Some TUIs (Codex) repaint their bottom input composer asynchronously
        // after the resize's SIGWINCH, so the layout-change capture misses it.
        // Re-capture once the repaint has settled, if no newer resize arrived.
        client.queue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !ended, generation == sizeGeneration else { return }
            resync()
        }
    }

    public func close() {
        client.queue.async { [self] in
            guard !ended else { return }
            // Remove our grouped session now; its windows survive in the
            // user's session, and `destroy-unattached` is the crash-safety
            // net if this command never lands.
            client.send("kill-session -t \(RemoteCommand.groupedSessionName(clientTag: client.clientTag))") { _ in }
            ended = true
            onTerminalBytes = nil
            onGeometry = nil
            onEnded = nil
        }
        // Let kill-session flush before stdin closes.
        client.queue.asyncAfter(deadline: .now() + 0.2) { [client] in client.close() }
    }

    // MARK: - Queue-confined

    static let formatFields = [
        "pane_width", "pane_height", "cursor_x", "cursor_y", "alternate_on",
        "keypad_cursor_flag", "keypad_flag", "mouse_standard_flag", "mouse_button_flag",
        "mouse_any_flag", "mouse_sgr_flag", "origin_flag", "wrap_flag", "insert_flag",
        "scroll_region_upper", "scroll_region_lower", "cursor_flag",
    ]

    /// Pane state, the normal screen saved under an alternate screen (empty
    /// otherwise) and the visible screen, as one unit.
    private var syncCommands: [String] {
        let target = TmuxQuote.id(paneID)!
        let format = Self.formatFields.map { "#{\($0)}" }.joined(separator: " ")
        return [
            "display-message -p -t \(target) '\(format)'",
            "capture-pane -p -e -N -a -q -t \(target)",
            "capture-pane -p -e -N -t \(target)",
        ]
    }

    private func applySync(_ result: Result<[ControlReply], ControlError>) {
        guard !ended else { return }
        switch result {
        case let .failure(error):
            end("\(error)")
        case let .success(replies):
            guard replies.count == 3, let state = Self.parseSync(
                state: replies[0].lines, savedNormal: replies[1].lines, visible: replies[2].lines
            ) else {
                end("could not read pane state")
                return
            }
            if geometry != state.geometry {
                geometry = state.geometry
                onGeometry?(state.geometry)
            }
            onTerminalBytes?(state.initialBytes())
            live = true
        }
    }

    private func handle(_ event: ControlEvent) {
        guard !ended else { return }
        switch event {
        case let .output(pane, data):
            if pane == paneID {
                // Before the sync reply, the capture already contains it.
                if live { onTerminalBytes?(data) }
            } else if !silenced.contains(pane), let target = TmuxQuote.id(pane) {
                // Only this pane's output is wanted.
                silenced.insert(pane)
                client.send("refresh-client -A \(target):off") { _ in }
            }
        case let .notification(name, arguments):
            switch name {
            case "pause" where arguments == paneID:
                // tmux paused this pane because we fell behind: resume and redraw.
                client.send("refresh-client -A \(TmuxQuote.id(paneID)!):continue") { _ in }
                resync()
            case "layout-change", "window-pane-changed", "window-close", "unlinked-window-close", "sessions-changed":
                checkPane()
            default:
                break
            }
        case let .exit(reason):
            end(reason ?? "connection closed")
        case .reply:
            break
        }
    }

    /// After a layout change: redraw if the size changed, end if the pane is gone.
    private func checkPane() {
        let target = TmuxQuote.id(paneID)!
        client.send("display-message -p -t \(target) '#{pane_width} #{pane_height}'") { [weak self] result in
            guard let self, !ended else { return }
            switch result {
            case let .success(reply):
                let fields = reply.textLines.first?.split(separator: " ").compactMap { Int($0) } ?? []
                if fields.count == 2, Geometry(columns: fields[0], rows: fields[1]) != geometry {
                    resync()
                }
            case .failure:
                end("pane closed")
            }
        }
    }

    private func end(_ reason: String) {
        guard !ended else { return }
        ended = true
        live = false
        onEnded?(reason)
    }

    // MARK: - Sync state

    struct SyncState: Equatable {
        var geometry: Geometry
        var cursorX: Int
        var cursorY: Int
        var alternate: Bool
        var flags: [String: Bool]
        var scrollRegion: (upper: Int, lower: Int)?
        var cursorVisible: Bool?
        /// Normal screen saved while the alternate screen is active.
        var savedNormal: [Data]
        var visible: [Data]

        static func == (lhs: SyncState, rhs: SyncState) -> Bool {
            lhs.geometry == rhs.geometry && lhs.cursorX == rhs.cursorX && lhs.cursorY == rhs.cursorY
                && lhs.alternate == rhs.alternate && lhs.flags == rhs.flags
                && lhs.scrollRegion?.upper == rhs.scrollRegion?.upper && lhs.scrollRegion?.lower == rhs.scrollRegion?.lower
                && lhs.cursorVisible == rhs.cursorVisible && lhs.savedNormal == rhs.savedNormal && lhs.visible == rhs.visible
        }

        /// Bytes that turn a fresh terminal into a copy of the pane.
        func initialBytes() -> Data {
            var out = Data("\u{1B}c".utf8) // full reset
            func draw(_ rows: [Data]) {
                for (index, row) in rows.prefix(geometry.rows).enumerated() {
                    out += Data("\u{1B}[\(index + 1);1H".utf8)
                    out += row
                    out += Data("\u{1B}[0m".utf8)
                }
            }
            if alternate {
                draw(savedNormal)
                out += Data("\u{1B}[?1049h".utf8)
            }
            draw(visible)
            if flags["keypad_cursor_flag"] == true { out += Data("\u{1B}[?1h".utf8) }
            if flags["keypad_flag"] == true { out += Data("\u{1B}=".utf8) }
            if flags["mouse_standard_flag"] == true { out += Data("\u{1B}[?1000h".utf8) }
            if flags["mouse_button_flag"] == true { out += Data("\u{1B}[?1002h".utf8) }
            if flags["mouse_any_flag"] == true { out += Data("\u{1B}[?1003h".utf8) }
            if flags["mouse_sgr_flag"] == true { out += Data("\u{1B}[?1006h".utf8) }
            if flags["wrap_flag"] == false { out += Data("\u{1B}[?7l".utf8) }
            if flags["insert_flag"] == true { out += Data("\u{1B}[4h".utf8) }
            var cursorRow = cursorY
            if let region = scrollRegion, region.upper != 0 || region.lower != geometry.rows - 1 {
                out += Data("\u{1B}[\(region.upper + 1);\(region.lower + 1)r".utf8)
                if flags["origin_flag"] == true {
                    out += Data("\u{1B}[?6h".utf8)
                    cursorRow -= region.upper
                }
            }
            out += Data("\u{1B}[\(cursorRow + 1);\(cursorX + 1)H".utf8)
            if cursorVisible == false { out += Data("\u{1B}[?25l".utf8) }
            return out
        }
    }

    static func parseSync(state: [Data], savedNormal: [Data], visible: [Data]) -> SyncState? {
        guard let first = state.first else { return nil }
        let values = String(decoding: first, as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard values.count == formatFields.count,
              let width = Int(values[0]), let height = Int(values[1]), width > 0, height > 0,
              let x = Int(values[2]), let y = Int(values[3])
        else { return nil }
        var flags: [String: Bool] = [:]
        for (name, value) in zip(formatFields, values) where name.hasSuffix("_flag") || name == "alternate_on" {
            if value == "1" { flags[name] = true } else if value == "0" { flags[name] = false }
        }
        let region: (Int, Int)? = Int(values[14]).flatMap { upper in Int(values[15]).map { (upper, $0) } }
        return SyncState(
            geometry: Geometry(columns: width, rows: height),
            cursorX: x,
            cursorY: y,
            alternate: flags["alternate_on"] == true,
            flags: flags,
            scrollRegion: region,
            cursorVisible: flags["cursor_flag"],
            savedNormal: savedNormal,
            visible: visible
        )
    }
}
