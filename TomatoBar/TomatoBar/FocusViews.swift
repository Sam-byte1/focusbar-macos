import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

private typealias FocusViewState<Value> = SwiftUI.State<Value>

private enum FocusHistoryRange: String, CaseIterable, Identifiable {
    case all = "全部日期", today = "今天", seven = "近 7 天", thirty = "近 30 天", custom = "自定范围"
    var id: Self { self }
}

@MainActor
struct FocusHistoryView: View {
    @ObservedObject var store: FocusStore
    @ObservedObject var timer: TBTimer
    @FocusViewState private var range: FocusHistoryRange = .all
    @FocusViewState private var typeID: UUID?
    @FocusViewState private var search = ""
    @FocusViewState private var fromDate = Calendar.current.startOfDay(for: Date())
    @FocusViewState private var toDate = Date()
    @FocusViewState private var exportError = ""

    private var interval: DateInterval? {
        let calendar = Calendar.current
        let now = Date()
        switch range {
        case .all: return nil
        case .today: return calendar.dateInterval(of: .day, for: now)
        case .seven: return FocusStatistics.interval(days: 7, now: now, calendar: calendar)
        case .thirty: return FocusStatistics.interval(days: 30, now: now, calendar: calendar)
        case .custom:
            let start = calendar.startOfDay(for: min(fromDate, toDate))
            let endDay = calendar.startOfDay(for: max(fromDate, toDate))
            let end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            return DateInterval(start: start, end: end)
        }
    }

    private func matches(_ record: FocusRecord) -> Bool {
        let inDates = interval.map { record.startedAt >= $0.start && record.startedAt < $0.end } ?? true
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return inDates && (typeID == nil || record.typeID == typeID)
            && (query.isEmpty || record.title.localizedStandardContains(query))
    }

    private var records: [FocusRecord] {
        timer.allRecords.filter(matches).sorted { $0.startedAt > $1.startedAt }
    }
    private var exportRecords: [FocusRecord] {
        store.history.filter(matches).sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        let filtered = records
        let groups = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.startedAt) }
        let dates = groups.keys.sorted(by: >)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("专注记录").font(.largeTitle.bold())
                        Text("按开始日期筛选；历史保留当时的类型名称和计划时长。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { exportCSV() } label: { Label("导出 CSV", systemImage: "square.and.arrow.up") }
                        .disabled(exportRecords.isEmpty)
                        .help("仅导出当前筛选下已保存的历史记录，不包含进行中的专注。")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { filters }
                    VStack(alignment: .leading, spacing: 12) { filters }
                }
                if range == .custom {
                    HStack(spacing: 16) {
                        DatePicker("开始日期", selection: $fromDate, displayedComponents: .date)
                        DatePicker("结束日期", selection: $toDate, displayedComponents: .date)
                    }
                    Text("包含首尾两天；日期顺序颠倒时会自动按先后排列。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("\(filtered.count) 条记录 · 时间按当前系统时区显示 · CSV 仅包含已保存记录")
                    .font(.caption).foregroundStyle(.secondary)
                if !exportError.isEmpty {
                    Label(exportError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
                if filtered.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.history.isEmpty && timer.activeRecord == nil ? "还没有专注记录" : "没有符合筛选的记录")
                            .font(.headline)
                        Text("完成或结束专注后，记录将保存在这里。可调整日期、类型或事项关键词。")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 32)
                } else {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(dates, id: \.self) { date in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(date.formatted(date: .complete, time: .omitted))
                                    .font(.headline).accessibilityAddTraits(.isHeader)
                                ForEach(groups[date] ?? []) { record in
                                    historyRow(record)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private var filters: some View {
        Picker("日期", selection: $range) {
            ForEach(FocusHistoryRange.allCases) { item in Text(item.rawValue).tag(item) }
        }.frame(maxWidth: 210)
        Picker("类型", selection: $typeID) {
            Text("全部类型").tag(nil as UUID?)
            ForEach(store.historicalTypes) { type in
                Text(type.name + (type.archived ? "（已归档）" : "")).tag(Optional(type.id))
            }
        }.frame(maxWidth: 230)
        TextField("搜索事项", text: $search)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 150, maxWidth: 320)
            .accessibilityLabel("搜索专注事项")
    }

    private func historyRow(_ record: FocusRecord) -> some View {
        let active = timer.activeRecord?.id == record.id
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(record.typeName, systemImage: record.symbol)
                    .font(.subheadline.weight(.semibold))
                Text(record.title.isEmpty ? "未填写事项" : record.title)
                    .foregroundStyle(record.title.isEmpty ? .secondary : .primary)
                    .lineLimit(3)
                Spacer(minLength: 8)
                Label(active ? "进行中" : (record.outcome?.label ?? "未结束"),
                      systemImage: active ? "timer" : (record.outcome == .completed ? "checkmark.circle" : "stop.circle"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) { recordDetails(record, active: active) }
                VStack(alignment: .leading, spacing: 6) { recordDetails(record, active: active) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func recordDetails(_ record: FocusRecord, active: Bool) -> some View {
        Text("开始 \(record.startedAt.formatted(date: .omitted, time: .standard))")
        Text("结束 \(record.endedAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? (active ? "进行中" : "—"))")
        Text("计划 \(FocusDuration.text(record.plannedSeconds))")
        Text("实际 \(FocusDuration.text(record.seconds))").monospacedDigit()
    }

    private func exportCSV() {
        let snapshot = exportRecords
        guard !snapshot.isEmpty else { return }
        exportError = ""
        let panel = NSSavePanel()
        panel.title = "导出筛选后的专注记录"
        panel.nameFieldStringValue = "专注记录-\(Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FocusStatistics.csv(snapshot).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = "导出失败：\(error.localizedDescription)"
        }
    }
}

private struct FocusTypeDraft: Identifiable {
    let id = UUID()
    var original: FocusType?
}

@MainActor
struct FocusTypesView: View {
    @ObservedObject var store: FocusStore
    @FocusViewState private var draft: FocusTypeDraft?
    @FocusViewState private var deleting: FocusType?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("专注类型").font(.largeTitle.bold())
                        Text("自由命名并选择图标；默认类型也可编辑或删除，历史记录保留。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { draft = FocusTypeDraft() } label: { Label("新增类型", systemImage: "plus") }
                        .disabled(store.readOnly)
                }
                FocusUIStorageNotice(store: store)
                VStack(alignment: .leading, spacing: 12) {
                    Text("可用类型").font(.headline)
                    ForEach(store.availableTypes) { type in typeRow(type) }
                }
                let archived = store.types.filter(\.archived)
                if !archived.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("已归档").font(.headline)
                        Text("归档类型不会出现在新一轮专注的选择中，历史记录仍保留。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(archived) { type in typeRow(type) }
                    }
                }
                Text("至少保留一种可用类型。类型名称最多 40 个字符，默认时长为 1–180 分钟。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(item: $draft) { item in
            FocusTypeEditor(store: store, original: item.original)
        }
        .alert("删除“\(deleting?.name ?? "")”？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除类型", role: .destructive) {
                if let type = deleting { _ = store.deleteType(type) }
                deleting = nil
            }
        } message: {
            Text("该类型将从首页和类型列表中移除。已有专注记录不会删除，正在进行的本轮也不受影响。")
        }
    }

    private func typeRow(_ type: FocusType) -> some View {
        HStack(spacing: 14) {
            Image(systemName: type.symbol).font(.title3).frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(type.name).font(.headline)
                Text("默认 \(type.minutes) 分钟").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !type.archived {
                if store.preferences.selectedTypeID == type.id {
                    Label("默认选中", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("设为默认") { store.select(type.id) }.disabled(store.readOnly)
                }
            }
            Button("编辑") { draft = FocusTypeDraft(original: type) }.disabled(store.readOnly)
            Button(type.archived ? "恢复" : "归档") { store.archive(type) }
                .disabled(store.readOnly || (!type.archived && store.availableTypes.count <= 1))
                .help(!type.archived && store.availableTypes.count <= 1 ? "至少保留一种可用的专注类型" : "不影响历史记录")
            Button(role: .destructive) { deleting = type } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(store.readOnly || (!type.archived && store.availableTypes.count <= 1))
                .help("删除类型，保留历史记录")
                .accessibilityLabel("删除“\(type.name)”")
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
struct FocusTypeEditor: View {
    @ObservedObject var store: FocusStore
    let original: FocusType?
    @Environment(\.dismiss) private var dismiss
    @FocusViewState private var name: String
    @FocusViewState private var symbol: String
    @FocusViewState private var minutes: Int
    @FocusViewState private var confirmDelete = false

    init(store: FocusStore, original: FocusType?) {
        self.store = store
        self.original = original
        _name = FocusViewState(initialValue: original?.name ?? "")
        _symbol = FocusViewState(initialValue: original?.symbol ?? FocusType.symbols[0])
        _minutes = FocusViewState(initialValue: original?.minutes ?? 25)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(original == nil ? "新增专注类型" : "编辑专注类型").font(.title2.bold())
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.primary).frame(width: 46, height: 46)
                    .background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
                TextField("自由命名，例如写作、练琴、冥想", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { value in
                        if value.count > 40 { name = String(value.prefix(40)) }
                    }
            }
            Text("选择图标").font(.subheadline.weight(.medium))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                ForEach(FocusType.symbols, id: \.self) { value in
                    Button { symbol = value } label: {
                        Image(systemName: value).font(.system(size: 19))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(Color.primary.opacity(symbol == value ? 0.12 : 0.035))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(symbol == value ? Color.primary.opacity(0.5) : .clear, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                    .help(FocusType.symbolName(value))
                    .accessibilityLabel(FocusType.symbolName(value) + (symbol == value ? "，已选择" : ""))
                }
            }
            Stepper("默认时长：\(minutes) 分钟", value: $minutes, in: 1...180)
            Text("更改仅用于之后开始的专注，不改写历史记录或当前专注。")
                .font(.caption).foregroundStyle(.secondary)
            FocusUIStorageNotice(store: store)
            HStack {
                if let original {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("删除类型", systemImage: "trash")
                    }
                    .disabled(store.readOnly || (!original.archived && store.availableTypes.count <= 1))
                    .help(store.availableTypes.count <= 1 ? "至少保留一种可用类型，请先新增其他类型" : "删除类型，不删除历史记录")
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if store.saveType(id: original?.id, name: name, symbol: symbol, minutes: minutes) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.readOnly || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("删除“\(original?.name ?? "")”？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除类型", role: .destructive) {
                if let original, store.deleteType(original) { dismiss() }
            }
        } message: {
            Text("该类型将从首页移除。已有历史记录和正在进行的本轮专注均会保留。")
        }
    }

}

@MainActor
struct FocusSettingsView: View {
    @ObservedObject var store: FocusStore
    @ObservedObject var timer: TBTimer
    @FocusViewState private var loginStatus = SMAppService.mainApp.status
    @FocusViewState private var loginError = ""
    @FocusViewState private var changingLogin = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("设置").font(.largeTitle.bold())
                FocusUIStorageNotice(store: store)
                FocusUISettingsPanel(title: "启动与提醒") {
                    Toggle("启动时显示主窗口", isOn: preference(\.showWindowAtLaunch))
                    Divider()
                    Toggle("专注完成时发送通知", isOn: preference(\.notifications))
                    Text(timer.notificationStatus.isEmpty ? "通知权限状态将在系统检查后显示。" : timer.notificationStatus)
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("专注完成时播放音效", isOn: preference(\.sound))
                    Text("通知和音效的更改从下一轮专注生效。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(store.readOnly)
                FocusUISettingsPanel(title: "全局快捷键") {
                    Toggle("启用全局快捷键", isOn: preference(\.hotKeyEnabled))
                    Label(hotKeyStatus, systemImage: !store.preferences.hotKeyEnabled ? "minus.circle" : (timer.hotKeyAvailable ? "checkmark.circle" : "exclamationmark.triangle"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(store.readOnly)
                FocusUISettingsPanel(title: "菜单栏与外观") {
                    Text("进度条样式").font(.subheadline.weight(.medium))
                    Text("预览为示意进度 56%；选择后立即应用，不改变本轮计时。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(MenuBarStyle.allCases) { style in
                        Button {
                            guard store.preferences.menuStyle != style else { return }
                            store.setPreferences { $0.menuStyle = style }
                        } label: {
                            HStack(spacing: 14) {
                                Image(nsImage: TBProgressImage.make(progress: 0.56, state: .running, width: 90, style: style))
                                    .renderingMode(.template).foregroundStyle(.primary)
                                    .frame(width: 122, height: 28).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(style.name).font(.system(size: 13, weight: .medium))
                                    Text(style.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: store.preferences.menuStyle == style ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(store.preferences.menuStyle == style ? Color.primary : Color.secondary.opacity(0.35))
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(store.preferences.menuStyle == style ? 0.065 : 0.025))
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(style.name + (store.preferences.menuStyle == style ? "，已选择" : "，未选择"))
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("进度条宽度")
                            Spacer()
                            Text("\(Int(store.preferences.menuWidth)) 点").monospacedDigit()
                        }
                        Slider(value: preference(\.menuWidth), in: 60...140, step: 1)
                            .accessibilityLabel("菜单栏进度条宽度")
                            .accessibilityValue("\(Int(store.preferences.menuWidth)) 点")
                    }
                    Toggle("菜单栏显示数字倒计时", isOn: preference(\.menuTime))
                    Picker("外观", selection: preference(\.appearance)) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                }
                .disabled(store.readOnly)
                FocusUISettingsPanel(title: "登录时启动") {
                    Label(loginStatusText, systemImage: loginStatus == .enabled ? "checkmark.circle" : "info.circle")
                    Text("登录项由 macOS 管理；仅在点击下方按钮后更改。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if loginStatus == .enabled || loginStatus == .requiresApproval {
                            Button("关闭登录启动") { changeLogin(enable: false) }
                        } else {
                            Button("开启登录启动") { changeLogin(enable: true) }
                                .disabled(loginStatus == .notFound)
                        }
                        if loginStatus == .requiresApproval {
                            Button("打开系统登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                        }
                        Button("刷新状态") { refreshLoginStatus() }
                    }
                    .disabled(changingLogin)
                    if changingLogin { ProgressView().controlSize(.small) }
                    if !loginError.isEmpty {
                        Label(loginError, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                FocusUISettingsPanel(title: "计时与数据") {
                    Text("系统睡眠时自动暂停，唤醒后由使用者继续。锁屏暂停采用系统事件尽力检测，可能受系统环境影响；离开电脑前可手动暂停。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Text("数据保存在本机。打开目录只会在 Finder 中显示文件，不会修改或删除记录。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(store.directory.path).font(.caption).textSelection(.enabled)
                    Button { NSWorkspace.shared.open(store.directory) } label: {
                        Label("在 Finder 中打开数据目录", systemImage: "folder")
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginStatus()
        }
    }

    private var hotKeyStatus: String {
        if !store.preferences.hotKeyEnabled { return "快捷键已关闭。" }
        return timer.hotKeyAvailable ? "⌃⌥ 空格可用：开始、暂停或继续专注。" : "快捷键不可用，可能已被其他应用占用。可在主窗口操作计时。"
    }

    private var loginStatusText: String {
        switch loginStatus {
        case .notRegistered: return "未开启登录启动"
        case .enabled: return "已开启登录启动"
        case .requiresApproval: return "等待系统批准，请在系统设置的登录项中允许"
        case .notFound: return "系统未找到可注册的应用，请从已安装的应用副本打开"
        @unknown default: return "登录项状态未知，可刷新后重试"
        }
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<FocusPreferences, Value>) -> Binding<Value> {
        Binding(get: { store.preferences[keyPath: keyPath] },
                set: { value in store.setPreferences { $0[keyPath: keyPath] = value } })
    }

    private func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
    }

    private func changeLogin(enable: Bool) {
        guard !changingLogin else { return }
        changingLogin = true
        loginError = ""
        Task { @MainActor in
            defer {
                refreshLoginStatus()
                changingLogin = false
            }
            do {
                if enable { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                refreshLoginStatus()
                if enable && loginStatus != .enabled && loginStatus != .requiresApproval {
                    loginError = "系统尚未确认登录启动已开启，请检查应用安装位置后重试。"
                } else if !enable && loginStatus != .notRegistered {
                    loginError = "系统尚未确认登录启动已关闭，请刷新或检查系统设置。"
                }
            } catch {
                loginError = "登录项更改失败：\(error.localizedDescription)"
            }
        }
    }
}

@MainActor
private struct FocusUISettingsPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
private struct FocusUIStorageNotice: View {
    @ObservedObject var store: FocusStore

    var body: some View {
        if store.readOnly || !store.errorMessage.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if store.readOnly {
                    Label("数据处于只读保护，暂不能修改。", systemImage: "lock")
                }
                if !store.errorMessage.isEmpty { Text(store.errorMessage).textSelection(.enabled) }
            }
            .font(.callout).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }
}
