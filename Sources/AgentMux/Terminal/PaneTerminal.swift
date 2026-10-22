import AgentMuxCore
import AppKit
import Combine
import Foundation
import GhosttyTerminal
import Observation

/// One Ghostty surface mirroring one remote pane through `PaneMirror`.
@MainActor
@Observable
final class PaneTerminal {
    enum Phase: Equatable {
        case connecting
        case live
        /// The mirror ended; input is disabled. The pane is untouched.
        case ended(String)
        /// The tmux server changed under this view.
        case stale(String)
    }

    /// Called on the main actor when the user zooms this terminal (⌘ +/−), so
    /// the model can remember the new size for next time. Set by the model.
    @ObservationIgnored var onFontSizeChanged: (@MainActor (Double) -> Void)?
    @ObservationIgnored private var fontSizeObserver: AnyCancellable?

    let ref: PaneRef
    let state = TerminalViewState(controller: GhosttyRuntime.controller)
    /// Called (throttled) when the mirrored pane emits output, so the model can
    /// refresh this agent's state promptly while the user is watching it.
    @ObservationIgnored var onActivity: (@MainActor @Sendable () -> Void)?
    /// A path the user asked to preview (via the terminal's context menu).
    @ObservationIgnored var onPreviewRequest: ((String) -> Void)?
    /// Last time an activity notification fired; confined to the mirror queue.
    @ObservationIgnored nonisolated(unsafe) private var lastActivityNotify = Date.distantPast
    private(set) var phase: Phase = .connecting
    /// The remote pane's size, which the app drives to match the local view.
    private(set) var geometry: PaneMirror.Geometry?
    private let mirror: PaneMirror
    private let session: InMemoryTerminalSession
    private let gate: InputGate
    private let host: HostConfig
    private let target: TargetConfig
    /// The surface's forced palette; Ghostty reads the view's appearance to pick
    /// light vs dark, so this just sets that appearance.
    private var themePreference: TerminalThemePreference = .system
    private weak var surfaceView: PasteInterceptingTerminalView?

    var clientTag: String { mirror.clientTag }

    /// Pins this terminal's palette (follow-system / light / dark). Applied to
    /// the live surface immediately and remembered for the surface if it has not
    /// been created yet.
    func applyTheme(_ preference: TerminalThemePreference) {
        themePreference = preference
        surfaceView?.appearance = preference.appearance
    }

    init(ref: PaneRef, sessionID: String, host: HostConfig, target: TargetConfig) throws {
        let mirror = try PaneMirror(host: host, target: target, session: sessionID, paneID: ref.paneID)
        let gate = InputGate()
        let session = InMemoryTerminalSession(
            write: { data in
                // Keys and mouse reports reach the pane only while this view
                // is selected and live.
                if gate.isOpen { mirror.sendInput(data) }
            },
            // The local surface drives the remote window size, so the pane
            // reflows to fill the view (like a normal terminal) rather than
            // being letterboxed.
            resize: { viewport in
                mirror.setViewportSize(columns: Int(viewport.columns), rows: Int(viewport.rows))
            }
        )
        self.ref = ref
        self.mirror = mirror
        self.session = session
        self.gate = gate
        self.host = host
        self.target = target

        state.makePlatformView = { [weak self] in
            let view = PasteInterceptingTerminalView(frame: .zero)
            view.onPaste = { text in self?.paste(text) ?? false }
            view.onPreviewPath = { raw in self?.onPreviewRequest?(raw) }
            view.onShiftEnter = { [weak self] in _ = self?.sendNewline() }
            view.onPasteImage = { [weak self] png in self?.pasteImage(png) }
            // Ghostty picks its palette from the view's appearance; honour the
            // terminal's theme preference (set before this runs via applyTheme).
            view.appearance = self?.themePreference.appearance
            self?.surfaceView = view
            return view
        }
        var options = TerminalSurfaceOptions(backend: .inMemory(session))
        options.fontSize = Float(GhosttyRuntime.currentFontSize)
        state.configuration = options

        // Remember a size reached by zooming (⌘ +/−): the published fontSize
        // changes, we drop the initial configured value and report the rest.
        fontSizeObserver = state.$fontSize
            .compactMap { $0 }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in self?.onFontSizeChanged?(Double(size)) }

        try mirror.start(
            onTerminalBytes: { [weak self] data in
                session.receive(data)
                self?.noteActivity()
            },
            onGeometry: { [weak self] geometry in
                Task { @MainActor in self?.geometry = geometry }
            },
            onEnded: { [weak self] reason in
                gate.close()
                Task { @MainActor in self?.markEnded(reason) }
            }
        )
        gate.markLive()
        phase = .live
        scheduleSmokeIfRequested()
    }

    /// Runs on the mirror's serial queue when pane output arrives. Throttled so
    /// a burst of output triggers at most one refresh every 1.5 s.
    nonisolated private func noteActivity() {
        let now = Date()
        guard now.timeIntervalSince(lastActivityNotify) > 1.5 else { return }
        lastActivityNotify = now
        Task { @MainActor [weak self] in self?.onActivity?() }
    }

    var phaseText: String {
        switch phase {
        case .connecting: "Connecting…"
        case .live: "Mirroring · input goes to this pane only"
        case let .ended(reason): "Disconnected: \(reason) · input disabled"
        case let .stale(reason): "Stale: \(reason) · input disabled"
        }
    }

    /// The mirror is no longer usable (the server generation changed or the
    /// client ended), as opposed to merely connecting or live.
    var isTrouble: Bool {
        switch phase {
        case .connecting, .live: false
        case .ended, .stale: true
        }
    }

    /// Only the terminal on screen may send input; hidden ones drop it even
    /// if they still hold keyboard focus.
    func setActive(_ active: Bool) {
        gate.setSelected(active)
        state.isSurfaceVisible = active
        if active { state.requestFocus() }
    }

    /// Pastes through tmux so bracketed paste follows the pane's real mode.
    func paste(_ text: String) -> Bool {
        guard gate.isOpen else { return false }
        return mirror.paste(text)
    }

    /// Whether input can currently be delivered (mirror live and on screen).
    var canSend: Bool { gate.isOpen }

    /// Pastes `text`, then (when `submit`) presses Enter so an agent CLI runs
    /// the prompt. Returns false if input is not currently allowed.
    func send(_ text: String, submit: Bool) -> Bool {
        guard gate.isOpen, mirror.paste(text) else { return false }
        if submit { mirror.sendInput(Data([0x0d])) }
        return true
    }

    /// Shift+Enter inserts a soft newline in the agent's input instead of
    /// submitting it: remote line editors (Claude Code, Codex) treat a bare LF
    /// as a newline, while plain Enter sends CR, which submits.
    func sendNewline() -> Bool {
        guard gate.isOpen else { return false }
        mirror.sendInput(Data([0x0a]))
        return true
    }

    /// ⌘V of an image: the remote agent can't see the Mac's clipboard, so the
    /// image is uploaded to a temp path in the container (/tmp, outside the
    /// workspace) and its path is injected as text — which Claude Code reads as
    /// an image reference. A unique name means no overwrite prompt.
    func pasteImage(_ png: Data) {
        guard gate.isOpen else { return }
        let directory = "/tmp/agentmux-paste"
        let path = "\(directory)/\(UUID().uuidString).png"
        Task { @MainActor in
            _ = await RemoteFileService.makeDirectory(directory, host: host, target: target)
            let result = await RemoteFileService.upload(png, to: path, host: host, target: target, overwrite: true)
            if case .success = result {
                _ = paste(path + " ")
                // Keep the cache small; the just-pasted file is new, so it stays.
                await RemoteFileService.pruneOld(directory, olderThanDays: 1, host: host, target: target)
            } else {
                NSSound.beep()
            }
        }
    }

    func resync() {
        mirror.resync()
    }

    func markStale(reason: String) {
        gate.close()
        phase = .stale(reason)
    }

    func close() {
        gate.close()
        mirror.close()
    }

    private func markEnded(_ reason: String) {
        if case .stale = phase { return }
        phase = .ended(reason)
    }

    /// AGENTMUX_SMOKE_DUMP=<path> with AGENTMUX_OPEN: type AGENTMUX_SMOKE_INPUT
    /// after the view connects, write the viewport text to <path> and quit.
    private func scheduleSmokeIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["AGENTMUX_SMOKE_DUMP"] else { return }
        let input = environment["AGENTMUX_SMOKE_INPUT"]
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if let input, let self {
                _ = self.paste(input)
                try? await Task.sleep(for: .milliseconds(300))
                self.mirror.sendInput(Data("\r".utf8))
            }
            try? await Task.sleep(for: .seconds(3))
            let text = self?.session.readViewportText() ?? "<no surface attached>"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            AppDelegate.performOnMainRunLoop { NSApp.terminate(nil) }
        }
    }
}

/// ⌘V goes to tmux (`paste-buffer -p`) instead of Ghostty's local paste:
/// the local mirror cannot know whether the remote program enabled
/// bracketed paste before the view was opened.
final class PasteInterceptingTerminalView: AppTerminalView {
    var onPaste: ((String) -> Bool)?
    var onPreviewPath: ((String) -> Void)?
    /// Shift+Return sends a soft newline to the pane instead of submitting.
    var onShiftEnter: (() -> Void)?
    /// ⌘V of a clipboard image (when no text is also present) hands over the PNG.
    var onPasteImage: ((Data) -> Void)?

    override func keyDown(with event: NSEvent) {
        // keyCode 36 is the main Return key; intercept Shift+Return only (no
        // other modifiers) so plain Enter still submits.
        if event.keyCode == 36,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .shift,
           let onShiftEnter
        {
            onShiftEnter()
            return
        }
        super.keyDown(with: event)
    }

    /// Adds a "Preview … in Files" item when the current selection looks like a
    /// path. Ghostty's copy-on-select keeps the selection on the pasteboard, so
    /// it is read from there.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let path = Self.selectedPath() {
            let name = (path as NSString).lastPathComponent
            let item = NSMenuItem(title: "Preview “\(name)” in Files",
                                  action: #selector(previewSelectedPath(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(item, at: 0)
        }
        return menu
    }

    @objc private func previewSelectedPath(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { onPreviewPath?(path) }
    }

    private static func selectedPath() -> String? {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count < 4096, !s.contains("\n") else { return nil }
        let looksLikePath = s.contains("/") || !(s as NSString).pathExtension.isEmpty
        return looksLikePath ? s : nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "v",
           window?.firstResponder === self
        {
            // Text wins when present, so a normal copy still pastes text; an
            // image-only clipboard (a screenshot) is uploaded and referenced.
            if let text = NSPasteboard.general.string(forType: .string) {
                _ = onPaste?(text)
            } else if let onPasteImage, let png = Self.clipboardImagePNG() {
                onPasteImage(png)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The clipboard image as PNG, from raw image data or an NSImage. nil when
    /// the clipboard holds no image.
    static func clipboardImagePNG() -> Data? {
        let pb = NSPasteboard.general
        if let png = pb.data(forType: .png) { return png }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) { return png }
        if let image = NSImage(pasteboard: pb),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) { return png }
        return nil
    }
}

/// Thread-safe switch read on the terminal's write path.
final class InputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var live = false
    private var closed = false
    private var selected = true

    var isOpen: Bool { lock.withLock { live && !closed && selected } }

    func markLive() {
        lock.withLock { live = true }
    }

    func setSelected(_ value: Bool) {
        lock.withLock { selected = value }
    }

    func close() {
        lock.withLock { closed = true }
    }
}
