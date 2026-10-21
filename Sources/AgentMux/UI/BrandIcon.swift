// Bundled SVG icon loading and the small badges built on it. The SVG assets in
// Resources/Icons are LobeHub agent icons (MIT) and Simple Icons OS icons (CC0);
// see THIRD_PARTY_NOTICES.md.
import AgentMuxCore
import AppKit
import SwiftUI

/// A bundled SVG icon; `-color` variants keep their colors, others tint
/// like SF Symbols. Falls back to an SF Symbol when the file is missing
/// (e.g. running the bare executable outside the .app).
struct BrandIcon: View {
    let resource: String
    var size: CGFloat = 12
    var fallbackSystemName: String = "terminal"

    var body: some View {
        if let image = BrandIconLoader.image(named: resource) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(resource.hasSuffix("-color") ? .original : .template)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallbackSystemName)
                .font(.system(size: size - 1))
        }
    }
}

@MainActor
enum BrandIconLoader {
    private static var cache: [String: NSImage?] = [:]

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        var loaded: NSImage?
        if let url = Bundle.main.url(forResource: name, withExtension: "svg"),
           let image = NSImage(contentsOf: url)
        {
            image.isTemplate = !name.hasSuffix("-color")
            loaded = image
        }
        cache[name] = loaded
        return loaded
    }

    static func agentIcon(for kind: AgentKind) -> String? {
        switch kind {
        case .codex: "codex"
        case .claudeCode: "claude-color"
        case .none, .unknown: nil
        }
    }

    static func osIcon(for osID: String?) -> String? {
        guard let os = osID?.lowercased(), !os.isEmpty else { return nil }
        let map = [
            "macos": "apple", "ubuntu": "ubuntu", "debian": "debian", "fedora": "fedora",
            "arch": "archlinux", "alpine": "alpinelinux", "rocky": "rockylinux", "centos": "centos",
        ]
        return map[os] ?? "linux"
    }
}

extension AgentKind {
    var label: String {
        switch self {
        case .codex: "codex"
        case .claudeCode: "claude"
        case .none: "terminal"
        case .unknown: "unknown"
        }
    }
}

/// Agent icon + kind label, used in sidebar rows and the detail titlebar.
struct AgentKindBadge: View {
    let kind: AgentKind
    var iconSize: CGFloat = 11
    var fontSize: CGFloat = 11.5
    var color: Color = Theme.textTertiary

    var body: some View {
        HStack(spacing: 4) {
            if let resource = BrandIconLoader.agentIcon(for: kind) {
                BrandIcon(resource: resource, size: iconSize)
                    .foregroundStyle(color)
            }
            Text(kind.label)
                .font(.system(size: fontSize))
                .foregroundStyle(color)
        }
    }
}

/// Small tinted chip naming the target a row belongs to.
struct DeviceChip: View {
    let device: DeviceInfo

    private var shortName: String {
        device.name.count > 14 ? String(device.name.prefix(13)) + "…" : device.name
    }

    var body: some View {
        let tint = Theme.deviceTint(device.id)
        HStack(spacing: 3) {
            DeviceIcon(osID: device.osID, size: 8)
            Text(verbatim: shortName)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .frame(height: 15)
        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
        .fixedSize()
        .help(Text(verbatim: device.subtitle))
    }
}

struct DeviceIcon: View {
    let osID: String?
    var size: CGFloat = 12

    var body: some View {
        if let resource = BrandIconLoader.osIcon(for: osID) {
            BrandIcon(resource: resource, size: size, fallbackSystemName: "shippingbox")
        } else {
            Image(systemName: "shippingbox")
                .font(.system(size: size - 0.5))
        }
    }
}
