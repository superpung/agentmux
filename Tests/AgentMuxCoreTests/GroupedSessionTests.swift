@testable import AgentMuxCore
import Testing

/// A pane shared between a real session and AgentMux's own grouped mirror
/// session must resolve to the real one, and must be recognised as a ghost once
/// the real session is gone.
@Suite struct GroupedSessionTests {
    private func membership(_ sessionID: String, _ paneID: String) -> InventorySnapshot.Membership {
        .init(sessionID: sessionID, windowID: "@1", paneID: paneID, windowIndex: 0, paneIndex: 0, paneActive: true, windowActive: true)
    }

    @Test func prefersRealSessionWhileMirrorOpen() {
        var snap = InventorySnapshot()
        snap.sessions = [.init(id: "$1", name: "fl"), .init(id: "$2", name: "agentmux-abc123")]
        // list-panes order can put the grouped membership first.
        snap.memberships = [membership("$2", "%5"), membership("$1", "%5")]

        #expect(snap.hasRealSession("%5"))
        #expect(snap.primaryMembership(of: "%5")?.sessionID == "$1")
    }

    @Test func paneIsAGhostWhenOnlyGroupedSessionRemains() {
        var snap = InventorySnapshot()
        snap.sessions = [.init(id: "$2", name: "agentmux-abc123")]
        snap.memberships = [membership("$2", "%5")]

        #expect(!snap.hasRealSession("%5"))
        // Falls back to the grouped membership rather than returning nil.
        #expect(snap.primaryMembership(of: "%5")?.sessionID == "$2")
    }

    @Test func unknownPaneHasNoSession() {
        let snap = InventorySnapshot()
        #expect(!snap.hasRealSession("%9"))
        #expect(snap.primaryMembership(of: "%9") == nil)
    }

    /// Reproduces the ordering that froze an opened terminal: `list-panes -a`
    /// sorts rows by session name, so every "agentmux-…" grouped mirror precedes
    /// the real session, which comes last. Resolving the pane's session with
    /// `memberships.first` therefore picks a mirror, and grouping a new mirror
    /// onto it orphans the view when that mirror is reaped. openTerminal and
    /// windowName must resolve through `primaryMembership`, which stays on the
    /// real session regardless of how many mirrors are open.
    @Test func picksRealSessionWhenMirrorsSortFirst() {
        var snap = InventorySnapshot()
        snap.sessions = [
            .init(id: "$86", name: "agentmux-15314aaa"),
            .init(id: "$81", name: "agentmux-e6572bbb"),
            .init(id: "$3", name: "tcad"),
        ]
        snap.memberships = [
            membership("$86", "%13"),
            membership("$81", "%13"),
            membership("$3", "%13"),
        ]

        // The naive resolver that caused the freeze lands on a grouped mirror.
        #expect(snap.memberships.first { $0.paneID == "%13" }?.sessionID == "$86")
        // The resolver openTerminal/windowName use lands on the real session.
        #expect(snap.primaryMembership(of: "%13")?.sessionID == "$3")
    }
}
