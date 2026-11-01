import Darwin
import SwiftUI

@MainActor
final class TBTimer: ObservableObject {
    let store: FocusStore
    @Published private(set) var session = TBFocusSession()
    @Published private(set) var activeRecord: FocusRecord?
    @Published var notificationStatus = ""
    @Published var hotKeyAvailable = false
    @Published var draftTitle = ""
    @Published var recoveryMessage = ""
    var onUpdate: (() -> Void)?
    var onOpen: (() -> Void)?
    var suppressAlerts = false

    private let notificationCenter = TBNotificationCenter()
    private let player = TBPlayer()
    private var sessionSound = true
    private var sessionNotification = true
    private var timer: DispatchSourceTimer?
    private var clockInfo = mach_timebase_info_data_t()
    private var observers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?
    private var segmentStart: Date?
    private var segmentClock: Double?
    private var segmentIndex: Int?
    private var baseSeconds = 0.0
    private var lastCheckpoint = 0.0

    init(store: FocusStore) {
        self.store = store
        mach_timebase_info(&clockInfo)
        sessionSound = store.preferences.sound
        sessionNotification = store.preferences.notifications
        lastCheckpoint = now
        notificationCenter.onOpen = { [weak self] in self?.onOpen?() }
        notificationCenter.onStatus = { [weak self] in self?.notificationStatus = $0 }
        if Bundle.main.bundleURL.pathExtension == "app" { notificationCenter.clearLegacyRequests() }
        if let active = store.document.active {
            activeRecord = active
            sessionSound = active.soundSnapshot ?? store.preferences.sound
            sessionNotification = active.notificationSnapshot ?? store.preferences.notifications
            session.restore(seconds: active.plannedSeconds, elapsed: active.seconds)
            recoveryMessage = "已恢复上次保存的进度，离线时间未计入。可继续或结束保存。"
            if session.state == .completed {
                activeRecord?.outcome = .completed
                activeRecord?.endedAt = active.endedAt ?? active.segments.last?.end ?? active.startedAt
                if !store.readOnly { startTimer() }
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseForAbsence() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseForAbsence() }
        })
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseForAbsence() }
        }
    }

    var state: TBFocusState { session.state }
    var progress: Double { session.progress }
    var minutes: Int { store.selectedType.minutes }
    var currentName: String { activeRecord?.typeName ?? store.selectedType.name }
    var allRecords: [FocusRecord] {
        var records = store.history
        if let activeRecord, !records.contains(where: { $0.id == activeRecord.id }) { records.append(activeRecord) }
        return records
    }
    var timeLeftString: String {
        let seconds = Int(ceil(state == .idle ? Double(minutes * 60) : session.remaining))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var primaryTitle: String {
        switch state {
        case .idle: return "开始 \(minutes) 分钟"
        case .running: return "暂停一下"
        case .paused: return "继续专注"
        case .completed: return "再来 \(minutes) 分钟"
        }
    }
    var primarySymbol: String { state == .running ? "pause.fill" : "play.fill" }
    private var now: Double { Double(mach_continuous_time()) * Double(clockInfo.numer) / Double(clockInfo.denom) / 1_000_000_000 }

    func startStop() {
        guard !store.readOnly else { return }
        switch state {
        case .idle, .completed: start()
        case .running: pause()
        case .paused:
            guard activeRecord != nil else { return }
            let clock = now
            let date = Date()
            session.resume(now: clock)
            openSegment(clock: clock, date: date)
            recoveryMessage = ""
            persistActive()
            scheduleNotification()
            startTimer()
            publish()
        }
    }

    func start(seconds: Double? = nil) {
        guard !store.readOnly else { return }
        let clock = now
        let date = Date()
        if state == .running { updateSegment(clock: clock, date: date) }
        var ended = activeRecord
        if ended != nil, ended?.outcome != .completed {
            let completed = state == .completed || (session.deadline.map { clock >= $0 } ?? false)
            ended?.endedAt = completed ? completionDate(clock: clock, date: date) : date
            ended?.outcome = completed ? .completed : .ended
        }
        let type = store.selectedType
        let requested = seconds ?? Double(type.minutes * 60)
        let length = requested.isFinite ? min(10800, max(1, requested)) : 1500
        var record = FocusRecord(typeID: type.id, typeName: type.name, symbol: type.symbol,
                                 title: String(draftTitle.prefix(160)), plannedSeconds: length, startedAt: Date())
        record.notificationSnapshot = store.preferences.notifications
        record.soundSnapshot = store.preferences.sound
        guard store.transaction({ data in
            if let ended, ended.seconds > 0, !data.history.contains(where: { $0.id == ended.id }) { data.history.append(ended) }
            data.active = record
        }) else { publish(); return }
        stopTimer()
        notificationCenter.cancel()
        closeSegment()
        activeRecord = record
        let startClock = now
        let startDate = Date()
        session.start(seconds: length, now: startClock)
        sessionSound = store.preferences.sound
        sessionNotification = store.preferences.notifications
        recoveryMessage = ""
        openSegment(clock: startClock, date: startDate)
        lastCheckpoint = startClock
        scheduleNotification()
        startTimer()
        publish()
    }

    func pause() {
        guard state == .running else { return }
        let clock = now
        let date = Date()
        updateTimeLeft(clock: clock, date: date)
        guard state == .running else { return }
        session.pause(now: clock)
        closeSegment()
        stopTimer()
        notificationCenter.cancel()
        persistActive()
        publish()
    }

    func end(outcome: FocusOutcome = .ended) -> Bool {
        if state == .running { pause() }
        guard var record = activeRecord else { return true }
        closeSegment()
        if record.outcome != .completed {
            record.endedAt = Date()
            record.outcome = outcome
        }
        guard store.transaction({ data in
            if record.seconds > 0, !data.history.contains(where: { $0.id == record.id }) { data.history.append(record) }
            data.active = nil
        }) else { pause(); return false }
        stopTimer()
        notificationCenter.cancel()
        activeRecord = nil
        session.reset(seconds: Double(minutes * 60))
        recoveryMessage = ""
        publish()
        return true
    }

    func updateTimeLeft() {
        updateTimeLeft(clock: now, date: Date())
    }

    private func updateTimeLeft(clock: Double, date: Date) {
        if state == .completed {
            if activeRecord?.outcome == .completed { _ = persistCompletion() }
            publish()
            return
        }
        guard state == .running else { return }
        let deadline = session.deadline
        updateSegment(clock: clock, date: date)
        let completed = session.refresh(now: clock)
        if completed {
            closeSegment()
            if var record = activeRecord {
                let lateness = max(0, clock - (deadline ?? clock))
                record.endedAt = record.segments.last?.end ?? date.addingTimeInterval(-lateness)
                record.outcome = .completed
                activeRecord = record
                _ = persistCompletion()
                if lateness <= 60, sessionSound, !suppressAlerts { player.playDing() }
                if lateness > 60 { notificationCenter.cancel() }
            } else { stopTimer() }
        } else if clock - lastCheckpoint >= 15 {
            persistActive()
        }
        publish()
    }

    func settingsChanged() {
        if state == .idle { session.reset(seconds: Double(minutes * 60)) }
        publish()
    }

    func prepareToQuit() -> Bool {
        if store.readOnly { return true }
        return end(outcome: .interrupted)
    }

    func shutdown() {
        stopTimer()
        notificationCenter.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        lockObserver = nil
    }

    private func pauseForAbsence() {
        if state == .running {
            pause()
            recoveryMessage = "系统休眠或锁屏已暂停，回来后可手动继续。"
        }
    }

    private func openSegment(clock: Double, date: Date) {
        baseSeconds = activeRecord?.seconds ?? 0
        segmentStart = date
        segmentClock = clock
        activeRecord?.segments.append(.init(start: segmentStart!, end: segmentStart!, seconds: 0))
        segmentIndex = (activeRecord?.segments.count ?? 1) - 1
    }

    private func updateSegment(clock: Double, date: Date) {
        guard let index = segmentIndex, let start = segmentStart, let startClock = segmentClock,
              let record = activeRecord, record.segments.indices.contains(index) else { return }
        let effectiveClock = min(clock, session.deadline ?? clock)
        let seconds = min(max(0, effectiveClock - startClock), max(0, record.plannedSeconds - baseSeconds))
        let expected = start.addingTimeInterval(seconds)
        let clippedDate = date.addingTimeInterval(-max(0, clock - effectiveClock))
        // An adjusted system clock must not create negative or inflated durations.
        let mappedEnd = abs(clippedDate.timeIntervalSince(expected)) < 5 ? clippedDate : expected
        activeRecord?.segments[index] = .init(start: start, end: mappedEnd, seconds: seconds)
    }

    private func closeSegment() {
        segmentStart = nil
        segmentClock = nil
        segmentIndex = nil
    }

    private func completionDate(clock: Double, date: Date) -> Date {
        activeRecord?.segments.last?.end ?? date.addingTimeInterval(-max(0, clock - (session.deadline ?? clock)))
    }

    @discardableResult
    private func persistCompletion() -> Bool {
        guard let record = activeRecord, record.outcome == .completed else { return true }
        guard store.transaction({ data in
            if !data.history.contains(where: { $0.id == record.id }) { data.history.append(record) }
            data.active = nil
        }) else {
            recoveryMessage = "本轮已完成，但未保存成功；正在自动重试，请保留应用。"
            return false
        }
        activeRecord = nil
        recoveryMessage = ""
        stopTimer()
        return true
    }

    private func persistActive() {
        let snapshot = activeRecord
        if store.transaction({ $0.active = snapshot }) { lastCheckpoint = now }
    }

    private func startTimer() {
        stopTimer()
        let generation = session.generation
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 0.2, repeating: 1, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            guard let self, self.session.generation == generation,
                  self.state == .running || (self.state == .completed && self.activeRecord?.outcome == .completed) else { return }
            self.updateTimeLeft()
        }
        timer = source
        source.resume()
    }

    private func stopTimer() { timer?.setEventHandler {}; timer?.cancel(); timer = nil }
    private func scheduleNotification() {
        guard sessionNotification, !suppressAlerts else { return }
        notificationCenter.schedule(seconds: session.remaining, minutes: Int(ceil(session.duration / 60)))
    }
    private func publish() { onUpdate?() }
}
