import Foundation
import Testing
@testable import AgentMuxCore

struct AgentProgressTests {
    private func job(_ json: String, id: String = "job") throws -> InventorySnapshot.AgentProgress {
        var value = try JSONDecoder().decode(InventorySnapshot.AgentProgress.self, from: Data(json.utf8))
        value.id = id
        return value
    }

    @Test func countsOverrideLegacyPercent() throws {
        let p = try job(#"{"current":8,"total":10,"percent":20}"#)
        #expect(p.fraction == 0.8)
    }

    @Test func noTotalMeansIndeterminate() throws {
        #expect(try job(#"{"state":"preparing"}"#).fraction == nil)
    }

    @Test func oldHeartbeatMeansStaleNotStopped() throws {
        let p = try job(#"{"state":"running","updated_at":100}"#)
        #expect(p.isStale(at: 191))
        #expect(p.isActive)
        #expect(!p.isStale(at: 150))
        #expect(try !job(#"{"state":"done","updated_at":100}"#).isStale(at: 500))
    }

    @Test func completionFreezesElapsed() throws {
        let p = try job(#"{"state":"done","started_at":100,"finished_at":160,"updated_at":200}"#)
        #expect(p.elapsed(at: 1000) == 60)
        let legacy = try job(#"{"state":"failed","started_at":100,"updated_at":160}"#)
        #expect(legacy.elapsed(at: 1000) == 60)
        #expect(try job(#"{"state":"running"}"#).elapsed(at: 1000) == nil)
    }

    @Test func etaCountsDownFromItsOwnSample() throws {
        let p = try job(#"{"state":"running","updated_at":150,"eta_at":100,"eta_seconds":58}"#)
        #expect(p.remaining(at: 110) == 48)
        #expect(p.remaining(at: 160) == nil)
        #expect(p.remaining(at: 200) == nil)
    }

    @Test func structuredDetailsDecode() throws {
        let p = try job(#"{"phase":"rq2","unit":"groups","source_updated_at":100,"details":[{"id":"a","label":"A","current":3,"total":9,"unit":"assertions"}]}"#)
        #expect(p.phase == "rq2")
        #expect(p.details.first?.id == "a")
        #expect(p.details.first?.fraction == 1.0 / 3.0)
    }

    @Test func reportsDoNotReorderActiveJobs() throws {
        let a = try job(#"{"started_at":100,"updated_at":500}"#, id: "a")
        let b = try job(#"{"started_at":200,"updated_at":600}"#, id: "b")
        #expect(InventorySnapshot.AgentProgress.displayOrder([b,a]).map(\.id) == ["a","b"])
        var updated = a
        updated.updatedAt = 1000
        #expect(InventorySnapshot.AgentProgress.displayOrder([b,updated]).map(\.id) == ["a","b"])
    }

    @Test func probeAssignsFileIdentity() throws {
        let text = "@@begin 1 test\n@@progress train {\"pane\":\"%77\",\"state\":\"running\"}\n@@end test\n"
        let snapshot = try InventoryProbe.parse(text, nonce: "test")
        #expect(snapshot.progress["train"]?.id == "train")
    }

    @Test func structuredReportReplacesItsRawWorkerOnly() throws {
        let report = try job(#"{"supersedes":["worker"]}"#, id: "report")
        let worker = try job(#"{}"#, id: "worker")
        let other = try job(#"{}"#, id: "other")
        #expect(Set(InventorySnapshot.AgentProgress.displayOrder([report,worker,other]).map(\.id)) == ["report","other"])
    }
}
