import SwiftUI

@MainActor
final class AppState {
    static let shared = AppState()

    let settings: AppSettings
    let stats: StatsStore
    let notifier: Notifier
    let blocker: AppBlocker
    let timer: PomodoroTimer

    private init() {
        settings = AppSettings()
        stats = StatsStore()
        notifier = Notifier()
        blocker = AppBlocker(settings: settings, notifier: notifier)
        timer = PomodoroTimer(settings: settings, stats: stats, notifier: notifier, blocker: blocker)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.notifier.setUp()
    }
}

@main
struct PomodoroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(state.timer)
                .environmentObject(state.settings)
                .environmentObject(state.stats)
        } label: {
            MenuBarLabel(timer: state.timer)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The countdown shown in the macOS menu bar.
struct MenuBarLabel: View {
    @ObservedObject var timer: PomodoroTimer

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: timer.state == .paused ? "pause.circle" : timer.phase.symbol)
            Text(timer.timeString).monospacedDigit()
        }
    }
}
