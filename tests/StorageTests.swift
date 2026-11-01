import Foundation
import Combine
import Darwin

@MainActor
enum StorageTests {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func probe(path: String) -> Int32 {
        let descriptor = Darwin.open(path, O_RDWR)
        guard descriptor >= 0 else { return 21 }
        let result = flock(descriptor, LOCK_EX | LOCK_NB)
        let denied = result == -1 && (errno == EWOULDBLOCK || errno == EAGAIN)
        if result == 0 { _ = flock(descriptor, LOCK_UN) }
        _ = Darwin.close(descriptor)
        return denied ? 0 : 22
    }

    static func run() throws -> Int {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("FocusStorageTests-\(UUID().uuidString)", isDirectory: true)
        // Never reuse an existing directory, and only remove this run's own fixtures.
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        var checks = 0

        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw Failure(description: "StorageTests: \(name)") }
            checks += 1
        }

        func expect(_ expected: FocusStorageError, _ name: String, _ action: () throws -> Void) throws {
            do {
                try action()
            } catch let error as FocusStorageError {
                let matches: Bool
                switch (expected, error) {
                case (.locked, .locked), (.invalid, .invalid), (.version, .version): matches = true
                default: matches = false
                }
                try check(matches, "\(name): unexpected storage error \(error)")
                return
            } catch {
                throw Failure(description: "\(name): unexpected error \(error)")
            }
            throw Failure(description: "\(name): expected an error")
        }

        func directory(_ name: String) -> URL {
            root.appendingPathComponent(name, isDirectory: true)
        }
        func primary(_ directory: URL) -> URL {
            directory.appendingPathComponent("focus-data.json")
        }
        func backup(_ directory: URL) -> URL {
            directory.appendingPathComponent("focus-data.backup.json")
        }
        func encoded(_ document: FocusDocument) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(document)
        }
        func fixture(_ data: Data, in directory: URL) throws {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            try data.write(to: primary(directory))
        }
        func record(completed: Bool = false) -> FocusRecord {
            let start = Date(timeIntervalSince1970: 1_750_000_000)
            return FocusRecord(
                typeID: FocusType.defaults[0].id,
                typeName: "工作快照",
                symbol: "laptopcomputer",
                title: "存储测试：中文 / unicode ✓",
                plannedSeconds: 1500,
                startedAt: start,
                endedAt: completed ? start.addingTimeInterval(1500) : nil,
                outcome: completed ? .completed : nil,
                segments: [.init(start: start, end: start.addingTimeInterval(completed ? 1500 : 300), seconds: completed ? 1500 : 300)],
                timeZoneID: "Asia/Shanghai"
            )
        }

        // New visual preferences must not classify an existing schema-1 database as corrupt.
        do {
            var original = FocusDocument()
            original.active = record()
            original.history = [record(completed: true)]
            var json = try JSONSerialization.jsonObject(with: encoded(original)) as! [String: Any]
            var preferences = json["preferences"] as! [String: Any]
            preferences.removeValue(forKey: "menuStyle")
            json["preferences"] = preferences
            let oldData = try JSONSerialization.data(withJSONObject: json)
            let path = directory("legacy-style")
            try fixture(oldData, in: path)
            let repository = try FocusRepository(directory: path)
            let loaded = try repository.load()!
            try check(!repository.readOnly && loaded.preferences.menuStyle == .minimal, "old library defaults to minimal")
            try check(loaded.history == original.history && loaded.active == original.active, "style migration preserves records")
            for style in MenuBarStyle.allCases {
                var next = loaded
                next.preferences.menuStyle = style
                try repository.save(next)
                try check(try repository.load()?.preferences.menuStyle == style, "style roundtrip \(style.rawValue)")
                try check(try repository.load()?.active == original.active, "style never changes active session")
            }
            for value in ["future-neon", "", NSNull()] as [Any] {
                preferences["menuStyle"] = value
                json["preferences"] = preferences
                let data = try JSONSerialization.data(withJSONObject: json)
                let result = try JSONDecoder().decode(FocusDocument.self, from: data)
                try check(result.preferences.menuStyle == .minimal, "unknown or null style falls back")
            }
            preferences["menuStyle"] = 123
            json["preferences"] = preferences
            do {
                _ = try JSONDecoder().decode(FocusDocument.self, from: JSONSerialization.data(withJSONObject: json))
                throw Failure(description: "wrong style type accepted")
            } catch is DecodingError { checks += 1 }
            preferences.removeValue(forKey: "sound")
            preferences["menuStyle"] = "minimal"
            json["preferences"] = preferences
            do {
                _ = try JSONDecoder().decode(FocusDocument.self, from: JSONSerialization.data(withJSONObject: json))
                throw Failure(description: "missing original field accepted")
            } catch is DecodingError { checks += 1 }
        }

        // Fresh storage, complete schema-1 data, and the immediately preceding backup.
        do {
            let path = directory("roundtrip")
            var repository: FocusRepository? = try FocusRepository(directory: path)
            try check(try repository!.load() == nil, "empty repository has no document")
            try check(!manager.fileExists(atPath: primary(path).path), "load does not create a primary")
            var first = FocusDocument()
            first.revision = 7
            first.types[1].archived = true
            first.types[0].minutes = 40
            first.preferences.sound = false
            first.preferences.notifications = false
            first.preferences.hotKeyEnabled = false
            first.preferences.showWindowAtLaunch = false
            first.preferences.menuWidth = 101.5
            first.preferences.menuTime = true
            first.preferences.appearance = "dark"
            first.history = [record(completed: true)]
            first.active = record()
            try repository!.save(first)
            try check(try repository!.load() == first, "schema-1 roundtrip preserves all fields")
            try check(!repository!.readOnly, "valid schema remains writable")
            try check(!manager.fileExists(atPath: backup(path).path), "first save has no fabricated backup")
            let firstBytes = try Data(contentsOf: primary(path))
            var second = first
            second.revision += 1
            second.preferences.selectedTypeID = first.types[2].id
            second.active?.title = "第二版"
            try repository!.save(second)
            try check(try Data(contentsOf: backup(path)) == firstBytes, "backup is exact previous primary bytes")
            try check(try JSONDecoder().decode(FocusDocument.self, from: Data(contentsOf: backup(path))) == first, "backup decodes to previous revision")
            let secondBytes = try Data(contentsOf: primary(path))
            var third = second
            third.revision += 1
            try repository!.save(third)
            try check(try Data(contentsOf: backup(path)) == secondBytes, "each save advances backup by one revision")
            repository = nil
            let reopened = try FocusRepository(directory: path)
            try check(try reopened.load() == third, "released repository reopens and loads latest revision")
            try check(!reopened.readOnly, "reopened valid repository remains writable")
        }

        // A damaged primary may be read from backup, but neither file may be repaired implicitly.
        do {
            let path = directory("corrupt-with-backup")
            let repository = try FocusRepository(directory: path)
            var first = FocusDocument()
            first.revision = 11
            first.active = record()
            try repository.save(first)
            var second = first
            second.revision += 1
            try repository.save(second)
            let savedBackup = try Data(contentsOf: backup(path))
            let damaged = Data("{broken primary; preserve exactly".utf8)
            try damaged.write(to: primary(path))
            try check(try repository.load() == first, "corrupt primary falls back to previous valid document")
            try check(repository.readOnly, "backup recovery is read-only")
            try check(!repository.notice.isEmpty, "backup recovery exposes a notice")
            try expect(.invalid, "recovery rejects save") { try repository.save(second) }
            try check(try Data(contentsOf: primary(path)) == damaged, "recovery preserves damaged primary bytes")
            try check(try Data(contentsOf: backup(path)) == savedBackup, "recovery preserves backup bytes")
            try check(try repository.load() == first, "repeated recovery stays on valid backup")
        }

        do {
            let path = directory("corrupt-no-backup")
            let damaged = Data([0xff, 0x00, 0x7b])
            try fixture(damaged, in: path)
            let repository = try FocusRepository(directory: path)
            try expect(.invalid, "corrupt primary without backup fails load") { _ = try repository.load() }
            try check(repository.readOnly, "unrecoverable primary enables read-only protection")
            try expect(.invalid, "unrecoverable primary rejects save") { try repository.save(FocusDocument()) }
            try check(try Data(contentsOf: primary(path)) == damaged, "unrecoverable primary is not overwritten")
            try check(!manager.fileExists(atPath: backup(path).path), "failed recovery does not fabricate backup")
        }

        do {
            let path = directory("corrupt-both")
            let damaged = Data("not JSON".utf8)
            try fixture(damaged, in: path)
            let badBackup = Data("also not JSON".utf8)
            try badBackup.write(to: backup(path))
            let repository = try FocusRepository(directory: path)
            try expect(.invalid, "invalid backup is not accepted") { _ = try repository.load() }
            try expect(.invalid, "invalid backup does not permit save") { try repository.save(FocusDocument()) }
            try check(try Data(contentsOf: primary(path)) == damaged, "both damaged files: primary preserved")
            try check(try Data(contentsOf: backup(path)) == badBackup, "both damaged files: backup preserved")
        }

        // Unknown schemas must not silently downgrade, even if a schema-1 backup exists.
        for version in [0, 2, 999] {
            let path = directory("schema-\(version)")
            var future = FocusDocument()
            future.schemaVersion = version
            let original = try encoded(future)
            try fixture(original, in: path)
            let goodBackup = try encoded(FocusDocument())
            try goodBackup.write(to: backup(path))
            let repository = try FocusRepository(directory: path)
            try expect(.version, "schema \(version) is rejected") { _ = try repository.load() }
            try check(repository.readOnly, "schema \(version) is protected")
            try expect(.invalid, "schema \(version) rejects replacement save") { try repository.save(FocusDocument()) }
            try check(try Data(contentsOf: primary(path)) == original, "schema \(version) primary not overwritten")
            try check(try Data(contentsOf: backup(path)) == goodBackup, "schema \(version) backup not overwritten")
        }

        // Two independent opens in this process must contend for the same writer lock.
        do {
            let path = directory("writer-lock")
            var owner: FocusRepository? = try FocusRepository(directory: path)
            try owner!.save(FocusDocument())
            try expect(.locked, "second repository in same process is rejected") {
                _ = try FocusRepository(directory: path)
            }
            try check(try owner!.load() == FocusDocument(), "rejected writer leaves owner functional")

            // Re-execute the test binary in probe mode; the main entry point handles
            // --lock-probe before running suites, so the child only tests the writer lock.
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--lock-probe", path.appendingPathComponent("writer.lock").path]
            try child.run()
            child.waitUntilExit()
            try check(child.terminationReason == .exit && child.terminationStatus == 0, "flock denies second process writer")
            owner = nil
            let reopened = try FocusRepository(directory: path)
            try check(try reopened.load() != nil, "lock releases after repository deinit")
            var next = FocusDocument()
            next.revision = 1
            try reopened.save(next)
            try check(try reopened.load() == next, "reopened repository can commit")
        }

        // Validation runs before replacing primary or rotating backup, including nonfinite values.
        do {
            let path = directory("invalid-duration")
            let repository = try FocusRepository(directory: path)
            var baseline = FocusDocument()
            baseline.active = record()
            baseline.history = [record(completed: true)]
            try repository.save(FocusDocument())
            try repository.save(baseline)
            let savedPrimary = try Data(contentsOf: primary(path))
            let savedBackup = try Data(contentsOf: backup(path))
            var invalid: [(String, FocusDocument)] = []
            for value in [0.0, -1, Double.infinity, -Double.infinity, Double.nan] {
                var active = baseline
                active.active?.plannedSeconds = value
                invalid.append(("active plannedSeconds \(value)", active))
                var history = baseline
                history.history[0].plannedSeconds = value
                invalid.append(("history plannedSeconds \(value)", history))
            }
            for value in [-1.0, Double.infinity, -Double.infinity, Double.nan] {
                var active = baseline
                active.active?.segments[0].seconds = value
                invalid.append(("active segment seconds \(value)", active))
                var history = baseline
                history.history[0].segments[0].seconds = value
                invalid.append(("history segment seconds \(value)", history))
            }
            for minutes in [0, 181] {
                var document = baseline
                document.types[0].minutes = minutes
                invalid.append(("type minutes \(minutes)", document))
            }
            for (label, document) in invalid {
                try expect(.invalid, "reject \(label)") { try repository.save(document) }
                try check(try Data(contentsOf: primary(path)) == savedPrimary, "\(label) preserves primary")
                try check(try Data(contentsOf: backup(path)) == savedBackup, "\(label) preserves previous backup")
            }
            try check(!repository.readOnly, "bad save does not poison an otherwise valid repository")
            try check(try repository.load() == baseline, "valid baseline survives rejected saves")
        }

        do {
            let path = directory("invalid-loaded-duration")
            var invalid = FocusDocument()
            invalid.active = record()
            invalid.active?.plannedSeconds = 0
            let original = try encoded(invalid)
            try fixture(original, in: path)
            let repository = try FocusRepository(directory: path)
            try expect(.invalid, "decoded invalid duration is rejected") { _ = try repository.load() }
            try check(repository.readOnly, "decoded invalid duration enables protection")
            try expect(.invalid, "invalid loaded duration cannot be overwritten") { try repository.save(FocusDocument()) }
            try check(try Data(contentsOf: primary(path)) == original, "invalid loaded duration preserves original bytes")
        }

        // Exercise store transactions without the application or timer side effects. The UUID
        // guard mirrors the completion transaction; the repository itself does not deduplicate.
        do {
            let path = directory("completion-transaction")
            var initial = FocusDocument()
            var active = record(completed: true)
            active.endedAt = nil
            active.outcome = nil
            initial.active = active
            try fixture(try encoded(initial), in: path)
            let store = FocusStore(directory: path)
            try check(!store.readOnly && store.document == initial, "store loads supplied temporary document without migration")
            var finished = active
            finished.endedAt = active.startedAt.addingTimeInterval(active.plannedSeconds)
            finished.outcome = .completed
            for _ in 0..<2 {
                let committed = store.transaction { document in
                    if !document.history.contains(where: { $0.id == finished.id }) {
                        document.history.append(finished)
                    }
                    document.active = nil
                }
                try check(committed, "completion transaction commits")
            }
            try check(store.history.count == 1 && store.history[0] == finished, "replayed completion UUID is recorded only once")
            try check(store.document.active == nil, "completion transaction clears active atomically")
            try check(store.document.revision == initial.revision + 2, "successful transactions advance revision")
            let disk = try store.repository!.load()
            try check(disk == store.document, "deduplicated completion and active removal persist together")
            let previous = try JSONDecoder().decode(FocusDocument.self, from: Data(contentsOf: backup(path)))
            try check(previous.history == [finished] && previous.active == nil, "backup also contains single completed UUID")
        }

        // Recover using persisted monotonic seconds, not wall-clock time since the last launch.
        do {
            let path = directory("restore-state")
            let repository = try FocusRepository(directory: path)
            var document = FocusDocument()
            document.active = record()
            try repository.save(document)
            guard let paused = try repository.load()?.active else {
                throw Failure(description: "restore fixture lost active record")
            }
            var session = TBFocusSession()
            session.start(seconds: 60, now: 100)
            let generation = session.generation
            session.restore(seconds: paused.plannedSeconds, elapsed: paused.seconds)
            try check(session.state == .paused && session.remaining == 1200, "partial active record restores paused")
            try check(session.deadline == nil && session.duration == 1500, "restore removes stale deadline and preserves duration")
            try check(session.generation > generation, "restore invalidates old callbacks")
            try check(abs(session.progress - 0.2) < 0.000001, "restore uses persisted segment seconds")
            try check(!session.refresh(now: 9_000_000) && session.remaining == 1200, "offline time is not added to paused record")
            session.resume(now: 10_000)
            try check(session.state == .running && session.deadline == 11_200, "restored paused state resumes from saved remaining time")

            document.active = record(completed: true)
            try repository.save(document)
            guard let completed = try repository.load()?.active else {
                throw Failure(description: "completed restore fixture lost active record")
            }
            session.restore(seconds: completed.plannedSeconds, elapsed: completed.seconds)
            try check(session.state == .completed && session.remaining == 0 && session.progress == 1, "full active record restores completed")
            try check(session.deadline == nil, "completed restore has no running deadline")
            try check(!session.refresh(now: 99_999), "restored completion does not emit a second completion")
            session.resume(now: 99_999)
            try check(session.state == .completed && session.deadline == nil, "completed restore cannot resume")
            session.restore(seconds: 1500, elapsed: 1800)
            try check(session.state == .completed && session.remaining == 0, "overrun elapsed restores completed without negative remaining")
        }

        return checks
    }
}
