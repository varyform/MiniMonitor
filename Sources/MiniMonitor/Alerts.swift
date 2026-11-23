import Foundation
import UserNotifications

/// macOS notifications for what the watchdog finds. Silent outside an app bundle
/// (swift run, tests), where UNUserNotificationCenter would crash.
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    var onQuitBrowsers: () -> Void = {}
    var onIgnore: (String) -> Void = { _ in }
    var onShow: () -> Void = {}

    private static let staleCategory = "stale"
    private static let loadCategory = "load"
    private static let staleID = "stale-browsers"
    private let center: UNUserNotificationCenter?

    override init() {
        center = Bundle.main.bundleIdentifier == nil ? nil : .current()
        super.init()
        guard let center else { return }
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.staleCategory,
                actions: [
                    UNNotificationAction(
                        identifier: "quit", title: "Quit Now", options: .destructive)
                ], intentIdentifiers: []),
            UNNotificationCategory(
                identifier: Self.loadCategory,
                actions: [UNNotificationAction(identifier: "ignore", title: "Ignore This App")],
                intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func staleBrowsers(_ browsers: [StaleBrowser], quitIn delay: TimeInterval) {
        let processes = browsers.reduce(0) { $0 + $1.processes.count }
        let cpu = browsers.reduce(0) { $0 + $1.cpu }
        let one = browsers.count == 1
        post(
            id: Self.staleID, category: Self.staleCategory,
            title: one
                ? "A stale test browser is using CPU"
                : "\(browsers.count) stale test browsers are using CPU",
            body: "Headless Chrome left by a killed test run: \(processes) processes at "
                + "\(percent(cpu)) CPU. Quitting \(one ? "it" : "them") in "
                + "\(Int(delay / 60)) minutes.")
    }

    func quitBrowsers(_ count: Int) {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.staleID])
        post(
            id: "stale-quit", category: nil,
            title: count == 1 ? "Quit a stale test browser" : "Quit \(count) stale test browsers",
            body: "Killed test runs had left \(count == 1 ? "it" : "them") running.")
    }

    func unusualLoad(_ episode: LoadWatch.Episode, app: String) {
        var usage = ["\(percent(episode.cpu)) CPU"]
        if episode.gpu >= 0.05 { usage.append("\(percent(episode.gpu)) GPU") }
        let detail = episode.name == app ? "" : ", mostly \(episode.name)"
        post(
            id: Self.loadID(episode.group), category: Self.loadCategory,
            title: "\(app) is busy while you're away",
            body: "\(usage.joined(separator: " and ")) for the last 5 minutes\(detail).",
            userInfo: ["group": episode.group])
    }

    /// Takes back everything shown, for when watching is turned off.
    func clearAll() {
        center?.removeAllDeliveredNotifications()
    }

    func clearLoad(_ group: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.loadID(group)])
    }

    private static func loadID(_ group: String) -> String { "load:\(group)" }

    private func post(
        id: String, category: String?, title: String, body: String, userInfo: [String: String] = [:]
    ) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        if let category { content.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) ->
            Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let group = response.notification.request.content.userInfo["group"] as? String
        DispatchQueue.main.async { [self] in
            switch action {
            case "quit": onQuitBrowsers()
            case "ignore": if let group { onIgnore(group) }
            case UNNotificationDefaultActionIdentifier: onShow()
            default: break
            }
        }
        completionHandler()
    }
}

/// "140%" for 1.4 cores, as Activity Monitor counts.
func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }
