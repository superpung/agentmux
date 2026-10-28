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
    /// Why an agent that is not working stopped short, per pane.
    var faults: [String: AgentFault] = [:]
    var faultTracker = FaultTracker()
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
    /// The focused agent: the one shown, or with several shown together, the
    /// tile that has keyboard focus. Selecting anything outside the tiles goes
    /// back to the single view.
    var selection: PaneRef? {
        didSet {
            guard selection != oldValue else { return }
            if let selection, tiles.contains(selection) {} else {
                tiles = []
                isZoomed = false
            }
            applyVisibility()
        }
    }
    /// Agents shown together in the detail area, in layout order; empty when
    /// one agent (the selection) fills it.
    private(set) var tiles: [PaneRef] = []
    /// The focused tile temporarily fills the detail area; the others keep
    /// their mirrors and sizes.
    private(set) var isZoomed = false
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
    /// When each host's resource snapshot was last stored, for I/O rate deltas.
    private var resourceSampledAt: [String: Date] = [:]
    /// The selected agent's own process resources, and which ref they belong to
    /// (so a just-changed selection never shows the previous agent's figures).
    private var focusedAgentRef: PaneRef?
    private(set) var focusedAgentResources: AgentResources?
    private var focusedGitRef: PaneRef?
    private(set) var focusedGitStatus: GitStatus?
    static let resourceInterval: Duration = .seconds(5)

    // MARK: Inspector / file-preview UI state

    var inspectorVisible = UserDefaults.standard.bool(forKey: "showResourceInspector") {
        didSet { UserDefaults.standard.set(inspectorVisible, forKey: "showResourceInspector") }
    }
    func toggleInspector() { inspectorVisible.toggle() }

    /// A request to preview a file in the Files window. The nonce lets the same
    /// path be re-requested; a view observes this and opens the window.
    struct PreviewRequest: Equatable, Sendable { var spec: FilesWindowSpec; var path: String; var nonce: Int }
    private(set) var previewRequest: PreviewRequest?
    private var previewNonce = 0

    func requestFilePreview(_ path: String, in spec: FilesWindowSpec) {
        previewNonce += 1
        previewRequest = PreviewRequest(spec: spec, path: path, nonce: previewNonce)
    }

    /// The Files window for a pane: its agent's working directory.
    func filesSpec(for ref: PaneRef) -> FilesWindowSpec? {
        let root = [agentEntry(ref)?.space.path, paneEntry(ref)?.space.path].compactMap { $0 }.first { !$0.isEmpty }
        return root.map { FilesWindowSpec(targetID: ref.targetID, root: $0) }
    }

    /// The Files window for the selected agent, if any.
    var selectedFilesSpec: FilesWindowSpec? {
        selection.flatMap(filesSpec(for:))
    }

    /// A path selected in `ref`'s terminal: resolve it (relative paths against
    /// the agent's cwd) and preview it.
    func previewFromTerminal(_ raw: String, ref: PaneRef) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let path: String
        if trimmed.hasPrefix("/") {
            path = trimmed
        } else if let cwd = agentEntry(ref)?.space.path ?? paneEntry(ref)?.space.path, !cwd.isEmpty {
            path = (cwd as NSString).appendingPathComponent(trimmed)
        } else {
            path = trimmed
        }
        if selection != ref { select(ref) }
        // Without a known cwd, browse the folder the path is in.
        let spec = filesSpec(for: ref)
            ?? FilesWindowSpec(targetID: ref.targetID, root: (path as NSString).deletingLastPathComponent)
        requestFilePreview(path, in: spec)
    }
    private var releasedOrphans: Set<String> = []
    @ObservationIgnored private let notifier = Notifier()
    /// Every notification, with read state (the toolbar bell).
    let inbox = Inbox()
    var showInbox = false

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

    /// The palette for embedded terminals: one global setting, since every
    /// mirror shares the terminal engine's single color scheme. `.system`
    /// follows the Mac; pin `.dark`/`.light` when agents render for a fixed theme
    /// (their TUIs usually assume dark).
    private(set) var terminalTheme: TerminalThemePreference =
        UserDefaults.standard.string(forKey: "terminalTheme")
            .flatMap(TerminalThemePreference.init(rawValue:)) ?? .system

    func setTerminalTheme(_ preference: TerminalThemePreference) {
        terminalTheme = preference
        UserDefaults.standard.set(preference.rawValue, forKey: "terminalTheme")
        applyTerminalTheme()
    }

    /// Applies the one global theme to every open terminal and the shared
    /// controller. All surfaces use the same scheme, so switching never flips it.
    func applyTerminalTheme() {
        for terminal in terminals.values { terminal.applyTheme(terminalTheme) }
        GhosttyRuntime.applyColorScheme(for: terminalTheme)
    }

    /// The font family for embedded terminals. Applied live to every open
    /// surface; defaults to SF Mono when this Mac can resolve it, else Menlo.
    private(set) var terminalFontFamily: String =
        UserDefaults.standard.string(forKey: GhosttyRuntime.fontFamilyKey) ?? GhosttyRuntime.defaultFontFamily

    func setTerminalFontFamily(_ family: String) {
        terminalFontFamily = family
        UserDefaults.standard.set(family, forKey: GhosttyRuntime.fontFamilyKey)
        GhosttyRuntime.applyFontFamily(family)
    }

    /// The terminal font size, persisted so a chosen size (or a zoom) survives a
    /// restart. Applied live to every open surface.
    private(set) var terminalFontSize: Double =
        (UserDefaults.standard.object(forKey: GhosttyRuntime.fontSizeKey) as? Double) ?? GhosttyRuntime.defaultFontSize

    func setTerminalFontSize(_ size: Double) {
        let clamped = min(GhosttyRuntime.maxFontSize, max(GhosttyRuntime.minFontSize, size))
        terminalFontSize = clamped
        UserDefaults.standard.set(clamped, forKey: GhosttyRuntime.fontSizeKey)
        GhosttyRuntime.applyFontSize(clamped)
    }

    /// Remembers a size the user reached by zooming a terminal (⌘ +/−), so new
    /// terminals and the next launch use it. Does not resize other open terminals.
    func rememberTerminalFontSize(_ size: Double) {
        let clamped = min(GhosttyRuntime.maxFontSize, max(GhosttyRuntime.minFontSize, size))
        guard abs(clamped - terminalFontSize) > 0.01 else { return }
        terminalFontSize = clamped
        UserDefaults.standard.set(clamped, forKey: GhosttyRuntime.fontSizeKey)
    }

    /// Which chips the bottom status bar shows. Version is off by default (it is
    /// always available in the hover tooltip); the rest are on.
    private(set) var statusBarFields: Set<StatusBarField> =
        (UserDefaults.standard.array(forKey: "statusBarFields") as? [String])
            .map { Set($0.compactMap(StatusBarField.init(rawValue:))) }
        ?? StatusBarField.defaultVisible

    func showsStatusField(_ field: StatusBarField) -> Bool { statusBarFields.contains(field) }

    func setStatusField(_ field: StatusBarField, _ on: Bool) {
        if on { statusBarFields.insert(field) } else { statusBarFields.remove(field) }
        UserDefaults.standard.set(statusBarFields.map(\.rawValue), forKey: "statusBarFields")
    }

    // MARK: Account links & switching

    /// Which tab the combined container window (Sessions / Accounts) shows.
    var containerTab: ContainerTab = .sessions

    /// Claude account link groups per target, populated lazily when a terminal
    /// opens so the "Switch Account" menu knows which accounts share a project.
    private(set) var linkGroupsByTarget: [String: [ProjectLinkGroup]] = [:]
    /// Codex account dirs + non-secret account ids per target, for switching.
    private(set) var codexAccountsByTarget: [String: [AgentSessionProbe.CodexAccount]] = [:]

    func refreshLinks(_ targetID: String) {
        guard let state = state(targetID) else { return }
        Task { [weak self] in
            if case let .success(entries) = await AgentSessionProbe.projectLinks(host: state.host, target: state.target) {
                let groups = AgentSessionProbe.linkGroups(from: entries)
                await MainActor.run { self?.linkGroupsByTarget[targetID] = groups }
            }
            if case let .success(accts) = await AgentSessionProbe.codexAccounts(host: state.host, target: state.target) {
                await MainActor.run { self?.codexAccountsByTarget[targetID] = accts }
            }
        }
    }

    /// The other accounts this agent's project is linked to, so its session can
    /// be resumed under them. Empty unless it is a Claude agent in a shared
    /// project (and the link scan for its container has completed).
    func switchableAccounts(for ref: PaneRef) -> [String] {
        guard let agent = agentEntry(ref) else { return [] }
        switch agent.kind {
        case .claudeCode:
            guard let groups = linkGroupsByTarget[ref.targetID],
                  let group = groups.first(where: { $0.cwd == agent.space.path && $0.isShared })
            else { return [] }
            // An agent on the default account has no CLAUDE_CONFIG_DIR, so no
            // configDir is reported; it is the ".claude" entry in the group.
            let current = agent.configDir ?? group.accounts.first { ($0 as NSString).lastPathComponent == ".claude" }
            return group.accounts.filter { $0 != current }
        case .codex:
            // Codex sessions are linked to one canonical copy, so any other codex
            // account dir can resume the session. Offer the ones whose account
            // differs from this agent's current one.
            guard let accounts = codexAccountsByTarget[ref.targetID] else { return [] }
            let currentAccount = state(ref.targetID)?.snapshot?.accounts[ref.paneID]
            let currentID = currentAccount.flatMap { $0.hasPrefix("codex:") ? String($0.dropFirst(6)) : nil }
            return accounts
                .filter { $0.accountID != currentID && $0.path != agent.configDir }
                .map(\.path)
        default:
            return []
        }
    }

    /// Switches the Claude agent to another linked account, resuming the same
    /// conversation in place. Returns nil on success (and requests a refresh),
    /// else an error string. Destructive — the caller confirms first.
    func switchAccount(_ ref: PaneRef, to configDir: String) async -> String? {
        guard let state = state(ref.targetID), let agent = agentEntry(ref),
              let pid = state.detections[ref.paneID]?.pid
        else { return "This agent is no longer available." }
        // The switch kills the agent and types the relaunch command into the
        // pane itself. Suspend this mirror's input for the duration so no local
        // key or stray mouse report races ahead of that command and corrupts it.
        terminals[ref]?.setInputSuspended(true)
        defer { terminals[ref]?.setInputSuspended(false) }
        let result: Result<String, RemoteFailure>
        switch agent.kind {
        case .claudeCode:
            result = await AgentAccountSwitch.switchClaudeAccount(
                host: state.host, target: state.target,
                paneID: ref.paneID, claudePID: pid, cwd: agent.space.path, newConfigDir: configDir
            )
        case .codex:
            result = await AgentAccountSwitch.switchCodexAccount(
                host: state.host, target: state.target,
                paneID: ref.paneID, codexPID: pid, cwd: agent.space.path, newConfigDir: configDir
            )
        default:
            return "Account switching is not supported for this agent."
        }
        switch result {
        case .success:
            state.refreshRequested = true
            refreshLinks(ref.targetID)
            return nil
        case let .failure(failure):
            return failure.detail.isEmpty ? failure.kind.rawValue : failure.detail
        }
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
        ClientRelease.ownerPrefix = Self.installID()
        loadSettings()
    }

    /// A stable per-install id, generated once and persisted, that scopes tmux
    /// client/session cleanup to this install. Two AgentMux copies on different
    /// machines can watch the same tmux server; without this, one launching
    /// would release the other's live mirror clients (and reap its grouped
    /// sessions), dropping its open terminals. Hex, no dashes, to satisfy the
    /// client-tag character set.
    private static func installID() -> String {
        let key = "installID"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty { return existing }
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        UserDefaults.standard.set(id, forKey: key)
        return id
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
                        var snapshot = snapshot
                        let now = Date()
                        fillIORates(&snapshot, previous: resources[host.id], since: resourceSampledAt[host.id], now: now)
                        resourceSampledAt[host.id] = now
                        resources[host.id] = snapshot
                        recordHistory(host.id, snapshot)
                    }
                }
                await pollFocusedAgent()
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

    /// Fills each container's I/O rate by differencing the cumulative Docker
    /// figures against the previous snapshot. Left nil when the container is new,
    /// the counters went backwards (container restarted), or the interval is too
    /// short to trust.
    private func fillIORates(_ snapshot: inout HostResources, previous: HostResources?, since: Date?, now: Date) {
        guard let previous, let since else { return }
        let dt = now.timeIntervalSince(since)
        guard dt > 0.5 else { return }
        for (name, container) in snapshot.containers {
            guard let prev = previous.containers[name] else { continue }
            var updated = container
            if let newNet = ResourceProbe.pairTotalBytes(container.netText),
               let oldNet = ResourceProbe.pairTotalBytes(prev.netText), newNet >= oldNet {
                updated.netRateBytesPerSec = (newNet - oldNet) / dt
            }
            if let newBlk = ResourceProbe.pairTotalBytes(container.blockText),
               let oldBlk = ResourceProbe.pairTotalBytes(prev.blockText), newBlk >= oldBlk {
                updated.blockRateBytesPerSec = (newBlk - oldBlk) / dt
            }
            snapshot.containers[name] = updated
        }
    }

    /// Probes just the selected agent's own process (CPU / memory / uptime) and
    /// its workspace filesystem, inside that agent's container. Runs once per
    /// cycle for the current selection only — never for every container.
    private func pollFocusedAgent() async {
        guard let ref = selection,
              let state = state(ref.targetID),
              let pid = state.detections[ref.paneID]?.pid
        else {
            focusedAgentResources = nil
            focusedAgentRef = nil
            focusedGitStatus = nil
            focusedGitRef = nil
            return
        }
        let cwd = agentEntry(ref)?.space.path
        if case let .success(resources) = await AgentResourceProbe.run(host: state.host, target: state.target, pid: pid, cwd: cwd),
           selection == ref {
            focusedAgentResources = resources
            focusedAgentRef = ref
        }
        if let cwd, !cwd.isEmpty,
           case let .success(git) = await GitStatusProbe.run(host: state.host, target: state.target, cwd: cwd),
           selection == ref {
            focusedGitStatus = git
            focusedGitRef = ref
        }
    }

    /// The selected agent's git working-tree summary, when its directory is a
    /// repo and the latest probe was for this exact ref.
    func gitStatus(for ref: PaneRef) -> GitStatus? {
        focusedGitRef == ref ? focusedGitStatus : nil
    }

    /// The unified diff of one changed file in the selected agent's working tree,
    /// fetched on demand when the user opens that file (never on the refresh
    /// cycle). Read-only `git diff HEAD -- <path>`.
    func fileDiff(for ref: PaneRef, path: String) async -> Result<String, RemoteFailure> {
        guard let state = state(ref.targetID) else {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "no container"))
        }
        guard let cwd = agentEntry(ref)?.space.path, !cwd.isEmpty else {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "no working directory"))
        }
        return await GitDiffProbe.file(host: state.host, target: state.target, cwd: cwd, path: path)
    }

    /// Any agent's usage (context tokens / rate limit) from the latest snapshot,
    /// with Claude's context window inferred so a fraction is available for both.
    func usage(for ref: PaneRef) -> InventorySnapshot.AgentUsage? {
        state(ref.targetID)?.snapshot?.usage[ref.paneID]?.withInferredWindow()
    }

    /// The selected agent's own process resources, but only when the latest
    /// focused probe was for this exact ref (otherwise nil, never stale).
    func agentResources(for ref: PaneRef) -> AgentResources? {
        focusedAgentRef == ref ? focusedAgentResources : nil
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
            return "The agent isn't connected yet. Try again in a moment."
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
        if state.lastFailure == nil, visibleRefs.contains(where: { $0.targetID == state.id }) {
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
            // A fault only describes an agent that is not busy: a working or
            // waiting agent has moved past it.
            let newFaults = snapshot.faults.filter { pane, _ in
                let activity = newActivities[pane] ?? .unknown
                return activity != .working && !activity.needsAttention
            }
            noteActivityTransitions(state, old: state.activities, new: newActivities, faults: newFaults)
            state.activities = newActivities
            state.faults = newFaults
            // Let the mirror forward mouse reports only while a live agent holds
            // the pane; a killed/terminated agent drops to a shell and mouse is
            // stripped so pointer events are not typed into it as commands.
            for (ref, terminal) in terminals where ref.targetID == state.id {
                terminal.setMouseForwardingAllowed(state.detections[ref.paneID]?.kind.isAgent ?? false)
            }
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
        await PaneMirror.reapOrphanGroupedSessions(prefix: RemoteCommand.groupedSessionPrefix + ClientRelease.ownerPrefix, host: state.host, target: state.target)
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
                logState: snapshot.logStates[paneID],
                title: snapshot.pane(paneID)?.title
            ).activity
        }
        return result
    }

    /// Records what happened to each agent since the last refresh: a turn
    /// finished (working → idle), it started needing the user, or its turn
    /// stopped on a usage limit or an error. Each goes to the inbox, with a
    /// banner unless the agent is on screen. Nothing fires on a target's first
    /// refresh (no prior state to compare); faults already there are only
    /// noted, not reported.
    private func noteActivityTransitions(_ state: TargetState, old: [String: AgentActivity],
                                         new: [String: AgentActivity], faults: [String: AgentFault]) {
        let first = old.isEmpty
        let started = state.faultTracker.update(faults, now: Date(), report: !first)
        guard !first else { return }
        for (paneID, now) in new {
            guard let before = old[paneID], before != now else { continue }
            if before == .working, now == .idle, faults[paneID] == nil {
                post(.finished, state, paneID)
            } else if !before.needsAttention, now.needsAttention {
                post(.needsInput, state, paneID)
            }
        }
        for (paneID, fault) in started {
            switch fault.kind {
            case .usageLimit:
                post(.usageLimit, state, paneID, detail: usageDetail(fault))
            case .error:
                post(.error, state, paneID, detail: fault.summary)
            }
        }
    }

    /// "5-hour limit · resets 4:00 PM"
    private func usageDetail(_ fault: AgentFault) -> String {
        guard let resetsAt = fault.resetsAt else { return fault.summary }
        let date = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        let style: Date.FormatStyle = Calendar.current.isDateInToday(date)
            ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute()
        return "\(fault.summary) · resets \(date.formatted(style))"
    }

    /// Adds an inbox item for `paneID`; it arrives already read, and without
    /// a banner, when the agent is on screen.
    private func post(_ kind: InboxItem.Kind, _ state: TargetState, _ paneID: String, detail: String? = nil) {
        guard let ref = state.ref(for: paneID) else { return }
        let viewed = visibleRefs.contains(ref) || poppedOut.contains(ref)
        let name = agentEntry(ref).map { customName($0.identityKey) ?? $0.title } ?? agentTitle(state, paneID: paneID)
        let item = InboxItem(kind: kind, ref: ref, agent: name, place: state.device.name, detail: detail, isRead: viewed)
        inbox.add(item)
        if !viewed, notificationsEnabled { notifier.notify(item) }
    }

    /// Opens the agent an inbox item is about (if it is still there) and
    /// marks the item read. Also the action of clicking its banner.
    func openInboxItem(_ id: UUID) {
        guard let item = inbox.item(id) else { return }
        markInboxRead(id)
        guard let state = state(item.ref.targetID), state.snapshot?.pane(item.ref.paneID) != nil,
              state.ref(for: item.ref.paneID) == item.ref else { return }
        select(item.ref)
    }

    func markInboxRead(_ id: UUID, _ read: Bool = true) {
        inbox.setRead(id, read)
        if read { notifier.withdraw([id]) }
    }

    func markAllInboxRead() {
        let unread = inbox.items.filter { !$0.isRead }.map(\.id)
        inbox.markAllRead()
        notifier.withdraw(unread)
    }

    func removeInboxItems(_ ids: [UUID]) {
        for id in ids { inbox.remove(id) }
        notifier.withdraw(ids)
    }

    func requestNotificationAuthorization() {
        if notificationsEnabled { notifier.requestAuthorizationIfNeeded() }
    }

    /// Moves the selection to the next (`delta` = 1) or previous agent in the
    /// current scope, wrapping around, and opens it like a click would. With
    /// several agents shown, it moves focus between their tiles instead.
    func selectAdjacentAgent(_ delta: Int) {
        if isTiled {
            let index = selection.flatMap { tiles.firstIndex(of: $0) } ?? 0
            selection = tiles[(index + delta + tiles.count) % tiles.count]
            return
        }
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
    /// mirroring changes nothing shared in tmux. A pane already in the tiles
    /// just takes focus.
    func select(_ ref: PaneRef) {
        selection = ref
        open([ref])
        applyVisibility()
    }

    /// Shows the sidebar's selection: one row fills the detail area, several
    /// are tiled. Tiles keep their places; new ones join at the end in sidebar
    /// order and the last of them takes focus. Past `TileLayout.maxTiles` the
    /// extra rows are left out.
    func show(_ refs: Set<PaneRef>, sidebarOrder: [PaneRef]) {
        guard refs.count > 1 else {
            if let ref = refs.first {
                tiles = []
                select(ref)
            } else {
                selection = nil
            }
            return
        }
        var next = tiles.filter(refs.contains)
        if next.isEmpty, let selection, refs.contains(selection) { next = [selection] }
        let added = sidebarOrder.filter { refs.contains($0) && !next.contains($0) }
        next += added
        next = Array(next.prefix(TileLayout.maxTiles))
        let focus = added.last(where: next.contains) ?? selection.flatMap { next.contains($0) ? $0 : nil } ?? next[0]
        tiles = next.count > 1 ? next : []
        selection = focus
        open(next)
        applyVisibility()
    }

    /// The agents in the detail area right now (all tiles, or the zoomed or
    /// single one).
    var visibleRefs: [PaneRef] {
        if isTiled, !isZoomed { return tiles }
        return selection.map { [$0] } ?? []
    }

    var isTiled: Bool { tiles.count > 1 }

    /// A tile's surface took keyboard focus (the user clicked into it).
    func focusTile(_ ref: PaneRef) {
        guard tiles.contains(ref), selection != ref else { return }
        selection = ref
    }

    /// Takes a tile out of the view; its mirror stays open like any recently
    /// viewed one. The last remaining tile fills the area again.
    func removeTile(_ ref: PaneRef) {
        guard let index = tiles.firstIndex(of: ref) else { return }
        var next = tiles
        next.remove(at: index)
        let focus = selection == ref ? next[min(index, next.count - 1)] : selection
        tiles = next.count > 1 ? next : []
        if tiles.isEmpty { isZoomed = false }
        selection = focus
        applyVisibility()
    }

    func toggleZoom() {
        guard isTiled else { return }
        isZoomed.toggle()
        applyVisibility()
    }

    /// Closes the view of `ref` from its Actions menu: a tile leaves the
    /// tiles; a single view returns to the dashboard.
    func closeView(_ ref: PaneRef) {
        if tiles.contains(ref) { removeTile(ref) } else if selection == ref { selection = nil }
        closeTerminal(ref)
    }

    /// Opens the mirrors of `refs` on attachable targets and marks them
    /// recently viewed.
    private func open(_ refs: [PaneRef]) {
        for ref in refs.reversed() where state(ref.targetID)?.target.access.allowsAttach == true {
            if terminals[ref] == nil { openTerminal(ref) }
            recentlyViewed.removeAll { $0 == ref }
            recentlyViewed.insert(ref, at: 0)
        }
        evictStaleTerminals()
    }

    /// Shows, and opens input to, exactly the mirrors on screen in the detail
    /// area, and gives the selected one keyboard focus. Mirrors in their own
    /// window are left alone.
    private func applyVisibility() {
        let shown = Set(visibleRefs)
        for terminal in terminals.values where !poppedOut.contains(terminal.ref) {
            terminal.setVisible(shown.contains(terminal.ref))
        }
        if let selection, !poppedOut.contains(selection) { terminals[selection]?.focus() }
    }

    /// Closes mirrors beyond the cap, oldest first, never one on screen or
    /// one shown in its own window.
    private func evictStaleTerminals() {
        while terminals.count > Self.maxOpenTerminals,
              let victim = recentlyViewed.last(where: {
                  $0 != selection && !tiles.contains($0) && !poppedOut.contains($0) && terminals[$0] != nil
              })
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
        // A tile moving to its own window leaves the tiles.
        removeTile(ref)
    }

    /// The window closed: the mirror returns to the main detail pane.
    func returnFromWindow(_ ref: PaneRef) {
        poppedOut.remove(ref)
        applyVisibility()
    }

    func terminal(for ref: PaneRef) -> PaneTerminal? {
        terminals[ref]
    }

    var hasOpenTerminals: Bool { !terminals.isEmpty }

    func openTerminal(_ ref: PaneRef) {
        // Group the mirror onto the pane's REAL session, never a leftover
        // "agentmux-…" grouped mirror. `list-panes -a` orders rows by session
        // name, so a grouped mirror (which sorts before real names) would be
        // `memberships.first`; grouping a new mirror onto it orphans the view
        // when that mirror is reaped. `primaryMembership` prefers the real one.
        guard terminals[ref] == nil, let state = state(ref.targetID),
              let sessionID = state.snapshot?.primaryMembership(of: ref.paneID)?.sessionID
        else { return }
        do {
            let terminal = try PaneTerminal(ref: ref, sessionID: sessionID, host: state.host, target: state.target)
            terminal.onActivity = { [weak self] in self?.nudge(ref.targetID) }
            terminal.onPreviewRequest = { [weak self] raw in self?.previewFromTerminal(raw, ref: ref) }
            terminal.onFontSizeChanged = { [weak self] size in self?.rememberTerminalFontSize(size) }
            terminal.onFocus = { [weak self] in self?.focusTile(ref) }
            terminal.applyTheme(terminalTheme)
            terminal.setMouseForwardingAllowed(state.detections[ref.paneID]?.kind.isAgent ?? false)
            terminals[ref] = terminal
            // Populate the account-link map so "Switch Account" is ready.
            if linkGroupsByTarget[ref.targetID] == nil { refreshLinks(ref.targetID) }
        } catch {
            state.lastFailure = RemoteFailure(.remoteCommandFailed, detail: "\(error)")
        }
    }

    /// Ends this view's mirror. The pane and its programs keep running.
    func closeTerminal(_ ref: PaneRef) {
        poppedOut.remove(ref)
        removeTile(ref)
        terminals.removeValue(forKey: ref)?.close()
    }

    /// Closes every mirror. Each control client leaves when its input
    /// closes, so quitting right after is safe.
    func closeAllTerminals() {
        terminals.values.forEach { $0.close() }
        terminals.removeAll()
        ephemeralTerminals.values.forEach { $0.close() }
        ephemeralTerminals.removeAll()
    }

    // MARK: Ephemeral terminals (throwaway shells, not in tmux)

    private var ephemeralTerminals: [UUID: EphemeralTerminal] = [:]

    /// A spec for a throwaway shell in the selected agent's container/host, or
    /// nil when nothing suitable is selected. A fresh id opens a new window.
    func newTerminalSpec() -> EphemeralTerminalSpec? {
        guard let ref = selection, let agent = agentEntry(ref), state(ref.targetID) != nil else { return nil }
        return EphemeralTerminalSpec(targetID: ref.targetID, label: agent.device.name, id: UUID())
    }

    /// The terminal for a window's spec, created lazily on first access.
    func ephemeralTerminal(for spec: EphemeralTerminalSpec) -> EphemeralTerminal? {
        if let existing = ephemeralTerminals[spec.id] { return existing }
        guard let state = state(spec.targetID),
              let terminal = try? EphemeralTerminal(host: state.host, target: state.target)
        else { return nil }
        ephemeralTerminals[spec.id] = terminal
        return terminal
    }

    func closeEphemeral(_ id: UUID) {
        ephemeralTerminals.removeValue(forKey: id)?.close()
    }
}
