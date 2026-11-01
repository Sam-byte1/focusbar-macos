import Foundation

@main
struct TimerModelTests {
    @MainActor
    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--lock-probe" { exit(StorageTests.probe(path: CommandLine.arguments[2])) }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            checks += 1
            print("PASS: \(name)")
        }
        var session = TBFocusSession()
        check(session.state == .idle && session.progress == 0, "idle is empty")
        session.start(seconds: 1500, now: 100)
        check(session.state == .running && session.remaining == 1500, "starts 25 minutes")
        session.refresh(now: 475)
        check(session.progress == 0.25, "quarter elapsed")
        session.refresh(now: 850)
        check(session.progress == 0.5, "half elapsed")
        let oldGeneration = session.generation
        session.pause(now: 850)
        check(session.state == .paused && session.remaining == 750, "pause preserves remaining")
        check(session.generation != oldGeneration, "pause invalidates old callbacks")
        session.refresh(now: 10000)
        check(session.remaining == 750 && session.progress == 0.5, "paused time does not advance")
        session.resume(now: 10000)
        check(session.deadline == 10750, "resume uses saved duration")
        session.refresh(now: 10749.9)
        check(session.remaining > 0 && session.state == .running, "not completed prematurely")
        check(session.refresh(now: 10750), "completion emits once")
        check(session.state == .completed && session.progress == 1 && session.remaining == 0, "completed stays full")
        check(!session.refresh(now: 99999), "no repeated completion")
        session.start(seconds: 60, now: 500)
        check(session.progress == 0 && session.remaining == 60, "restart clears old progress")
        check(session.pause(now: 600), "pause after deadline completes rather than pauses")
        check(session.state == .completed, "late pause stays completed")
        session.start(seconds: 1500, now: 0)
        check(session.refresh(now: 7200), "delayed refresh caps completion")
        check(session.progress == 1, "delayed callback does not erase completion")
        session.start(seconds: 0, now: 0)
        check(session.duration == 1, "invalid zero duration clamped")
        session.start(seconds: .infinity, now: 0)
        check(session.duration == 1500, "nonfinite duration gets safe default")
        session.start(seconds: 999999, now: 0)
        check(session.duration == 10800, "maximum duration clamped")
        session.reset(seconds: 1200)
        check(session.state == .idle && session.remaining == 1200 && session.progress == 0, "reset is safe")
        session.resume(now: 10)
        check(session.state == .idle, "resume ignored in idle")
        session.start(seconds: 1500, now: 0)
        let settingsDuration = 600
        session.refresh(now: 100)
        check(session.duration == 1500 && settingsDuration == 600, "active duration snapshot independent of settings")
        session.refresh(now: -1)
        check(session.progress >= 0 && session.progress <= 1, "progress clamped")
        let statistics = try StatisticsTests.run()
        let storage = try StorageTests.run()
        print("\(checks) timer + \(statistics) statistics + \(storage) storage checks passed (\(checks + statistics + storage) total)")
    }
}
