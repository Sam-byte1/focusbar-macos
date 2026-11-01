import Foundation

struct FocusType: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var symbol: String
    var minutes: Int
    var archived = false

    static let defaults: [FocusType] = [
        .init(id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, name: "工作", symbol: "laptopcomputer", minutes: 25),
        .init(id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!, name: "阅读", symbol: "book", minutes: 25),
        .init(id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!, name: "思考", symbol: "lightbulb", minutes: 25)
    ]
    static let symbols = [
        "laptopcomputer", "book", "lightbulb", "pencil", "graduationcap", "paintbrush", "leaf", "headphones",
        "briefcase", "keyboard", "doc.text", "folder", "calendar", "checklist", "target", "flag",
        "brain.head.profile", "sparkles", "camera", "music.note", "mic", "film", "globe", "cup.and.saucer",
        "heart", "figure.walk", "bicycle", "dumbbell", "sun.max", "moon", "star", "puzzlepiece"
    ]

    static func symbolName(_ value: String) -> String {
        let names = ["电脑", "阅读", "思考", "书写", "学习", "创作", "自然", "聆听",
                     "工作", "键盘", "文档", "文件", "计划", "清单", "目标", "旗帜",
                     "头脑", "灵感", "摄影", "音乐", "录音", "影视", "世界", "咖啡",
                     "健康", "散步", "骑行", "运动", "白天", "夜晚", "收藏", "探索"]
        guard let index = symbols.firstIndex(of: value) else { return "自定义图标" }
        return names[index]
    }
}

struct FocusSegment: Codable, Equatable {
    var start: Date
    var end: Date
    var seconds: Double
}

enum FocusOutcome: String, Codable, CaseIterable {
    case completed, ended, interrupted
    var label: String {
        switch self {
        case .completed: return "已完成"
        case .ended: return "提前结束"
        case .interrupted: return "中断保存"
        }
    }
}

struct FocusRecord: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var typeID: UUID
    var typeName: String
    var symbol: String
    var title: String
    var plannedSeconds: Double
    var startedAt: Date
    var endedAt: Date?
    var outcome: FocusOutcome?
    var segments: [FocusSegment] = []
    var timeZoneID: String = TimeZone.current.identifier
    var notificationSnapshot: Bool? = nil
    var soundSnapshot: Bool? = nil
    var seconds: Double { min(plannedSeconds, max(0, segments.reduce(0) { $0 + max(0, $1.seconds) })) }
}

enum MenuBarStyle: String, CaseIterable, Codable, Identifiable {
    case minimal, segmented, cursor, dots
    var id: String { rawValue }
    var name: String {
        switch self {
        case .minimal: return "极简圆角"
        case .segmented: return "分段刻度"
        case .cursor: return "细线游标"
        case .dots: return "圆点阵列"
        }
    }
    var detail: String {
        switch self {
        case .minimal: return "安静、连续，保留最初的简约"
        case .segmented: return "一步一格，让投入更有节奏"
        case .cursor: return "一根细线，标记此刻的位置"
        case .dots: return "点滴累积，逐一点亮"
        }
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .minimal
    }
}

struct FocusPreferences: Codable, Equatable {
    var selectedTypeID = FocusType.defaults[0].id
    var notifications = true
    var sound = true
    var hotKeyEnabled = true
    var showWindowAtLaunch = true
    var menuWidth: Double = 76
    var menuTime = false
    var appearance = "system"
    var menuStyle: MenuBarStyle = .minimal

    init() {}

    private enum CodingKeys: String, CodingKey {
        case selectedTypeID, notifications, sound, hotKeyEnabled, showWindowAtLaunch
        case menuWidth, menuTime, appearance, menuStyle
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selectedTypeID = try values.decode(UUID.self, forKey: .selectedTypeID)
        notifications = try values.decode(Bool.self, forKey: .notifications)
        sound = try values.decode(Bool.self, forKey: .sound)
        hotKeyEnabled = try values.decode(Bool.self, forKey: .hotKeyEnabled)
        showWindowAtLaunch = try values.decode(Bool.self, forKey: .showWindowAtLaunch)
        menuWidth = try values.decode(Double.self, forKey: .menuWidth)
        menuTime = try values.decode(Bool.self, forKey: .menuTime)
        appearance = try values.decode(String.self, forKey: .appearance)
        menuStyle = try values.decodeIfPresent(MenuBarStyle.self, forKey: .menuStyle) ?? .minimal
    }
}

struct FocusDocument: Codable, Equatable {
    var schemaVersion = 1
    var revision = 0
    var types = FocusType.defaults
    var history: [FocusRecord] = []
    var active: FocusRecord?
    var preferences = FocusPreferences()
}

// Dates describe attribution; monotonic seconds remain the source of truth.
enum FocusDuration {
    static func text(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        if value < 60 { return "\(value) 秒" }
        let minutes = value / 60
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }
}
