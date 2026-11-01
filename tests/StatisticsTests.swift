import Foundation

enum StatisticsTests {
    private struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(description: "StatisticsTests: " + message) }
            checks += 1
        }
        func close(_ actual: Double, _ expected: Double, _ message: String) throws {
            try check(actual.isFinite && abs(actual - expected) < 0.000_001, "\(message): \(actual) != \(expected)")
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        utc.firstWeekday = 1 // Week calculation must still begin on Monday.
        var la = utc
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
                  calendar: Calendar? = nil) -> Date {
            (calendar ?? utc).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }
        let typeA = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let typeB = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        func record(_ segments: [FocusSegment], type: UUID? = nil, name: String = "旧名字",
                    plan: Double = 10_000, outcome: FocusOutcome? = .completed,
                    endedAt: Date? = nil, title: String = "测试事项") -> FocusRecord {
            FocusRecord(typeID: type ?? typeA, typeName: name, symbol: "book", title: title,
                        plannedSeconds: plan, startedAt: segments.first?.start ?? date(2025, 1, 1),
                        endedAt: endedAt ?? segments.last?.end, outcome: outcome, segments: segments,
                        timeZoneID: "UTC")
        }
        func segment(_ start: Date, _ end: Date, _ seconds: Double) -> FocusSegment {
            FocusSegment(start: start, end: end, seconds: seconds)
        }

        let midnight = date(2025, 1, 2)
        let crossing = record([segment(date(2025, 1, 1, 23, 30), date(2025, 1, 2, 0, 30), 1_200)])
        let firstDay = DateInterval(start: date(2025, 1, 1), end: midnight)
        let secondDay = DateInterval(start: midnight, end: date(2025, 1, 3))
        try close(FocusStatistics.seconds([crossing]), 1_200, "Monotonic seconds override wall time")
        try close(FocusStatistics.seconds([crossing], in: firstDay), 600, "Before midnight fraction")
        try close(FocusStatistics.seconds([crossing], in: secondDay), 600, "After midnight fraction")
        try close(FocusStatistics.seconds([crossing], in: DateInterval(start: midnight, end: midnight)), 0, "Empty half-open range")
        try close(FocusStatistics.seconds([crossing], typeID: typeB), 0, "Type filter")

        let days = FocusStatistics.daily([crossing], from: date(2025, 1, 1), to: date(2025, 1, 4), calendar: utc)
        try check(days.count == 3, "No extra day when end is midnight")
        try check(days.map(\.date) == [date(2025, 1, 1), midnight, date(2025, 1, 3)], "Day identities are local midnights")
        try close(days[0].seconds, 600, "First daily bucket")
        try close(days[1].seconds, 600, "Second daily bucket")
        try close(days[2].seconds, 0, "Empty daily bucket")
        try close(days.reduce(0) { $0 + $1.seconds }, FocusStatistics.seconds([crossing]), "Daily conservation")
        let partial = FocusStatistics.daily([crossing], from: date(2025, 1, 1, 23, 45), to: date(2025, 1, 2, 0, 15), calendar: utc)
        try check(partial.count == 2, "Partial days remain separate buckets")
        try close(partial.reduce(0) { $0 + $1.seconds }, 600, "Daily clips partial first and last days")
        try check(FocusStatistics.daily([], from: midnight, to: midnight, calendar: utc).isEmpty, "Empty daily range")
        try check(FocusStatistics.daily([], from: date(2025, 1, 3), to: midnight, calendar: utc).isEmpty, "Reversed daily range")
        let emptyDays = FocusStatistics.daily([], from: date(2025, 1, 1), to: date(2025, 1, 3), calendar: utc)
        try check(emptyDays.count == 2 && emptyDays.allSatisfy { $0.seconds == 0 }, "Empty input still emits requested days")

        let invalidWall = record([
            segment(midnight, midnight, 40),
            segment(midnight, date(2025, 1, 1, 23), 60),
            segment(midnight, date(2025, 1, 2, 1), -100)
        ])
        try close(FocusStatistics.seconds([invalidWall]), 100, "Negative segment seconds cannot erase elapsed seconds")
        try close(FocusStatistics.seconds([invalidWall], in: firstDay), 0, "Invalid wall duration excluded at end boundary")
        try close(FocusStatistics.seconds([invalidWall], in: secondDay), 100, "Invalid wall duration belongs to start")
        let invalidDays = FocusStatistics.daily([invalidWall], from: date(2025, 1, 1), to: date(2025, 1, 3), calendar: utc)
        try close(invalidDays.reduce(0) { $0 + $1.seconds }, 100, "Invalid wall duration conserves daily totals")
        let capped = record([
            segment(date(2025, 1, 1, 12), date(2025, 1, 1, 13), 80),
            segment(date(2025, 1, 2, 12), date(2025, 1, 2, 13), 80)
        ], plan: 100)
        try close(FocusStatistics.seconds([capped]), 100, "Record cannot exceed planned seconds")
        let cappedDays = FocusStatistics.daily([capped], from: date(2025, 1, 1), to: date(2025, 1, 3), calendar: utc)
        try close(cappedDays.reduce(0) { $0 + $1.seconds }, 100, "Plan cap is applied before interval filtering")
        try close(FocusStatistics.seconds([capped], in: secondDay), 20, "Earlier segment consumes plan allowance")
        try close(FocusStatistics.seconds([record([segment(midnight, midnight, 80)], plan: -10)]), 0, "Negative plan yields zero")
        try close(FocusStatistics.seconds([record([], plan: 100)]), 0, "No segments yields zero")

        var previous = crossing
        previous.id = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        var latest = previous
        latest.segments = [segment(midnight, midnight, 25)]
        latest.outcome = nil
        latest.endedAt = nil
        try close(FocusStatistics.seconds([previous, latest]), 25, "Last duplicate record wins")
        try check(FocusStatistics.completedCount([previous, latest]) == 0, "Deduplication happens before completion filtering")
        try close(FocusStatistics.seconds([previous, latest], in: firstDay), 0, "Deduplication happens before date filtering")
        var changedType = latest
        changedType.typeID = typeB
        try close(FocusStatistics.seconds([previous, changedType], typeID: typeA), 0, "Deduplication happens before type filtering")
        try close(FocusStatistics.seconds([latest]), 25, "Active snapshot counts its completed segments")
        try check(FocusStatistics.completedCount([latest]) == 0, "Active snapshot is not a completed session")

        let endingAtMidnight = record([segment(date(2025, 1, 1, 23), midnight, 90)])
        let early = record([segment(midnight, date(2025, 1, 2, 1), 20)], outcome: .ended)
        let interrupted = record([segment(midnight, date(2025, 1, 2, 2), 30)], outcome: .interrupted)
        try check(FocusStatistics.completedCount([endingAtMidnight], in: firstDay) == 0, "Completion excludes interval end")
        try check(FocusStatistics.completedCount([endingAtMidnight], in: secondDay) == 1, "Completion includes interval start")
        try check(FocusStatistics.completedCount([endingAtMidnight, early, interrupted, latest]) == 1, "Only completed outcome counts")
        try check(FocusStatistics.completedCount([endingAtMidnight], typeID: typeB) == 0, "Completion type filter")
        var missingEnd = endingAtMidnight
        missingEnd.endedAt = nil
        try check(FocusStatistics.completedCount([missingEnd], in: secondDay) == 0, "Missing endedAt cannot be attributed")
        try close(FocusStatistics.seconds([early, interrupted]), 50, "Early and interrupted sessions retain actual time")

        let renamed = FocusType(id: typeA, name: "当前名字", symbol: "book", minutes: 25, archived: true)
        let a1 = record([segment(midnight, midnight, 30)], name: "曾用名")
        let a2 = record([segment(midnight, midnight, 40)], name: "最新快照")
        let b = record([segment(midnight, midnight, 50)], type: typeB, name: "已删除分类")
        let totals = FocusStatistics.byType([a1, a2, b], in: secondDay, types: [renamed])
        try check(totals.count == 2, "Type IDs merge across historical names")
        try check(totals[0].id == typeA && totals[0].name == "当前名字", "Archived type uses its current name")
        try close(totals[0].seconds, 70, "Renamed type accumulates all records")
        try check(totals[1].id == typeB && totals[1].name == "已删除分类", "Missing type uses record snapshot")
        let fallback = FocusStatistics.byType([a1, a2], in: secondDay, types: [])
        try check(fallback.first?.name == "最新快照", "Latest contributing snapshot names missing type")
        try close(totals.reduce(0) { $0 + $1.seconds }, 120, "Type totals conserve seconds")
        try check(FocusStatistics.byType([a1], in: firstDay, types: [renamed]).isEmpty, "No zero-valued type buckets")
        try close(FocusStatistics.byType([previous, latest], in: secondDay, types: []).first?.seconds ?? -1, 25, "By-type deduplication")

        let now = date(2025, 1, 1, 12)
        let recent = FocusStatistics.interval(days: 3, now: now, calendar: utc)
        try check(recent.start == date(2024, 12, 30) && recent.end == now, "Recent days cross year boundary")
        let today = FocusStatistics.interval(days: 1, now: now, calendar: utc)
        try check(today.start == date(2025, 1, 1) && today.end == now, "One day includes elapsed today only")
        try close(FocusStatistics.interval(days: 0, now: now, calendar: utc).duration, 0, "Zero days is empty")
        try close(FocusStatistics.interval(days: -2, now: now, calendar: utc).duration, 0, "Negative days is empty")
        let week = FocusStatistics.week(now: now, calendar: utc)
        try check(week.start == date(2024, 12, 30) && week.end == now, "Monday-based week crosses year boundary")
        try check(FocusStatistics.week(now: date(2025, 1, 5, 12), calendar: utc).start == date(2024, 12, 30), "Sunday remains in preceding Monday's week")
        try check(FocusStatistics.week(now: date(2025, 1, 6, 12), calendar: utc).start == date(2025, 1, 6), "Monday begins new week")

        for (month, day, hours) in [(3, 9, 23), (11, 2, 25)] {
            let start = date(2025, month, day, calendar: la)
            let end = la.date(byAdding: .day, value: 1, to: start)!
            let elapsed = Double(hours * 3_600)
            try close(end.timeIntervalSince(start), elapsed, "Fixture spans \(hours)-hour DST day")
            let dst = record([segment(start, end, elapsed)], plan: 100_000)
            let buckets = FocusStatistics.daily([dst], from: start, to: end, calendar: la)
            try check(buckets.count == 1 && buckets[0].date == start, "DST day uses one calendar bucket")
            try close(buckets[0].seconds, elapsed, "DST \(hours)-hour day retains all seconds")
            let after = la.date(byAdding: .hour, value: 12, to: end)!
            let twoDays = FocusStatistics.interval(days: 2, now: after, calendar: la)
            try check(twoDays.start == start && twoDays.end == after, "Recent days use DST-aware midnights")
            let monday = FocusStatistics.week(now: after, calendar: la)
            try check(monday.start == end, "Monday after DST transition starts at local midnight")
        }
        let localCross = record([segment(date(2025, 7, 1, 23, 30, calendar: la), date(2025, 7, 2, 0, 30, calendar: la), 600)])
        let localDays = FocusStatistics.daily([localCross], from: date(2025, 7, 1, calendar: la), to: date(2025, 7, 3, calendar: la), calendar: la)
        try close(localDays[0].seconds, 300, "Los Angeles local midnight first half")
        try close(localDays[1].seconds, 300, "Los Angeles local midnight second half")

        let csvRecord = record([segment(midnight, midnight, 12.5)], name: "阅读,\"书\"", plan: 100,
                               title: "第一行\n第二行")
        let exported = FocusStatistics.csv([csvRecord])
        try check(exported.hasPrefix("记录ID,类型ID,类型,事项,开始时间,结束时间,计划秒数,专注秒数,结果\r\n"), "CSV has Chinese headers")
        try check(exported.contains("\"阅读,\"\"书\"\"\""), "CSV doubles quotes and encloses commas")
        try check(exported.contains("\"第一行\n第二行\""), "CSV retains quoted newlines")
        try check(exported.contains("2025-01-02T00:00:00.000Z"), "CSV dates use ISO8601 UTC")
        try check(exported.contains(",100.0,12.5,"), "CSV numeric columns remain numeric")
        try check(exported.contains("\"已完成\""), "CSV localizes outcome")
        try check(String(data: Data(exported.utf8), encoding: .utf8) == exported, "CSV round-trips UTF-8")
        for dangerous in ["=SUM(A1)", "+1", "-1", "@SUM(A1)", "\tcmd", "\rcmd", "  =cmd", "\n=cmd"] {
            let injected = record([], name: dangerous, title: dangerous)
            let csv = FocusStatistics.csv([injected])
            let escaped = dangerous.replacingOccurrences(of: "\"", with: "\"\"")
            try check(csv.contains("\"'" + escaped + "\",\"'" + escaped + "\""), "CSV neutralizes both text columns: \(dangerous.debugDescription)")
        }
        var empty = record([], name: "", outcome: nil, title: "")
        empty.endedAt = nil
        let emptyCSV = FocusStatistics.csv([empty])
        try check(emptyCSV.contains(",\"\",\"\","), "CSV preserves empty name and title")
        try check(emptyCSV.hasSuffix(",\"\",10000.0,0.0,\"\"\r\n"), "CSV preserves missing end and active outcome")
        try check(FocusStatistics.csv([]).components(separatedBy: "\r\n").count == 2, "Empty export contains header only")
        try check(FocusStatistics.csv([previous, latest]).components(separatedBy: "\r\n").count == 3, "CSV exports last duplicate once")
        try close(FocusStatistics.seconds([]), 0, "Empty seconds")
        try check(FocusStatistics.completedCount([]) == 0, "Empty completion count")
        try check(FocusStatistics.byType([], in: secondDay, types: []).isEmpty, "Empty by-type totals")
        return checks
    }
}
