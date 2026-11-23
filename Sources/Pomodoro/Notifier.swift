import AppKit
import UserNotifications

enum SoundPlayer {
    static let none = "None"
    static let names = [none, "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    static func play(_ name: String) {
        guard name != none, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.stop()
        sound.play()
    }
}

/// Posts macOS notifications. Sounds are played separately by `SoundPlayer`
/// so they work even when notifications are muted or in Focus mode.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// UNUserNotificationCenter crashes when the process isn't a bundled app (e.g. `swift run`).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func announce(finished: Phase, next: Phase, nextMinutes: Int, autoStarted: Bool, todayCount: Int,
                  progress: String? = nil, tip: String? = nil, goalReached: Bool = false) {
        let title: String
        var body: String
        switch finished {
        case .focus:
            title = goalReached ? "Daily goal reached 🏆"
                : next == .longBreak ? "Full cycle complete 🎉" : "Pomodoro complete 🍅"
            let breakKind = next == .longBreak ? "long break" : "short break"
            let countText = todayCount == 1 ? "1 pomodoro" : "\(todayCount) pomodoros"
            if next == .longBreak {
                body = autoStarted
                    ? "\(countText) today. Your \(nextMinutes)-minute long break has started."
                    : "\(countText) today. Time for a \(nextMinutes)-minute long break."
            } else {
                let lead = progress.map { "\($0). " } ?? ""
                body = autoStarted
                    ? "\(lead)Your \(nextMinutes)-minute \(breakKind) has started."
                    : "\(lead)Time for a \(nextMinutes)-minute \(breakKind)."
            }
            if let tip { body += "\nBreak idea: \(tip)." }
        case .shortBreak, .longBreak:
            title = "Break's over"
            body = autoStarted
                ? "Your next \(nextMinutes)-minute focus session has started."
                : "Ready for the next \(nextMinutes)-minute focus session?"
        }
        post(title: title, body: body, identifier: "phase-end")
    }

    func post(title: String, body: String, identifier: String = UUID().uuidString) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    // Show banners even while the app is "active" (menu bar popover open).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
