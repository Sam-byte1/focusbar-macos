import SwiftUI
import AppKit

private typealias MainViewState<Value> = SwiftUI.State<Value>

struct FocusBrandMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary)
            Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.3)).frame(width: 21, height: 5)
            HStack(spacing: 0) {
                Capsule().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 14, height: 5)
                Spacer(minLength: 0)
            }.frame(width: 21, height: 5)
        }.accessibilityLabel("专注条标志")
    }
}

enum FocusPage: String, CaseIterable, Identifiable {
    case focus = "开始专注", dashboard = "统计看板", history = "历史记录", types = "专注类型", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .focus: return "timer"
        case .dashboard: return "chart.bar.xaxis"
        case .history: return "clock.arrow.circlepath"
        case .types: return "square.grid.2x2"
        case .settings: return "slider.horizontal.3"
        }
    }
}

@MainActor
final class FocusNavigation: ObservableObject {
    @Published var page: FocusPage = .focus
}

@MainActor
final class FocusWindowController: NSWindowController, NSWindowDelegate {
    init(store: FocusStore, timer: TBTimer, navigation: FocusNavigation) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "专注条 · FocusBar"
        window.minSize = NSSize(width: 880, height: 620)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("FocusBar.MainWindow")
        window.contentViewController = NSHostingController(rootView: FocusMainView(store: store, timer: timer, navigation: navigation))
        window.setContentSize(NSSize(width: 1080, height: 760))
        super.init(window: window)
        window.delegate = self
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
struct FocusMainView: View {
    @ObservedObject var store: FocusStore
    @ObservedObject var timer: TBTimer
    @ObservedObject var navigation: FocusNavigation

    private var scheme: ColorScheme? {
        switch store.preferences.appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    FocusBrandMark().frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("专注条").font(.system(size: 17, weight: .semibold))
                        Text("FOCUS, THEN FLOW").font(.system(size: 8, weight: .medium)).tracking(1.2).foregroundStyle(.secondary)
                    }
                }.padding(.bottom, 32)
                ForEach(FocusPage.allCases) { page in
                    Button { navigation.page = page } label: {
                        HStack(spacing: 11) {
                            Image(systemName: page.symbol).frame(width: 18)
                            Text(page.rawValue)
                            Spacer()
                        }
                        .font(.system(size: 13, weight: navigation.page == page ? .semibold : .regular))
                        .padding(.horizontal, 13).padding(.vertical, 11)
                        .background(navigation.page == page ? Color.primary.opacity(0.07) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 7) {
                    Text(timer.state.label).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(timer.timeLeftString).font(.system(size: 24, weight: .light, design: .rounded))
                    Text("小步向前，也算向前。").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(13)
                Text("本地保存 · 无需账号").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 13)
            }
            .padding(20).frame(width: 210).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                if !store.errorMessage.isEmpty {
                    Label(store.errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14).background(Color.orange.opacity(0.12))
                }
                Group {
                    switch navigation.page {
                    case .focus: FocusStartView(store: store, timer: timer)
                    case .dashboard: FocusDashboardView(store: store, timer: timer)
                    case .history: FocusHistoryView(store: store, timer: timer)
                    case .types: FocusTypesView(store: store)
                    case .settings: FocusSettingsView(store: store, timer: timer)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(scheme)
        .frame(minWidth: 880, minHeight: 620)
    }
}

@MainActor
struct FocusStartView: View {
    @ObservedObject var store: FocusStore
    @ObservedObject var timer: TBTimer
    @MainViewState private var restart = false
    @MainViewState private var end = false
    @MainViewState private var addingType = false
    @MainViewState private var editingType: FocusType?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("把注意力，交给眼前这一件事。").font(.system(size: 26, weight: .semibold))
                    Text("选择一个方向，立即开始。每一点投入都会留下来。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    ForEach(store.availableTypes) { type in
                        Button { store.select(type.id) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: type.symbol).font(.system(size: 20))
                                Text(type.name).font(.system(size: 14, weight: .medium))
                            }
                            .frame(minWidth: 72, maxWidth: .infinity, alignment: .leading).padding(18)
                            .background(store.preferences.selectedTypeID == type.id ? Color.blue.opacity(0.09) : Color.primary.opacity(0.03))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(store.preferences.selectedTypeID == type.id ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { editingType = type })
                        .contextMenu {
                            Button("编辑或删除") { editingType = type }
                        }
                        .help("单击选择，双击编辑或删除")
                        .accessibilityAction(named: Text("编辑或删除")) { editingType = type }
                        .disabled(store.readOnly)
                    }
                    Button { addingType = true } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "plus.circle").font(.system(size: 20))
                            Text("自定义").font(.system(size: 14, weight: .medium))
                        }
                        .frame(minWidth: 72, maxWidth: .infinity, alignment: .leading).padding(18)
                        .foregroundStyle(.secondary)
                        .background(Color.primary.opacity(0.025))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).disabled(store.readOnly)
                }
                if timer.state == .running || timer.state == .paused {
                    Text("本轮：\(timer.currentName)；切换类型将用于下一轮。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(spacing: 18) {
                    Text(timer.state.label + " · " + timer.currentName).font(.system(size: 13)).foregroundStyle(.secondary)
                    Text(timer.timeLeftString).font(.system(size: 82, weight: .ultraLight, design: .rounded))
                        .accessibilityLabel("剩余 \(timer.timeLeftString)")
                    ProgressView(value: timer.progress).tint(.primary).frame(maxWidth: 360)
                    if let record = timer.activeRecord, !record.title.isEmpty {
                        Text(record.title).font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    if timer.state == .idle || timer.state == .completed {
                        TextField("这轮想做什么？（可不填）", text: $timer.draftTitle)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                    }
                    Button { timer.startStop() } label: {
                        Label(timer.primaryTitle, systemImage: timer.primarySymbol)
                            .font(.system(size: 15, weight: .medium)).frame(width: 240, height: 36)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.readOnly)
                    FocusDurationControl(store: store, isActive: timer.state == .running || timer.state == .paused)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    if timer.state == .running || timer.state == .paused {
                        HStack(spacing: 24) {
                            Button("结束并保存") { end = true }
                            Button("重新开始") { restart = true }
                        }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if !timer.recoveryMessage.isEmpty {
                        Text(timer.recoveryMessage).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 30).frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.025)).clipShape(RoundedRectangle(cornerRadius: 18))
                HStack {
                    Label("\(timer.hotKeyAvailable ? "⌃⌥ 空格 · 随时开始 / 暂停" : "快捷键不可用，可通过按钮操作")", systemImage: "keyboard")
                    Spacer()
                    Text("今日投入 " + FocusDuration.text(FocusStatistics.seconds(timer.allRecords, in: FocusStatistics.interval(days: 1, now: Date(), calendar: .current))))
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(34)
        }
        .sheet(isPresented: $addingType) { FocusTypeEditor(store: store, original: nil) }
        .sheet(item: $editingType) { type in FocusTypeEditor(store: store, original: type) }
        .alert("重新开始？", isPresented: $restart) {
            Button("取消", role: .cancel) {}
            Button("保存并重开") { timer.start() }
        } message: { Text("本轮已投入的时间会保存，随后开始新的一轮。") }
        .alert("结束本轮？", isPresented: $end) {
            Button("取消", role: .cancel) {}
            Button("结束并保存") { _ = timer.end() }
        } message: { Text("已投入的时间会计入统计，不会丢失。") }
    }
}
