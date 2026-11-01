import Foundation
import AppKit

@main
struct CoordinatorTests {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FocusBar-coordinator-\(UUID().uuidString)")
        let store = FocusStore(directory: directory)
        let timer = TBTimer(store: store)
        timer.suppressAlerts = true
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            count += 1
            print("PASS: \(message)")
        }
        do {
            let durationStore = FocusStore(directory: directory.appendingPathComponent("duration"))
            let durationTimer = TBTimer(store: durationStore)
            durationTimer.suppressAlerts = true
            durationStore.onPreferencesChanged = { durationTimer.settingsChanged() }
            let type = durationStore.selectedType
            check(type.minutes == 25, "new users default to 25 minutes")
            _ = durationStore.saveType(id: type.id, name: type.name, symbol: type.symbol, minutes: 37)
            check(durationTimer.timeLeftString == "37:00", "custom minutes update idle countdown")
            durationTimer.start()
            check(durationTimer.session.duration == 2220, "custom minutes used to start session")
            let id = durationTimer.activeRecord!.id
            _ = durationStore.saveType(id: type.id, name: type.name, symbol: type.symbol, minutes: 15)
            check(durationTimer.session.duration == 2220 && durationTimer.activeRecord!.id == id, "editing duration preserves current round")
            durationTimer.pause()
            let paused = durationTimer.session.remaining
            _ = durationStore.saveType(id: type.id, name: type.name, symbol: type.symbol, minutes: 45)
            check(durationTimer.session.remaining == paused, "editing duration preserves paused remaining")
            _ = durationTimer.end()
            durationTimer.start()
            check(durationTimer.session.duration == 2700, "next round uses updated duration")
            _ = durationTimer.end()
            durationTimer.shutdown()
            let decoded = try JSONDecoder().decode(FocusDocument.self, from: Data(contentsOf: durationStore.directory.appendingPathComponent("focus-data.json")))
            check(decoded.types.first!.minutes == 45, "custom duration persisted")
        }
        do {
            let typeStore = FocusStore(directory: directory.appendingPathComponent("custom-types"))
            let typeTimer = TBTimer(store: typeStore)
            typeTimer.suppressAlerts = true
            typeTimer.start(seconds: 60)
            Thread.sleep(forTimeInterval: 0.02)
            typeTimer.pause()
            let snapshot = typeTimer.activeRecord!
            check(typeStore.saveType(id: nil, name: "自由输入 · 练琴 🎹", symbol: "music.note", minutes: 35), "free name and selected icon accepted")
            let custom = typeStore.types.last!
            for type in FocusType.defaults { check(typeStore.deleteType(type), "default type can be deleted: \(type.name)") }
            check(typeStore.availableTypes.count == 1 && typeStore.selectedType.id == custom.id, "custom type replaces defaults and becomes selection")
            check(typeTimer.activeRecord == snapshot && typeTimer.state == .paused, "deleting current type preserves running snapshot")
            check(!typeStore.deleteType(custom), "last usable type protected")
            _ = typeTimer.end()
            check(typeStore.history.first?.typeName == "工作", "deleted type history retained")
            check(typeStore.historicalTypes.contains(where: { $0.id == snapshot.typeID }), "deleted type remains filterable in history")
            let decoded = try JSONDecoder().decode(FocusDocument.self, from: Data(contentsOf: typeStore.directory.appendingPathComponent("focus-data.json")))
            check(decoded.types == [custom] && decoded.types[0].symbol == "music.note", "custom icon and removed defaults persist")
            typeTimer.shutdown()
        }
        timer.start(seconds: 1)
        Thread.sleep(forTimeInterval: 0.08)
        timer.pause()
        let first = timer.activeRecord!.seconds
        check(abs(first - (timer.session.duration - timer.session.remaining)) < 0.002, "pause clock matches ledger")
        Thread.sleep(forTimeInterval: 0.03)
        timer.updateTimeLeft()
        check(timer.activeRecord!.seconds == first, "paused ledger frozen")
        timer.startStop()
        Thread.sleep(forTimeInterval: 0.06)
        timer.pause()
        check(abs(timer.activeRecord!.seconds - (timer.session.duration - timer.session.remaining)) < 0.002, "multiple resumes match ledger")
        check(timer.end(), "partial round saved")
        check(store.history.count == 1 && store.history[0].outcome == .ended, "partial outcome preserved")
        timer.start(seconds: 1)
        Thread.sleep(forTimeInterval: 1.1)
        timer.updateTimeLeft()
        check(timer.state == .completed && timer.activeRecord == nil, "completion committed")
        check(store.history.count == 2 && abs(store.history.last!.seconds - 1) < 0.001, "late tick clipped to planned seconds")
        check(store.history.last!.segments.last!.end == store.history.last!.endedAt, "completion wall date clipped")
        timer.updateTimeLeft()
        check(store.history.count == 2, "completion idempotent")
        timer.start(seconds: 1)
        Thread.sleep(forTimeInterval: 0.04)
        timer.start(seconds: 1)
        check(store.history.count == 3 && store.history.last!.outcome == .ended, "restart saves partial old round")
        let file = directory.appendingPathComponent("focus-data.json")
        let displaced = directory.appendingPathComponent("saved-before-fault.json")
        try FileManager.default.moveItem(at: file, to: displaced)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        Thread.sleep(forTimeInterval: 1.1)
        timer.updateTimeLeft()
        check(timer.activeRecord?.outcome == .completed && timer.state == .completed, "disk failure retains completed in memory")
        check(!store.errorMessage.isEmpty, "disk failure visible")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: displaced, to: file)
        timer.updateTimeLeft()
        check(timer.activeRecord == nil && store.history.count == 4, "retry commits once after storage repaired")
        timer.start(seconds: 60)
        Thread.sleep(forTimeInterval: 0.04)
        check(timer.prepareToQuit(), "quit flush succeeds")
        check(store.history.last!.outcome == .interrupted, "quit preserves interruption outcome")
        check(store.document.active == nil, "quit clears checkpoint atomically")
        timer.shutdown()
        print("\(count) coordinator checks passed")
    }
}
