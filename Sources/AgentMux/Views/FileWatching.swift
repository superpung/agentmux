import AgentMuxCore
import AppKit
import SwiftUI

/// Notices changes to the file shown and the folder listed in a Files window
/// while the window is on screen. Once a second it asks a `RemoteWatch`
/// session for their stamps; that session costs a `stat` a check, where a
/// fresh ssh connection and `docker exec` would cost about 0.3 s of the
/// host's CPU. A change bumps `fileVersion` or `folderVersion`, and the views
/// reload; changes that keep coming reload at most every `reloadSpacing`.
@MainActor @Observable
final class FileWatcher {
    private(set) var fileVersion = 0
    private(set) var folderVersion = 0

    static let interval: Duration = .seconds(1)
    static let reloadSpacing: Duration = .seconds(3)
    /// After a session fails to start or ends early, wait before the next.
    static let retryDelay: Duration = .seconds(15)

    private enum Part { case file, folder }

    @ObservationIgnored private var session: RemoteWatch?
    @ObservationIgnored private var retryAt: ContinuousClock.Instant?
    @ObservationIgnored private var stamps: [String: String?] = [:]
    @ObservationIgnored private var lastReload: [Part: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var pending: Set<Part> = []

    /// Watches `file` and `folder` until the calling task is cancelled.
    func watch(file: String?, folder: String, host: HostConfig, target: TargetConfig) async {
        stamps = [:]
        pending = []
        let paths = [file, folder].compactMap { $0 }
        while !Task.isCancelled {
            if let checked = await check(paths, host: host, target: target), !Task.isCancelled {
                for (path, stamp) in zip(paths, checked) {
                    if let seen = stamps[path], seen != stamp { pending.insert(path == file ? .file : .folder) }
                    stamps[path] = stamp
                }
            }
            reloadDue()
            try? await Task.sleep(for: Self.interval)
        }
    }

    /// Ends the session (the window closed or went off screen).
    func stop() {
        session?.stop()
        session = nil
    }

    private func check(_ paths: [String], host: HostConfig, target: TargetConfig) async -> [String?]? {
        if session?.isRunning != true {
            session = nil
            if let retryAt, ContinuousClock.now < retryAt { return nil }
            guard let started = try? RemoteWatch(host: host, target: target), (try? started.start()) != nil else {
                retryAt = .now + Self.retryDelay
                return nil
            }
            session = started
        }
        guard let stamps = await session?.check(paths) else {
            retryAt = .now + Self.retryDelay
            return nil
        }
        return stamps
    }

    private func reloadDue() {
        let now = ContinuousClock.now
        for part in pending where lastReload[part].map({ now - $0 >= Self.reloadSpacing }) ?? true {
            pending.remove(part)
            lastReload[part] = now
            switch part {
            case .file: fileVersion += 1
            case .folder: folderVersion += 1
            }
        }
    }
}

/// Reports whether its window is on screen: not minimized, hidden, or fully
/// covered.
struct WindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.report = { visible = $0 }
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.report = { visible = $0 }
    }

    final class Probe: NSView {
        var report: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return send(false) }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.send(self?.window?.occlusionState.contains(.visible) ?? false) }
            }
            send(window.occlusionState.contains(.visible))
        }

        /// After the current view update, which may not change state.
        private func send(_ visible: Bool) {
            DispatchQueue.main.async { [weak self] in self?.report?(visible) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension PreviewTextView {
    /// Puts in a newer version of the text shown, keeping the reader's
    /// place: at the end it follows new lines (as `tail -f`); otherwise the
    /// line at the top stays at the top as far as the text allows.
    func replaceKeepingPlace(with text: NSAttributedString) {
        guard let storage = textStorage, let layoutManager, let textContainer,
              let clip = enclosingScrollView?.contentView else {
            textStorage?.setAttributedString(text)
            return
        }
        let atEnd = clip.bounds.maxY >= frame.height - 4
        var top: (char: Int, offset: CGFloat)?
        if clip.bounds.minY > 0, storage.length > 0 {
            let y = clip.bounds.minY - textContainerOrigin.y
            let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: y), in: textContainer)
            top = (layoutManager.characterIndexForGlyph(at: glyph),
                   y - layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY)
        }
        storage.setAttributedString(text)
        guard storage.length > 0, atEnd || top != nil else { return }
        if atEnd, clip.bounds.minY > 0 {
            scrollToEndOfDocument(nil)
            return
        }
        guard let top else { return }
        let char = min(top.char, storage.length - 1)
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(storage.length, char + 20_000)))
        let line = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: char), effectiveRange: nil)
        let origin = NSPoint(x: clip.bounds.minX, y: line.minY + top.offset + textContainerOrigin.y)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
}
