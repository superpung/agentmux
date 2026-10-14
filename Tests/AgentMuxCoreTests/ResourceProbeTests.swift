@testable import AgentMuxCore
import Foundation
import Testing

/// Output shaped like a real run of the resource script. Values are synthetic.
private let hostFixture = """
@@host
48
3.40 3.27 3.04 2/1234 56789
mem 9048 12000
swap 512 2048
uptime 123456
@@disk
12345678 52428800 /
900000000 1000000000 /data
@@gpu
@@containers
conf-scheduler\t12.50%\t7.00%\t9.126GiB / 12.00GiB\t54.1GB / 74.1GB\t578GB / 143GB\t4899
@@end
"""

@Suite struct ResourceProbeTests {
    @Test func parsesHostCoresLoadMem() {
        let r = ResourceProbe.parse(hostFixture)
        #expect(r.cores == 48)
        #expect(r.load1 == 3.40)
        #expect(r.load5 == 3.27)
        #expect(r.load15 == 3.04)
        #expect(r.memUsedMB == 9048)
        #expect(r.memTotalMB == 12000)
    }

    @Test func parsesSwapAndUptime() {
        let r = ResourceProbe.parse(hostFixture)
        #expect(r.swapUsedMB == 512)
        #expect(r.swapTotalMB == 2048)
        #expect(r.swapPercent == 25)
        #expect(r.uptimeSeconds == 123456)
    }

    @Test func parsesDiskMounts() {
        let r = ResourceProbe.parse(hostFixture)
        #expect(r.disks.count == 2)
        let root = r.disks.first { $0.mount == "/" }
        #expect(root?.usedKB == 12345678)
        #expect(root?.totalKB == 52428800)
        #expect(r.disks.contains { $0.mount == "/data" && $0.totalKB == 1000000000 })
    }

    @Test func parsesContainerRow() {
        let r = ResourceProbe.parse(hostFixture)
        let c = r.containers["conf-scheduler"]
        #expect(c?.cpuPercent == 12.5)
        #expect(c?.memPercent == 7.0)
        #expect(c?.pids == 4899)
        #expect(c?.netText == "54.1GB / 74.1GB")
        #expect(c?.blockText == "578GB / 143GB")
        // Rates are only filled by differencing snapshots, never by the probe.
        #expect(c?.netRateBytesPerSec == nil)
    }

    @Test func parsesHostGPUAndContainers() {
        let text = """
        @@host
        48
        0.52 0.58 0.59 1/1234 5678
        mem 38056 128536
        @@disk
        @@gpu
        0, NVIDIA RTX, 45, 1234, 16384
        @@containers
        app01\t207.12%\t47.74%\t45.83GiB / 96GiB\t84.8GB / 139GB\t4.56TB / 565GB\t15660
        app02\t28.41%\t19.45%\t18.68GiB / 96GiB\t59.5GB / 17.9GB\t664GB / 124GB\t646
        @@end
        """
        let r = ResourceProbe.parse(text)
        #expect(r.cores == 48)
        #expect(r.load1 == 0.52)
        #expect(r.load5 == 0.58)
        #expect(r.load15 == 0.59)
        #expect(r.memUsedMB == 38056)
        #expect(r.memTotalMB == 128536)
        #expect(r.gpus.count == 1)
        #expect(r.gpus.first?.utilizationPercent == 45)
        #expect(r.gpus.first?.memTotalMB == 16384)
        #expect(r.containers["app01"]?.cpuPercent == 207.12)
        #expect(r.containers["app01"]?.memPercent == 47.74)
        #expect(r.containers["app01"]?.pids == 15660)
        #expect(r.containers["app01"]?.memText == "45.83GiB / 96GiB")
        #expect(r.containers["app02"]?.cpuPercent == 28.41)
    }

    @Test func handlesNoGPU() {
        let text = "@@host\n4\n1.0 1.0 1.0\nmem 100 200\n@@disk\n@@gpu\n@@containers\n@@end"
        let r = ResourceProbe.parse(text)
        #expect(r.cores == 4)
        #expect(r.gpus.isEmpty)
        #expect(r.containers.isEmpty)
    }

    @Test func parseBytesHandlesDecimalAndBinaryUnits() {
        #expect(ResourceProbe.parseBytes("12B") == 12)
        #expect(ResourceProbe.parseBytes("1.2kB") == 1200)
        #expect(ResourceProbe.parseBytes("578MB") == 578_000_000)
        #expect(ResourceProbe.parseBytes("54.1GB") == Double("54.1")! * 1_000_000_000)
        #expect(ResourceProbe.parseBytes("3.4MiB") == Double("3.4")! * 1_048_576)
        #expect(ResourceProbe.parseBytes("nope") == nil)
    }

    @Test func pairTotalBytesSumsBothHalves() {
        let total = ResourceProbe.pairTotalBytes("54.1GB / 74.1GB")
        #expect(total == Double("54.1")! * 1_000_000_000 + Double("74.1")! * 1_000_000_000)
        #expect(ResourceProbe.pairTotalBytes("0B / 0B") == 0)
    }

    @Test func agentResourceProbeParsesProcAndDisk() {
        let out = AgentResourceProbe.parse("""
        @@proc
         12.3 456789 3600
        @@disk
         12345 67890
        @@end
        """)
        #expect(out.cpuPercent == 12.3)
        #expect(out.rssKB == 456789)
        #expect(out.uptimeSeconds == 3600)
        #expect(out.diskUsedKB == 12345)
        #expect(out.diskTotalKB == 67890)
        #expect(out.hasDisk == true)
    }

    @Test func gitStatusParsesFullStatus() {
        let out = "@@git\nbranch feature/x\ncounts 3 2\ndiff 45 12\nab 1 4\n"
        let g = GitStatusProbe.parse(out)
        #expect(g?.branch == "feature/x")
        #expect(g?.changedFiles == 3)
        #expect(g?.untracked == 2)
        #expect(g?.insertions == 45)
        #expect(g?.deletions == 12)
        #expect(g?.behind == 1)
        #expect(g?.ahead == 4)
        #expect(g?.isClean == false)
    }

    @Test func gitStatusNoRepoIsNil() {
        #expect(GitStatusProbe.parse("@@norepo\n") == nil)
        #expect(GitStatusProbe.parse("") == nil)
    }

    @Test func gitStatusCleanTree() {
        let g = GitStatusProbe.parse("@@git\nbranch main\ncounts 0 0\ndiff 0 0\n")
        #expect(g?.isClean == true)
        #expect(g?.branch == "main")
    }

    @Test func gitStatusAheadBehindTabSeparated() {
        // git rev-list --left-right --count emits a tab between the two numbers.
        let g = GitStatusProbe.parse("@@git\nbranch main\ncounts 0 0\ndiff 0 0\nab 2\t7\n")
        #expect(g?.behind == 2)
        #expect(g?.ahead == 7)
    }

    @Test func agentResourceProbeWithoutDiskHasNoWorkspace() {
        let out = AgentResourceProbe.parse("""
        @@proc
         5.0 1000 60
        @@disk
        @@end
        """)
        #expect(out.rssKB == 1000)
        #expect(out.hasDisk == false)
        #expect(out.diskTotalKB == 0)
    }
}
