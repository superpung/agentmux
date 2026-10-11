import AgentMuxCore
import SwiftUI

/// Native settings window — the app's only configuration surface. The user adds
/// the SSH hosts here, then picks which of each host's auto-discovered
/// containers to monitor. There is no hand-edited config file.
struct SettingsView: View {
    var body: some View {
        TabView {
            HostsSettings()
                .tabItem { Label("Hosts", systemImage: "server.rack") }
            ContainersSettings()
                .tabItem { Label("Containers", systemImage: "shippingbox") }
        }
        .frame(width: 540, height: 480)
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
                    ContentUnavailableView(
                        "No hosts", systemImage: "server.rack",
                        description: Text("Add an SSH host to discover its containers.")
                    )
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
            .buttonStyle(.borderless)
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
            Text("The SSH destination is an alias from ~/.ssh/config or user@host. No passwords or keys — authentication goes through ssh and ssh-agent.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
