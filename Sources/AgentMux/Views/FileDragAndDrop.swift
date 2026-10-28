import AgentMuxCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag out: a remote file row to Finder or another app
//
// The technique (a mouse monitor that starts an AppKit file-promise drag from
// a SwiftUI row) is adapted from DragOut.swift in MiSTerFTP,
// https://github.com/Simon-nhelix/mister-ftp, Copyright (c) 2026 Simon-nhelix,
// MIT License. See THIRD_PARTY_NOTICES.md.

/// Drags file rows out of the Files browser to Finder or another app.
///
/// SwiftUI's own drag sources can't promise a file whose bytes are still on a
/// remote host, so rows keep their SwiftUI tap and menu handling and a local
/// mouse monitor starts the drag instead: a press on a file row that moves a
/// few points becomes an AppKit drag of an `NSFilePromiseProvider`. Nothing is
/// fetched until the drop lands; then the receiving app names the destination
/// and the file is downloaded straight to it.
@MainActor
final class FileDragOut: NSObject {
    /// Downloads one remote file; the browser binds its host and target.
    var fetch: (@MainActor (RemoteFileEntry) async -> Result<Data, RemoteFailure>)?
    /// A promised download started (`true`) or ended (`false`) for a path.
    var onActivity: (@MainActor (String, Bool) -> Void)?
    /// A promised download failed: the file's name and the reason.
    var onFailure: (@MainActor (String, String) -> Void)?

    private let rows = NSHashTable<DragOutRowView>.weakObjects()
    private var monitor: Any?
    private var press: Press?

    private struct Press {
        let entry: RemoteFileEntry
        let window: NSWindow
        let location: NSPoint
    }

    /// Pointer travel (points) that turns a press into a drag.
    private static let threshold: CGFloat = 4

    fileprivate func register(_ row: DragOutRowView) {
        rows.add(row)
        installMonitor()
    }

    /// Watches the mouse again after `stop()` if rows are still on screen.
    func resume() {
        if !rows.allObjects.isEmpty { installMonitor() }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return used ? nil : event
        }
    }

    fileprivate func unregister(_ row: DragOutRowView) {
        rows.remove(row)
        if rows.allObjects.isEmpty { stop() }
    }

    /// Stops watching the mouse.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        press = nil
    }

    /// Stops watching and drops the browser's callbacks, which capture its
    /// view state and would otherwise keep it and this controller alive. A
    /// download already under way still answers the receiving app.
    func disconnect() {
        stop()
        fetch = nil
        onActivity = nil
        onFailure = nil
    }

    /// Turns a press on a file row that moves into a drag. Returns true when it
    /// used the event.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            press = nil
            // Control-click belongs to the context menu; no drags start under a
            // sheet or while a modal panel is up.
            guard !event.modifierFlags.contains(.control), NSApp.modalWindow == nil,
                  let window = event.window, window.attachedSheet == nil,
                  let row = row(at: event.locationInWindow, in: window) else { return false }
            press = Press(entry: row.entry, window: window, location: event.locationInWindow)
            return false
        case .leftMouseDragged:
            guard let press, event.window === press.window else { return false }
            let dx = event.locationInWindow.x - press.location.x
            let dy = event.locationInWindow.y - press.location.y
            guard dx * dx + dy * dy >= Self.threshold * Self.threshold else { return false }
            self.press = nil
            return beginDrag(press, event: event)
        default:
            press = nil
            return false
        }
    }

    /// The file row under the pointer, matched against the visible part of each
    /// row only (the list clips rows scrolled under its edges).
    private func row(at location: NSPoint, in window: NSWindow) -> DragOutRowView? {
        rows.allObjects.first { row in
            row.window === window && !row.isHiddenOrHasHiddenAncestor
                && row.visibleRect.contains(row.convert(location, from: nil))
        }
    }

    private func beginDrag(_ press: Press, event: NSEvent) -> Bool {
        guard let view = press.window.contentView else { return false }
        let type = Self.fileType(for: press.entry.name)
        let promise = RemoteFilePromise(entry: press.entry, owner: self)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: promise)
        // NSFilePromiseProvider keeps only a weak delegate; userInfo owns it.
        provider.userInfo = promise
        let item = NSDraggingItem(pasteboardWriter: provider)
        let pointer = view.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: pointer.x - 16, y: pointer.y - 16, width: 32, height: 32),
                              contents: NSWorkspace.shared.icon(for: type))
        view.beginDraggingSession(with: [item], event: event, source: self)
        return true
    }

    private static func fileType(for name: String) -> UTType {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .data }
        return type
    }

    /// Downloads `entry` to the drop location, then answers the receiving app,
    /// which waits on `completion`.
    fileprivate func fulfill(_ entry: RemoteFileEntry, at url: URL, completion: @escaping (Error?) -> Void) {
        guard let fetch else {
            completion(CocoaError(.userCancelled))
            return
        }
        onActivity?(entry.path, true)
        Task {
            var problem: String?
            switch await fetch(entry) {
            case let .success(data):
                do { try await Self.write(data, to: url) }
                catch { problem = error.localizedDescription }
            case let .failure(failure):
                problem = failure.detail.isEmpty ? failure.kind.rawValue : failure.detail
            }
            onActivity?(entry.path, false)
            if let problem {
                completion(CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: problem]))
                onFailure?(entry.name, problem)
            } else {
                completion(nil)
            }
        }
    }

    /// Writes off the main thread; a file can be 50 MB. The receiving app picks
    /// `url`, and an empty file there may be its placeholder, but a non-empty
    /// file is somebody's data: refuse rather than replace it.
    private static func write(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let existing = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
            if let existing, existing > 0 {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
            }
            try data.write(to: url, options: .atomic)
        }.value
    }
}

extension FileDragOut: NSDraggingSource {
    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy to other apps only. Inside AgentMux the drop has no meaning, and
        // this keeps the browser's own drop targets from receiving its rows.
        context == .outsideApplication ? .copy : []
    }
}

/// Answers one promised file by downloading it to where the drop landed.
private final class RemoteFilePromise: NSObject, NSFilePromiseProviderDelegate {
    let entry: RemoteFileEntry
    private weak var owner: FileDragOut?

    init(entry: RemoteFileEntry, owner: FileDragOut) {
        self.entry = entry
        self.owner = owner
        super.init()
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        entry.name
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let owner = owner, entry = entry
        let completion = PromiseCompletion(completionHandler)
        // AppKit calls this on `operationQueue(for:)`, the main queue.
        MainActor.assumeIsolated {
            guard let owner else {
                completion.call(CocoaError(.userCancelled))
                return
            }
            owner.fulfill(entry, at: url) { completion.call($0) }
        }
    }

    /// The main queue: answering a request only starts an async download.
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }
}

/// The receiving app's completion handler for one promise. AppKit accepts a
/// call from any thread, and it is called exactly once.
private struct PromiseCompletion: @unchecked Sendable {
    let call: (Error?) -> Void

    init(_ call: @escaping (Error?) -> Void) {
        self.call = call
    }
}

/// A file row's footprint for `FileDragOut`: an invisible view behind the row
/// that tells the monitor where the row is. It never takes clicks.
struct DragOutRow: NSViewRepresentable {
    let entry: RemoteFileEntry
    let controller: FileDragOut

    func makeNSView(context: Context) -> DragOutRowView {
        let view = DragOutRowView(entry: entry)
        view.controller = controller
        return view
    }

    func updateNSView(_ view: DragOutRowView, context: Context) {
        view.entry = entry
        view.controller = controller
    }
}

final class DragOutRowView: NSView {
    fileprivate(set) var entry: RemoteFileEntry
    weak var controller: FileDragOut? {
        didSet {
            guard controller !== oldValue, window != nil else { return }
            oldValue?.unregister(self)
            controller?.register(self)
        }
    }

    init(entry: RemoteFileEntry) {
        self.entry = entry
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Events go to the SwiftUI row in front of it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { controller?.unregister(self) } else { controller?.register(self) }
    }
}

// MARK: - Drop in: Finder files onto the list or a folder row

/// Loads the file URLs of a drop. Loading starts right away, as a drop
/// requires; the URLs arrive together, in drop order, on the main actor.
@MainActor
func loadDroppedFileURLs(_ providers: [NSItemProvider], then deliver: @escaping @MainActor ([URL]) -> Void) {
    let collector = DroppedURLs()
    let group = DispatchGroup()
    for (index, provider) in providers.enumerated() where provider.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url, url.isFileURL { collector.set(url, at: index) }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        MainActor.assumeIsolated { deliver(collector.inOrder) }
    }
}

/// Collects URLs from the loaders' background callbacks.
private final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [Int: URL] = [:]

    func set(_ url: URL, at index: Int) {
        lock.withLock { urls[index] = url }
    }

    var inOrder: [URL] {
        lock.withLock { urls.sorted { $0.key < $1.key }.map(\.value) }
    }
}

/// Accepts Finder files dropped on a folder row and uploads them into that
/// folder, highlighting the row while a drag hovers over it.
struct FolderDropDelegate: DropDelegate {
    let folder: String
    @Binding var targeted: String?
    let upload: @MainActor ([URL], String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        targeted = folder
    }

    func dropExited(info: DropInfo) {
        if targeted == folder { targeted = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = nil
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        let folder = folder
        let upload = upload
        loadDroppedFileURLs(providers) { urls in upload(urls, folder) }
        return true
    }
}

extension View {
    /// Makes a folder row accept Finder files, uploaded into that folder. A
    /// file row is left alone, so a drop on it goes to the list (the browsed
    /// folder), as in Finder.
    @ViewBuilder
    func folderDropTarget(_ entry: RemoteFileEntry, targeted: Binding<String?>,
                          upload: @escaping @MainActor ([URL], String) -> Void) -> some View {
        if entry.isDirectory {
            onDrop(of: [.fileURL], delegate: FolderDropDelegate(folder: entry.path, targeted: targeted, upload: upload))
        } else {
            self
        }
    }
}
