import SwiftUI

/// Settings ▸ Shortcuts: every key the app answers to. The app's commands
/// come from `AppCommand`, which also gives the menus their keys, so this
/// list can't drift from them; the rest are keys of one place (a terminal,
/// the Files window, the palette).
struct ShortcutsSettings: View {
    @Environment(AppModel.self) private var model

    private struct Row: Identifiable {
        let title: String
        let keys: String
        var id: String { title }
    }

    private func commands(_ list: [AppCommand]) -> [Row] {
        list.compactMap { command in command.shortcut.map { Row(title: command.title(model), keys: $0.symbols) } }
    }

    private var sections: [(String, [Row])] {
        [
            ("Agents", commands([.goToAgent, .nextAgent, .previousAgent, .zoom, .dashboard, .refresh])
                + [Row(title: "Show Side by Side", keys: "⌘-Click")]),
            ("Windows", commands([.commandPalette, .files, .newTerminal, .sessions, .notifications, .toggleSidebar, .settings])),
            ("Terminal", [
                Row(title: "Paste, or Upload a Copied Picture", keys: "⌘V"),
                Row(title: "Copy", keys: "⌘C"),
                Row(title: "New Line", keys: "⇧↩"),
                Row(title: "Bigger Text", keys: "⌘+"),
                Row(title: "Smaller Text", keys: "⌘−"),
            ]),
            ("Files", [
                Row(title: "Find", keys: "⌘F"),
                Row(title: "Find Next", keys: "⌘G"),
                Row(title: "Find Previous", keys: "⇧⌘G"),
                Row(title: "Use Selection for Find", keys: "⌘E"),
                Row(title: "Back", keys: "⌃⌘←"),
                Row(title: "Forward", keys: "⌃⌘→"),
            ]),
            ("Palette", [
                Row(title: "Commands", keys: ">"),
                Row(title: "Message the Agent", keys: "⇥"),
                Row(title: "Send from the Search Field", keys: "⌘↩"),
            ]),
        ]
    }

    var body: some View {
        Form {
            ForEach(sections, id: \.0) { title, rows in
                Section(title) {
                    ForEach(rows) { row in
                        LabeledContent(row.title) {
                            Text(row.keys).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
