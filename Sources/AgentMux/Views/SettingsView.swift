import AgentMuxCore
import SwiftUI

/// Native settings window. Lists the containers auto-discovered on each host
/// (read-only `docker ps`) and lets the user pick which ones AgentMux monitors.
/// Only the enabled containers become targets in the sidebar.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            ContainersSettings()
                .tabItem { Label("Containers", systemImage: "shippingbox") }
        }
        .frame(width: 520, height: 460)
    }
}

private struct ContainersSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if model.discoverableHosts.isEmpty {
                    Text("No hosts are configured for discovery.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.discoverableHosts) { host in
                    Section {
                        hostBody(host)
                    } header: {
                        Text(host.displayName.isEmpty ? host.id : host.displayName)
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
            Text("\(model.enabledContainers.count) monitored")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await model.discoverAll() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(model.isDiscovering)
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
        if isConfigured {
            // Monitored via an explicit targets.json5 entry; not toggleable here.
            HStack(spacing: 8) {
                label
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .help("Monitored via your configuration file")
            }
        } else {
            Toggle(isOn: binding) { label }
                .disabled(!container.running && !isEnabled)
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(container.running ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(container.name)
                Text(isConfigured ? "Configured · \(container.status)" : container.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var isConfigured: Bool {
        model.isExplicitlyConfigured(host: host, container: container.name)
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
