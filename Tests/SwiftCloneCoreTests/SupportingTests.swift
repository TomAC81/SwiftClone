import Foundation
import Testing
@testable import SwiftCloneCore

@Suite struct ScheduleTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test func manualNeverRuns() {
        #expect(ScheduleCalculator.nextRun(after: Date(), schedule: Schedule(kind: .manual)) == nil)
    }

    @Test func dailyRunsLaterTodayOrTomorrow() {
        let s = Schedule(kind: .daily, hour: 2, minute: 30)
        #expect(ScheduleCalculator.nextRun(after: date("2026-11-15T01:00:00Z"), schedule: s, calendar: utc) == date("2026-11-15T02:30:00Z"))
        #expect(ScheduleCalculator.nextRun(after: date("2026-11-15T02:30:00Z"), schedule: s, calendar: utc) == date("2026-11-16T02:30:00Z"))
    }

    @Test func weeklyRunsOnTheChosenWeekday() {
        // 2026-11-15 is a Sunday; weekday 4 is Wednesday.
        let s = Schedule(kind: .weekly, hour: 9, minute: 0, weekday: 4)
        #expect(ScheduleCalculator.nextRun(after: date("2026-11-15T12:00:00Z"), schedule: s, calendar: utc) == date("2026-11-18T09:00:00Z"))
    }
}

@Suite struct AdaptiveConcurrencyTests {
    @Test func climbsWhileThroughputImproves() {
        var c = AdaptiveConcurrency(initial: 2, minimum: 1, maximum: 8)
        c.record(bytes: 100_000_000, files: 10, seconds: 1)
        c.record(bytes: 150_000_000, files: 10, seconds: 1)
        c.record(bytes: 200_000_000, files: 10, seconds: 1)
        #expect(c.limit == 5)
    }

    @Test func backsOffWhenThroughputDrops() {
        var c = AdaptiveConcurrency(initial: 4, minimum: 1, maximum: 8)
        c.record(bytes: 100_000_000, files: 10, seconds: 1)   // 5
        c.record(bytes: 50_000_000, files: 10, seconds: 1)    // worse: back to 4
        #expect(c.limit == 4)
    }

    @Test func staysWithinBounds() {
        var c = AdaptiveConcurrency(initial: 2, minimum: 1, maximum: 3)
        for i in 1...10 { c.record(bytes: Int64(i) * 100_000_000, files: 1, seconds: 1) }
        #expect(c.limit == 3)
        var d = AdaptiveConcurrency(initial: 1, minimum: 1, maximum: 8)
        d.record(bytes: 0, files: 0, seconds: 1)
        #expect(d.limit == 1)
    }
}

@Suite struct PersistenceTests {
    @Test func jobsAndHistoryRoundTrip() throws {
        let s = try Sandbox()
        let store = Persistence(directory: URL(fileURLWithPath: s.root + "/db"))
        #expect(try store.loadJobs().isEmpty)
        let job = BackupJob(name: "Photos", sourcePath: "/a", destinationPath: "/b", mode: .mirror,
                            schedule: Schedule(kind: .weekly, hour: 3, minute: 15, weekday: 6))
        try store.saveJobs([job])
        let loaded = try store.loadJobs()
        #expect(loaded.count == 1)
        #expect(loaded[0].name == "Photos" && loaded[0].mode == .mirror && loaded[0].schedule == job.schedule)

        var record = RunRecord(jobID: job.id, jobName: job.name, startedAt: Date(), finishedAt: Date(),
                               status: .completedWithErrors, summary: "x")
        record.errors = [RunError(path: "p", message: "m")]
        try store.saveHistory([record])
        #expect(try store.loadHistory().first?.errors.first?.path == "p")
    }

    @Test func sampleJobConfigurationDecodes() throws {
        let sample = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Samples/sample-job.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let jobs = try decoder.decode([BackupJob].self, from: Data(contentsOf: sample))
        #expect(jobs.first?.mode == .backup)
        #expect(jobs.first?.schedule.kind == .daily)
    }
}

@Suite struct RestoreTests {
    @Test func restoreNeverOverwrites() throws {
        let s = try Sandbox()
        try s.write("dst/report.txt", "from backup")
        try s.write("src/report.txt", "current work")
        let created = try Restorer.restore(items: [s.dst + "/report.txt"], into: s.src)
        #expect(s.read("src/report.txt") == "current work")
        #expect(created == [s.src + "/report (restored).txt"])
        #expect(s.read("src/report (restored).txt") == "from backup")
    }
}
