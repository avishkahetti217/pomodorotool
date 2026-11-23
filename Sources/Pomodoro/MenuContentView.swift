import SwiftUI

extension Phase {
    var color: Color {
        switch self {
        case .focus: return Color(red: 0.91, green: 0.30, blue: 0.24)
        case .shortBreak: return Color(red: 0.20, green: 0.66, blue: 0.45)
        case .longBreak: return Color(red: 0.25, green: 0.48, blue: 0.85)
        }
    }
}

/// The popover shown when clicking the menu bar item.
struct MenuContentView: View {
    @EnvironmentObject private var timer: PomodoroTimer
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var stats: StatsStore

    var body: some View {
        VStack(spacing: 14) {
            header
            dial
            cycleDots
            if let tip = timer.visibleBreakTip {
                breakIdea(tip)
            }
            controls
            Divider()
            todaySummary
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 290)
    }

    private var header: some View {
        HStack {
            Label(timer.phase.title, systemImage: timer.phase.symbol)
                .font(.headline)
                .foregroundStyle(timer.phase.color)
            Spacer()
            if timer.isBlockingActive {
                Label("Blocking", systemImage: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("App blocking is active for this focus session")
            }
        }
    }

    private var dial: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 10)
            Circle()
                .trim(from: 0, to: timer.progress)
                .stroke(timer.phase.color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: timer.progress)
            VStack(spacing: 2) {
                Text(timer.timeString)
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 170, height: 170)
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch timer.state {
        case .idle: return "Ready"
        case .running: return timer.phase.isBreak ? "Relax" : "Stay focused"
        case .paused: return "Paused"
        }
    }

    private var cycleDots: some View {
        let total = settings.sessionsBeforeLongBreak
        let current = min(timer.completedInCycle + (timer.phase == .focus ? 1 : 0), total)
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(0..<total, id: \.self) { i in
                    Circle()
                        .fill(i < timer.completedInCycle ? Phase.focus.color : Color.secondary.opacity(0.25))
                        .frame(width: 9, height: 9)
                }
            }
            Text(cycleCaption(current: max(current, 1), total: total))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func cycleCaption(current: Int, total: Int) -> String {
        switch timer.phase {
        case .longBreak:
            return "Full cycle complete 🎉"
        case .shortBreak:
            let left = timer.sessionsLeftInCycle
            return left == 1 ? "Just 1 more session to a full cycle" : "\(left) more sessions to a full cycle"
        case .focus:
            return "Session \(current) of \(total)"
        }
    }

    private func breakIdea(_ tip: String) -> some View {
        Label {
            Text(tip)
        } icon: {
            Image(systemName: timer.phase == .longBreak ? "figure.walk" : "leaf.fill")
                .foregroundStyle(timer.phase.color)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(timer.phase.color.opacity(0.1)))
    }

    private func hint(_ action: HotKeyAction) -> String {
        settings.shortcuts[action.rawValue].map { "  (\($0.display))" } ?? ""
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { timer.reset() } label: {
                Image(systemName: "arrow.counterclockwise").frame(width: 22)
            }
            .help("Restart this \(timer.phase.isBreak ? "break" : "session")" + hint(.restart))
            .disabled(timer.state == .idle)

            Button { timer.toggle() } label: {
                Label(timer.primaryActionTitle, systemImage: timer.state == .running ? "pause.fill" : "play.fill")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .tint(timer.phase.color)
            .keyboardShortcut(.space, modifiers: [])
            .help(timer.primaryActionTitle + hint(.toggle))

            Button { timer.skip() } label: {
                Image(systemName: "forward.end.fill").frame(width: 22)
            }
            .help((timer.phase.isBreak ? "Skip break" : "Skip to break (won't count as completed)") + hint(.skip))
        }
        .controlSize(.large)
    }

    private var todaySummary: some View {
        let today = stats.today
        return VStack(spacing: 8) {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today").font(.caption).foregroundStyle(.secondary)
                Text("\(today.pomodoros) \(today.pomodoros == 1 ? "pomodoro" : "pomodoros")")
                    .font(.title3.weight(.semibold))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Focused").font(.caption).foregroundStyle(.secondary)
                Text(formatMinutes(today.focusSeconds)).font(.title3.weight(.semibold))
            }
        }
            if let goal = settings.activeDailyGoal {
                goalProgress(count: today.pomodoros, goal: goal)
            }
        }
    }

    private func goalProgress(count: Int, goal: Int) -> some View {
        let fraction = min(1, Double(count) / Double(goal))
        let met = count >= goal
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(met ? Color.orange : Phase.focus.color)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 6)
            Text(met ? "Daily goal reached 🏆" + (count > goal ? " · \(count - goal) bonus" : "")
                     : "\(goal - count) more to your daily goal of \(goal)")
                .font(.caption)
                .foregroundStyle(met ? Color.orange : Color.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Statistics") { SettingsWindowController.shared.show(.stats) }
            Button("Settings…") { SettingsWindowController.shared.show(.timer) }
                .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Menu {
                Button("Reset Cycle") { timer.resetCycle() }
                Divider()
                Button("Quit Pomodoro") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

func formatMinutes(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes) min" }
    return "\(minutes / 60)h \(minutes % 60)m"
}
