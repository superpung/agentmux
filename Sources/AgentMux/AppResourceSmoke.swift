import AppKit
import Foundation

/// Exercises the real preview highlighter before settings, polling or windows
/// are created. The packaging check runs this in a relocated, standalone app.
@MainActor
enum AppResourceSmoke {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["AGENTMUX_RESOURCE_SMOKE_TEST"] else { return }
        _ = NSApplication.shared
        let code = "let answer = 42 // preview fixture\n"
        let highlighter = CodeHighlighter.shared
        var variants = [[String: Any]]()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let result = highlighter.highlight(code, language: "swift")
            guard result.string.string == code else { fail("Preview text changed") }
            var colors = Set<String>()
            result.string.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.string.length)) { value, _, _ in
                if let color = value as? NSColor { colors.insert(color.description) }
            }
            if highlighter.isAvailable && colors.count < 2 { fail("Preview has no syntax colors") }
            variants.append(["theme": name, "colors": colors.count])
        }
        do {
            let report: [String: Any] = [
                "mode": highlighter.isAvailable ? "highlighted" : "plain",
                "bundle": Bundle.main.bundleURL.path,
                "variants": variants,
                "textPreserved": true,
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path), options: .atomic)
            exit(0)
        } catch { fail("Could not write resource smoke report: \(error)") }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
