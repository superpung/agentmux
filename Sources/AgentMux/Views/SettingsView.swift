import AgentMuxCore
import SwiftUI

/// Native settings window — the app's only configuration surface. The user adds
/// the SSH hosts here, then picks which of each host's auto-discovered
/// containers to monitor. There is no hand-edited config file.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            HostsSettings()
                .tabItem { Label("Hosts", systemImage: "server.rack") }
            ContainersSettings()
                .tabItem { Label("Containers", systemImage: "shippingbox") }
        }
        .frame(width: 540, height: 480)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage(NotificationSound.needsYouKey) private var needsYouSound = NotificationSound.needsYouDefault
    @AppStorage(NotificationSound.doneKey) private var doneSound = NotificationSound.doneDefault
    @AppStorage("autoContinueEnabled") private var autoContinueEnabled = false
    @AppStorage(UpdateChecker.enabledKey) private var checkForUpdates = true
    @AppStorage(MenuBarContent.showsResourcesKey) private var menuBarShowsResources = true
    @AppStorage("autoContinueMessage") private var autoContinueMessage = "continue"
    @AppStorage("autoContinueAttempts") private var autoContinueAttempts = 3

    /// Installed monospaced families, with the current choice always present.
    private var fontFamilies: [String] {
        var families = GhosttyRuntime.monospacedFamilies()
        if !families.contains(model.terminalFontFamily) {
            families.insert(model.terminalFontFamily, at: 0)
        }
        return families
    }

    private func soundPicker(_ title: String, _ selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag("")
            Divider()
            ForEach(NotificationSound.names, id: \.self) { Text($0).tag($0) }
        }
        .disabled(!notificationsEnabled)
        .onChange(of: selection.wrappedValue) { _, name in NotificationSound.preview(name) }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show banners for new notifications", isOn: $notificationsEnabled)
                soundPicker("Needs you sound", $needsYouSound)
                soundPicker("Done sound", $doneSound)
                Toggle("Check for updates", isOn: $checkForUpdates)
            }
            Section {
                Toggle("Continue agents stopped by an error", isOn: $autoContinueEnabled)
                TextField("Message", text: $autoContinueMessage, prompt: Text("continue"))
                    .disabled(!autoContinueEnabled)
                LabeledContent("Tries in a row") {
                    HStack(spacing: 8) {
                        Text("\(autoContinueAttempts)").monospacedDigit().foregroundStyle(.primary)
                        Stepper("", value: $autoContinueAttempts, in: 1 ... 10).labelsHidden()
                    }
                }
                .disabled(!autoContinueEnabled)
            } header: {
                Text("Auto-continue")
            }
            Section {
                Picker("Terminal theme", selection: Binding(
                    get: { model.terminalTheme },
                    set: { model.setTerminalTheme($0) }
                )) {
                    ForEach(TerminalThemePreference.allCases, id: \.self) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
            }
            Section {
                Picker("Terminal font", selection: Binding(
                    get: { model.terminalFontFamily },
                    set: { model.setTerminalFontFamily($0) }
                )) {
                    ForEach(fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                LabeledContent("Terminal font size") {
                    HStack(spacing: 8) {
                        Text("\(Int(model.terminalFontSize)) pt").monospacedDigit().foregroundStyle(.primary)
                        Stepper("", value: Binding(
                            get: { model.terminalFontSize },
                            set: { model.setTerminalFontSize($0) }
                        ), in: 8 ... 32).labelsHidden()
                    }
                }
            }
            Section {
                Toggle("Container CPU and memory", isOn: $menuBarShowsResources)
            } header: {
                Text("Menu bar")
            }
            Section {
                ForEach(StatusBarField.allCases, id: \.self) { field in
                    Toggle(field.label, isOn: Binding(
                        get: { model.showsStatusField(field) },
                        set: { model.setStatusField(field, $0) }
                    ))
                }
            } header: {
                Text("Status bar")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Hosts

private struct HostsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var editor: HostEditor.Target?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(model.hosts) { host in
                    HStack(spacing: 10) {
                        Image(systemName: "server.rack").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(host.displayName)
                            Text(host.sshDestination)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .tag(host.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editor = .edit(host) }
                }
            }
            .overlay {
                if model.hosts.isEmpty {
                    ContentUnavailableView("No hosts", systemImage: "server.rack")
                }
            }
            Divider()
            HStack(spacing: 6) {
                Button { editor = .add } label: { Image(systemName: "plus") }
                    .help("Add a host")
                Button { if let id = selection { removeSelected(id) } } label: { Image(systemName: "minus") }
                    .help("Remove the selected host")
                    .disabled(selection == nil)
                Spacer()
                if let id = selection, let host = model.hosts.first(where: { $0.id == id }) {
                    Button("Edit…") { editor = .edit(host) }
                }
            }
            .buttonStyle(.hover)
            .padding(10)
        }
        .sheet(item: $editor) { target in
            HostEditor(target: target) { name, ssh in
                switch target {
                case .add: model.addHost(displayName: name, sshDestination: ssh)
                case let .edit(host): model.updateHost(id: host.id, displayName: name, sshDestination: ssh)
                }
            }
        }
    }

    private func removeSelected(_ id: String) {
        model.removeHost(id: id)
        selection = nil
    }
}

private struct HostEditor: View {
    enum Target: Identifiable {
        case add
        case edit(HostConfig)
        var id: String { if case let .edit(host) = self { return host.id } else { return "add" } }
    }

    let target: Target
    let onSave: (_ name: String, _ ssh: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var ssh = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEdit ? "Edit Host" : "Add Host").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("Lab server"))
                TextField("SSH destination", text: $ssh, prompt: Text("ssh-config alias or user@host"))
                    .autocorrectionDisabled()
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isEdit ? "Save" : "Add") {
                    onSave(name, ssh)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ssh.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if case let .edit(host) = target {
                name = host.displayName
                ssh = host.sshDestination
            }
        }
    }

    private var isEdit: Bool { if case .edit = target { return true } else { return false } }
}

// MARK: - Containers

private struct ContainersSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if model.hosts.isEmpty {
                    Text("Add a host first, in the Hosts tab.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.hosts) { host in
                    Section {
                        hostBody(host)
                    } header: {
                        Text(host.displayName)
                    }
                }
            }
            .formStyle(.grouped)
            footer
        }
    }

    @ViewBuilder
    private func hostBody(_ host: HostConfig) -> some View {
        let containers = model.discovered[host.id] ?? []
        if containers.isEmpty {
            Text(model.isDiscovering ? "Discovering…" : "No containers found.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(containers) { container in
                ContainerToggle(host: host, container: container)
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.isDiscovering {
                ProgressView().controlSize(.small)
            }
            Text("\(model.monitoredCount) monitored")
                .font(.caption)
                .foregroundStyle(.secondary)
                .animation(Motion.quick, value: model.isDiscovering)
            Spacer()
            Button {
                Task { await model.discoverAll() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(model.isDiscovering || model.hosts.isEmpty)
        }
        .padding(12)
        .background(.bar)
    }
}

private struct ContainerToggle: View {
    @Environment(AppModel.self) private var model
    let host: HostConfig
    let container: DiscoveredContainer

    var body: some View {
        Toggle(isOn: binding) {
            HStack(spacing: 8) {
                Circle()
                    .fill(container.running ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(container.name)
                    Text(container.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .disabled(!container.running && !isEnabled)
    }

    private var isEnabled: Bool {
        model.isContainerEnabled(host: host, container: container)
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { model.setContainer(container, on: host, enabled: $0) }
        )
    }
}
