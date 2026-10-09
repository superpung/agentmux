// AgentMux local patch (see scripts/vendor-libghostty.sh).
import Foundation

extension Bundle {
    /// GhosttyTerminal's resource bundle. SwiftPM's generated `Bundle.module`
    /// only checks the .app root, where codesign rejects unsealed content,
    /// and the absolute build directory; an app keeps it in Contents/Resources.
    static let ghosttyTerminalResources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("GhosttyKit_GhosttyTerminal.bundle"),
           let bundle = Bundle(url: url)
        {
            return bundle
        }
        return .module
    }()
}
