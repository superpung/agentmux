import AgentMuxCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A Mac app that can open a file.
struct LocalApp: Identifiable, Equatable {
    let url: URL
    let name: String
    var id: URL { url }

    /// The app's icon at menu size.
    @MainActor var icon: NSImage { LocalApps.icon(of: url) }
}

/// The apps that open a kind of file, as Finder's Open With lists them.
@MainActor
enum LocalApps {
    private struct Lookup {
        let at: Date
        let preferred: LocalApp?
        let others: [LocalApp]
    }

    private static var lookups: [String: Lookup] = [:]
    private static var icons: [URL: NSImage] = [:]

    /// The default app for a file called `name`, and the others that open it,
    /// by name, one copy of each app. A kind no app claims (an unknown
    /// extension) has no default and lists the apps that open any file.
    /// Looked up again after a minute, so a newly installed app shows.
    static func forFile(named name: String) -> (preferred: LocalApp?, others: [LocalApp]) {
        let ext = (name as NSString).pathExtension
        let type = ext.isEmpty ? .data : UTType(filenameExtension: ext) ?? .data
        if let hit = lookups[type.identifier], hit.at.timeIntervalSinceNow > -60 { return (hit.preferred, hit.others) }
        let workspace = NSWorkspace.shared
        var urls = workspace.urlsForApplications(toOpen: type)
        let preferred = urls.isEmpty ? nil : workspace.urlForApplication(toOpen: type)
        if urls.isEmpty { urls = workspace.urlsForApplications(toOpen: .data) }
        var seen: Set<String> = preferred.map { [identity($0)] } ?? []
        let others = urls.filter { seen.insert(identity($0)).inserted }.map(app)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let lookup = Lookup(at: Date(), preferred: preferred.map(app), others: others)
        lookups[type.identifier] = lookup
        return (lookup.preferred, lookup.others)
    }

    /// Copies of one app (an old version, a second install) count once.
    private static func identity(_ url: URL) -> String {
        Bundle(url: url)?.bundleIdentifier ?? url.path
    }

    private static func app(_ url: URL) -> LocalApp {
        let name = FileManager.default.displayName(atPath: url.path)
        return LocalApp(url: url, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
    }

    static func icon(of app: URL) -> NSImage {
        if let icon = icons[app] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: app.path).copy() as! NSImage
        icon.size = NSSize(width: 16, height: 16)
        icons[app] = icon
        return icon
    }

    /// Asks for any app, as Finder's Open With > Other… does.
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.prompt = "Open"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Opens remote files in Mac apps: the file is downloaded (read-only on the
/// remote, up to `RemoteFileService.downloadByteCap`) into a read-only local
/// copy, `LocalCopies`, and handed to the app.
@MainActor @Observable
final class RemoteOpener {
    struct Failure: Equatable {
        let id = UUID()
        let name: String
        let message: String
    }

    /// Remote paths being fetched to open.
    private(set) var opening: Set<String> = []
    /// The latest failure, for the browser to show.
    var failure: Failure?

    /// Old copies are cleared once a launch, before the first copy is made.
    private static var pruned = false

    /// Opens `path` in `app`, or in the default app for its kind when nil.
    func open(_ path: String, in app: URL?, host: HostConfig, target: TargetConfig) {
        let name = (path as NSString).lastPathComponent
        guard !opening.contains(path) else { return }
        guard let app = app ?? LocalApps.forFile(named: name).preferred?.url ?? LocalApps.choose() else { return }
        opening.insert(path)
        let prune = !Self.pruned
        Self.pruned = true
        let targetID = target.id
        Task {
            defer { opening.remove(path) }
            let data: Data
            switch await RemoteFileService.download(path, host: host, target: target) {
            case let .success(fetched): data = fetched
            case let .failure(f): return fail(name, f.detail.isEmpty ? f.kind.rawValue : f.detail)
            }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    let copies = LocalCopies.standard
                    if prune { copies.prune(olderThanDays: 7) }
                    return try copies.store(data, for: path, target: targetID)
                }.value
                try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                fail(name, error.localizedDescription)
            }
        }
    }

    private func fail(_ name: String, _ message: String) {
        failure = Failure(name: name, message: message)
    }
}

/// The apps in an Open With menu: the default first, then the others, then
/// Other… to pick any app.
private struct OpenWithList: View {
    let preferred: LocalApp?
    let others: [LocalApp]
    let open: (URL) -> Void

    var body: some View {
        if let preferred {
            item(preferred, title: "\(preferred.name) (default)")
            Divider()
        }
        ForEach(others) { item($0, title: $0.name) }
        if preferred != nil || !others.isEmpty { Divider() }
        Button("Other…") { if let app = LocalApps.choose() { open(app) } }
    }

    private func item(_ app: LocalApp, title: String) -> some View {
        Button { open(app.url) } label: {
            Label { Text(title) } icon: { Image(nsImage: app.icon) }
        }
    }
}

/// A file row's context-menu entries: Open in the default app, Open With.
struct OpenWithItems: View {
    let path: String
    let open: (URL?) -> Void

    var body: some View {
        let apps = LocalApps.forFile(named: (path as NSString).lastPathComponent)
        if let preferred = apps.preferred {
            Button { open(preferred.url) } label: {
                Label { Text("Open in \(preferred.name)") } icon: { Image(nsImage: preferred.icon) }
            }
        }
        Menu("Open With") {
            OpenWithList(preferred: apps.preferred, others: apps.others) { open($0) }
        }
    }
}

/// The toolbar's Open button for the file in the preview: a click opens it in
/// the default app, the arrow lists the others. A spinner while it downloads.
struct OpenWithButton: View {
    let path: String
    let busy: Bool
    let open: (URL?) -> Void

    var body: some View {
        let apps = LocalApps.forFile(named: (path as NSString).lastPathComponent)
        if busy {
            ProgressView().controlSize(.small)
        } else {
            Menu {
                OpenWithList(preferred: apps.preferred, others: apps.others) { open($0) }
            } label: {
                if let preferred = apps.preferred {
                    Label { Text("Open in \(preferred.name)") } icon: { Image(nsImage: preferred.icon) }
                } else {
                    Label("Open With", systemImage: "arrow.up.forward.app")
                }
            } primaryAction: {
                open(apps.preferred?.url)
            }
            .help(apps.preferred.map { "Open in \($0.name)" } ?? "Open With")
        }
    }
}
