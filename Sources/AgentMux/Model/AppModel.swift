import AgentMuxCore
import Foundation
import Observation

/// Identifies a pane on one tmux server generation. `%3` on another socket,
/// another container or a restarted server is a different pane.
struct PaneRef: Hashable, Sendable {
    var targetID: String
    var serverPID: Int
    var serverStart: Int
    var paneID: String
}

/// Live state of one configured target.
@MainActor
@Observable
final class TargetState: Identifiable {
    let host: HostConfig
    let target: TargetConfig
    var snapshot: InventorySnapshot?
    var detections: [String: AgentDetection] = [:]
    var lastSuccess: Date?
    var lastFailure: RemoteFailure?
    var lastAttempt: Date?
    var isRefreshing = false
    /// Set by a manual refresh; the poller picks it up within 250 ms.
    var refreshRequested = false
    /// Next refresh delay; grows on failure.
    var interval: Duration = TargetState.baseInterval

    static let baseInterval: Duration = .seconds(10)
    static let maxInterval: Duration = .seconds(120)

    nonisolated var id: String { target.id }

    init(host: HostConfig, target: TargetConfig) {
        self.host = host
        self.target = target
    }

    /// The last snapshot is shown but marked stale after a failed refresh.
    var isStale: Bool {
        lastFailure != nil && snapshot != nil
    }

    func ref(for paneID: String) -> PaneRef? {
        guard let server = snapshot?.server else { return nil }
        return PaneRef(targetID: target.id, serverPID: server.pid, serverStart: server.startTime, paneID: paneID)
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var targets: [TargetState] = []
    private(set) var configError: String?
    private(set) var configPath: String?
    var selection: PaneRef?
    /// Sidebar scope: one target (nil = all) and one working directory (nil = all).
    var deviceFilter: String? {
        didSet { if oldValue != deviceFilter { spaceFilter = nil } }
    }
    var spaceFilter: SpaceKey?
    var showDevicePanel = false
    var showSearch = false
    private(set) var terminals: [PaneRef: PaneTerminal] = [:]

    private var pollers: [String: Task<Void, Never>] = [:]
    private var releasedOrphans: Set<String> = []
    /// AGENTMUX_OPEN=<target-id>/<pane-id>: select and open that pane once it
    /// is discovered (used by scripted smoke tests).
    @ObservationIgnored private var pendingOpen = AppModel.paneFromEnvironment("AGENTMUX_OPEN")
    /// AGENTMUX_SELECT=<target-id>/<pane-id>: only select it (no attach).
    @ObservationIgnored private var pendingSelect = AppModel.paneFromEnvironment("AGENTMUX_SELECT")

    private static func paneFromEnvironment(_ name: String) -> (targetID: String, paneID: String)? {
        guard let value = ProcessInfo.processInfo.environment[name],
              let slash = value.firstIndex(of: "/") else { return nil }
        return (String(value[..<slash]), String(value[value.index(after: slash)...]))
    }

    init() {
        loadConfig()
    }

    // MARK: Config

    /// AGENTMUX_CONFIG, else ~/Library/Application Support/AgentMux/targets.json5.
    static func configURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["AGENTMUX_CONFIG"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentMux/targets.json5")
    }

    func loadConfig() {
        let url = Self.configURL()
        configPath = url.path
        do {
            let config = try TargetsConfig.load(from: url)
            targets = config.targets.compactMap { target in
                config.host(for: target).map { TargetState(host: $0, target: target) }
            }
            configError = nil
        } catch {
            targets = []
            configError = "\(error)"
        }
    }

    // MARK: Polling

    func startPolling() {
        for state in targets where pollers[state.id] == nil {
            pollers[state.id] = Task { [weak self] in
                await self?.poll(state)
            }
        }
    }

    func stopPolling() {
        pollers.values.forEach { $0.cancel() }
        pollers.removeAll()
    }

    func refresh(_ targetID: String) {
        state(targetID)?.refreshRequested = true
    }

    func refreshAll() {
        targets.forEach { $0.refreshRequested = true }
    }

    private func poll(_ state: TargetState) async {
        while !Task.isCancelled {
            await refreshOnce(state)
            // Wait for the interval, or less if a manual refresh comes in.
            let deadline = ContinuousClock.now + state.interval
            while !Task.isCancelled, ContinuousClock.now < deadline, !state.refreshRequested {
                try? await Task.sleep(for: .milliseconds(250))
            }
            state.refreshRequested = false
        }
    }

    private func refreshOnce(_ state: TargetState) async {
        state.isRefreshing = true
        state.lastAttempt = Date()
        let result = await TargetProbe.run(host: state.host, target: state.target)
        state.isRefreshing = false
        switch result {
        case let .success(snapshot):
            let previousServer = state.snapshot?.server
            state.snapshot = snapshot
            state.detections = AgentDetector.detect(snapshot)
            state.lastSuccess = Date()
            state.lastFailure = nil
            state.interval = TargetState.baseInterval
            if previousServer != snapshot.server {
                invalidateTerminals(of: state)
            }
            await releaseOrphansOnce(state)
            if let pending = pendingSelect, pending.targetID == state.id,
               snapshot.pane(pending.paneID) != nil, let ref = state.ref(for: pending.paneID)
            {
                pendingSelect = nil
                selection = ref
            }
            if let pending = pendingOpen, pending.targetID == state.id,
               snapshot.pane(pending.paneID) != nil, let ref = state.ref(for: pending.paneID)
            {
                pendingOpen = nil
                select(ref)
            }
        case let .failure(failure):
            state.lastFailure = failure
            let doubled = state.interval * 2
            state.interval = doubled > TargetState.maxInterval ? TargetState.maxInterval : doubled
        }
    }

    /// After a crash or lost connection, tagged clients of earlier views stay
    /// attached (docker exec keeps them alive). Release them once per run,
    /// keeping the views that are open now. Only clients carrying the
    /// AgentMux tag are touched.
    private func releaseOrphansOnce(_ state: TargetState) async {
        guard state.target.access.allowsAttach, !releasedOrphans.contains(state.id),
              let context = try? state.target.executionContext() else { return }
        releasedOrphans.insert(state.id)
        let live = terminals.values.filter { $0.ref.targetID == state.id }.map(\.clientTag)
        _ = await ClientRelease.release(host: state.host, context: context, options: SSHOptions(), tags: [], keeping: live)
    }

    /// A restarted tmux server reuses pane ids; views of the old generation
    /// must not keep sending input.
    private func invalidateTerminals(of state: TargetState) {
        for (ref, terminal) in terminals where ref.targetID == state.id {
            if ref.serverPID != state.snapshot?.server?.pid || ref.serverStart != state.snapshot?.server?.startTime {
                terminal.markStale(reason: "tmux server changed")
            }
        }
    }

    // MARK: Derived data

    func state(_ targetID: String) -> TargetState? {
        targets.first { $0.id == targetID }
    }

    /// `session:window.pane` using the first membership.
    func location(of paneID: String, in snapshot: InventorySnapshot) -> String {
        guard let row = snapshot.memberships.first(where: { $0.paneID == paneID }) else { return paneID }
        let session = snapshot.sessions.first { $0.id == row.sessionID }?.name ?? row.sessionID
        return "\(session):\(row.windowIndex).\(row.paneIndex)"
    }

    // MARK: Selection and terminals

    /// Selecting a pane on an attachable target opens its mirror at once,
    /// as a Mac agent console does; mirroring changes nothing shared in tmux.
    func select(_ ref: PaneRef) {
        selection = ref
        if terminals[ref] == nil, state(ref.targetID)?.target.access.allowsAttach == true {
            openTerminal(ref)
        }
        for terminal in terminals.values {
            terminal.setActive(terminal.ref == ref)
        }
    }

    func terminal(for ref: PaneRef) -> PaneTerminal? {
        terminals[ref]
    }

    func openTerminal(_ ref: PaneRef) {
        guard terminals[ref] == nil, let state = state(ref.targetID),
              let sessionID = state.snapshot?.memberships.first(where: { $0.paneID == ref.paneID })?.sessionID
        else { return }
        do {
            terminals[ref] = try PaneTerminal(ref: ref, sessionID: sessionID, host: state.host, target: state.target)
        } catch {
            state.lastFailure = RemoteFailure(.remoteCommandFailed, detail: "\(error)")
        }
    }

    /// Ends this view's mirror. The pane and its programs keep running.
    func closeTerminal(_ ref: PaneRef) {
        terminals.removeValue(forKey: ref)?.close()
    }

    /// Closes every mirror. Each control client leaves when its input
    /// closes, so quitting right after is safe.
    func closeAllTerminals() {
        terminals.values.forEach { $0.close() }
        terminals.removeAll()
    }
}
