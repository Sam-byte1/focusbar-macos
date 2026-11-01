import Foundation

enum TBFocusState: String {
    case idle, running, paused, completed

    var label: String {
        switch self {
        case .idle: return "准备开始"
        case .running: return "正在专注"
        case .paused: return "已暂停"
        case .completed: return "本轮已完成"
        }
    }
}

// Pure session state. The caller supplies a continuous clock that includes sleep.
struct TBFocusSession {
    private(set) var state: TBFocusState = .idle
    private(set) var duration: TimeInterval = 1500
    private(set) var remaining: TimeInterval = 1500
    private(set) var deadline: TimeInterval?
    private(set) var generation = 0

    var progress: Double {
        if state == .completed { return 1 }
        return min(1, max(0, 1 - remaining / duration))
    }

    mutating func start(seconds: TimeInterval, now: TimeInterval) {
        generation += 1
        duration = seconds.isFinite ? min(10800, max(1, seconds)) : 1500
        remaining = duration
        deadline = now + duration
        state = .running
    }

    // Returns true exactly once per session when its deadline is reached.
    @discardableResult
    mutating func refresh(now: TimeInterval) -> Bool {
        guard state == .running, let deadline else { return false }
        remaining = min(duration, max(0, deadline - now))
        guard remaining == 0 else { return false }
        state = .completed
        self.deadline = nil
        return true
    }

    @discardableResult
    mutating func pause(now: TimeInterval) -> Bool {
        let completed = refresh(now: now)
        guard state == .running else { return completed }
        state = .paused
        deadline = nil
        generation += 1
        return false
    }

    mutating func resume(now: TimeInterval) {
        guard state == .paused else { return }
        generation += 1
        deadline = now + remaining
        state = .running
    }

    mutating func restore(seconds: TimeInterval, elapsed: TimeInterval) {
        reset(seconds: seconds)
        remaining = max(0, duration - max(0, elapsed))
        state = remaining == 0 ? .completed : .paused
    }

    mutating func reset(seconds: TimeInterval = 1500) {
        generation += 1
        duration = seconds.isFinite ? min(10800, max(1, seconds)) : 1500
        remaining = duration
        deadline = nil
        state = .idle
    }
}
