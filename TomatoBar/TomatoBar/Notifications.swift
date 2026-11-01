import AppKit
import UserNotifications

@MainActor
final class TBNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    private lazy var center = UNUserNotificationCenter.current()
    private var requestID: String?
    private var revision = 0
    private var scheduling: Task<Void, Never>?
    var onOpen: (() -> Void)?
    var onStatus: ((String) -> Void)?

    override init() {
        super.init()
    }

    func clearLegacyRequests() {
        center.getPendingNotificationRequests { [weak self] requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix("focus-") }
            Task { @MainActor in
                guard let self else { return }
                self.center.removePendingNotificationRequests(withIdentifiers: ids.filter { $0 != self.requestID })
            }
        }
    }

    func schedule(seconds: TimeInterval, minutes: Int) {
        cancel()
        center.delegate = self
        let currentRevision = revision
        let id = "focus-\(UUID().uuidString)"
        requestID = id
        let end = Date().addingTimeInterval(seconds)
        scheduling = Task { [weak self] in
            guard let self else { return }
            do {
                let granted = try await center.requestAuthorization(options: [.alert])
                guard revision == currentRevision, !Task.isCancelled else { return }
                guard granted else {
                    onStatus?("通知未获允许；完成后仍会保留满条。")
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = "这一轮，完成了。"
                content.body = "已完成 \(minutes) 分钟专注，可以停一下，或再来一轮。"
                // Sound is played once by the session owner, never by both channels.
                let delay = end.timeIntervalSinceNow
                // An authorization dialog can outlive a short session.
                guard delay > -60 else { return }
                let trigger = delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false) : nil
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                if revision != currentRevision || Task.isCancelled {
                    center.removePendingNotificationRequests(withIdentifiers: [id])
                    center.removeDeliveredNotifications(withIdentifiers: [id])
                } else {
                    onStatus?("")
                }
            } catch {
                if revision == currentRevision {
                    onStatus?("系统通知暂不可用；完成后仍会保留满条。")
                }
            }
        }
    }

    func cancel() {
        revision += 1
        scheduling?.cancel()
        scheduling = nil
        if let requestID {
            center.removePendingNotificationRequests(withIdentifiers: [requestID])
            center.removeDeliveredNotifications(withIdentifiers: [requestID])
        }
        requestID = nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor [weak self] in self?.onOpen?() }
        completionHandler()
    }
}
