import SwiftUI

@MainActor
final class AppState {
    static let shared = AppState()

    let settings: AppSettings
    let stats: StatsStore
    let notifier: Notifier
    let blocker: AppBlocker
    let timer: PomodoroTimer
    let widget: FloatingWidgetController
    let celebration: CelebrationController
    let away: AwayController
    let hotkeys: HotKeyManager
    let alarm: AlarmController
    let breakScreen: BreakScreenController
    let focusMode: FocusModeController

    private init() {
        settings = AppSettings()
        stats = StatsStore()
        notifier = Notifier()
        blocker = AppBlocker(settings: settings, notifier: notifier)
        timer = PomodoroTimer(settings: settings, stats: stats, notifier: notifier, blocker: blocker)
        widget = FloatingWidgetController(settings: settings, timer: timer)
        celebration = CelebrationController(widget: widget)
        away = AwayController(widget: widget, timer: timer)
        hotkeys = HotKeyManager(settings: settings, timer: timer, widget: widget)
        alarm = AlarmController(widget: widget, timer: timer, settings: settings)
        breakScreen = BreakScreenController(timer: timer, settings: settings, stats: stats)
        focusMode = FocusModeController(timer: timer, settings: settings)
        timer.onFocusCompleted = { [celebration] in celebration.show($0) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.notifier.setUp()
        AppState.shared.widget.start()
        AppState.shared.hotkeys.start()
        AppState.shared.breakScreen.start()
        AppState.shared.focusMode.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.focusMode.turnOffIfNeeded()
    }

    /// Opening the app again (Spotlight, Launchpad, Finder) shows Settings, so it's always
    /// reachable even when the menu bar item is turned off.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show(.display)
        return true
    }
}

@main
struct PomodoroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let state = AppState.shared
    @StateObject private var settings = AppState.shared.settings

    var body: some Scene {
        MenuBarExtra(isInserted: $settings.showsMenuBarItem) {
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
