// AgentMux local patch (see scripts/vendor-highlightr.sh).
import Foundation

extension Bundle {
    /// Signed apps keep resources inside Contents/Resources. SwiftPM's
    /// generated accessor checks the app root and an absolute build path,
    /// then traps. Missing highlighting resources should yield plain text.
    static func highlightrResources(in mainBundle: Bundle = .main) -> Bundle? {
        let name = "Highlightr_Highlightr.bundle"
        var candidates = [URL]()
        if let resources = mainBundle.resourceURL {
            candidates.append(resources.appendingPathComponent(name))
        }
        if mainBundle.bundleURL.pathExtension != "app" {
            // SwiftPM executables and test runners keep package resources
            // beside their executable or .xctest bundle.
            candidates.append(mainBundle.bundleURL.appendingPathComponent(name))
            candidates.append(mainBundle.bundleURL.deletingLastPathComponent().appendingPathComponent(name))
        }
        for url in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }
}
