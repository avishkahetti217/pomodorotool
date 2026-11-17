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
            Text(timer.phase == .longBreak
                 ? "Cycle complete"
                 : "Session \(max(current, 1)) of \(total) · long break after \(total)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { timer.reset() } label: {
                Image(systemName: "arrow.counterclockwise").frame(width: 22)
            }
            .help("Restart this \(timer.phase.isBreak ? "break" : "session")")
            .disabled(timer.state == .idle)

            Button { timer.toggle() } label: {
                Label(primaryTitle, systemImage: timer.state == .running ? "pause.fill" : "play.fill")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .tint(timer.phase.color)
            .keyboardShortcut(.space, modifiers: [])

            Button { timer.skip() } label: {
                Image(systemName: "forward.end.fill").frame(width: 22)
            }
            .help(timer.phase.isBreak ? "Skip break" : "Skip to break (won't count as completed)")
        }
        .controlSize(.large)
    }

    private var primaryTitle: String {
        switch timer.state {
        case .idle: return timer.phase.isBreak ? "Start Break" : "Start Focus"
        case .running: return "Pause"
        case .paused: return "Resume"
        }
    }

    private var todaySummary: some View {
        let today = stats.today
        return HStack {
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
