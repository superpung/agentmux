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

    @Test func finishTimeStaysFixedBetweenReports() throws {
        let p = try job(#"{"state":"running","updated_at":150,"eta_at":100,"eta_seconds":58}"#)
        #expect(p.estimatedFinish(at: 110) == 158)
        #expect(p.estimatedFinish(at: 120) == 158)
        #expect(p.remaining(at: 120) == 38)
        let paused = try job(#"{"state":"paused","updated_at":100,"eta_at":100,"eta_seconds":58}"#)
        #expect(paused.estimatedFinish(at: 110) == nil)
    }

    @Test func completionLabelsUseLocalDatesAcrossMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        let parser = ISO8601DateFormatter()
        let now = parser.date(from: "2026-11-04T15:30:00Z")!.timeIntervalSince1970
        #expect(JobTimeLabel.finish(now + 600, relativeTo: now, calendar: calendar) == "Today 23:40")
        #expect(JobTimeLabel.finish(now + 3600, relativeTo: now, calendar: calendar) == "Tomorrow 00:30")
        #expect(JobTimeLabel.finish(now + 90000, relativeTo: now, calendar: calendar) == "Nov 6, 00:30")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(JobTimeLabel.finish(now + 3600, relativeTo: now, calendar: calendar) == "Today 16:30")
    }

    @Test func approximateDurationAvoidsFalseSecondPrecision() {
        #expect(JobTimeLabel.remaining(31) == "≈ 1m")
        #expect(JobTimeLabel.remaining(3601) == "≈ 1h 1m")
        #expect(JobTimeLabel.remaining(86400) == "≈ 1d")
    }

    @Test func structuredDetailsDecode() throws {
        let p = try job(#"{"phase":"rq2","unit":"groups","source_updated_at":100,"details":[{"id":"a","label":"A","current":3,"total":9,"unit":"assertions"}]}"#)
        #expect(p.phase == "rq2")
        #expect(p.details.first?.id == "a")
        #expect(p.details.first?.fraction == 1.0 / 3.0)
    }

    @Test func decimalMetricsDoNotDiscardOtherDetails() throws {
        let p = try job(#"{"current":45,"total":117,"details":[{"id":"cases","label":"Cases","current":45,"total":117},{"id":"cpu","label":"CPU","current":25.17,"total":100,"unit":"%"},null,{"label":"Incomplete","current":"unknown"},{"label":"Missing counts"}]}"#)
        #expect(p.details.count == 4)
        #expect(p.details.first?.fraction == 45.0 / 117)
        let cpu = try #require(p.details.dropFirst().first?.fraction)
        #expect(abs(cpu - 0.2517) < 0.000001)
        #expect(p.details.first?.amount == "45/117")
        #expect(p.details.dropFirst().first?.amount == "25.17/100")
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

    @Test func sharedCodexDaemonPaneIsReplacedByExactThreadOwner() throws {
        let thread = "01a1bf35-d874-7310-abe5-b0d96d101ef1"
        let text = """
        @@begin 1 test
        @@progress train {"pane":"%2","codex_thread_id":"\(thread)","current":19,"total":40}
        @@codexthread %158 \(thread)
        @@codexthread %158 \(thread)
        @@end test
        """
        let snapshot = try InventoryProbe.parse(text, nonce: "test")
        #expect(snapshot.progress["train"]?.pane == "%158")
        #expect(snapshot.progress["train"]?.fraction == 0.475)
    }

    @Test func uniqueLiveThreadCorrectsAnExplicitStaleDaemonPane() throws {
        let thread = "01a1bf35-d874-7310-abe5-b0d96d101ef1"
        let text = "@@begin 1 test\n@@codexthread %158 \(thread)\n@@codexthread %2 aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n@@progress train {\"pane\":\"%2\",\"pane_explicit\":true,\"codex_thread_id\":\"\(thread)\",\"current\":60,\"total\":117}\n@@end test\n"
        let snapshot = try InventoryProbe.parse(text, nonce: "test")
        #expect(snapshot.progress["train"]?.pane == "%158")
        #expect(snapshot.progress["train"]?.current == 60)
        #expect(snapshot.progress["train"]?.reportedPane == "%2")
        #expect(snapshot.progress.values.filter { $0.pane == "%2" }.isEmpty)
    }

    @Test func explicitPaneStillWorksWithoutUniqueThreadEvidence() throws {
        let thread = "01a1bf35-d874-7310-abe5-b0d96d101ef1"
        let text = "@@begin 1 test\n@@codexthread %158 \(thread)\n@@codexthread %168 \(thread)\n@@progress train {\"pane\":\"%168\",\"pane_explicit\":true,\"codex_thread_id\":\"\(thread)\"}\n@@end test\n"
        #expect(try InventoryProbe.parse(text, nonce: "test").progress["train"]?.pane == "%168")
        #expect(try job(#"{"pane":"%168","pane_explicit":true}"#).pane == "%168")
    }

    @Test func correctedReporterKeepsTheOriginalPaneForDiagnostics() throws {
        let value = try job(#"{"pane":"%158","requested_pane":"%2","pane_explicit":true,"owner_source":"codex_thread"}"#)
        #expect(value.pane == "%158")
        #expect(value.reportedPane == "%2")
    }

    @Test func ambiguousThreadDoesNotGuessAPane() throws {
        let thread = "01a1bf35-d874-7310-abe5-b0d96d101ef1"
        let text = "@@begin 1 test\n@@codexthread %158 \(thread)\n@@codexthread %168 \(thread)\n@@progress train {\"pane\":\"%2\",\"codex_thread_id\":\"\(thread)\"}\n@@end test\n"
        #expect(try InventoryProbe.parse(text, nonce: "test").progress["train"]?.pane == nil)
    }

    @Test func anotherKnownThreadCannotInheritTheDaemonPane() throws {
        let text = """
        @@begin 1 test
        @@codexthread %2 01a1bf35-d874-7310-abe5-b0d96d101ef1
        @@progress train {"pane":"%2","codex_thread_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}
        @@end test
        """
        #expect(try InventoryProbe.parse(text, nonce: "test").progress["train"]?.pane == nil)
    }

    @Test func legacyPaneAssociationStillWorks() throws {
        let text = "@@begin 1 test\n@@progress train {\"pane\":\"%77\"}\n@@end test\n"
        #expect(try InventoryProbe.parse(text, nonce: "test").progress["train"]?.pane == "%77")
    }

    @Test func completionRetainsVerifiedIdentityOnlyForTheSameRunAndServer() throws {
        let thread = "01a1bf35-d874-7310-abe5-b0d96d101ef1"
        func snapshot(run: String, state: String, identity: Bool, server: Int = 1) throws -> InventorySnapshot {
            let meta = identity ? ",\"codex_thread_id\":\"\(thread)\"" : ""
            return try InventoryProbe.parse("@@begin 1 test\n@@server \(server) 100 /tmp/tmux\n@@codexthread %158 \(thread)\n@@progress train {\"run_id\":\"\(run)\",\"state\":\"\(state)\",\"pane\":\"%2\"\(meta)}\n@@end test\n", nonce: "test")
        }
        let old = try snapshot(run: "a", state: "running", identity: true)
        var finished = try snapshot(run: "a", state: "done", identity: false)
        finished.retainProgressIdentity(from: old)
        #expect(finished.progress["train"]?.pane == "%158")
        var restarted = try snapshot(run: "b", state: "running", identity: false)
        restarted.retainProgressIdentity(from: old)
        #expect(restarted.progress["train"]?.codexThreadID == nil)
        var newServer = try snapshot(run: "a", state: "done", identity: false, server: 2)
        newServer.retainProgressIdentity(from: old)
        #expect(newServer.progress["train"]?.codexThreadID == nil)
    }

    @Test func readerRecoversOnlyVerifiedLiveJobMetadataWithoutWritingFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentmux-progress-reader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let records = dir.appendingPathComponent("progress")
        let proc = dir.appendingPathComponent("proc/123")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: proc, withIntermediateDirectories: true)
        var fields = Array(repeating: "0", count: 20)
        fields[19] = "999"
        try ("123 (worker) " + fields.joined(separator: " ")).write(to: proc.appendingPathComponent("stat"), atomically: true, encoding: .utf8)
        let thread = "01a1bf35-d874-7310-abe5-b0d96d101ef1"
        try Data("CODEX_THREAD_ID=\(thread)\u{0}TMUX_PANE=%2\u{0}UNRELATED_SECRET=must-not-leave-proc\u{0}".utf8)
            .write(to: proc.appendingPathComponent("environ"))
        let live = #"{"pane":"%2","pid":123,"pid_start_ticks":999}"#
        try live.write(to: records.appendingPathComponent("live.json"), atomically: true, encoding: .utf8)
        try #"{"pane":"%2","pid":123,"pid_start_ticks":998}"#.write(to: records.appendingPathComponent("reused.json"), atomically: true, encoding: .utf8)
        try #"{"pane":"%2","pid":123}"#.write(to: records.appendingPathComponent("unverified.json"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", InventoryProbe.progressReader, records.path, dir.appendingPathComponent("proc").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(!output.contains("must-not-leave-proc"))
        let snapshot = try InventoryProbe.parse("@@begin 1 test\n" + output + "@@end test\n", nonce: "test")
        #expect(snapshot.progress["live"]?.codexThreadID == thread)
        #expect(snapshot.progress["reused"]?.codexThreadID == nil)
        #expect(snapshot.progress["unverified"]?.codexThreadID == nil)
        #expect(try String(contentsOf: records.appendingPathComponent("live.json"), encoding: .utf8) == live)
    }

    @Test func structuredReportReplacesItsRawWorkerOnly() throws {
        let report = try job(#"{"supersedes":["worker"]}"#, id: "report")
        let worker = try job(#"{}"#, id: "worker")
        let other = try job(#"{}"#, id: "other")
        #expect(Set(InventorySnapshot.AgentProgress.displayOrder([report,worker,other]).map(\.id)) == ["report","other"])
    }
}
