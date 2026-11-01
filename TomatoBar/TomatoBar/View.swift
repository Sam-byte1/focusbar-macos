import SwiftUI

private typealias FocusViewState<Value> = SwiftUI.State<Value>

@MainActor
struct TBPopoverView: View {
    @ObservedObject var timer: TBTimer
    @ObservedObject var store: FocusStore
    var openWindow: () -> Void
    @FocusViewState private var confirmEnd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("专注条").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: openWindow) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.plain).help("打开主窗口")
            }
            Picker("下一轮类型", selection: Binding(get: { store.preferences.selectedTypeID }, set: { store.select($0) })) {
                ForEach(store.availableTypes) { type in Text(type.name).tag(type.id) }
            }
            FocusDurationControl(store: store, isActive: timer.state == .running || timer.state == .paused, compact: true)
            Text(timer.state.label + " · " + timer.currentName).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(timer.timeLeftString).font(.system(size: 54, weight: .light, design: .rounded))
            ProgressView(value: timer.progress).tint(.primary)
            Button { timer.startStop() } label: {
                Label(timer.primaryTitle, systemImage: timer.primarySymbol).frame(maxWidth: .infinity, minHeight: 32)
            }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).disabled(store.readOnly)
            if timer.state == .running || timer.state == .paused {
                Button("结束并保存") { confirmEnd = true }.buttonStyle(.plain).font(.system(size: 12))
            }
            if !timer.recoveryMessage.isEmpty { Text(timer.recoveryMessage).font(.system(size: 11)).foregroundStyle(.secondary) }
            if !store.errorMessage.isEmpty { Text(store.errorMessage).font(.system(size: 11)).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Button("打开主窗口", action: openWindow).buttonStyle(.plain)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }.buttonStyle(.plain).keyboardShortcut("q")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(24).frame(width: 312).fixedSize(horizontal: false, vertical: true)
        .alert("结束本轮并保存已投入时间？", isPresented: $confirmEnd) {
            Button("取消", role: .cancel) {}
            Button("结束并保存") { _ = timer.end() }
        }
    }
}

@MainActor
struct FocusDurationControl: View {
    @ObservedObject var store: FocusStore
    var isActive: Bool
    var compact = false
    @FocusViewState private var text = ""
    @FocusViewState private var validation = ""

    init(store: FocusStore, isActive: Bool, compact: Bool = false) {
        self.store = store
        self.isActive = isActive
        self.compact = compact
        _text = FocusViewState(initialValue: String(store.selectedType.minutes))
    }

    private var selected: Int { store.selectedType.minutes }
    private var validMinutes: Int? {
        guard let minutes = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), (1...180).contains(minutes) else { return nil }
        return minutes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 9 : 12) {
            HStack {
                Text(isActive ? "下一轮时长" : "专注时长").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(selected) 分钟").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: compact ? 6 : 8) {
                ForEach([15, 25, 45, 60], id: \.self) { minutes in
                    Button { save(minutes) } label: {
                        Text("\(minutes)").font(.system(size: 12, weight: selected == minutes ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .background(Color.primary.opacity(selected == minutes ? 0.12 : 0.045))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                    .accessibilityLabel("\(minutes) 分钟" + (selected == minutes ? "，已选择" : ""))
                }
            }
            HStack(spacing: 8) {
                Text("自定义").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("1–180", text: $text)
                    .textFieldStyle(.roundedBorder).frame(width: compact ? 64 : 78)
                    .onSubmit { apply() }
                    .accessibilityLabel("自定义专注分钟数，1至180")
                Text("分钟").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("应用") { apply() }
                    .disabled(validMinutes == nil || validMinutes == selected)
                    .controlSize(.small)
            }
            if !validation.isEmpty {
                Text(validation).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(isActive ? "仅用于下一轮，当前倒计时保持不变。" : "1–180 分钟，将记为“\(store.selectedType.name)”的默认时长。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: compact ? nil : 380)
        .disabled(store.readOnly)
        .onAppear { sync() }
        .onChange(of: store.selectedType.id) { _ in sync() }
        .onChange(of: selected) { _ in sync() }
    }

    private func sync() { text = String(selected); validation = "" }
    private func apply() {
        guard let value = validMinutes else { validation = "请输入 1–180 的整数分钟。"; return }
        save(value)
    }
    private func save(_ minutes: Int) {
        let type = store.selectedType
        guard type.minutes != minutes else { return }
        if store.saveType(id: type.id, name: type.name, symbol: type.symbol, minutes: minutes) { sync() }
    }
}
