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
}
