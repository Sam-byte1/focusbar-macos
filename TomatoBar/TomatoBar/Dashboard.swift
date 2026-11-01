import SwiftUI
import Charts

// The application also owns a model named State; keep property-wrapper lookup explicit.
private typealias DashboardState<Value> = SwiftUI.State<Value>

private enum DashboardRange: String, CaseIterable, Identifiable {
    case week = "本周", seven = "近 7 天", thirty = "近 30 天"
    var id: Self { self }

    func interval(now: Date, calendar: Calendar) -> DateInterval {
        switch self {
        case .week: return FocusStatistics.week(now: now, calendar: calendar)
        case .seven: return FocusStatistics.interval(days: 7, now: now, calendar: calendar)
        case .thirty: return FocusStatistics.interval(days: 30, now: now, calendar: calendar)
        }
    }
}

@MainActor
struct FocusDashboardView: View {
    @ObservedObject var store: FocusStore
    @ObservedObject var timer: TBTimer
    @Environment(\.colorScheme) private var colorScheme
    @DashboardState private var typeID: UUID?
    @DashboardState private var range: DashboardRange = .week
    @DashboardState private var showTable = false
    @DashboardState private var hoveredDate: Date?

    private var calendar: Calendar { .current }
    private var records: [FocusRecord] {
        timer.allRecords.filter { typeID == nil || $0.typeID == typeID }
    }
    private var blue: Color {
        colorScheme == .dark
            ? Color(red: 57 / 255, green: 135 / 255, blue: 229 / 255)
            : Color(red: 42 / 255, green: 120 / 255, blue: 214 / 255)
    }
    private var surface: Color {
        colorScheme == .dark
            ? Color(red: 26 / 255, green: 26 / 255, blue: 25 / 255)
            : Color(red: 252 / 255, green: 252 / 255, blue: 251 / 255)
    }

    var body: some View {
        let now = Date()
        let interval = range.interval(now: now, calendar: calendar)
        let days = FocusStatistics.daily(records, from: interval.start, to: interval.end, calendar: calendar)
        let totals = FocusStatistics.byType(records, in: interval, types: store.types)
            .filter { $0.seconds > 0 }
            .sorted { $0.seconds > $1.seconds }

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("专注概览").font(.largeTitle.bold())
                    Text("只统计实际专注时间；暂停与睡眠时间不计入。")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("专注类型").foregroundStyle(.secondary)
                    Picker("专注类型", selection: $typeID) {
                        Text("全部类型").tag(nil as UUID?)
                        ForEach(store.historicalTypes) { type in
                            Text(type.name + (type.archived ? "（已归档）" : ""))
                                .tag(Optional(type.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 230)
                    Spacer()
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) { metrics(now: now) }
                    VStack(alignment: .leading, spacing: 16) { metrics(now: now) }
                }
                Text("完成轮数仅包含正常完成的专注；进行中的实际时长会实时计入。")
                    .font(.caption).foregroundStyle(.secondary)

                Divider()
                HStack {
                    Picker("趋势与分布范围", selection: $range) {
                        ForEach(DashboardRange.allCases) { item in Text(item.rawValue).tag(item) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 290)
                    Spacer(minLength: 12)
                    Toggle("数据表", isOn: $showTable).toggleStyle(.checkbox)
                }
                .onChange(of: range) { _ in hoveredDate = nil }
                Text("以下趋势与类型分布使用同一时间范围。")
                    .font(.caption).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 16) {
                    Text("每日实际专注时长").font(.title3.weight(.semibold))
                    if days.allSatisfy({ $0.seconds <= 0 }) {
                        emptyState("所选范围暂无专注时长", detail: "开始一次专注后，这里会显示真实记录。")
                    } else if showTable {
                        dailyTable(days)
                    } else {
                        dailyChart(days)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(surface, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 18) {
                    Text("类型分布 · 实际时长").font(.title3.weight(.semibold))
                    if totals.isEmpty {
                        emptyState("暂无类型分布", detail: "所选范围内还没有实际专注时长。")
                    } else {
                        if showTable {
                            HStack {
                                Text("类型").fontWeight(.semibold)
                                Spacer()
                                Text("实际专注时长").fontWeight(.semibold)
                            }
                            Divider()
                        }
                        ForEach(totals) { total in
                            typeBar(name: total.name, seconds: total.seconds,
                                    maximum: totals.map(\.seconds).max() ?? 1, table: showTable)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(surface, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func metrics(now: Date) -> some View {
        metric("今日", interval: calendar.dateInterval(of: .day, for: now))
        metric("本周", interval: FocusStatistics.week(now: now, calendar: calendar))
        metric("累计", interval: nil)
    }

    private func metric(_ title: String, interval: DateInterval?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text(FocusDuration.text(FocusStatistics.seconds(records, in: interval)))
                .font(.system(size: 27, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("完成 \(FocusStatistics.completedCount(records, in: interval)) 轮")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func dailyChart(_ days: [FocusDay]) -> some View {
        let hovered = days.first { day in
            hoveredDate.map { calendar.isDate(day.date, inSameDayAs: $0) } ?? false
        }
        return VStack(alignment: .leading, spacing: 10) {
            Group {
                if let hovered {
                    Text("\(hovered.date.formatted(date: .abbreviated, time: .omitted)) · \(minutes(hovered.seconds)) 分钟")
                } else {
                    Text("移入图表查看日期与分钟；也可切换数据表。")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(height: 18, alignment: .leading)
            Chart(days) { day in
                BarMark(x: .value("日期", day.date, unit: .day),
                        y: .value("实际专注（分钟）", day.seconds / 60),
                        width: .fixed(days.count > 14 ? 12 : 22))
                    .foregroundStyle(blue)
                    .cornerRadius(4)
                    .opacity(hoveredDate.map { calendar.isDate(day.date, inSameDayAs: $0) ? 1 : 0.55 } ?? 1)
                    .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
                    .accessibilityValue("实际专注 \(minutes(day.seconds)) 分钟")
            }
            .chartYScale(domain: 0...max(1, (days.map { $0.seconds / 60 }.max() ?? 0) * 1.12))
            .chartYAxisLabel("分钟")
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: days.count > 14 ? 5 : 1)) { _ in
                    AxisValueLabel(format: .dateTime.month(.twoDigits).day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel()
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                let frame = geometry[proxy.plotAreaFrame]
                                guard frame.contains(point),
                                      let date: Date = proxy.value(atX: point.x - frame.minX) else {
                                    hoveredDate = nil
                                    return
                                }
                                hoveredDate = days.first { calendar.isDate($0.date, inSameDayAs: date) }?.date
                            case .ended: hoveredDate = nil
                            }
                        }
                }
            }
            .frame(height: 250)
            .accessibilityLabel("每日实际专注时长柱状图")
            .accessibilityHint("可使用上方数据表开关读取全部日期和精确分钟。")
        }
    }

    private func dailyTable(_ days: [FocusDay]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("日期").fontWeight(.semibold)
                Spacer()
                Text("实际专注（分钟）").fontWeight(.semibold)
            }
            .padding(.vertical, 8)
            ForEach(days) { day in
                Divider()
                HStack {
                    Text(day.date.formatted(date: .abbreviated, time: .omitted))
                    Spacer()
                    Text(minutes(day.seconds)).monospacedDigit()
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func typeBar(name: String, seconds: Double, maximum: Double, table: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).lineLimit(2)
                Spacer()
                Text(FocusDuration.text(seconds)).monospacedDigit()
            }
            if !table {
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(blue)
                        .frame(width: max(0, geometry.size.width * seconds / max(1, maximum)), height: 12)
                }
                .frame(height: 12)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func minutes(_ seconds: Double) -> String {
        (seconds / 60).formatted(.number.precision(.fractionLength(0...1)))
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
    }
}
