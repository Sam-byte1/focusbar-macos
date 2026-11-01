import Foundation

struct FocusDay: Identifiable, Equatable {
    var date: Date
    var seconds: Double
    var id: Date { date }
}

struct FocusTypeTotal: Identifiable, Equatable {
    var id: UUID
    var name: String
    var seconds: Double
}

/// Pure calculations over immutable record snapshots. All date ranges are half-open.
enum FocusStatistics {
    static func seconds(_ records: [FocusRecord], in interval: DateInterval? = nil, typeID: UUID? = nil) -> Double {
        total(unique(records), in: interval, typeID: typeID)
    }

    static func completedCount(_ records: [FocusRecord], in interval: DateInterval? = nil, typeID: UUID? = nil) -> Int {
        unique(records).filter { record in
            guard record.outcome == .completed,
                  typeID == nil || record.typeID == typeID,
                  let endedAt = record.endedAt else { return false }
            return interval.map { contains(endedAt, in: $0) } ?? true
        }.count
    }

    static func daily(_ records: [FocusRecord], from start: Date, to end: Date, calendar: Calendar) -> [FocusDay] {
        guard start < end else { return [] }
        let records = unique(records)
        var days: [FocusDay] = []
        var day = calendar.startOfDay(for: start)
        while day < end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            let interval = DateInterval(start: max(start, day), end: min(end, next))
            days.append(FocusDay(date: day, seconds: total(records, in: interval)))
            day = next
        }
        return days
    }

    static func byType(_ records: [FocusRecord], in interval: DateInterval, types: [FocusType]) -> [FocusTypeTotal] {
        var names: [UUID: String] = [:]
        for type in types { names[type.id] = type.name }
        var totals: [UUID: FocusTypeTotal] = [:]
        for record in unique(records) {
            let value = recordSeconds(record, in: interval)
            guard value > 0 else { continue }
            let previous = totals[record.typeID]?.seconds ?? 0
            totals[record.typeID] = FocusTypeTotal(
                id: record.typeID,
                name: names[record.typeID] ?? record.typeName,
                seconds: previous + value
            )
        }
        return totals.values.sorted {
            if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// The last N calendar days, including today's elapsed portion, not N × 24 hours.
    static func interval(days: Int, now: Date, calendar: Calendar) -> DateInterval {
        guard days > 0 else { return DateInterval(start: now, end: now) }
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        return DateInterval(start: min(start, now), end: now)
    }

    /// Monday at local midnight through now, independent of the calendar's firstWeekday setting.
    static func week(now: Date, calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let daysSinceMonday = (calendar.component(.weekday, from: today) + 5) % 7
        let start = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today
        return DateInterval(start: min(start, now), end: now)
    }

    static func csv(_ records: [FocusRecord]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var rows = ["记录ID,类型ID,类型,事项,开始时间,结束时间,计划秒数,专注秒数,结果"]
        for record in unique(records) {
            let fields = [
                csvText(record.id.uuidString),
                csvText(record.typeID.uuidString),
                csvText(record.typeName),
                csvText(record.title),
                csvText(formatter.string(from: record.startedAt)),
                csvText(record.endedAt.map { formatter.string(from: $0) } ?? ""),
                String(nonnegative(record.plannedSeconds)),
                String(recordSeconds(record, in: nil)),
                csvText(record.outcome?.label ?? "")
            ]
            rows.append(fields.joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    private static func unique(_ records: [FocusRecord]) -> [FocusRecord] {
        var seen = Set<UUID>()
        return records.reversed().filter { seen.insert($0.id).inserted }.reversed()
    }

    private static func total(_ records: [FocusRecord], in interval: DateInterval?, typeID: UUID? = nil) -> Double {
        records.reduce(0) { result, record in
            guard typeID == nil || record.typeID == typeID else { return result }
            return result + recordSeconds(record, in: interval)
        }
    }

    private static func recordSeconds(_ record: FocusRecord, in interval: DateInterval?) -> Double {
        if let interval, interval.start >= interval.end { return 0 }
        var remaining = nonnegative(record.plannedSeconds)
        var result = 0.0
        for segment in record.segments {
            // Apply the plan cap before date filtering, so querying a subrange cannot reclaim
            // seconds already consumed by an earlier segment outside that range.
            let seconds = min(remaining, nonnegative(segment.seconds))
            remaining = max(0, remaining - seconds)
            guard seconds > 0 else { continue }
            guard let interval else {
                result += seconds
                continue
            }
            let wall = segment.end.timeIntervalSince(segment.start)
            if wall.isFinite && wall > 0 {
                let start = max(segment.start, interval.start)
                let end = min(segment.end, interval.end)
                if end > start {
                    let fraction = min(1, max(0, end.timeIntervalSince(start) / wall))
                    result += seconds * fraction
                }
            } else if contains(segment.start, in: interval) {
                // Clock corrections can produce zero or negative wall duration. The monotonic
                // seconds remain valid and belong to the bucket containing the segment start.
                result += seconds
            }
        }
        return min(nonnegative(record.plannedSeconds), max(0, result))
    }

    private static func contains(_ date: Date, in interval: DateInterval) -> Bool {
        date >= interval.start && date < interval.end
    }

    private static func nonnegative(_ seconds: Double) -> Double {
        seconds.isFinite ? max(0, seconds) : 0
    }

    private static func csvText(_ text: String) -> String {
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first
        let unsafe = text.first == "\t" || text.first == "\r" || text.first == "\n"
            || first.map { "=+-@".contains($0) } == true
        let safe = unsafe ? "'" + text : text
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
