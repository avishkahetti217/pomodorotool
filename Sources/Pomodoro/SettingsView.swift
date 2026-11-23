import Charts
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: Hashable { case timer, display, shortcuts, blocking, stats }

/// Owns the settings window. A plain NSWindow is used because SwiftUI's `Settings`
/// scene doesn't reliably come to the front in menu-bar-only apps.
@MainActor
final class SettingsWindowController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    @Published var tab: SettingsTab = .timer
    private var window: NSWindow?

    func show(_ tab: SettingsTab) {
        self.tab = tab
        // Menu-bar-only apps can't bring windows forward reliably, so become a regular
        // app (Dock icon) while Settings is open, and go back when it closes.
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let state = AppState.shared
            let root = SettingsView()
                .environmentObject(state.settings)
                .environmentObject(state.stats)
                .environmentObject(state.timer)
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            w.title = "Pomodoro Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        // Let the menu bar popover finish closing before activating.
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
            self?.window?.orderFrontRegardless()
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct SettingsView: View {
    @ObservedObject private var router = SettingsWindowController.shared

    var body: some View {
        TabView(selection: $router.tab) {
            TimerSettingsView()
                .tabItem { Label("Timer", systemImage: "timer") }
                .tag(SettingsTab.timer)
            DisplaySettingsView()
                .tabItem { Label("Display", systemImage: "macwindow") }
                .tag(SettingsTab.display)
            ShortcutSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts)
            BlockingSettingsView()
                .tabItem { Label("Focus", systemImage: "moon") }
                .tag(SettingsTab.blocking)
            StatsView()
                .tabItem { Label("Statistics", systemImage: "chart.bar") }
                .tag(SettingsTab.stats)
        }
        .padding()
        .frame(width: 560, height: 540)
    }
}

// MARK: - Timer

struct TimerSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Durations") {
                MinutesRow(title: "Focus session", value: $settings.focusMinutes, range: 1...180)
                MinutesRow(title: "Short break", value: $settings.shortBreakMinutes, range: 1...60)
                MinutesRow(title: "Long break", value: $settings.longBreakMinutes, range: 1...120)
                LabeledContent("Long break after") {
                    HStack {
                        Text("\(settings.sessionsBeforeLongBreak) sessions").monospacedDigit()
                        Stepper("", value: $settings.sessionsBeforeLongBreak, in: 2...12).labelsHidden()
                    }
                }
            }

            Section {
                Toggle("Set a daily goal", isOn: $settings.dailyGoalEnabled)
                LabeledContent("Pomodoros per day") {
                    HStack {
                        Text("\(settings.dailyGoal)").monospacedDigit()
                        Stepper("", value: $settings.dailyGoal, in: 1...24).labelsHidden()
                    }
                }
                .disabled(!settings.dailyGoalEnabled)
            } header: {
                Text("Daily goal")
            } footer: {
                Text("\(settings.dailyGoal) sessions ≈ \(formatMinutes(Double(settings.dailyGoal * settings.focusMinutes * 60))) of focus. Progress shows in the popover and widget, with a bigger celebration when you hit it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Pause focus sessions when I'm away", isOn: $settings.idlePauseEnabled)
                LabeledContent("After no activity for") {
                    HStack {
                        Text("\(settings.idleMinutes) min").monospacedDigit()
                        Stepper("", value: $settings.idleMinutes, in: 1...30).labelsHidden()
                    }
                }
                .disabled(!settings.idlePauseEnabled)
            } header: {
                Text("Away detection")
            } footer: {
                Text("Also pauses when you lock the screen or the Mac sleeps. When you're back, choose to resume, count the time away as focus, or restart. Watching a video or reading without touching the keyboard can trigger it, so pick a duration that suits you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Automation") {
                Toggle("Start breaks automatically", isOn: $settings.autoStartBreaks)
                Toggle("Start the next focus session automatically", isOn: $settings.autoStartFocus)
            }

            Section {
                Picker("Show break screen", selection: $settings.breakScreenMode) {
                    ForEach(BreakScreenMode.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Darkness") {
                    HStack {
                        Slider(value: $settings.breakScreenOpacity, in: 0.6...1.0)
                            .frame(width: 160)
                        Text("\(Int(settings.breakScreenOpacity * 100))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(settings.breakScreenMode == .off)
                Toggle("Show a “Skip break” button", isOn: $settings.breakScreenAllowSkip)
                    .disabled(settings.breakScreenMode == .off)
            } header: {
                Text("Break screen")
            } footer: {
                Text("Darkens all displays during breaks and shows the break timer and a break idea, so you actually step away. It fades in a few seconds after focus ends, starts the break automatically, and disappears when the break is over. Your skip shortcut (⌃⌥S by default) always works.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Commit to full cycles", isOn: $settings.commitFullCycle)
            } header: {
                Text("Full-cycle commitment")
            } footer: {
                Text("When a short break ends, an alarm keeps ringing and a reminder stays on screen until you start the next focus session. It rings every few seconds, then every 15 seconds after 2 minutes. Need to step away? Choose “End full cycle” on the reminder, popover or widget to drop it for the current cycle. It switches back on with the next cycle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sound") {
                HStack {
                    Picker("End-of-session sound", selection: $settings.soundName) {
                        ForEach(SoundPlayer.names, id: \.self) { Text($0).tag($0) }
                    }
                    Button {
                        SoundPlayer.play(settings.soundName)
                    } label: {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    .help("Preview sound")
                    .disabled(settings.soundName == SoundPlayer.none)
                }
                Toggle("Also play when a break ends", isOn: $settings.soundAfterBreaks)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Button("Notification Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            } header: {
                Text("General")
            } footer: {
                Text("If you don't see end-of-session banners, allow notifications for Pomodoro in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't update login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct MinutesRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: $value, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                Text("min").foregroundStyle(.secondary)
                Stepper(title, value: $value, in: range).labelsHidden()
            }
        }
    }
}

// MARK: - Display

struct DisplaySettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Show the timer in", selection: $settings.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Toggle("Celebrate completed focus sessions", isOn: $settings.celebrateSessions)
                    Spacer()
                    Button("Preview") {
                        AppState.shared.celebration.show(Celebration(
                            completedInCycle: 2,
                            cycleLength: settings.sessionsBeforeLongBreak,
                            todayCount: 5,
                            isPersonalBest: true,
                            nextPhase: .shortBreak,
                            nextMinutes: settings.shortBreakMinutes,
                            tip: settings.showBreakTips ? BreakIdeas.random(for: .shortBreak) : nil,
                            dailyGoal: settings.activeDailyGoal
                        ))
                    }
                }
                Toggle("Suggest screen-free break ideas", isOn: $settings.showBreakTips)
            } header: {
                Text("Motivation")
            } footer: {
                Text("A short reward card appears for a few seconds after each focus session, showing how close you are to a full cycle. Break ideas appear as a single line during breaks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Floating widget") {
                Picker("Size", selection: $settings.widgetSize) {
                    ForEach(WidgetSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Opacity") {
                    HStack {
                        Slider(value: $settings.widgetOpacity, in: 0.4...1.0)
                            .frame(width: 180)
                        Text("\(Int(settings.widgetOpacity * 100))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("Move to corner") {
                    HStack(spacing: 6) {
                        ForEach(ScreenCorner.allCases) { corner in
                            Button {
                                AppState.shared.widget.move(to: corner)
                            } label: {
                                Image(systemName: corner.symbol).frame(width: 18)
                            }
                            .help(corner.label)
                        }
                    }
                }
                Text("Drag the widget anywhere on screen; its position is remembered. Hover it for skip and more options, or right-click it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.displayMode.showsWidget)
        }
        .formStyle(.grouped)
    }

    private var footer: String {
        switch settings.displayMode {
        case .menuBar:
            return "A countdown in the menu bar. Click it for controls and today's count."
        case .floating:
            return "A small always-on-top card with the countdown and a progress bar. With the menu bar item off, open Pomodoro again from Spotlight or Launchpad to get back to Settings."
        case .both:
            return "Countdown in the menu bar and the floating widget on screen."
        }
    }
}

// MARK: - Shortcuts

struct ShortcutSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.label) {
                        ShortcutRecorder(action: action)
                    }
                }
            } header: {
                Text("Global keyboard shortcuts")
            } footer: {
                Text("These work from any app, with no extra permissions. Click a shortcut, then press a new combination that includes ⌘, ⌥ or ⌃. Esc cancels, ⌫ removes it. A ⚠︎ means another app already uses that combination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Restore Defaults") {
                    settings.shortcuts = Shortcut.defaults
                }
            } footer: {
                Text("Defaults: ⌃⌥P start/pause, ⌃⌥S skip, ⌃⌥R restart. When the floating widget is hidden, a small card briefly confirms what a shortcut did.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Blocking

struct BlockingSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    private var list: Binding<[ListedApp]> {
        settings.blockMode == .blocklist ? $settings.blockedApps : $settings.allowedApps
    }

    var body: some View {
        Form {
            FocusModeSettingsSection()

            Section {
                Toggle("Block distracting apps during focus sessions", isOn: $settings.blockingEnabled)
            } footer: {
                Text("Rules apply only while a focus session is running. Breaks and paused sessions are unrestricted. Finder and System Settings are always allowed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Rules") {
                Picker("Mode", selection: $settings.blockMode) {
                    ForEach(BlockMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("When a blocked app opens", selection: $settings.blockAction) {
                    ForEach(BlockAction.allCases) { Text($0.label).tag($0) }
                }
            }
            .disabled(!settings.blockingEnabled)

            Section(settings.blockMode == .blocklist ? "Blocked apps" : "Allowed apps") {
                if list.wrappedValue.isEmpty {
                    Text(settings.blockMode == .blocklist
                         ? "No apps blocked yet. Add apps that distract you."
                         : "No apps allowed yet. Every app except Finder will be blocked.")
                        .foregroundStyle(.secondary)
                }
                ForEach(list.wrappedValue) { app in
                    HStack {
                        AppIcon(bundleID: app.bundleID)
                        Text(app.name)
                        Spacer()
                        Button {
                            list.wrappedValue.removeAll { $0.bundleID == app.bundleID }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
                HStack {
                    Menu("Add Running App") {
                        let candidates = runningApps()
                        if candidates.isEmpty { Text("No other apps running") }
                        ForEach(candidates) { app in
                            Button(app.name) { add([app]) }
                        }
                    }
                    .fixedSize()
                    Button("Choose from Applications…") { chooseApps() }
                }
            }
            .disabled(!settings.blockingEnabled)
        }
        .formStyle(.grouped)
    }

    private func add(_ apps: [ListedApp]) {
        for app in apps where !list.wrappedValue.contains(where: { $0.bundleID == app.bundleID }) {
            list.wrappedValue.append(app)
        }
        list.wrappedValue.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func runningApps() -> [ListedApp] {
        let existing = Set(list.wrappedValue.map(\.bundleID))
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> ListedApp? in
                guard let id = app.bundleIdentifier,
                      id != Bundle.main.bundleIdentifier,
                      !AppBlocker.alwaysAllowed.contains(id),
                      !existing.contains(id),
                      seen.insert(id).inserted else { return nil }
                return ListedApp(bundleID: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let apps = panel.urls.compactMap { url -> ListedApp? in
            guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
            return ListedApp(bundleID: id, name: url.deletingPathExtension().lastPathComponent)
        }
        add(apps)
    }
}

struct AppIcon: View {
    let bundleID: String

    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
    }
}

// MARK: - Statistics

struct StatsView: View {
    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var settings: AppSettings
    @State private var confirmReset = false

    var body: some View {
        let history = stats.history(days: 14)
        let week = history.suffix(7).reduce(0) { $0 + $1.stats.pomodoros }

        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                StatTile(title: "Today", value: "\(stats.today.pomodoros)", caption: "pomodoros")
                StatTile(title: "Focused today", value: formatMinutes(stats.today.focusSeconds), caption: "of focus time")
                StatTile(title: "Last 7 days", value: "\(week)", caption: goalCaption(history))
                StatTile(title: "Streak", value: "\(stats.currentStreak)", caption: stats.currentStreak == 1 ? "day" : "days")
            }

            Text("Last 14 days").font(.headline)
            Chart(history) { entry in
                BarMark(
                    x: .value("Day", entry.date, unit: .day),
                    y: .value("Pomodoros", entry.stats.pomodoros)
                )
                .foregroundStyle(Phase.focus.color.gradient)
                .cornerRadius(4)

                if let goal = settings.activeDailyGoal {
                    RuleMark(y: .value("Goal", goal))
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("Goal \(goal)").font(.caption2).foregroundStyle(.orange)
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 240)

            HStack {
                Text("All-time total: \(stats.totalPomodoros) pomodoros")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset Today…", role: .destructive) { confirmReset = true }
            }
        }
        .padding()
        .confirmationDialog("Reset today's count?", isPresented: $confirmReset) {
            Button("Reset Today", role: .destructive) { stats.resetToday() }
        } message: {
            Text("This clears today's pomodoros and focus time. Other days are kept.")
        }
    }
}

extension StatsView {
    func goalCaption(_ history: [DayEntry]) -> String {
        guard let goal = settings.activeDailyGoal else { return "pomodoros" }
        let met = history.suffix(7).filter { $0.stats.pomodoros >= goal }.count
        return "goal met \(met) of 7 days"
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}
