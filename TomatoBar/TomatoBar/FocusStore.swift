import Foundation
import Combine
import Darwin

enum FocusStorageError: LocalizedError {
    case locked, version, invalid
    var errorDescription: String? {
        switch self {
        case .locked: return "另一个专注条实例正在使用此数据目录。"
        case .version: return "数据来自更高版本，已进入只读保护。"
        case .invalid: return "本地数据无法读取；原文件已保留，未覆盖。"
        }
    }
}

final class FocusRepository {
    let directory: URL
    private var lock: Int32 = -1
    private(set) var readOnly = false
    private(set) var notice = ""
    private var validPrimary = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var file: URL { directory.appendingPathComponent("focus-data.json") }
    private var backup: URL { directory.appendingPathComponent("focus-data.backup.json") }

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lock = Darwin.open(directory.appendingPathComponent("writer.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if lock >= 0 { Darwin.close(lock) }
            lock = -1
            throw FocusStorageError.locked
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    deinit {
        if lock >= 0 { flock(lock, LOCK_UN); Darwin.close(lock) }
    }

    func load() throws -> FocusDocument? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let data = try Data(contentsOf: file)
            let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard header?["schemaVersion"] as? Int == 1 else {
                readOnly = true
                throw FocusStorageError.version
            }
            let result = try decoder.decode(FocusDocument.self, from: data)
            guard valid(result) else { throw FocusStorageError.invalid }
            validPrimary = true
            return result
        } catch {
            readOnly = true
            if let error = error as? FocusStorageError, case .version = error { throw error }
            if let data = try? Data(contentsOf: backup), let document = try? decoder.decode(FocusDocument.self, from: data), valid(document) {
                notice = "主文件损坏，当前显示上次有效备份（只读）。原文件已保留，请先备份后修复。"
                return document
            }
            throw FocusStorageError.invalid
        }
    }

    func save(_ document: FocusDocument) throws {
        guard !readOnly else { throw FocusStorageError.invalid }
        guard valid(document) else { throw FocusStorageError.invalid }
        let data = try encoder.encode(document)
        if validPrimary, let previous = try? Data(contentsOf: file) {
            try previous.write(to: backup, options: .atomic)
        }
        try data.write(to: file, options: .atomic)
        validPrimary = true
    }

    private func valid(_ document: FocusDocument) -> Bool {
        guard document.schemaVersion == 1, !document.types.isEmpty,
              document.types.contains(where: { !$0.archived }),
              Set(document.types.map(\.id)).count == document.types.count else { return false }
        let records = document.history + [document.active].compactMap { $0 }
        let preferences = document.preferences
        guard preferences.menuWidth.isFinite, (60...140).contains(preferences.menuWidth),
              ["system", "light", "dark"].contains(preferences.appearance),
              Set(document.history.map(\.id)).count == document.history.count,
              !document.history.contains(where: { $0.id == document.active?.id }) else { return false }
        return document.types.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...180).contains($0.minutes) }
            && records.allSatisfy { $0.plannedSeconds.isFinite && $0.plannedSeconds > 0 && $0.segments.allSatisfy { $0.seconds.isFinite && $0.seconds >= 0 } }
    }
}

@MainActor
final class FocusStore: ObservableObject {
    @Published private(set) var document: FocusDocument
    @Published private(set) var errorMessage = ""
    @Published private(set) var readOnly = false
    let repository: FocusRepository?
    var directory: URL { repository?.directory ?? Self.defaultDirectory }
    var onPreferencesChanged: (() -> Void)?

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.shijie.FocusBar", isDirectory: true)
    }

    init(directory: URL? = nil) {
        var document = FocusDocument()
        var repository: FocusRepository?
        var message = ""
        var protected = false
        do {
            repository = try FocusRepository(directory: directory ?? Self.defaultDirectory)
            if let loaded = try repository?.load() { document = loaded }
            else {
                let defaults = UserDefaults.standard
                if let value = defaults.object(forKey: "focusMinutes") as? Int { document.types[0].minutes = min(180, max(1, value)) }
                if defaults.object(forKey: "completionSound") != nil { document.preferences.sound = defaults.bool(forKey: "completionSound") }
                if defaults.object(forKey: "completionNotification") != nil { document.preferences.notifications = defaults.bool(forKey: "completionNotification") }
                try repository?.save(document)
            }
            protected = repository?.readOnly ?? false
            message = repository?.notice ?? ""
        } catch {
            message = error.localizedDescription
            protected = true
        }
        self.repository = repository
        self.document = document
        self.readOnly = protected
        self.errorMessage = message
        if !document.types.contains(where: { $0.id == document.preferences.selectedTypeID && !$0.archived }),
           let first = document.types.first(where: { !$0.archived }) {
            self.document.preferences.selectedTypeID = first.id
        }
    }

    var types: [FocusType] { document.types }
    var availableTypes: [FocusType] { types.filter { !$0.archived } }
    var history: [FocusRecord] { document.history }
    var preferences: FocusPreferences { document.preferences }
    var selectedType: FocusType { availableTypes.first(where: { $0.id == preferences.selectedTypeID }) ?? availableTypes.first ?? FocusType.defaults[0] }

    // All mutations and disk writes are serialized on MainActor. At this scale,
    // synchronous atomic commits also make termination and checkpoint ordering explicit.
    @discardableResult
    func transaction(_ change: (inout FocusDocument) -> Void) -> Bool {
        guard !readOnly, let repository else { return false }
        var next = document
        change(&next)
        next.revision += 1
        do {
            try repository.save(next)
            document = next
            errorMessage = ""
            return true
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)。当前操作未提交，请重试。"
            return false
        }
    }

    func setPreferences(_ change: (inout FocusPreferences) -> Void) {
        if transaction({ change(&$0.preferences) }) { onPreferencesChanged?() }
    }

    func select(_ id: UUID) {
        guard availableTypes.contains(where: { $0.id == id }) else { return }
        setPreferences { $0.selectedTypeID = id }
    }

    @discardableResult
    func saveType(id: UUID?, name: String, symbol: String, minutes: Int) -> Bool {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty else { errorMessage = "请填写专注类型名称。"; return false }
        guard FocusType.symbols.contains(symbol) else { errorMessage = "请从图标列表选择一个图标。"; return false }
        let result = transaction { data in
            if let id, let index = data.types.firstIndex(where: { $0.id == id }) {
                data.types[index].name = name
                data.types[index].symbol = symbol
                data.types[index].minutes = min(180, max(1, minutes))
            } else {
                data.types.append(.init(id: UUID(), name: name, symbol: symbol, minutes: min(180, max(1, minutes))))
            }
        }
        if result { onPreferencesChanged?() }
        return result
    }

    var historicalTypes: [FocusType] {
        var result = types
        var seen = Set(result.map(\.id))
        for record in document.history + [document.active].compactMap({ $0 }) {
            if seen.insert(record.typeID).inserted {
                result.append(.init(id: record.typeID, name: record.typeName + "（已删除）", symbol: record.symbol,
                                    minutes: max(1, Int(record.plannedSeconds / 60)), archived: true))
            }
        }
        return result
    }

    @discardableResult
    func deleteType(_ type: FocusType) -> Bool {
        guard types.contains(where: { $0.id == type.id }) else { return false }
        if !type.archived && availableTypes.count <= 1 {
            errorMessage = "至少保留一种可用类型，请先新增其他类型再删除。"
            return false
        }
        let saved = transaction { data in
            data.types.removeAll { $0.id == type.id }
            if data.preferences.selectedTypeID == type.id, let next = data.types.first(where: { !$0.archived }) {
                data.preferences.selectedTypeID = next.id
            }
        }
        if saved { onPreferencesChanged?() }
        return saved
    }

    func archive(_ type: FocusType) {
        if !type.archived && availableTypes.count <= 1 {
            errorMessage = "至少保留一种可用的专注类型。"
            return
        }
        if transaction({ data in
            guard let index = data.types.firstIndex(where: { $0.id == type.id }) else { return }
            data.types[index].archived.toggle()
            if !data.types.contains(where: { $0.id == data.preferences.selectedTypeID && !$0.archived }),
               let first = data.types.first(where: { !$0.archived }) { data.preferences.selectedTypeID = first.id }
        }) { onPreferencesChanged?() }
    }
}
