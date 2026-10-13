import AgentMuxCore
import Foundation
import Observation

/// Identifies a pane on one tmux server generation. `%3` on another socket,
/// another container or a restarted server is a different pane.
struct PaneRef: Hashable, Sendable, Codable {
    var targetID: String
    var serverPID: Int
    var serverStart: Int
    var paneID: String
}

/// Live state of one configured target.
@MainActor
@Observable
final class TargetState: Identifiable {
    /// Updated in place when the host is edited in Settings.
    var host: HostConfig
    let target: TargetConfig
    var snapshot: InventorySnapshot?
    var detections: [String: AgentDetection] = [:]
    /// Resolved activity per agent pane, recomputed each refresh.
    var activities: [String: AgentActivity] = [:]
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
    /// Interval for a target the user is actively viewing (a mirror is open).
    static let activeInterval: Duration = .seconds(2)

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
    /// Non-nil only when saving settings failed.
    private(set) var configError: String?
    var selection: PaneRef?
    /// Sidebar scope: one target (nil = all) and one working directory (nil = all).
    var deviceFilter: String? {
        didSet { if oldValue != deviceFilter { spaceFilter = nil } }
    }
    var spaceFilter: SpaceKey?
    var showDevicePanel = false
    var showSearch = false
    /// Toggled by ⌘K; RootView shows the command palette overlay.
    var showCommandPalette = false
    private(set) var terminals: [PaneRef: PaneTerminal] = [:]
    /// Mirrors shown in their own window; the main detail renders a placeholder
    /// for these so a single surface is never in two view hierarchies.
    private(set) var poppedOut: Set<PaneRef> = []

    /// The single source of truth, managed in Settings and saved to disk.
    private(set) var settings = AppSettings()
    /// Containers found per host (for the Settings list). Not all are monitored.
    private(set) var discovered: [String: [DiscoveredContainer]] = [:]
    private(set) var isDiscovering = false

    private var targetStates: [String: TargetState] = [:]
    private var isPolling = false
    private var pollers: [String: Task<Void, Never>] = [:]
    /// Live host/container resources, by host id, refreshed only while a view
    /// (the inspector or dashboard) is showing them.
    private(set) var resources: [String: HostResources] = [:]
    /// Rolling metric history for sparklines, by host id then series key
    /// ("host.cpu", "host.mem", "container.<name>.cpu", "container.<name>.mem",
    /// "gpu.<i>"). Oldest-to-newest, capped at `historyCapacity` points.
    private(set) var resourceHistory: [String: [String: [Double]]] = [:]
    private static let historyCapacity = 40
    private var resourcePoller: Task<Void, Never>?
    private var resourceConsumers = 0
    static let resourceInterval: Duration = .seconds(5)

    // MARK: Inspector / file-preview UI state

    enum InspectorMode: String, Sendable { case resources, files }
    var inspectorMode: InspectorMode = .resources
    var inspectorVisible = UserDefaults.standard.bool(forKey: "showResourceInspector") {
        didSet { UserDefaults.standard.set(inspectorVisible, forKey: "showResourceInspector") }
    }

    func toggleInspector() { inspectorVisible.toggle() }
    func showInspector(_ mode: InspectorMode) {
        inspectorMode = mode
        inspectorVisible = true
    }

    /// A request (from a terminal link or the browser) to preview a file. The
    /// nonce lets the same path be re-requested.
    struct PreviewRequest: Equatable, Sendable { var targetID: String; var path: String; var nonce: Int }
    private(set) var previewRequest: PreviewRequest?
    private var previewNonce = 0

    /// Switch the inspector to Files and ask it to open `path` on `targetID`.
    func requestFilePreview(_ path: String, targetID: String) {
        previewNonce += 1
        inspectorMode = .files
        inspectorVisible = true
        previewRequest = PreviewRequest(targetID: targetID, path: path, nonce: previewNonce)
    }
    private var releasedOrphans: Set<String> = []
    @ObservationIgnored private let notifier = Notifier()

    /// Whether OS notifications fire (shared with the Settings toggle).
    var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
    }

    /// User labels keyed by `AgentEntry.identityKey`, persisted.
    private(set) var pinnedAgents: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pinnedAgents") ?? [])
    private(set) var customNames: [String: String] = (UserDefaults.standard.dictionary(forKey: "customNames") as? [String: String]) ?? [:]

    func isPinned(_ key: String) -> Bool { pinnedAgents.contains(key) }

    func togglePin(_ key: String) {
        if pinnedAgents.contains(key) { pinnedAgents.remove(key) } else { pinnedAgents.insert(key) }
        UserDefaults.standard.set(Array(pinnedAgents), forKey: "pinnedAgents")
    }

    func customName(_ key: String) -> String? { customNames[key] }

    func setCustomName(_ key: String, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { customNames[key] = nil } else { customNames[key] = trimmed }
        UserDefaults.standard.set(customNames, forKey: "customNames")
    }

    var hosts: [HostConfig] { settings.hosts }

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
        loadSettings()
    }

    // MARK: Settings

    private var settingsURL: URL { AppSettings.defaultURL() }

    func loadSettings() {
        let url = settingsURL
        if FileManager.default.fileExists(atPath: url.path) {
            // A corrupt file must not be silently replaced with empty settings
            // (and must not be overwritten here) — surface the error instead.
            do {
                settings = try AppSettings.load(from: url)
                configError = nil
            } catch {
                settings = AppSettings()
                configError = "Could not read \(url.lastPathComponent): \(error)"
            }
        } else {
            settings = AppSettings.loadOrImport(url: url)
            configError = nil
        }
        reconcileTargets()
    }

    private func persistSettings() {
        settings.normalize()
        do {
            try settings.save(to: settingsURL)
            configError = nil
        } catch {
            configError = "\(error)"
        }
    }

    // MARK: Hosts

    /// Adds a host (ssh destination is an alias or user@host). The id is derived
    /// from the display name and made unique. Rediscovers afterwards.
    func addHost(displayName: String, sshDestination: String) {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        let ssh = sshDestination.trimmingCharacters(in: .whitespaces)
        guard !ssh.isEmpty else { return }
        let base = Self.slug(name.isEmpty ? ssh : name)
        var id = base
        var n = 2
        let existing = Set(settings.hosts.map(\.id))
        while id.isEmpty || existing.contains(id) { id = "\(base.isEmpty ? "host" : base)-\(n)"; n += 1 }
        settings.hosts.append(HostConfig(id: id, displayName: name.isEmpty ? ssh : name, sshDestination: ssh))
        persistSettings()
        reconcileTargets()
        Task { await discover(hostID: id) }
    }

    func updateHost(id: String, displayName: String, sshDestination: String) {
        guard let index = settings.hosts.firstIndex(where: { $0.id == id }) else { return }
        let name = displayName.trimmingCharacters(in: .whitespaces)
        let ssh = sshDestination.trimmingCharacters(in: .whitespaces)
        guard !ssh.isEmpty else { return }
        settings.hosts[index].displayName = name.isEmpty ? ssh : name
        settings.hosts[index].sshDestination = ssh
        persistSettings()
        reconcileTargets()
        Task { await discover(hostID: id) }
    }

    func removeHost(id: String) {
        settings.hosts.removeAll { $0.id == id }
        settings.monitoredContainers.removeAll { $0.hasPrefix("\(id)/") }
        discovered[id] = nil
        persistSettings()
        reconcileTargets()
    }

    private static func slug(_ text: String) -> String {
        let allowed = text.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
        return String(allowed).split(separator: "-").joined(separator: "-")
    }

    // MARK: Target set

    /// The targets to monitor: every discovered container the user enabled in
    /// Settings whose host still exists.
    private func desiredTargets() -> [(HostConfig, TargetConfig)] {
        var result: [(HostConfig, TargetConfig)] = []
        var seen = Set<String>()
        for key in settings.monitoredContainers {
            guard let parts = AppSettings.splitKey(key),
                  let host = hosts.first(where: { $0.id == parts.hostID }),
                  seen.insert(key).inserted else { continue }
            result.append((host, .discovered(host: host, container: parts.container)))
        }
        return result
    }

    /// Brings the live `targets` in line with `desiredTargets()`, keeping the
    /// states that persist, adding new ones (and their pollers, if polling),
    /// and tearing down the ones that left (poller, mirrors, selection).
    private func reconcileTargets() {
        let desired = desiredTargets()
        let desiredIDs = Set(desired.map { $0.1.id })

        // Snapshot keys before mutating the dictionaries we iterate.
        for id in Array(targetStates.keys) where !desiredIDs.contains(id) {
            pollers.removeValue(forKey: id)?.cancel()
            for ref in Array(terminals.keys) where ref.targetID == id { closeTerminal(ref) }
            if selection?.targetID == id { selection = nil }
            releasedOrphans.remove(id)
            targetStates.removeValue(forKey: id)
        }

        for (host, target) in desired {
            if let existing = targetStates[target.id] {
                // Keep the live state, but pick up an edited host name / ssh.
                if existing.host != host { existing.host = host }
            } else {
                let state = TargetState(host: host, target: target)
                targetStates[target.id] = state
                if isPolling {
                    pollers[target.id] = Task { [weak self] in await self?.poll(state) }
                }
            }
        }

        targets = desired.compactMap { targetStates[$0.1.id] }
    }

    // MARK: Container selection

    var monitoredCount: Int { settings.monitoredContainers.count }

    func isContainerEnabled(host: HostConfig, container: DiscoveredContainer) -> Bool {
        settings.monitoredContainers.contains("\(host.id)/\(container.name)")
    }

    /// Enables or disables a discovered container and reconciles the target set.
    func setContainer(_ container: DiscoveredContainer, on host: HostConfig, enabled: Bool) {
        let key = "\(host.id)/\(container.name)"
        settings.monitoredContainers.removeAll { $0 == key }
        if enabled { settings.monitoredContainers.append(key) }
        persistSettings()
        reconcileTargets()
    }

    // MARK: Discovery

    /// Lists containers on every host (read-only) and refreshes the Settings
    /// list. Discovery only fills the container list; the monitored target set
    /// comes from `settings` and is reconciled when the selection changes, so no
    /// reconcile is needed here.
    func discoverAll() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        for host in hosts {
            await discover(host: host)
        }
    }

    /// Discovers one host by id (after it is added or edited).
    func discover(hostID: String) async {
        guard !isDiscovering, let host = hosts.first(where: { $0.id == hostID }) else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        await discover(host: host)
    }

    private func discover(host: HostConfig) async {
        let result = await DockerDiscovery.list(host: host)
        if case let .success(containers) = result {
            discovered[host.id] = containers.sorted { $0.name < $1.name }
        }
    }

    // MARK: Polling

    func startPolling() {
        isPolling = true
        for state in targets where pollers[state.id] == nil {
            pollers[state.id] = Task { [weak self] in
                await self?.poll(state)
            }
        }
        if resourcePoller == nil {
            resourcePoller = Task { [weak self] in await self?.pollResourcesLoop() }
        }
    }

    func stopPolling() {
        isPolling = false
        pollers.values.forEach { $0.cancel() }
        pollers.removeAll()
        resourcePoller?.cancel()
        resourcePoller = nil
    }

    // MARK: Resource monitoring

    /// Resource polling runs only while something is watching it.
    func beginResourceMonitoring() {
        resourceConsumers += 1
    }

    func endResourceMonitoring() {
        resourceConsumers = max(0, resourceConsumers - 1)
    }

    private func pollResourcesLoop() async {
        while !Task.isCancelled {
            if resourceConsumers > 0 {
                for host in hosts {
                    if case let .success(snapshot) = await ResourceProbe.run(host: host) {
                        resources[host.id] = snapshot
                        recordHistory(host.id, snapshot)
                    }
                }
                try? await Task.sleep(for: Self.resourceInterval)
            } else {
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Resources for the host behind a target id.
    func resources(forTarget targetID: String) -> HostResources? {
        guard let hostID = state(targetID)?.host.id else { return nil }
        return resources[hostID]
    }

    /// A rolling series for sparklines (oldest-to-newest); empty until enough
    /// samples have arrived.
    func history(_ hostID: String, _ key: String) -> [Double] {
        resourceHistory[hostID]?[key] ?? []
    }

    private func recordHistory(_ hostID: String, _ snapshot: HostResources) {
        var series = resourceHistory[hostID] ?? [:]
        func push(_ key: String, _ value: Double) {
            var points = series[key] ?? []
            points.append(value)
            if points.count > Self.historyCapacity {
                points.removeFirst(points.count - Self.historyCapacity)
            }
            series[key] = points
        }
        let cores = Double(max(snapshot.cores, 1))
        push("host.cpu", min(100, snapshot.load1 / cores * 100))
        push("host.mem", snapshot.memPercent)
        for (name, container) in snapshot.containers {
            // docker's cpuPercent is summed across cores (0…cores*100); scale to
            // a share of the whole host so the sparkline reads 0…100.
            push("container.\(name).cpu", min(100, container.cpuPercent / cores))
            push("container.\(name).mem", container.memPercent)
        }
        for gpu in snapshot.gpus { push("gpu.\(gpu.index)", gpu.utilizationPercent) }
        // Drop series for containers / GPUs that are gone, so stale keys don't
        // accumulate over a long session.
        var live: Set<String> = ["host.cpu", "host.mem"]
        for name in snapshot.containers.keys { live.insert("container.\(name).cpu"); live.insert("container.\(name).mem") }
        for gpu in snapshot.gpus { live.insert("gpu.\(gpu.index)") }
        series = series.filter { live.contains($0.key) }
        resourceHistory[hostID] = series
    }

    // MARK: Session admin (only from the Sessions window; deletes are confirmed)

    /// Returns nil on success (and requests a refresh), or an error string.
    private func adminResult(_ result: Result<Void, RemoteFailure>, targetID: String) -> String? {
        switch result {
        case .success:
            state(targetID)?.refreshRequested = true
            return nil
        case let .failure(failure):
            return "\(failure.kind.rawValue): \(failure.detail)"
        }
    }

    func newSession(_ targetID: String, name: String) async -> String? {
        guard let s = state(targetID) else { return "unknown target" }
        return adminResult(await TmuxAdmin.newSession(host: s.host, target: s.target, name: name), targetID: targetID)
    }

    func newWindow(_ targetID: String, sessionID: String) async -> String? {
        guard let s = state(targetID) else { return "unknown target" }
        return adminResult(await TmuxAdmin.newWindow(host: s.host, target: s.target, sessionID: sessionID), targetID: targetID)
    }

    func killSession(_ targetID: String, sessionID: String) async -> String? {
        guard let s = state(targetID) else { return "unknown target" }
        return adminResult(await TmuxAdmin.killSession(host: s.host, target: s.target, sessionID: sessionID), targetID: targetID)
    }

    func killWindow(_ targetID: String, windowID: String) async -> String? {
        guard let s = state(targetID) else { return "unknown target" }
        return adminResult(await TmuxAdmin.killWindow(host: s.host, target: s.target, windowID: windowID), targetID: targetID)
    }

    func killPane(_ targetID: String, paneID: String) async -> String? {
        guard let s = state(targetID) else { return "unknown target" }
        return adminResult(await TmuxAdmin.killPane(host: s.host, target: s.target, paneID: paneID), targetID: targetID)
    }

    /// Sends a prompt to an agent from the command palette: selects and opens
    /// it (so the user sees what was sent), waits for the mirror to connect,
    /// then pastes the text and presses Enter. Returns nil on success, else an
    /// error string. Observe-only targets are refused.
    func sendPrompt(_ ref: PaneRef, _ text: String) async -> String? {
        guard state(ref.targetID)?.target.access.allowsAttach == true else {
            return "This target is observe-only."
        }
        select(ref)
        // Wait up to ~4s for the control-mode mirror to go live.
        for _ in 0 ..< 40 {
            if terminal(for: ref)?.canSend == true { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let terminal = terminal(for: ref), terminal.canSend else {
            return "The agent isn't connected yet — try again in a moment."
        }
        return terminal.send(text, submit: true) ? nil : "Couldn't send input to this pane."
    }

    // MARK: Agent launch (only from the Sessions window)

    func agentConfigDirs(_ targetID: String) async -> Result<[AgentConfigDir], RemoteFailure> {
        guard let s = state(targetID) else { return .failure(RemoteFailure(.remoteCommandFailed, detail: "unknown target")) }
        return await AgentSessionProbe.configDirs(host: s.host, target: s.target)
    }

    func agentSessions(_ targetID: String, _ dir: AgentConfigDir) async -> Result<[AgentSessionInfo], RemoteFailure> {
        guard let s = state(targetID) else { return .failure(RemoteFailure(.remoteCommandFailed, detail: "unknown target")) }
        return await AgentSessionProbe.sessions(host: s.host, target: s.target, configDir: dir)
    }

    /// Starts (or resumes) one agent in its own new tmux session. Returns nil on
    /// success, else an error string.
    func launchAgent(_ targetID: String, kind: AgentKind, configDir: String, cwd: String, resumeID: String?) async -> String? {
        guard let s = state(targetID) else { return "unknown target" }
        guard let command = AgentCommand.launch(kind: kind, configDir: configDir, resumeID: resumeID) else {
            return "Couldn't build a launch command for this agent."
        }
        let name = uniqueSessionName(targetID, base: SpaceLabel.label(cwd))
        return adminResult(await AgentLauncher.launchInNewSession(host: s.host, target: s.target, name: name, cwd: cwd, command: command), targetID: targetID)
    }

    /// Starts (or resumes) one agent in a new window of an existing session.
    func launchAgentInWindow(_ targetID: String, sessionID: String, kind: AgentKind, configDir: String, cwd: String, resumeID: String?) async -> String? {
        guard let s = state(targetID) else { return "unknown target" }
        guard let command = AgentCommand.launch(kind: kind, configDir: configDir, resumeID: resumeID) else {
            return "Couldn't build a launch command for this agent."
        }
        return adminResult(await AgentLauncher.launchInNewWindow(host: s.host, target: s.target, sessionID: sessionID, cwd: cwd, command: command), targetID: targetID)
    }

    /// Real (non-grouped) sessions on a target, for the launch destination picker.
    func realSessions(_ targetID: String) -> [InventorySnapshot.Session] {
        (state(targetID)?.snapshot?.sessions ?? []).filter { !$0.name.hasPrefix(RemoteCommand.groupedSessionPrefix) }
    }

    /// A tmux-safe session name derived from `base`, made unique against the
    /// sessions already on the target.
    func uniqueSessionName(_ targetID: String, base: String) -> String {
        let cleaned = base.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-" }
        var name = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if name.isEmpty { name = "agent" }
        let existing = Set(state(targetID)?.snapshot?.sessions.map(\.name) ?? [])
        guard existing.contains(name) else { return name }
        var n = 2
        while existing.contains("\(name)-\(n)") { n += 1 }
        return "\(name)-\(n)"
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
            // Wait for the interval, or less if a manual refresh / activity
            // nudge comes in.
            let deadline = ContinuousClock.now + effectiveInterval(state)
            while !Task.isCancelled, ContinuousClock.now < deadline, !state.refreshRequested {
                try? await Task.sleep(for: .milliseconds(250))
            }
            state.refreshRequested = false
        }
    }

    /// The target of the agent the user is currently viewing is polled much
    /// faster, so its idle/working state tracks closely. Everything else stays
    /// on the background interval to keep remote load low; output from any open
    /// mirror still nudges its own target (see `nudge`).
    private func effectiveInterval(_ state: TargetState) -> Duration {
        if state.lastFailure == nil, selection?.targetID == state.id {
            return min(TargetState.activeInterval, state.interval)
        }
        return state.interval
    }

    /// An open mirror saw output (the agent is doing something): refresh its
    /// target now so the sidebar flips to working without waiting a full cycle.
    /// Throttled on the terminal side; a no-op while the target is failing.
    func nudge(_ targetID: String) {
        guard let state = state(targetID), state.lastFailure == nil else { return }
        state.refreshRequested = true
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
            let newActivities = Self.resolveActivities(snapshot: snapshot, detections: state.detections)
            notifyActivityTransitions(state, old: state.activities, new: newActivities)
            state.activities = newActivities
            state.lastSuccess = Date()
            state.lastFailure = nil
            state.interval = TargetState.baseInterval
            if previousServer != snapshot.server {
                invalidateTerminals(of: state)
            }
            closeOrphanedMirrors(state)
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
        // We no longer set `destroy-unattached` (it crashes tmux on abrupt
        // teardown), so reap grouped mirror sessions a crashed instance left
        // behind — now unattached after ClientRelease, killed safely here.
        await PaneMirror.reapOrphanGroupedSessions(prefix: RemoteCommand.groupedSessionPrefix, host: state.host, target: state.target)
    }

    /// Closes a mirror once its pane no longer belongs to any real (non-grouped)
    /// session — i.e. the user killed their session and only our own grouped
    /// mirror session was keeping that window (and its agent) alive. Closing the
    /// mirror destroys the grouped session, so the window dies as the user
    /// intended and the ghost leaves the UI. A grouped session always coexists
    /// with its real session while open, so this never fires on a live view.
    private func closeOrphanedMirrors(_ state: TargetState) {
        guard let snapshot = state.snapshot else { return }
        for ref in Array(terminals.keys) where ref.targetID == state.id {
            if !snapshot.hasRealSession(ref.paneID) {
                closeTerminal(ref)
                if selection == ref { selection = nil }
            }
        }
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

    // MARK: Activity & notifications

    /// Resolves each agent pane's activity from the snapshot's log/screen
    /// signals. Shared by the sidebar and by notification transitions.
    static func resolveActivities(snapshot: InventorySnapshot, detections: [String: AgentDetection]) -> [String: AgentActivity] {
        var result: [String: AgentActivity] = [:]
        for (paneID, detection) in detections where detection.kind == .codex || detection.kind == .claudeCode {
            let evidence = detection.pid.flatMap { snapshot.agents[$0] }
            result[paneID] = ActivityDetector.resolve(
                kind: detection.kind,
                logEvent: evidence?.logEvent,
                logAgeSeconds: evidence?.logAgeSeconds,
                screenState: snapshot.screenStates[paneID],
                logState: snapshot.logStates[paneID]
            ).activity
        }
        return result
    }

    /// Fires a notification when a known agent finishes (working → idle) or
    /// starts needing input, unless the user is already viewing it. Nothing
    /// fires on a target's first refresh (no prior state to compare).
    private func notifyActivityTransitions(_ state: TargetState, old: [String: AgentActivity], new: [String: AgentActivity]) {
        guard notificationsEnabled, !old.isEmpty else { return }
        for (paneID, now) in new {
            guard let before = old[paneID], before != now else { continue }
            if let ref = state.ref(for: paneID), ref == selection { continue }
            let title = agentTitle(state, paneID: paneID)
            if before == .working, now == .idle {
                notifier.notify(.finished, agent: title, detail: state.device.name)
            } else if !before.needsAttention, now.needsAttention {
                notifier.notify(.needsAttention, agent: title, detail: state.device.name)
            }
        }
    }

    func requestNotificationAuthorization() {
        if notificationsEnabled { notifier.requestAuthorizationIfNeeded() }
    }

    /// Moves the selection to the next (`delta` = 1) or previous agent in the
    /// current scope, wrapping around, and opens it like a click would.
    func selectAdjacentAgent(_ delta: Int) {
        let refs = agentEntries.map(\.ref)
        guard !refs.isEmpty else { return }
        if let current = selection, let index = refs.firstIndex(of: current) {
            select(refs[(index + delta + refs.count) % refs.count])
        } else {
            select(delta >= 0 ? refs[0] : refs[refs.count - 1])
        }
    }

    private func agentTitle(_ state: TargetState, paneID: String) -> String {
        guard let snapshot = state.snapshot, let pane = snapshot.pane(paneID) else { return paneID }
        let kind = state.detections[paneID]?.kind ?? .none
        return AgentTitle.from(paneTitle: pane.title, kind: kind) ?? SpaceLabel.label(pane.currentPath)
    }

    // MARK: Derived data

    func state(_ targetID: String) -> TargetState? {
        targetStates[targetID]
    }

    /// `session:window.pane` using the first membership.
    func location(of paneID: String, in snapshot: InventorySnapshot) -> String {
        guard let row = snapshot.primaryMembership(of: paneID) else { return paneID }
        let session = snapshot.sessions.first { $0.id == row.sessionID }?.name ?? row.sessionID
        return "\(session):\(row.windowIndex).\(row.paneIndex)"
    }

    // MARK: Selection and terminals

    /// How many mirrors stay open at once. Open mirrors are live control-mode
    /// connections to a shared, often loaded server, so the least-recently
    /// viewed ones are closed rather than accumulating without bound.
    static let maxOpenTerminals = 4

    /// Most-recently viewed first; drives eviction.
    private var recentlyViewed: [PaneRef] = []

    /// Selecting a pane on an attachable target opens its mirror at once;
    /// mirroring changes nothing shared in tmux.
    func select(_ ref: PaneRef) {
        selection = ref
        if state(ref.targetID)?.target.access.allowsAttach == true {
            if terminals[ref] == nil { openTerminal(ref) }
            recentlyViewed.removeAll { $0 == ref }
            recentlyViewed.insert(ref, at: 0)
            evictStaleTerminals()
        }
        for terminal in terminals.values where !poppedOut.contains(terminal.ref) {
            terminal.setActive(terminal.ref == ref)
        }
    }

    /// Closes mirrors beyond the cap, oldest first, never the selected one or
    /// one shown in its own window.
    private func evictStaleTerminals() {
        while terminals.count > Self.maxOpenTerminals,
              let victim = recentlyViewed.last(where: { $0 != selection && !poppedOut.contains($0) && terminals[$0] != nil })
        {
            recentlyViewed.removeAll { $0 == victim }
            closeTerminal(victim)
        }
    }

    /// Moves the selected agent's mirror into its own window. The mirror itself
    /// is unchanged; only which window renders its surface moves.
    func popOut(_ ref: PaneRef) {
        guard state(ref.targetID)?.target.access.allowsAttach == true else { return }
        if terminals[ref] == nil { openTerminal(ref) }
        poppedOut.insert(ref)
        terminals[ref]?.setActive(true)
    }

    /// The window closed: the mirror returns to the main detail pane.
    func returnFromWindow(_ ref: PaneRef) {
        poppedOut.remove(ref)
    }

    func terminal(for ref: PaneRef) -> PaneTerminal? {
        terminals[ref]
    }

    var hasOpenTerminals: Bool { !terminals.isEmpty }

    func openTerminal(_ ref: PaneRef) {
        guard terminals[ref] == nil, let state = state(ref.targetID),
              let sessionID = state.snapshot?.memberships.first(where: { $0.paneID == ref.paneID })?.sessionID
        else { return }
        do {
            let terminal = try PaneTerminal(ref: ref, sessionID: sessionID, host: state.host, target: state.target)
            terminal.onActivity = { [weak self] in self?.nudge(ref.targetID) }
            terminals[ref] = terminal
        } catch {
            state.lastFailure = RemoteFailure(.remoteCommandFailed, detail: "\(error)")
        }
    }

    /// Ends this view's mirror. The pane and its programs keep running.
    func closeTerminal(_ ref: PaneRef) {
        poppedOut.remove(ref)
        terminals.removeValue(forKey: ref)?.close()
    }

    /// Closes every mirror. Each control client leaves when its input
    /// closes, so quitting right after is safe.
    func closeAllTerminals() {
        terminals.values.forEach { $0.close() }
        terminals.removeAll()
    }
}
